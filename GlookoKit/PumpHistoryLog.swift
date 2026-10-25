import Foundation

/// A dose as Loop's reconciled insulin-delivery stream reports it, without LoopKit types.
public struct SourceDose: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case basal, tempBasal, suspend, resume, bolus }

    /// Loop `syncIdentifier`; stable across updates of the same dose.
    public var id: String
    public var kind: Kind
    public var start: Date
    public var end: Date
    /// U/h for basal and temporary basal.
    public var rate: Double?
    /// Programmed units for a bolus.
    public var programmed: Double
    /// Delivered units when the pump reported them.
    public var delivered: Double?
    public var automatic: Bool?
    /// Still changing (running temp basal, bolus in progress); never committed to history.
    public var isMutable: Bool

    public init(id: String, kind: Kind, start: Date, end: Date, rate: Double? = nil, programmed: Double = 0,
                delivered: Double? = nil, automatic: Bool? = nil, isMutable: Bool = false) {
        self.id = id; self.kind = kind; self.start = start; self.end = end; self.rate = rate
        self.programmed = programmed; self.delivered = delivered; self.automatic = automatic; self.isMutable = isMutable
    }
}

/// The durable history of one virtual PDM, persisted by its owner.
///
/// Glooko's InsuletOmnipod importer behaves like a PDM download: every upload is a complete, chronological
/// history whose records keep their indices. Verified against the test account (records 1000-1030,
/// .log/261025-1645): repeated records are not duplicated, a record flagged in progress is held back and
/// ingested with its final duration later, and a day's server summary appears once its last record is final.
///
/// So committed records never change. Doses are committed only once settled: older than `settleDelay`
/// and before the start of any dose Loop still reports as mutable.
public struct PumpHistoryLog: Codable, Equatable, Sendable {
    public var serial: UInt32
    public var powerUp: Date
    public var podLot: UInt16
    public var podSerial: UInt16
    public var nextIndex: UInt32
    /// Committed history, chronological. Pruned to `retention` when building a file.
    public private(set) var records: [IBFHistoryEvent]
    /// End of the committed period; nothing before it can be added.
    public private(set) var committedThrough: Date?
    /// Delivery in effect at `committedThrough`.
    public private(set) var state: DeliveryTimeline.State?
    /// Doses received but not yet wholly committed, by Loop sync identifier.
    public private(set) var pending: [String: SourceDose]
    /// Doses that arrived for an already committed period; counted so the loss is visible, never silent.
    public private(set) var lateDoses: Int
    /// Sync identifiers already (at least partly) in history, with their end, for recognising resends.
    public private(set) var committed: [String: Date]
    /// Index of the last record included in an acknowledged upload.
    public var lastUploadedIndex: UInt32?
    /// Nothing earlier is sent. Loop's stores can hold pump-simulator or pre-pairing delivery
    /// (its basal overlay fills back to the last reconciliation), which must never reach a real account.
    public var historyStart: Date?

    public init(serial: UInt32, powerUp: Date, podLot: UInt16, podSerial: UInt16, firstIndex: UInt32 = 1) {
        self.serial = serial; self.powerUp = powerUp; self.podLot = podLot; self.podSerial = podSerial
        nextIndex = firstIndex; records = []; pending = [:]; lateDoses = 0; committed = [:]
    }

    /// Fixed origin for seconds-since-power-up; well before any history Loop can still hold.
    public static let defaultPowerUp = Date(timeIntervalSince1970: 1_577_836_800)   // 1 January 2020

    /// A new identity in the synthetic range used by the verified experiments, so it never collides with a real PDM.
    public static func newIdentity() -> PumpHistoryLog {
        PumpHistoryLog(serial: UInt32.random(in: 900_000_000...999_999_999), powerUp: defaultPowerUp,
                       podLot: UInt16.random(in: 1000...65000), podSerial: UInt16.random(in: 1000...65000), firstIndex: 1000)
    }

    public var hasUnuploadedRecords: Bool {
        guard let last = records.last else { return false }
        return lastUploadedIndex.map { last.index > $0 } ?? true
    }

    /// Records Loop's created and deleted doses. Manually entered (non-pump) doses must be filtered by the caller.
    public mutating func ingest(created: [SourceDose], deleted: [SourceDose] = []) {
        for dose in deleted { pending[dose.id] = nil }
        for var dose in created where dose.kind != .resume {
            if let historyStart {
                if dose.end <= historyStart || (dose.kind == .bolus && dose.start < historyStart) { continue }
                dose.start = max(dose.start, historyStart)
            }
            if let committedThrough, dose.end <= committedThrough || (dose.kind == .bolus && dose.start < committedThrough) {
                // Loop resends doses (backfill, updates); only a dose history has never seen is a loss.
                if committed[dose.id] == nil { lateDoses += 1 }
                continue
            }
            pending[dose.id] = dose
        }
    }

    /// Moves settled doses into history and returns how many records were added.
    @discardableResult
    public mutating func commit(now: Date, timeZone: TimeZone, settleDelay: TimeInterval = 60 * 60) -> Int {
        var horizon = now.addingTimeInterval(-settleDelay)
        // Loop's basal overlay inserts scheduled entries only between later doses, so the newest scheduled
        // period is unreported until the next dose. Never commit past reported delivery, or that period
        // would be written as a suspension.
        let delivery = pending.values.filter { $0.kind == .basal || $0.kind == .tempBasal || $0.kind == .suspend }
        let reported = delivery.map { $0.isMutable ? $0.start : $0.end }.max()
        horizon = min(horizon, max(reported ?? .distantPast, committedThrough ?? .distantPast))
        // Mutable doses can still be truncated, replaced or deleted.
        for dose in pending.values where dose.isMutable { horizon = min(horizon, dose.start) }
        let start = committedThrough ?? pending.values.map(\.start).min()
        guard let start, horizon > start else { return 0 }

        var intervals: [DeliveryTimeline.Interval] = []
        var boluses: [DeliveryTimeline.Bolus] = []
        for dose in pending.values {
            switch dose.kind {
            case .basal: intervals.append(.init(start: dose.start, end: dose.end, delivery: .scheduled(rate: dose.rate ?? 0), id: dose.id))
            case .tempBasal: intervals.append(.init(start: dose.start, end: dose.end, delivery: .temporary(rate: dose.rate ?? 0), id: dose.id))
            case .suspend: intervals.append(.init(start: dose.start, end: dose.end, delivery: .suspended, id: dose.id))
            case .resume: break
            case .bolus:
                guard dose.start >= start, dose.start < horizon else { continue }
                boluses.append(.init(start: dose.start, end: dose.end, delivered: dose.delivered ?? dose.programmed,
                                     programmed: max(dose.programmed, dose.delivered ?? 0)))
            }
        }
        let window = DeliveryTimeline.window(intervals: intervals, boluses: boluses, timeZone: timeZone,
                                             from: start, initial: state, through: horizon)
        var added: [IBFHistoryEvent] = []
        if committedThrough == nil {
            added.append(event(start, .activate(lot: podLot, serial: podSerial), timeZone))
        }
        for record in window.records { added.append(event(record.date, record.record, timeZone)) }
        records += added
        for dose in pending.values where dose.start < horizon { committed[dose.id] = dose.end }
        committedThrough = horizon
        state = window.final
        pending = pending.filter { $0.value.end > horizon && !($0.value.kind == .bolus && $0.value.start < horizon) }
        return added.count
    }

    private mutating func event(_ date: Date, _ record: IBFRecord, _ zone: TimeZone) -> IBFHistoryEvent {
        defer { nextIndex += 1 }
        return IBFHistoryEvent(index: nextIndex, date: date, record: record, utcOffset: zone.secondsFromGMT(for: date))
    }

    /// Appends a Download record and returns the complete file. The download stays in history, as on a PDM,
    /// so later indices are unaffected by whether this upload succeeds.
    public mutating func exportFile(timeZone: TimeZone, retention: TimeInterval = 14 * 86400,
                                    basalProgram: [Double]? = nil) throws -> (data: Data, lastIndex: UInt32)? {
        guard hasUnuploadedRecords, let committedThrough else { return nil }
        if case .download? = records.last?.record {} else {
            records.append(event(max(committedThrough, records.last?.date ?? committedThrough), .download, timeZone))
        }
        if let first = records.first?.date, first < powerUp { powerUp = first }   // logs made before the fixed origin
        let cutoff = committedThrough.addingTimeInterval(-retention)
        records.removeAll { $0.date < cutoff }
        committed = committed.filter { $0.value >= cutoff }
        var history = records
        if state?.isDelivering == true, let i = history.lastIndex(where: { if case .basal = $0.record { return true } else { return false } }) {
            history[i].inProgress = true
        }
        let document = PumpHistoryIBF(serial: serial, timeZone: timeZone, powerUp: powerUp,
                                      basalProgram: basalProgram ?? Array(repeating: 0, count: 48), events: history)
        return (try document.encode(), history.last!.index)
    }
}
