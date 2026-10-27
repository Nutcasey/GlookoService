import Foundation

/// One record in an Insulet Eros PDM history log, in the units the IBF file stores.
/// Layout: Tidepool insuletDriver.js (logRecords) and the genuine balshor/ibf-file-reader b705fa1 export.
public enum IBFRecord: Equatable, Codable, Sendable {
    /// `tempMinutes == 0` is a scheduled rate; otherwise a temporary rate that a later record may supersede.
    case basal(rate: Double, tempMinutes: Int)
    case suspend, resume
    /// IBF bolus volume is the delivered amount; `terminateBolus` carries the undelivered remainder.
    case bolus(delivered: Double, immediateSeconds: Int)
    case terminateBolus(undelivered: Double)
    case carb(grams: Int)
    case activate(lot: UInt16, serial: UInt16)
    case deactivate, download

    var kind: UInt32 {
        switch self {
        case .basal: return 0x0008
        case .suspend: return 0x0010
        case .resume: return 0x10000
        case .bolus: return 0x0004
        case .terminateBolus: return 0x2000
        case .carb: return 0x1000
        case .activate: return 0x8000
        case .deactivate: return 0x0001
        case .download: return 0x20000
        }
    }

    var payload: [UInt8] {
        func hundredths(_ units: Double) -> UInt32 { UInt32(max(0, (units * 100).rounded())) }
        switch self {
        case let .basal(rate, minutes): return le32(hundredths(rate)) + le16(UInt16(clamping: minutes)) + le16(0)
        case let .bolus(delivered, seconds): return le32(hundredths(delivered)) + le16(0) + le16(0) + le16(UInt16(clamping: seconds))
        case let .terminateBolus(left): return le32(hundredths(left)) + le16(0)
        case let .carb(grams): return le16(UInt16(clamping: grams)) + [0, 0]
        case let .activate(lot, serial): return be16(lot) + be16(serial) + [2, 0, 0, 2, 0, 0]
        case .suspend, .resume, .deactivate, .download: return []
        }
    }

    /// Order of records sharing one timestamp, following the genuine log (carb, then bolus).
    var sameTimeRank: Int {
        switch self {
        case .deactivate: return 0
        case .activate: return 1
        case .suspend: return 2
        case .resume: return 3
        case .basal: return 4
        case .carb: return 5
        case .bolus: return 6
        case .terminateBolus: return 7
        case .download: return 8
        }
    }
}

public struct IBFHistoryEvent: Equatable, Codable, Sendable {
    public var index: UInt32
    public var date: Date
    public var record: IBFRecord
    /// The genuine export flags the still-running basal record IN_PROGRESS (0x04).
    public var inProgress: Bool
    /// Seconds from GMT fixed when the record was made, so a PDM wall-clock time never shifts later.
    /// `nil` uses the document's time zone at that instant.
    public var utcOffset: Int?

    public init(index: UInt32, date: Date, record: IBFRecord, inProgress: Bool = false, utcOffset: Int? = nil) {
        self.index = index; self.date = date; self.record = record; self.inProgress = inProgress; self.utcOffset = utcOffset
    }
}

/// A complete PDM export: fixed device/settings records, then the newest-first history log.
/// Times are written as wall-clock components in `timeZone`, as a PDM stores them.
public struct PumpHistoryIBF: Sendable {
    public var serial: UInt32
    public var name: String
    public var timeZone: TimeZone
    /// Origin of the monotonic seconds-since-power-up field. Keep it fixed for one PDM identity.
    public var powerUp: Date
    /// 48 half-hour scheduled rates (U/h) for basal programme 0.
    public var basalProgram: [Double]
    public var settings: IBFPumpSettings?
    /// Chronological history; indices strictly increasing.
    public var events: [IBFHistoryEvent]

    public init(serial: UInt32, name: String = "LOOP", timeZone: TimeZone, powerUp: Date,
                basalProgram: [Double] = Array(repeating: 0, count: 48), events: [IBFHistoryEvent], settings: IBFPumpSettings? = nil) {
        self.serial = serial; self.name = name; self.timeZone = timeZone; self.powerUp = powerUp
        self.basalProgram = basalProgram; self.events = events
        self.settings = settings
    }

    public enum EncodingError: Error, Equatable {
        case invalidSerial, emptyHistory, unorderedHistory(index: UInt32), beforePowerUp, invalidBasalProgram, nameTooLong
        case missingSettings, invalidSettings, invalidRecord
    }

    static let endDay: UInt16 = 0x08, newDay: UInt16 = 0x02, inProgressFlag: UInt16 = 0x04

    /// Per-record flags. Every genuine boundary (99 of 99) is an adjacent END_DAY/NEW_DAY pair across
    /// the chronological stream, regardless of record kind.
    public func flags() -> [UInt16] {
        var flags = events.map { $0.inProgress ? Self.inProgressFlag : 0 }
        let days = events.map { clock($0) }.map { [Int($0.year), Int($0.month), Int($0.day)] }
        for i in events.indices.dropFirst() where days[i - 1] != days[i] {
            flags[i - 1] |= Self.endDay
            flags[i] |= Self.newDay
        }
        return flags
    }

    public func encode() throws -> Data {
        guard (1...999_999_999).contains(serial) else { throw EncodingError.invalidSerial }
        guard let last = events.last else { throw EncodingError.emptyHistory }
        guard basalProgram.count == 48 else { throw EncodingError.invalidBasalProgram }
        guard let settings else { throw EncodingError.missingSettings }
        try settings.validate()
        for event in events {
            switch event.record {
            case let .basal(rate, minutes):
                guard rate.isFinite, rate >= 0, rate < 65535, minutes >= 0, minutes <= 65535 else { throw EncodingError.invalidRecord }
            case let .bolus(units, seconds):
                guard units.isFinite, units >= 0, units < 65535, seconds >= 0, seconds <= 65535 else { throw EncodingError.invalidRecord }
            case let .terminateBolus(units):
                guard units.isFinite, units >= 0, units < 65535 else { throw EncodingError.invalidRecord }
            default: break
            }
        }
        guard name.utf8.count < 23 else { throw EncodingError.nameTooLong }
        for i in events.indices.dropFirst() where events[i].index <= events[i - 1].index || events[i].date < events[i - 1].date {
            throw EncodingError.unorderedHistory(index: events[i].index)
        }
        guard events[0].date >= powerUp else { throw EncodingError.beforePowerUp }

        var records: [[UInt8]] = []
        records.append([0, 1, 7, 0, 1, 7].flatMap { be16(UInt16($0)) } + string("Insulet", 8) + string("OmniPod", 8))
        records.append([0, 2, 0, 5, 0, 0, 2, 0, 0, 2, 2, 0, 2, 1, 0])
        records.append(string(name, 23))
        var names = be16(7) + be16(0) + be16(32)
        for index in 0..<7 { names += be16(UInt16(index)) + string(index == 0 ? name : "Unused \(index)", 32) }
        records.append(names)
        var eeprom = [UInt8](repeating: 0, count: 120)
        let maxBasal = UInt32((settings.maximumBasal * 100).rounded())
        let maxBolus = UInt32((settings.maximumBolus * 100).rounded())
        // Keep the known accepted Eros hardware descriptors (0.05 U increment / 10 U reserve). These describe
        // the virtual PDM, not the attached pump. Every exported therapy value below comes from Loop.
        eeprom.replaceSubrange(13..<31, with: [5, maxBolus, maxBasal, 10].flatMap(le32) + [0, 0])
        eeprom.replaceSubrange(53..<57, with: le32(serial))
        let glucoseBounds = [settings.minimumGlucoseMGDL, settings.targetMGDL[0], settings.correctionThresholdMGDL[0]]
        eeprom.replaceSubrange(76..<90, with: [0, 0, 0, 1, 1, settings.glucoseDisplayMMOL ? 1 : 0, 0] +
                               glucoseBounds.flatMap { le16(UInt16($0.rounded())) } +
                               [UInt8(clamping: Int((Double(settings.insulinActionMinutes) / 30).rounded()))])
        records.append(eeprom)
        let program = settings.basal.map { UInt32(($0 * 100).rounded()) }
        let profiles = [11: settings.carbRatio, 12: settings.sensitivityMGDL,
                        13: settings.targetMGDL, 14: settings.correctionThresholdMGDL]
        for index in Array(15...21) + [12, 11, 13, 14] {
            let values: [UInt32] = index == 15 ? program : profiles[index]?.map { UInt32($0.rounded()) } ?? Array(repeating: 0, count: 48)
            let header = [UInt8(index)] + be32(1) + be16(196) + be16(0) + le32(86400)
            records.append(header + values.flatMap(le32))
        }

        let exported = clock(last)
        var logHeader: [UInt8] = [2, 1, 1, 1, 1, exported.day, exported.month] + be16(exported.year)
        logHeader += [exported.second, exported.minute, exported.hour, 0] + be16(26)
        var descriptors: [(UInt16, UInt16, UInt16, UInt16)] = [(0,2,0,16),(0,2,0,76),(2,1,0,76),(1,0,0,76),
            (0,2,0,41),(2,1,0,41),(0,2,0,16),(0,2,0,10),(0,2,1,20),(0,2,1,20),(0,2,0,8)]
        descriptors += Array(repeating: (0,1,0,196), count: 11)
        descriptors += [(0,2,0,20),(0,2,0,12),(0,2,0,18),(0,2,1,22)]
        for (index, d) in descriptors.enumerated() {
            let active = (1...3).contains(index)
            logHeader += [UInt16(index), d.0, d.1, d.2, d.3].flatMap(be16)
            logHeader += be32(active ? events[0].index : .max) + be32(active ? last.index : .max)
        }
        records.append(logHeader)

        let flags = flags()
        for (event, flag) in zip(events, flags).reversed() {
            let c = clock(event)
            let elapsed = event.date.timeIntervalSince(powerUp).rounded(.down)
            guard elapsed.isFinite, elapsed >= 0, elapsed < Double(UInt32.max - 86400) else { throw EncodingError.invalidRecord }
            let sincePowerUp = UInt32(elapsed) + 86400
            var bytes = [UInt8(3)] + be32(event.index) + be16(76) + be16(0)
            bytes += [c.day, c.month] + le16(c.year) + [c.second, c.minute, c.hour, 0]
            bytes += le32(sincePowerUp) + le32(event.record.kind) + le16(flag) + [0, 0] + event.record.payload
            bytes += Array(repeating: 0, count: 85 - bytes.count)
            records.append(bytes)
        }
        for (logID, size) in [(3, 76), (5, 41)] {
            records.append([UInt8(logID)] + be32(.max) + be16(UInt16(size)) + be16(0) + Array(repeating: 0, count: size))
        }
        return Data(records.flatMap { payload in
            let checksum = payload.reduce(UInt32(0)) { $0 + UInt32($1) }
            return be16(UInt16(payload.count + 2)) + payload + be16(UInt16(truncatingIfNeeded: checksum))
        })
    }
}

/// Destination-neutral delivery, shaped like Loop's reconciled dose stream, converted to PDM records.
extension PumpHistoryIBF {
    /// Local wall-clock components the PDM would display for this record.
    func clock(_ event: IBFHistoryEvent) -> (day: UInt8, month: UInt8, year: UInt16, second: UInt8, minute: UInt8, hour: UInt8) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let offset = event.utcOffset ?? timeZone.secondsFromGMT(for: event.date)
        let c = calendar.dateComponents([.day, .month, .year, .second, .minute, .hour], from: event.date.addingTimeInterval(Double(offset)))
        return (UInt8(c.day!), UInt8(c.month!), UInt16(c.year!), UInt8(c.second!), UInt8(c.minute!), UInt8(c.hour!))
    }
}

public enum DeliveryTimeline {
    public enum Delivery: Equatable, Codable, Sendable { case scheduled(rate: Double), temporary(rate: Double), suspended }

    public struct Interval: Equatable, Codable, Sendable {
        public var start: Date, end: Date, delivery: Delivery
        /// Source identity (Loop `syncIdentifier`); lets a dose continue across commit windows without a new record.
        public var id: String?
        public init(start: Date, end: Date, delivery: Delivery, id: String? = nil) {
            self.start = start; self.end = end; self.delivery = delivery; self.id = id
        }
    }

    public struct Bolus: Equatable, Codable, Sendable {
        public var start: Date, end: Date, delivered: Double, programmed: Double
        public init(start: Date, end: Date, delivered: Double, programmed: Double) {
            self.start = start; self.end = end; self.delivered = delivered; self.programmed = programmed
        }
    }

    public struct Carb: Equatable, Codable, Sendable {
        public var date: Date, grams: Int
        public init(date: Date, grams: Int) { self.date = date; self.grams = grams }
    }

    /// Delivery in effect at the end of a converted window.
    public struct State: Equatable, Codable, Sendable {
        public var delivery: Delivery
        public var id: String?
        public init(delivery: Delivery, id: String? = nil) { self.delivery = delivery; self.id = id }
        var isDelivering: Bool { delivery != .suspended }
    }

    public typealias Record = (date: Date, record: IBFRecord, inProgress: Bool)

    /// Converts intervals and boluses to chronological PDM records ending at `through`.
    public static func records(intervals: [Interval], boluses: [Bolus], carbs: [Carb] = [],
                               timeZone: TimeZone, through: Date, gapTolerance: TimeInterval = 0) -> [Record] {
        window(intervals: intervals, boluses: boluses, carbs: carbs, timeZone: timeZone, through: through,
               gapTolerance: gapTolerance).records
    }

    /// Converts the window `[from, through)` to chronological PDM records.
    ///
    /// - Time not covered by any interval is written as a suspension: no insulin is invented for gaps.
    /// - A later-starting interval truncates an overlapping earlier one.
    /// - Every local midnight while delivering gets a fresh basal record, as the genuine PDM writes one.
    /// - `initial` is the delivery already in effect at `from`; the same dose continuing gets no new record.
    /// - The basal record still running at `through` is flagged in progress.
    public static func window(intervals: [Interval], boluses: [Bolus], carbs: [Carb] = [], timeZone: TimeZone,
                              from: Date? = nil, initial: State? = nil, through: Date,
                              gapTolerance: TimeInterval = 0) -> (records: [Record], final: State?) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func isMidnight(_ date: Date) -> Bool { calendar.startOfDay(for: date) == date }
        var basal: [Record] = []
        // Supersession is real and applies before windowing; the window edges are not, so a temp record's
        // duration always comes from its dose's own (superseded) end.
        var whole = intervals.filter { $0.start.timeIntervalSince1970.isFinite && $0.end.timeIntervalSince1970.isFinite && $0.end > $0.start }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
        for i in whole.indices.dropLast() where whole[i].end > whole[i + 1].start { whole[i].end = whole[i + 1].start }
        whole = whole.flatMap(quantised)
        let sorted = whole.compactMap { interval -> (interval: Interval, end: Date)? in
            var clipped = interval
            if let from { clipped.start = max(clipped.start, from) }
            clipped.end = min(clipped.end, through)
            return clipped.end > clipped.start ? (clipped, interval.end) : nil
        }

        var state = initial
        var cursor: Date? = initial == nil ? nil : from
        func suspend(_ date: Date) {
            if state?.isDelivering == true { basal.append((date, .suspend, false)) }
            state = State(delivery: .suspended)
        }
        func deliver(_ date: Date, _ interval: Interval, doseEnd: Date) {
            switch interval.delivery {
            case .suspended:
                suspend(date)
                state?.id = interval.id
            case let .scheduled(rate), let .temporary(rate):
                let continuing = state?.delivery == interval.delivery && state?.id != nil && state?.id == interval.id
                if continuing && !isMidnight(date) { return }
                if state?.delivery == .suspended { basal.append((date, .resume, false)) }
                var minutes = 0
                if case .temporary = interval.delivery { minutes = max(1, Int((doseEnd.timeIntervalSince(date) / 60).rounded(.up))) }
                basal.append((date, .basal(rate: rate, tempMinutes: minutes), false))
                state = State(delivery: interval.delivery, id: interval.id)
            }
        }
        for (interval, doseEnd) in sorted {
            if let cursor, interval.start.timeIntervalSince(cursor) > gapTolerance { suspend(cursor) }
            deliver(interval.start, interval, doseEnd: doseEnd)
            var midnight = calendar.startOfDay(for: interval.start)
            while let next = calendar.date(byAdding: .day, value: 1, to: midnight), next < interval.end {
                midnight = next
                if state?.isDelivering == true { deliver(midnight, interval, doseEnd: doseEnd) }
            }
            cursor = interval.end
        }
        if let cursor, through.timeIntervalSince(cursor) > gapTolerance { suspend(cursor) }
        if state?.isDelivering == true, let i = basal.lastIndex(where: { if case .basal = $0.record { return true } else { return false } }) {
            basal[i].inProgress = true
        }

        var all = basal
        for bolus in boluses where bolus.start < through && bolus.end <= through && bolus.start >= (from ?? .distantPast) {
            all.append((bolus.start, .bolus(delivered: bolus.delivered,
                                             immediateSeconds: max(1, Int(bolus.end.timeIntervalSince(bolus.start).rounded()))), false))
            if bolus.programmed - bolus.delivered >= 0.005 {
                all.append((max(bolus.end, bolus.start), .terminateBolus(undelivered: bolus.programmed - bolus.delivered), false))
            }
        }
        for carb in carbs where carb.date < through && carb.date >= (from ?? .distantPast) && carb.grams > 0 {
            all.append((carb.date, .carb(grams: carb.grams), false))
        }
        // A stable sort keeps the generated order of equal-time, equal-rank records.
        let ordered = all.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            if x.date != y.date { return x.date < y.date }
            if x.record.sameTimeRank != y.record.sameTimeRank { return x.record.sameTimeRank < y.record.sameTimeRank }
            return a.offset < b.offset
        }.map(\.element)
        return (ordered, state)
    }

    /// IBF stores hundredths of U/h and whole seconds. Adjacent native rates preserve the source volume
    /// to half a rate-second (0.0000014 U), rather than accumulating rate rounding over a day. Bound each
    /// pair to a UTC hour so the intermediate deviation also stays below 0.0025 U. IDs and split times
    /// depend on the whole source interval, so continuation remains stable across commitment windows.
    private static func quantised(_ interval: Interval) -> [Interval] {
        let start = floor(interval.start.timeIntervalSince1970)
        let end = floor(interval.end.timeIntervalSince1970)
        guard end > start else { return [] }
        let rate: Double
        switch interval.delivery {
        case .suspended:
            return [Interval(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end),
                             delivery: .suspended, id: interval.id)]
        case let .scheduled(value), let .temporary(value): rate = value
        }
        guard rate.isFinite, rate >= 0, rate < 65535 else { return [interval] }
        let adjusted = rate * interval.end.timeIntervalSince(interval.start) / (end - start)
        let low = floor(adjusted * 100 + 1e-9) / 100
        let fraction = max(0, min(1, (adjusted - low) * 100))
        func delivery(_ value: Double) -> Delivery {
            if case .temporary = interval.delivery { return .temporary(rate: value) }
            return .scheduled(rate: value)
        }
        if fraction < 1e-8 {
            return [Interval(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end),
                             delivery: delivery(low), id: interval.id)]
        }
        var result: [Interval] = []
        var cursor = start
        var remainder = 0.0
        while cursor < end {
            let boundary = min(end, (floor(cursor / 3600) + 1) * 3600)
            let seconds = boundary - cursor
            let wanted = fraction * seconds + remainder
            let highSeconds = min(seconds, max(0, wanted.rounded()))
            remainder = wanted - highSeconds
            let split = boundary - highSeconds
            if split > cursor {
                result.append(.init(start: Date(timeIntervalSince1970: cursor), end: Date(timeIntervalSince1970: split),
                                    delivery: delivery(low), id: interval.id.map { "\($0):\(Int(cursor)):lo" }))
            }
            if boundary > split {
                result.append(.init(start: Date(timeIntervalSince1970: split), end: Date(timeIntervalSince1970: boundary),
                                    delivery: delivery(low + 0.01), id: interval.id.map { "\($0):\(Int(cursor)):hi" }))
            }
            cursor = boundary
        }
        return result
    }
}

private func be16(_ n: UInt16) -> [UInt8] { [UInt8(n >> 8), UInt8(n & 255)] }
private func le16(_ n: UInt16) -> [UInt8] { be16(n).reversed() }
private func be32(_ n: UInt32) -> [UInt8] { [UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)] }
private func le32(_ n: UInt32) -> [UInt8] { be32(n).reversed() }
private func string(_ value: String, _ count: Int) -> [UInt8] { Array(value.utf8) + Array(repeating: 0, count: count - value.utf8.count) }

public extension DeliveryTimeline {
    /// Independent source truth: delivered basal (integrated intervals) and bolus units per local day,
    /// rounded to 0.001 U. Suspended time and gaps contribute nothing.
    static func dailyTotals(intervals: [Interval], boluses: [Bolus], timeZone: TimeZone,
                            through: Date) -> [String: [String: Double]] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        var totals: [String: (basal: Double, bolus: Double)] = [:]
        var sorted = intervals.filter { $0.end > $0.start }.sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
        for i in sorted.indices.dropLast() where sorted[i].end > sorted[i + 1].start { sorted[i].end = sorted[i + 1].start }
        for interval in sorted {
            let rate: Double
            switch interval.delivery { case let .scheduled(r), let .temporary(r): rate = r; case .suspended: continue }
            var start = interval.start
            let end = min(interval.end, through)
            while start < end {
                let dayEnd = min(end, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))!)
                totals[formatter.string(from: start), default: (0, 0)].basal += rate * dayEnd.timeIntervalSince(start) / 3600
                start = dayEnd
            }
        }
        for bolus in boluses where bolus.start < through { totals[formatter.string(from: bolus.start), default: (0, 0)].bolus += bolus.delivered }
        func r(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
        return totals.mapValues { ["basal": r($0.basal), "bolus": r($0.bolus), "total": r($0.basal + $0.bolus)] }
    }
}
