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
    public var sourceID: String?
    /// Still changing (running temp basal, bolus in progress); never committed to history.
    public var isMutable: Bool

    public init(id: String, kind: Kind, start: Date, end: Date, rate: Double? = nil, programmed: Double = 0,
                delivered: Double? = nil, automatic: Bool? = nil, isMutable: Bool = false, sourceID: String? = nil) {
        self.id = id; self.kind = kind; self.start = start; self.end = end; self.rate = rate
        self.programmed = programmed; self.delivered = delivered; self.automatic = automatic; self.isMutable = isMutable; self.sourceID = sourceID
    }
}

/// A recoverable source mutation which cannot safely change already submitted PDM indices.
public struct HistoryConflict: Codable, Equatable, Sendable {
    public var original: SourceDose?
    public var replacement: SourceDose?
    public var deletion: Bool
    public var reason: String
}

/// Durable responsibility for source doses, immutable submitted indices and explicit source conflicts.
public struct PumpHistoryLog: Codable, Equatable, Sendable {
    public var schemaVersion = 4
    public var ownerID: String?
    public var ownerEmail: String?
    public var sourceID: String?
    public var reportingContextData: Data?
    public var serial: UInt32
    public var powerUp: Date
    public var podLot: UInt16
    public var podSerial: UInt16
    public var nextIndex: UInt32
    public private(set) var records: [IBFHistoryEvent]
    public private(set) var committedThrough: Date?
    public private(set) var state: DeliveryTimeline.State?
    public private(set) var pending: [String: SourceDose]
    public private(set) var committed: [String: Date]
    public private(set) var sourceDoses: [String: SourceDose] = [:]
    public private(set) var conflicts: [String: HistoryConflict] = [:]
    public private(set) var unclassified: [String: SourceDose] = [:]
    public private(set) var stagedDeletions: [String: SourceDose] = [:]
    private var droppedIDs: Set<String> = []
    private var legacyIDs: Set<String> = []
    private var legacyLateDoses = 0
    /// Submission intent is persisted before the request, including ambiguous network failures.
    public var lastSubmittedIndex: UInt32? {
        didSet { submittedThrough = nil; submittedState = nil; submittedIDs = nil }
    }
    private var submittedThrough: Date?
    private var submittedState: DeliveryTimeline.State?
    private var submittedIDs: Set<String>?
    /// Highest contiguous native prefix verified by readback; deferred intervals remain protected from pruning.
    public var lastUploadedIndex: UInt32?
    /// A file may have passed verification of its final rows while its newest interval is deferred.
    public private(set) var lastVerifiedFileIndex: UInt32?
    public var historyStart: Date?
    /// Native marker repairs change only the exported view; original submitted records remain here.
    public private(set) var repairedBasalIndices: Set<UInt32> = []
    public private(set) var ingestionCorrections: [String: IngestionCorrection] = [:]
    public var lateDoses: Int { legacyLateDoses + droppedIDs.count }

    public init(serial: UInt32, powerUp: Date, podLot: UInt16, podSerial: UInt16, firstIndex: UInt32 = 1) {
        self.serial = serial; self.powerUp = powerUp; self.podLot = podLot; self.podSerial = podSerial
        nextIndex = firstIndex; records = []; pending = [:]; committed = [:]
    }

    public static let defaultPowerUp = Date(timeIntervalSince1970: 1_577_836_800)
    public static func newIdentity() -> PumpHistoryLog {
        PumpHistoryLog(serial: UInt32.random(in: 900_000_000...999_999_999), powerUp: defaultPowerUp,
                       podLot: UInt16.random(in: 1000...65000), podSerial: UInt16.random(in: 1000...65000), firstIndex: 1000)
    }

    public var hasUnuploadedRecords: Bool {
        records.last.map { $0.index > max(lastUploadedIndex ?? 0, lastVerifiedFileIndex ?? 0) } ?? false
    }

    /// Own the source callback durably before its settings/source stream has caught up.
    public mutating func stage(created: [SourceDose], deleted: [SourceDose]) {
        for dose in deleted { unclassified[dose.id] = nil; stagedDeletions[dose.id] = dose }
        for dose in created { stagedDeletions[dose.id] = nil; unclassified[dose.id] = dose }
    }

    public mutating func classifyStaged(resolve: (SourceDose) -> String?) {
        let deletions = Array(stagedDeletions.values)
        stagedDeletions = [:]
        ingest(created: [], deleted: deletions)
        for var dose in Array(unclassified.values) {
            guard let resolved = resolve(dose) else { continue }
            dose.sourceID = resolved
            unclassified[dose.id] = nil
            ingest(created: [dose])
        }
    }

    public func blockedReason(now: Date) -> String? {
        if !conflicts.isEmpty {
            return "\(conflicts.count) source change(s) need review. Original records and changes are retained; uploads are paused."
        }
        if let oldest = pending.values.filter({ $0.isMutable }).map(\.start).min(), now.timeIntervalSince(oldest) > 6 * 3600 {
            return "A pump dose has remained provisional for over six hours. Reconnect to the pump to finalise it; history is retained."
        }
        return nil
    }

    /// Replays are deduplicated by identity and clinical content. Unsupported remote mutations remain durable.
    public mutating func ingest(created: [SourceDose], deleted: [SourceDose] = []) {
        captureSubmissionCheckpoint()
        for dose in deleted {
            if committed[dose.id] != nil {
                if !wasSubmitted(dose.id) {
                    sourceDoses[dose.id] = nil
                    conflicts[dose.id] = nil
                    rebuildUnsubmitted()
                } else {
                    conflicts[dose.id] = .init(original: sourceDoses[dose.id], replacement: nil, deletion: true,
                                               reason: "A submitted dose was deleted in Loop")
                }
            } else {
                pending[dose.id] = nil
                sourceDoses[dose.id] = nil
                conflicts[dose.id] = nil
            }
        }
        for var dose in created where dose.kind != .resume {
            let duration = dose.end.timeIntervalSince(dose.start)
            guard dose.start.timeIntervalSince1970.isFinite, dose.end.timeIntervalSince1970.isFinite, duration >= 0,
                  dose.programmed.isFinite, dose.programmed >= 0,
                  dose.delivered.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  dose.rate.map({ $0.isFinite && $0 >= 0 && $0 < 65535 }) ?? true else {
                conflicts[dose.id] = .init(original: sourceDoses[dose.id], replacement: nil, deletion: false,
                                           reason: "The source dose has invalid quantities or dates")
                continue
            }
            if committed[dose.id] != nil, !wasSubmitted(dose.id), let boundary = submissionBoundary, dose.start < boundary {
                conflicts[dose.id] = .init(original: sourceDoses[dose.id], replacement: dose, deletion: false,
                                           reason: "A dose moved into an already submitted period")
                continue
            }
            if let historyStart {
                if (dose.end <= historyStart && !(dose.isMutable && dose.start == historyStart)) || (dose.kind == .bolus && dose.start < historyStart) {
                    if sourceDoses[dose.id] != nil || committed[dose.id] != nil {
                        if wasSubmitted(dose.id) {
                            conflicts[dose.id] = .init(original: sourceDoses[dose.id], replacement: dose, deletion: false,
                                                       reason: "A submitted dose moved outside the reporting period")
                        } else {
                            sourceDoses[dose.id] = nil; pending[dose.id] = nil; conflicts[dose.id] = nil
                            if committed[dose.id] != nil { rebuildUnsubmitted() }
                        }
                    }
                    continue
                }
                if dose.start < historyStart, duration > 0 {
                    dose.delivered = dose.delivered.map { $0 * dose.end.timeIntervalSince(historyStart) / duration }
                    dose.start = historyStart
                }
            }
            if let sourceID, dose.sourceID != sourceID {
                conflicts[dose.id] = .init(original: sourceDoses[dose.id], replacement: dose, deletion: false,
                                           reason: "The dose belongs to a simulator, an unknown source or another pump")
                continue
            }
            if let original = sourceDoses[dose.id], clinicallyEqual(original, dose) {
                // Finalisation still replaces a mutable marker even if its quantities are unchanged.
                if pending[dose.id] != nil { pending[dose.id] = dose }
                sourceDoses[dose.id] = dose
                conflicts[dose.id] = nil
                continue
            }
            if legacyIDs.contains(dose.id), sourceDoses[dose.id] == nil, matchesLegacyRecords(dose) {
                sourceDoses[dose.id] = dose
                conflicts[dose.id] = nil
                continue
            }
            if committed[dose.id] != nil {
                if !wasSubmitted(dose.id) {
                    sourceDoses[dose.id] = dose
                    conflicts[dose.id] = nil
                    rebuildUnsubmitted()
                } else {
                    conflicts[dose.id] = .init(original: sourceDoses[dose.id], replacement: dose, deletion: false,
                                               reason: "A submitted dose changed in Loop")
                }
                continue
            }
            if let committedThrough, dose.start < committedThrough {
                droppedIDs.insert(dose.id)
                conflicts[dose.id] = .init(original: nil, replacement: dose, deletion: false,
                                           reason: "A previously unseen dose arrived for a submitted period")
                if lastSubmittedIndex == nil || submissionBoundary.map({ dose.start >= $0 }) == true {
                    sourceDoses[dose.id] = dose
                    conflicts[dose.id] = nil
                    droppedIDs.remove(dose.id)
                    rebuildUnsubmitted()
                }
                continue
            }
            sourceDoses[dose.id] = dose
            pending[dose.id] = dose
            conflicts[dose.id] = nil
        }
    }

    /// Called only after the service has durably drained the available source query, never per page.
    @discardableResult
    public mutating func commit(now: Date, timeZone: TimeZone, settleDelay: TimeInterval = 60 * 60) -> Int {
        guard conflicts.isEmpty, unclassified.isEmpty, stagedDeletions.isEmpty else { return 0 }
        var horizon = Date(timeIntervalSince1970: floor(now.addingTimeInterval(-settleDelay).timeIntervalSince1970))
        let delivery = pending.values.filter { $0.kind == .basal || $0.kind == .tempBasal || $0.kind == .suspend }
        let reported = delivery.map { $0.isMutable ? $0.start : $0.end }.max()
        horizon = min(horizon, max(reported ?? .distantPast, committedThrough ?? .distantPast))
        for dose in pending.values where dose.isMutable || (dose.kind == .bolus && dose.end > horizon) {
            horizon = min(horizon, dose.start)
        }
        // Source caps retain fractions; native delivery boundaries represent whole seconds only.
        // Keep the remainder pending instead of inventing a suspension at the end of this window.
        horizon = Date(timeIntervalSince1970: floor(horizon.timeIntervalSince1970))
        let start = committedThrough ?? pending.values.map(\.start).min()
        guard let start, horizon > start else { return 0 }
        var intervals: [DeliveryTimeline.Interval] = []
        var boluses: [DeliveryTimeline.Bolus] = []
        for dose in pending.values {
            let rate = dose.delivered.flatMap { dose.end > dose.start ? $0 * 3600 / dose.end.timeIntervalSince(dose.start) : nil } ?? dose.rate ?? 0
            switch dose.kind {
            case .basal: intervals.append(.init(start: dose.start, end: dose.end, delivery: .scheduled(rate: rate), id: dose.id))
            case .tempBasal: intervals.append(.init(start: dose.start, end: dose.end, delivery: .temporary(rate: rate), id: dose.id))
            case .suspend: intervals.append(.init(start: dose.start, end: dose.end, delivery: .suspended, id: dose.id))
            case .resume: break
            case .bolus:
                guard dose.start >= start, dose.start < horizon, dose.end <= horizon, !dose.isMutable else { continue }
                boluses.append(.init(start: dose.start, end: dose.end, delivered: dose.delivered ?? dose.programmed,
                                     programmed: max(dose.programmed, dose.delivered ?? 0)))
            }
        }
        let window = DeliveryTimeline.window(intervals: intervals, boluses: boluses, timeZone: timeZone,
                                             from: start, initial: state, through: horizon)
        var added: [IBFHistoryEvent] = []
        if committedThrough == nil { added.append(event(start, .activate(lot: podLot, serial: podSerial), timeZone)) }
        for record in window.records { added.append(event(record.date, record.record, timeZone)) }
        records += added
        for dose in pending.values where !dose.isMutable && dose.start < horizon { committed[dose.id] = dose.end }
        committedThrough = horizon
        state = window.final
        pending = pending.filter { $0.value.isMutable || $0.value.start >= horizon || $0.value.end > horizon }
        return added.count
    }

    private func clinicallyEqual(_ lhs: SourceDose, _ rhs: SourceDose) -> Bool {
        let tolerance = legacyIDs.contains(lhs.id) ? 1.0 : 0.001
        func rate(_ dose: SourceDose) -> Double {
            dose.delivered.flatMap { dose.end > dose.start ? $0 * 3600 / dose.end.timeIntervalSince(dose.start) : nil } ?? dose.rate ?? 0
        }
        guard lhs.kind == rhs.kind, abs(lhs.start.timeIntervalSince(rhs.start)) < tolerance,
              abs(lhs.end.timeIntervalSince(rhs.end)) < tolerance else { return false }
        if lhs.kind == .bolus {
            return lhs.programmed == rhs.programmed && (lhs.delivered ?? lhs.programmed) == (rhs.delivered ?? rhs.programmed)
        }
        // Earlier stores rounded dates to milliseconds. An unchanged measured volume is still the same
        // delivery even if that rounding slightly changes its reconstructed effective rate.
        if let left = lhs.delivered, let right = rhs.delivered { return abs(left - right) < 1e-8 }
        return abs(rate(lhs) - rate(rhs)) < (legacyIDs.contains(lhs.id) ? 0.0001 : 1e-8)
    }

    private func matchesLegacyRecords(_ dose: SourceDose) -> Bool {
        guard let end = committed[dose.id], abs(end.timeIntervalSince(dose.end)) < 1 else { return false }
        let rate = dose.delivered.flatMap { dose.end > dose.start ? $0 * 3600 / dose.end.timeIntervalSince(dose.start) : nil } ?? dose.rate ?? 0
        return records.contains { event in
            guard abs(event.date.timeIntervalSince(dose.start)) < 1 else { return false }
            switch (dose.kind, event.record) {
            case let (.bolus, .bolus(units, _)):
                return abs((units * 100).rounded() - ((dose.delivered ?? dose.programmed) * 100).rounded()) < 0.001
            case let (.basal, .basal(existing, minutes)):
                return minutes == 0 && (existing * 100).rounded() == (rate * 100).rounded()
            case let (.tempBasal, .basal(existing, minutes)):
                return minutes > 0 && (existing * 100).rounded() == (rate * 100).rounded()
            case (.suspend, .suspend): return true
            default: return false
            }
        }
    }

    /// Capture exactly the prefix which may reach the server, including a dose crossing its boundary.
    public mutating func markSubmitted(through index: UInt32) {
        lastSubmittedIndex = index
        submittedThrough = committedThrough
        submittedState = state
        submittedIDs = Set(committed.keys)
    }

    /// The last boundary which may have reached Glooko through a submitted file.
    public var submittedBoundary: Date? { submissionBoundary }

    private var submissionBoundary: Date? {
        if let submittedThrough { return submittedThrough }
        // Migration of old files whose lastSubmittedIndex was recorded without an explicit checkpoint.
        guard let index = lastSubmittedIndex else { return nil }
        return records.last(where: { $0.index <= index && $0.record == .download })?.date
    }

    private func wasSubmitted(_ id: String) -> Bool {
        guard lastSubmittedIndex != nil else { return false }
        if let submittedIDs { return submittedIDs.contains(id) }
        guard let dose = sourceDoses[id], let boundary = submissionBoundary else { return true }
        return dose.start < boundary
    }

    /// Migrate membership from the original source snapshots, before a deletion or edit removes them.
    private mutating func captureSubmissionCheckpoint() {
        guard submittedIDs == nil, let index = lastSubmittedIndex, let boundary = submissionBoundary else { return }
        let ids = Set(committed.keys.filter { wasSubmitted($0) })
        submittedIDs = ids; submittedThrough = boundary
        if let record = records.last(where: {
            guard $0.index <= index else { return false }
            switch $0.record { case .basal, .suspend: return true; default: return false }
        })?.record {
            switch record {
            case let .basal(rate, minutes): submittedState = .init(delivery: minutes == 0 ? .scheduled(rate: rate) : .temporary(rate: rate))
            case .suspend: submittedState = .init(delivery: .suspended)
            default: break
            }
        }
    }

    private mutating func rebuildUnsubmitted() {
        let first = records.first?.index ?? nextIndex
        if let index = lastSubmittedIndex, let boundary = submissionBoundary {
            records.removeAll { $0.index > index }
            submittedThrough = boundary
            committed = committed.filter { submittedIDs!.contains($0.key) }
            committedThrough = boundary; state = submittedState; nextIndex = index + 1
            pending = sourceDoses.filter { !submittedIDs!.contains($0.key) || $0.value.end > boundary }
        } else {
            records = []; committed = [:]; committedThrough = nil; state = nil; nextIndex = first
            pending = sourceDoses
        }
    }

    private mutating func event(_ date: Date, _ record: IBFRecord, _ zone: TimeZone) -> IBFHistoryEvent {
        defer { nextIndex += 1 }
        return IBFHistoryEvent(index: nextIndex, date: date, record: record, utcOffset: zone.secondsFromGMT(for: date))
    }

    /// Submission and retention are separate: unconfirmed records are never pruned. If old confirmed history
    /// can be pruned, retain its preceding delivery record to anchor the first surviving interval.
    public mutating func exportFile(timeZone: TimeZone, retention: TimeInterval = 14 * 86400,
                                    basalProgram: [Double]? = nil, settings: IBFPumpSettings? = nil) throws -> (data: Data, lastIndex: UInt32, events: [IBFHistoryEvent])? {
        guard conflicts.isEmpty else { throw HistoryError.conflictsRequireReview }
        guard hasUnuploadedRecords, let committedThrough else { return nil }
        guard let settings else { throw PumpHistoryIBF.EncodingError.missingSettings }
        try settings.validate()
        repairedBasalIndices.formUnion(Self.repairZeroDurationMarkers(records).indices)
        if case .download? = records.last?.record {} else {
            records.append(event(max(committedThrough, records.last?.date ?? committedThrough), .download, timeZone))
        }
        if let first = records.first?.date, first < powerUp { powerUp = first }
        let cutoff = committedThrough.addingTimeInterval(-retention)
        let anchor = records.last(where: { event in
            guard event.date < cutoff else { return false }
            switch event.record { case .basal, .suspend: return true; default: return false }
        })?.index
        if let anchor { records.removeAll { $0.index < anchor && $0.index <= (lastUploadedIndex ?? 0) } }
        let firstUnconfirmed = records.first(where: { $0.index > (lastUploadedIndex ?? 0) })?.date ?? cutoff
        let sourceCutoff = min(cutoff, firstUnconfirmed)
        sourceDoses = sourceDoses.filter { id, dose in
            dose.end >= sourceCutoff || committed[id] == nil || pending[id] != nil || conflicts[id] != nil
        }
        committed = committed.filter { $0.value >= sourceCutoff || sourceDoses[$0.key] != nil }
        legacyIDs = legacyIDs.intersection(Set(committed.keys).union(pending.keys))
        var history = exportedEvents
        // The native importer accepts overlapping complete-day suffixes. An arbitrary record delta
        // can recalculate a partial day's summary, so keep yesterday, today and every unconfirmed day.
        // Only use an actual midnight delivery anchor with consistent source clock context; otherwise
        // send the retained file. Local retention, indices and the immutable submitted prefix stay intact.
        if lastUploadedIndex != nil,
           history.allSatisfy({ ($0.utcOffset ?? timeZone.secondsFromGMT(for: $0.date)) == timeZone.secondsFromGMT(for: $0.date) }) {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
            let today = calendar.startOfDay(for: committedThrough)
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: today) {
                let earliest = calendar.startOfDay(for: firstUnconfirmed)
                let wanted = min(yesterday, earliest)
                let boundary = history.last(where: { event in
                    guard event.date <= wanted, event.date == calendar.startOfDay(for: event.date) else { return false }
                    switch event.record { case .basal, .suspend: return true; default: return false }
                })?.date
                if let boundary { history.removeAll { $0.date < boundary } }
            }
        }
        let document = PumpHistoryIBF(serial: serial, timeZone: timeZone, powerUp: powerUp,
                                      basalProgram: settings.basal, events: history, settings: settings)
        return (try document.encode(), history.last!.index, history)
    }

    public var exportedEvents: [IBFHistoryEvent] {
        var events = Self.repairZeroDurationMarkers(records).events
        if state?.isDelivering == true, let i = events.lastIndex(where: { if case .basal = $0.record { return true }; return false }) {
            events[i].inProgress = true
        }
        return events
    }

    /// Glooko turns a zero-second suspend/resume into a zero scheduled rate. Inert markers preserve
    /// every date, index and clinical payload while the original submitted records remain on disk.
    private static func repairZeroDurationMarkers(_ original: [IBFHistoryEvent]) -> (events: [IBFHistoryEvent], indices: Set<UInt32>) {
        var events = original, indices = Set<UInt32>()
        var suspension: Int?, resume: Int?
        for i in original.indices {
            switch original[i].record {
            case .suspend: suspension = i; resume = nil
            case .resume: resume = i
            case let .basal(rate, minutes):
                if minutes == 0, rate > 0, let start = suspension, let end = resume,
                   floor(original[start].date.timeIntervalSince1970) == floor(original[end].date.timeIntervalSince1970),
                   floor(original[end].date.timeIntervalSince1970) == floor(original[i].date.timeIntervalSince1970),
                   original[start].utcOffset == original[end].utcOffset, original[end].utcOffset == original[i].utcOffset {
                    events[start].record = .download; events[end].record = .download
                    indices.insert(original[i].index)
                }
                suspension = nil; resume = nil
            case .activate, .deactivate: suspension = nil; resume = nil
            default: break
            }
        }
        return (events, indices)
    }

    public mutating func recordCorrectionIntent(_ correction: IngestionCorrection) {
        // Preserve the first before-image when a write succeeds but its acknowledgement is lost.
        if ingestionCorrections[correction.guid] == nil { ingestionCorrections[correction.guid] = correction }
    }

    public mutating func confirmCorrections(through index: UInt32, at date: Date) {
        for key in Array(ingestionCorrections.keys) where ingestionCorrections[key]!.index <= index && ingestionCorrections[key]!.confirmedAt == nil {
            ingestionCorrections[key]!.confirmedAt = date
        }
    }

    public mutating func markVerified(fileIndex: UInt32, through index: UInt32, at date: Date) {
        lastUploadedIndex = max(lastUploadedIndex ?? 0, min(index, fileIndex))
        lastVerifiedFileIndex = max(lastVerifiedFileIndex ?? 0, fileIndex)
        confirmCorrections(through: index, at: date)
    }

    public enum HistoryError: Error { case conflictsRequireReview }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, ownerID, ownerEmail, sourceID, reportingContextData, serial, powerUp, podLot, podSerial, nextIndex, records, committedThrough
        case state, pending, committed, sourceDoses, conflicts, unclassified, stagedDeletions, droppedIDs, legacyIDs, legacyLateDoses, lateDoses, lastSubmittedIndex, lastUploadedIndex, lastVerifiedFileIndex, historyStart, submittedThrough, submittedState, submittedIDs, repairedBasalIndices, ingestionCorrections
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serial = try c.decode(UInt32.self, forKey: .serial); powerUp = try c.decode(Date.self, forKey: .powerUp)
        podLot = try c.decode(UInt16.self, forKey: .podLot); podSerial = try c.decode(UInt16.self, forKey: .podSerial)
        nextIndex = try c.decode(UInt32.self, forKey: .nextIndex); records = try c.decode([IBFHistoryEvent].self, forKey: .records)
        committedThrough = try c.decodeIfPresent(Date.self, forKey: .committedThrough)
        state = try c.decodeIfPresent(DeliveryTimeline.State.self, forKey: .state)
        pending = try c.decode([String: SourceDose].self, forKey: .pending)
        committed = try c.decode([String: Date].self, forKey: .committed)
        historyStart = try c.decodeIfPresent(Date.self, forKey: .historyStart)
        ownerID = try c.decodeIfPresent(String.self, forKey: .ownerID); sourceID = try c.decodeIfPresent(String.self, forKey: .sourceID)
        ownerEmail = try c.decodeIfPresent(String.self, forKey: .ownerEmail)
        reportingContextData = try c.decodeIfPresent(Data.self, forKey: .reportingContextData)
        sourceDoses = try c.decodeIfPresent([String: SourceDose].self, forKey: .sourceDoses) ?? pending
        conflicts = try c.decodeIfPresent([String: HistoryConflict].self, forKey: .conflicts) ?? [:]
        unclassified = try c.decodeIfPresent([String: SourceDose].self, forKey: .unclassified) ?? [:]
        stagedDeletions = try c.decodeIfPresent([String: SourceDose].self, forKey: .stagedDeletions) ?? [:]
        droppedIDs = try c.decodeIfPresent(Set<String>.self, forKey: .droppedIDs) ?? []
        legacyLateDoses = try c.decodeIfPresent(Int.self, forKey: .legacyLateDoses) ?? c.decodeIfPresent(Int.self, forKey: .lateDoses) ?? 0
        let previousIndex = try c.decodeIfPresent(UInt32.self, forKey: .lastUploadedIndex)
        lastSubmittedIndex = try c.decodeIfPresent(UInt32.self, forKey: .lastSubmittedIndex) ?? previousIndex
        submittedThrough = try c.decodeIfPresent(Date.self, forKey: .submittedThrough)
        submittedState = try c.decodeIfPresent(DeliveryTimeline.State.self, forKey: .submittedState)
        submittedIDs = try c.decodeIfPresent(Set<String>.self, forKey: .submittedIDs)
        lastUploadedIndex = (try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1) >= 2 ? previousIndex : nil
        lastVerifiedFileIndex = try c.decodeIfPresent(UInt32.self, forKey: .lastVerifiedFileIndex) ?? lastUploadedIndex
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        legacyIDs = try c.decodeIfPresent(Set<String>.self, forKey: .legacyIDs) ?? (version == 1 ? Set(committed.keys).union(pending.keys) : [])
        repairedBasalIndices = try c.decodeIfPresent(Set<UInt32>.self, forKey: .repairedBasalIndices) ?? []
        repairedBasalIndices.formUnion(Self.repairZeroDurationMarkers(records).indices)
        ingestionCorrections = try c.decodeIfPresent([String: IngestionCorrection].self, forKey: .ingestionCorrections) ?? [:]
        guard version <= 4, nextIndex > (records.last?.index ?? 0) else { throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c, debugDescription: "Unsupported or inconsistent history") }
        if version < 4, repairedBasalIndices.contains(where: { $0 <= (lastUploadedIndex ?? 0) }) {
            lastUploadedIndex = nil; lastVerifiedFileIndex = nil
        }
        captureSubmissionCheckpoint()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(4, forKey: .schemaVersion); try c.encodeIfPresent(ownerID, forKey: .ownerID); try c.encodeIfPresent(sourceID, forKey: .sourceID)
        try c.encodeIfPresent(ownerEmail, forKey: .ownerEmail)
        try c.encodeIfPresent(reportingContextData, forKey: .reportingContextData)
        try c.encode(serial, forKey: .serial); try c.encode(powerUp, forKey: .powerUp); try c.encode(podLot, forKey: .podLot); try c.encode(podSerial, forKey: .podSerial)
        try c.encode(nextIndex, forKey: .nextIndex); try c.encode(records, forKey: .records); try c.encodeIfPresent(committedThrough, forKey: .committedThrough)
        try c.encodeIfPresent(state, forKey: .state); try c.encode(pending, forKey: .pending); try c.encode(committed, forKey: .committed)
        try c.encode(sourceDoses, forKey: .sourceDoses); try c.encode(conflicts, forKey: .conflicts); try c.encode(droppedIDs, forKey: .droppedIDs)
        try c.encode(unclassified, forKey: .unclassified); try c.encode(stagedDeletions, forKey: .stagedDeletions); try c.encode(legacyIDs, forKey: .legacyIDs)
        try c.encode(legacyLateDoses, forKey: .legacyLateDoses); try c.encode(lateDoses, forKey: .lateDoses)
        try c.encodeIfPresent(lastSubmittedIndex, forKey: .lastSubmittedIndex); try c.encodeIfPresent(lastUploadedIndex, forKey: .lastUploadedIndex)
        try c.encodeIfPresent(lastVerifiedFileIndex, forKey: .lastVerifiedFileIndex)
        try c.encodeIfPresent(submittedThrough, forKey: .submittedThrough); try c.encodeIfPresent(submittedState, forKey: .submittedState)
        try c.encodeIfPresent(submittedIDs, forKey: .submittedIDs)
        try c.encodeIfPresent(historyStart, forKey: .historyStart)
        try c.encode(repairedBasalIndices, forKey: .repairedBasalIndices)
        try c.encode(ingestionCorrections, forKey: .ingestionCorrections)
    }
}
