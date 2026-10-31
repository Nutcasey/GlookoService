import Foundation

/// Delivered insulin reported as Glooko insulin entries with no medication (research/glooko/app-write-protocol.md).
/// `medicationGuid: null` keeps the declared basal/bolus type; naming a rapid-acting drug would turn basal into bolus,
/// and naming a long-acting one would invent an injection. Each bolus is one entry. Basal is the delivered volume of
/// each local clock hour, so the rate, temporary basal and suspension timeline is not represented.
/// Entries are upserts keyed by deterministic GUIDs: corrections update and deletions soft-delete the same rows.
public struct InsulinOutbox: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case basal, bolus }

    public struct Entry: Codable, Equatable, Sendable {
        public var guid: String
        public var kind: Kind
        public var start: Date
        public var units: Double
        public var deleted: Bool
        public var externalID: String
        /// Nil only for entries saved before display names were uploaded.
        public var name: String? = nil
        /// Fixed when first queued; nil identifies a pre-offset entry requiring readback migration.
        public var utcOffset: Int? = nil
        /// The end of a basal hour aligned to the local clock. Nil for boluses and for hours aligned to
        /// UTC before local hours were introduced, which always end on the next UTC hour.
        public var end: Date? = nil
    }

    public struct Tracked: Codable, Equatable, Sendable {
        public var current: Entry
        public var confirmed: Entry?
        /// Set before any request that may create it in Glooko; such an entry is deleted there, never just dropped.
        public var submitted: Bool
    }

    /// Nothing before this is reported. On cut-over it is the last boundary the previous uploader submitted.
    public private(set) var reportingStart: Date
    /// Separate from the original reporting period, so pruning cannot recreate earlier basal hours.
    public private(set) var recomputeFrom: Date?
    /// Basal hours from here follow the local clock, and their rounding restarts at local midnight. Earlier
    /// hours keep the UTC alignment they were first sent with, so no existing entry changes. Nil only in a
    /// queue saved before local hours; the first refresh sets it.
    public private(set) var localHoursFrom: Date?
    public private(set) var doses: [String: SourceDose] = [:]
    public private(set) var entries: [String: Tracked] = [:]
    /// Glooko never revives a soft-deleted GUID, so an identity wanted again after deletion moves to a new revision.
    public private(set) var revisions: [String: Int]?

    public static let bolusSettle: TimeInterval = 10 * 60
    public static let basalSettle: TimeInterval = 15 * 60
    public static let retention: TimeInterval = 14 * 86400

    public init(reportingStart: Date) {
        self.reportingStart = reportingStart; recomputeFrom = reportingStart; localHoursFrom = reportingStart
    }

    /// Deletions first, then creations; a re-created identity replaces the previous version.
    public mutating func stage(created: [SourceDose], deleted: [SourceDose]) {
        for dose in deleted { doses[dose.id] = nil }
        let boundary = max(reportingStart, recomputeFrom ?? reportingStart)
        for dose in created where dose.kind != .resume && dose.end > boundary && Self.isValid(dose) {
            if dose.kind == .bolus && dose.start < boundary { continue }
            doses[dose.id] = dose
        }
    }

    private static func isValid(_ dose: SourceDose) -> Bool {
        dose.start.timeIntervalSince1970.isFinite && dose.end.timeIntervalSince1970.isFinite && dose.end >= dose.start &&
            dose.programmed.isFinite && dose.programmed >= 0 && (dose.delivered.map { $0.isFinite && $0 >= 0 } ?? true) &&
            (dose.rate.map { $0.isFinite && $0 >= 0 } ?? true)
    }

    /// Basal is reported through the latest delivery evidence and never past a running (mutable) delivery.
    public func basalHorizon(now: Date) -> Date {
        let delivery = doses.values.filter { $0.kind != .bolus }
        var horizon = now.addingTimeInterval(-Self.basalSettle)
        horizon = min(horizon, delivery.map { $0.isMutable ? $0.start : $0.end }.max() ?? reportingStart)
        for dose in delivery where dose.isMutable { horizon = min(horizon, dose.start) }
        return horizon
    }

    /// Recomputes the wanted entries. Known entries no longer wanted become deletions; unsent ones are dropped.
    public mutating func refresh(now: Date, insulinName: (SourceDose) -> String? = { $0.insulinName },
                                 utcOffset: (Date) -> Int = { TimeZone.current.secondsFromGMT(for: $0) }) {
        initialiseRetentionBoundary(now: now)
        initialiseLocalHours()
        let boundary = max(reportingStart, recomputeFrom ?? reportingStart)
        // Metadata-only upgrade: keep the same GUID, amount and time. Never guess an old dose's drug.
        for (guid, tracked) in entries where !tracked.current.deleted && tracked.current.name == nil {
            entries[guid]?.current.name = Self.displayName([nil])
        }
        var wanted: [String: Entry] = [:]
        for dose in doses.values where dose.kind == .bolus && dose.start >= boundary && !dose.isMutable && dose.end <= now.addingTimeInterval(-Self.bolusSettle) {
            let units = Self.rounded(dose.delivered ?? dose.programmed)
            guard units > 0 else { continue }
            let resolved = identity("loop-insulin-bolus|\(dose.id)")
            let guid = resolved.guid
            let old = entries[guid]?.current ?? resolved.previous
            wanted[guid] = Entry(guid: guid, kind: .bolus, start: dose.start, units: units, deleted: false,
                                 externalID: "loop:bolus:\(guid.prefix(8).lowercased())", name: Self.displayName([insulinName(dose)]),
                                 utcOffset: old?.start == dose.start ? old?.utcOffset : utcOffset(dose.start))
        }
        let horizon = basalHorizon(now: now)
        let localFrom = localHoursFrom ?? .distantFuture
        let hours = Self.completeHours(from: boundary, through: horizon, localFrom: localFrom, utcOffset: utcOffset)
        // Hours are rounded from a running total within each day (UTC before `localHoursFrom`, local after),
        // so their sum keeps the measured volume (two halves of one 0.025 U pulse report 0.013 + 0.012, not
        // 0.026) and a change only re-sends that day.
        var day = -1, running = 0.0, local = false
        for (hour, to) in hours {
            let from = max(hour, reportingStart, to > localFrom ? localFrom : .distantPast)
            let isLocal = to > localFrom
            let hourDay = isLocal ? Self.dayIndex(from, utcOffset: utcOffset(from)) : Int(floor(hour.timeIntervalSince1970 / 86400))
            if hourDay != day || isLocal != local { day = hourDay; local = isLocal; running = 0 }
            let before = Self.rounded(running)
            let contributions = doses.values.compactMap { dose -> (Double, String?)? in
                let units = Self.basalVolume(dose, from: from, to: to)
                return units > 0 ? (units, insulinName(dose)) : nil
            }
            running += contributions.reduce(0) { $0 + $1.0 }
            let units = Self.rounded(Self.rounded(running) - before)
            guard units > 0 else { continue }
            // A whole hour has one identity. A partial first hour also names its start, so a later reporting
            // period beginning inside that hour can never overwrite a different quantity under the same GUID.
            let epoch = Int(hour.timeIntervalSince1970)
            let seed = from == hour ? "\(epoch)" : "\(epoch)|from:\(Int(from.timeIntervalSince1970.rounded(.down)))"
            let resolved = identity("loop-insulin-basal|\(seed)")
            let guid = resolved.guid
            let old = entries[guid]?.current ?? resolved.previous
            wanted[guid] = Entry(guid: guid, kind: .basal, start: from, units: units, deleted: false,
                                 externalID: "loop:basal:\(seed)", name: Self.displayName(contributions.map(\.1)),
                                 utcOffset: old?.start == from ? old?.utcOffset : utcOffset(from), end: isLocal ? to : nil)
        }
        let lastHourEnd = hours.last?.end ?? reportingStart
        for (guid, tracked) in entries where wanted[guid] == nil {
            if tracked.current.start < boundary { continue }
            // A basal hour beyond the current horizon is not yet recomputable; leave it as it is.
            if tracked.current.kind == .basal, tracked.current.start >= lastHourEnd { continue }
            if tracked.submitted || tracked.confirmed != nil {
                entries[guid]?.current.deleted = true
            } else { entries[guid] = nil }
        }
        for (guid, entry) in wanted {
            if entries[guid] == nil { entries[guid] = Tracked(current: entry, confirmed: nil, submitted: false) }
            else { entries[guid]?.current = entry }
        }
    }

    /// Keep the hourly quantity/identity intact if an hour contains more than one insulin.
    private static func displayName(_ names: [String?]) -> String {
        let known = Set(names.compactMap { value -> String? in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        })
        guard !known.isEmpty else { return "Insulin via Loop" }
        var labels = known.sorted()
        if names.contains(where: { $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false }) {
            labels.append("unknown insulin")
        }
        return labels.joined(separator: " / ") + " via Loop"
    }

    /// The current GUID for a seed, moving past a revision Glooko holds (or may hold) as deleted.
    private mutating func identity(_ seed: String) -> (guid: String, previous: Entry?) {
        var revision = revisions?[seed] ?? 0
        func guid() -> String { Self.guid(revision == 0 ? seed : "\(seed)|r\(revision)") }
        let previous = entries[guid()]?.current
        while let tracked = entries[guid()], tracked.current.deleted, tracked.submitted || tracked.confirmed != nil {
            revision += 1
        }
        if revision > 0 { revisions = (revisions ?? [:]).merging([seed: revision]) { _, new in new } }
        return (guid(), previous)
    }

    /// Entries whose current version Glooko has not confirmed.
    public var due: [Entry] {
        entries.values.filter { $0.confirmed != $0.current }.map(\.current).sorted { $0.start < $1.start }
    }

    public var confirmedEntries: [Entry] { entries.values.compactMap(\.confirmed).filter { !$0.deleted } }

    public mutating func markSubmitted(_ sent: [Entry]) {
        for entry in sent { entries[entry.guid]?.submitted = true }
    }

    /// Glooko holds this GUID deleted and will not revive it: record that, so the next refresh uses a new revision.
    public mutating func supersede(_ entry: Entry) {
        guard entries[entry.guid]?.current == entry, !entry.deleted else { return }
        var deleted = entry; deleted.deleted = true
        entries[entry.guid] = Tracked(current: deleted, confirmed: deleted, submitted: true)
    }

    public mutating func confirm(_ entry: Entry) {
        guard entries[entry.guid]?.current == entry else { return }
        entries[entry.guid]?.confirmed = entry
    }

    /// A complete UTC day owns the rounding accumulator and all source intervals contributing to it.
    /// Never prune a day with pending entries or mutable delivery, and never move the boundary backwards.
    public mutating func prune(now: Date, utcOffset: (Date) -> Int = { TimeZone.current.secondsFromGMT(for: $0) }) {
        initialiseRetentionBoundary(now: now)
        initialiseLocalHours()
        let cutoff = now.addingTimeInterval(-Self.retention)
        let oldestDue = due.map(\.start).min() ?? now
        let oldestMutable = doses.values.filter(\.isMutable).map(\.start).min() ?? now
        let earliest = min(cutoff, oldestDue, oldestMutable)
        var day = Self.utcDay(earliest)
        if let localFrom = localHoursFrom, earliest >= localFrom {
            // A local day owns the rounding accumulator. Never prune into the UTC-aligned history either.
            day = max(Self.localDayStart(earliest, utcOffset: utcOffset), localFrom)
        }
        let keepFrom = max(recomputeFrom ?? reportingStart, max(reportingStart, day))
        recomputeFrom = keepFrom
        doses = doses.filter { $0.value.end > keepFrom || $0.value.isMutable }
        entries = entries.filter { $0.value.current.start >= keepFrom || $0.value.confirmed != $0.value.current }
    }

    /// Old caches may already have lost part of their first retained day. Freeze those saved entries
    /// rather than recomputing their quantities from incomplete evidence during the upgrade.
    private mutating func initialiseRetentionBoundary(now: Date) {
        guard recomputeFrom == nil else { return }
        guard entries.values.contains(where: { $0.submitted || $0.confirmed != nil }) else {
            recomputeFrom = reportingStart // A never-submitted backlog must still be computed in full.
            return
        }
        let oldestDue = due.map(\.start).min() ?? now
        let oldestMutable = doses.values.filter(\.isMutable).map(\.start).min() ?? now
        let cutoffInstant = min(now.addingTimeInterval(-Self.retention), oldestDue, oldestMutable)
        guard reportingStart < cutoffInstant else { recomputeFrom = reportingStart; return }
        let cutoff = Self.utcDay(cutoffInstant)
        // The old implementation's cutoff could be inside this day, even if a long retained dose
        // starts earlier. Its first complete later day is the earliest safe recomputation point.
        recomputeFrom = max(reportingStart, cutoff == cutoffInstant ? cutoff : cutoff.addingTimeInterval(86400))
    }

    /// Local midnight before `date`, using the offset in effect at midnight (which differs on a clock-change day).
    static func localDayStart(_ date: Date, utcOffset: (Date) -> Int) -> Date {
        func midnight(_ offset: Int) -> Date {
            let shift = TimeInterval(offset)
            return Date(timeIntervalSince1970: floor((date.timeIntervalSince1970 + shift) / 86400) * 86400 - shift)
        }
        let guess = midnight(utcOffset(date))
        return midnight(utcOffset(guess))
    }

    private static func utcDay(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 86400) * 86400)
    }

    var legacyClockEntries: [Entry] {
        entries.values.compactMap { tracked in
            if let confirmed = tracked.confirmed, confirmed.utcOffset == nil { return confirmed }
            return tracked.current.utcOffset == nil ? tracked.current : nil
        }
    }

    mutating func pinClockOffsets(_ offsets: [String: Int]) {
        for (guid, offset) in offsets {
            if entries[guid]?.current.utcOffset == nil { entries[guid]?.current.utcOffset = offset }
            if entries[guid]?.confirmed?.utcOffset == nil { entries[guid]?.confirmed?.utcOffset = offset }
        }
    }

    /// Whole clock hours whose end is not after the horizon: UTC hours before `localFrom`, then local
    /// clock hours. The local hour containing `localFrom` is reported from `localFrom`. A change of UTC offset
    /// (travel, or a half-hour zone) can make one local hour shorter than 60 minutes.
    static func completeHours(from start: Date, through horizon: Date, localFrom: Date = .distantFuture,
                              utcOffset: (Date) -> Int = { TimeZone.current.secondsFromGMT(for: $0) }) -> [(start: Date, end: Date)] {
        var result: [(start: Date, end: Date)] = []
        var hour = Date(timeIntervalSince1970: floor(start.timeIntervalSince1970 / 3600) * 3600)
        while hour.addingTimeInterval(3600) <= localFrom {
            guard hour.addingTimeInterval(3600) <= horizon else { return result }
            result.append((hour, hour.addingTimeInterval(3600))); hour.addTimeInterval(3600)
        }
        let first = max(start, localFrom)
        hour = localHourStart(first, utcOffset: utcOffset(first))
        while true {
            let candidate = hour.addingTimeInterval(3600)
            var end = localHourStart(candidate, utcOffset: utcOffset(candidate))
            if end <= hour { end.addTimeInterval(3600) }
            guard end <= horizon else { return result }
            result.append((hour, end)); hour = end
        }
    }

    static func localHourStart(_ date: Date, utcOffset: Int) -> Date {
        let offset = TimeInterval(utcOffset)
        return Date(timeIntervalSince1970: floor((date.timeIntervalSince1970 + offset) / 3600) * 3600 - offset)
    }

    static func dayIndex(_ date: Date, utcOffset: Int) -> Int {
        Int(floor((date.timeIntervalSince1970 + TimeInterval(utcOffset)) / 86400))
    }

    /// A queue saved before local hours keeps UTC hours up to the end of the last basal hour it holds.
    private mutating func initialiseLocalHours() {
        guard localHoursFrom == nil else { return }
        let basal = entries.values.map(\.current).filter { $0.kind == .basal }
        localHoursFrom = basal.isEmpty ? max(reportingStart, recomputeFrom ?? reportingStart) : basal.map(Self.hourEnd).max()!
    }

    /// Delivered volume inside the interval, proportionally split. Measured volume wins over programmed rate.
    static func basalVolume(_ dose: SourceDose, from: Date, to: Date) -> Double {
        guard dose.kind == .basal || dose.kind == .tempBasal, !dose.isMutable else { return 0 }
        let overlap = min(dose.end, to).timeIntervalSince(max(dose.start, from))
        guard overlap > 0 else { return 0 }
        let duration = dose.end.timeIntervalSince(dose.start)
        let total = dose.delivered ?? (dose.rate ?? 0) * duration / 3600
        return duration > 0 ? total * overlap / duration : 0
    }

    static func rounded(_ units: Double) -> Double { (units * 1000).rounded() / 1000 }

    /// The end of the clock hour an entry reports; a partial first hour still ends on the hour.
    public static func hourEnd(_ entry: Entry) -> Date {
        entry.end ?? Date(timeIntervalSince1970: floor(entry.start.timeIntervalSince1970 / 3600) * 3600 + 3600)
    }

    public static func guid(_ seed: String) -> String { CarbOutbox.guid(seed) }
}

public extension GlookoRecords {
    /// A delivered insulin entry with no medication. Glooko counts it as device insulin of the declared type.
    static func deliveredInsulin(_ entry: InsulinOutbox.Entry, timeZone: TimeZone) -> [String: Any] {
        insulin(guid: entry.guid, timestamp: entry.start, units: entry.units, type: entry.kind.rawValue,
                deleted: entry.deleted, extra: ["medicationGuid": NSNull(), "deviceDelivered": 1, "externalId": entry.externalID,
                                               "name": entry.name ?? "Insulin via Loop"],
                timeZone: entry.utcOffset.flatMap(TimeZone.init(secondsFromGMT:)) ?? timeZone)
    }
}

public extension GlookoClient {
    /// Upserts the entries, then reads `insulins` back and returns those Glooko holds exactly as sent.
    func submitInsulin(_ entries: [InsulinOutbox.Entry], timeZone: TimeZone) async throws -> (confirmed: [InsulinOutbox.Entry], heldDeleted: [InsulinOutbox.Entry], detail: String) {
        guard !entries.isEmpty else { return ([], [], "No insulin to send") }
        try Task.checkCancellation()
        var readbackFrom = Date().addingTimeInterval(-300)
        let uptime = ProcessInfo.processInfo.systemUptime
        let result = try await put(resource: "insulins", records: entries.map { GlookoRecords.deliveredInsulin($0, timeZone: timeZone) })
        try Task.checkCancellation()
        if [301, 302, 303, 307, 308, 401, 403, 421].contains(result.status) { throw GlookoError.authenticationRequired(result.status) }
        guard (200..<300).contains(result.status) else {
            throw GlookoError.requestRejected("Glooko rejected the insulin entries (HTTP \(result.status)): \(Self.redact(result.text.prefix(300)))")
        }
        if let serverDate = result.serverDate {
            readbackFrom = min(readbackFrom, serverDate.addingTimeInterval(-(ProcessInfo.processInfo.systemUptime - uptime) - 300))
        }
        _ = try? await send("POST", host: region.dataHost,
                            path: "/api/v3/users/activities_and_event_data_sync/complete?syncTimestamp=\(Self.isoTimestamp(Date()))",
                            body: nil, authenticated: true)
        try Task.checkCancellation()
        let scan = await scan("insulins", since: Self.isoTimestamp(readbackFrom))
        try Task.checkCancellation()
        guard case .complete = scan.outcome else { return ([], [], "Insulin sent; Glooko readback incomplete (\(scan.outcome))") }
        var confirmed = entries.filter { Self.matches($0, scan.match(guid: $0.guid), timeZone: timeZone) }
        var heldDeleted = entries.filter { !$0.deleted && scan.match(guid: $0.guid).0 == .foundDeleted }
        // An upsert that changes nothing (such as deleting an already deleted entry) keeps its old update time,
        // so it is outside the incremental cursor. Resolve those from a complete read.
        let unresolved = entries.filter { entry in !confirmed.contains(entry) && scan.match(guid: entry.guid).0 == .completeNoMatch }
        if !unresolved.isEmpty {
            try Task.checkCancellation()
            let full = await self.scan("insulins")
            if case .complete = full.outcome {
                confirmed += unresolved.filter { Self.matches($0, full.match(guid: $0.guid), timeZone: timeZone) }
                heldDeleted += unresolved.filter { !$0.deleted && full.match(guid: $0.guid).0 == .foundDeleted }
            }
        }
        let held = heldDeleted.isEmpty ? "" : "; \(heldDeleted.count) held deleted by Glooko will be re-sent under new identities"
        return (confirmed, heldDeleted, "\(confirmed.count) of \(entries.count) insulin entries confirmed in Glooko" + held)
    }

    /// GETs only: every confirmed live entry must still be held, live and unchanged.
    func verifyInsulin(_ entries: [InsulinOutbox.Entry], timeZone: TimeZone) async throws -> (matched: Int, missing: Int, different: Int) {
        let scan = await scan("insulins")
        guard case .complete = scan.outcome else { throw GlookoError.requestRejected("Glooko readback incomplete (\(scan.outcome))") }
        var matched = 0, missing = 0, different = 0
        for entry in entries {
            let found = scan.match(guid: entry.guid)
            if Self.matches(entry, found, timeZone: timeZone) { matched += 1 }
            else if found.0 == .completeNoMatch { missing += 1 }
            else { different += 1 }
        }
        return (matched, missing, different)
    }

    internal static func matches(_ entry: InsulinOutbox.Entry, _ found: (MatchOutcome, [String: Any]?), timeZone: TimeZone) -> Bool {
        switch found.0 {
        case .foundDeleted: return entry.deleted
        case .foundLive:
            guard !entry.deleted, let record = found.1 else { return false }
            let units = (record["value"] as? NSNumber)?.doubleValue
            let stamp = (record["timestamp"] as? String)?.prefix(19)
            let medication = record["medicationGuid"]
            return units.map { abs($0 - entry.units) < 0.0005 } == true &&
                record["insulinType"] as? String == entry.kind.rawValue &&
                (record["deviceDelivered"] as? Bool) == true && (medication == nil || medication is NSNull) &&
                (entry.name == nil || record["name"] as? String == entry.name) &&
                stamp == WallClock(timeZone: entry.utcOffset.flatMap(TimeZone.init(secondsFromGMT:)) ?? timeZone).string(entry.start).prefix(19)
        default: return false
        }
    }
}

/// Missing, unreadable and malformed acknowledged storage must never become a new empty outbox.
public struct InsulinOutboxRepository {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public enum Failure: Error, CustomStringConvertible {
        case missingOutbox
        public var description: String { "The saved insulin outbox is missing. Restore its backup before continuing." }
    }

    private func folder(_ accountID: String) -> URL {
        directory.appendingPathComponent(GlookoAccount(id: accountID, email: "").storageKey, isDirectory: true)
    }

    /// Returns nil only when this account has never had an insulin outbox.
    public func load(accountID: String) throws -> InsulinOutbox? {
        let folder = folder(accountID)
        do { return try StoredJSON.decoder().decode(InsulinOutbox.self, from: Data(contentsOf: folder.appendingPathComponent("insulin.json"))) }
        catch CocoaError.fileReadNoSuchFile {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("insulin-initialised").path) { throw Failure.missingOutbox }
            return nil
        }
    }

    public func save(_ outbox: InsulinOutbox, accountID: String) throws {
        let folder = folder(accountID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        try StoredJSON.encoder().encode(outbox).write(to: folder.appendingPathComponent("insulin.json"), options: options)
        try Data().write(to: folder.appendingPathComponent("insulin-initialised"), options: options)
    }
}

public extension InsulinOutbox {
    /// Cut-over from the retired pump-file route. Reporting starts where that route's submitted history ends,
    /// so no delivery is counted twice; doses after it which the old log still holds are carried over.
    static func cutOver(from history: PumpHistoryLog?, now: Date) -> InsulinOutbox {
        // Locally committed but never submitted history has not reached Glooko, so it is reported from its start.
        let start = history.flatMap { $0.submittedBoundary ?? $0.historyStart } ?? now
        var outbox = InsulinOutbox(reportingStart: start)
        if let history {
            let carried = Array(history.sourceDoses.values) + Array(history.pending.values) + Array(history.unclassified.values)
            outbox.stage(created: carried.filter { $0.sourceID == nil || $0.sourceID == history.sourceID }, deleted: [])
        }
        return outbox
    }
}

public extension InsulinOutbox {
    /// Drops doses the caller cannot attribute to a real pump. Already reported entries are recomputed, never orphaned.
    mutating func retainDoses(_ keep: (SourceDose) -> Bool) {
        doses = doses.filter { keep($0.value) }
    }
}
