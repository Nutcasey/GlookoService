import Foundation

/// The original reading and its clock offset are retained. CSV timestamps have minute precision.
public struct SourceGlucose: Codable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable { case directSensor, manufacturerApp }
    public var id: String
    public var date: Date
    public var mgdl: Double
    public var utcOffset: Int
    public var origin: Origin?

    public init(id: String, date: Date, mgdl: Double, utcOffset: Int, origin: Origin = .directSensor) {
        self.id = id; self.date = date; self.mgdl = mgdl; self.utcOffset = utcOffset
        self.origin = origin
    }

    public var minute: String {
        String(WallClock(timeZone: TimeZone(secondsFromGMT: utcOffset)!).string(date).prefix(16))
    }
    public var encodedValue: Int { Int((mgdl * 100).rounded()) }
    fileprivate var priority: Int { origin == .manufacturerApp ? 0 : 1 }
    fileprivate func validate() throws {
        guard date.timeIntervalSince1970.isFinite, mgdl.isFinite, mgdl > 0, mgdl < 1000,
              TimeZone(secondsFromGMT: utcOffset) != nil else {
            throw GlookoError.requestRejected("Invalid glucose reading; the original source cursor is retained")
        }
    }
}

/// A reading Glooko's minute-precision CSV can't represent. It is recorded and left out, so one
/// bad minute never blocks the readings after it.
public struct SkippedGlucose: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// A second instant at an occupied wall-clock minute, as in the repeated hour when clocks go back.
        case repeatedMinute
        /// The same instant with a different value. CSV can't correct a point once it may have been sent.
        case changedValue
        /// Glooko already holds a different, duplicate or incomplete reading at this minute.
        case differentInGlooko
    }
    public var reading: SourceGlucose
    public var reason: Reason
    public var message: String {
        switch reason {
        case .repeatedMinute: return "Skipped a reading at \(reading.minute) (UTC offset \(reading.utcOffset / 60) min): that clock minute already holds an earlier reading"
        case .changedValue: return "Skipped a changed reading at \(reading.minute): the original value is kept"
        case .differentInGlooko: return "Skipped the reading at \(reading.minute): Glooko already has a different reading at that minute"
        }
    }
}

/// Account-scoped, immutable CGM readings. A changed reading is never silently acknowledged as an edit,
/// because a CSV import can't correct a stored point.
public struct GlucoseOutbox: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var reading: SourceGlucose
        public var confirmed: Bool = false
        /// Nil is a legacy queue: a previously attempted request cannot be ruled out.
        public var submitted: Bool? = nil
        /// Set when Glooko holds a different reading at this minute. The minute stays occupied so
        /// replays are ignored, and the entry is no longer due.
        public var skipped: SkippedGlucose.Reason? = nil
        /// Set when Glooko rejected the file holding this reading. It stays due and is tried again from this date.
        public var retryAfter: Date? = nil
    }
    public struct StageResult: Equatable, Sendable {
        public var skipped: [SkippedGlucose] = []
        public var invalid = 0
        public init() {}
    }
    public private(set) var entries: [String: Entry] = [:]
    /// Skipped readings by source ID, kept for the same retention window as confirmed readings.
    public private(set) var skipped: [String: SkippedGlucose] = [:]
    public var historyStart: Date?
    public init(historyStart: Date?) { self.historyStart = historyStart }

    private enum CodingKeys: String, CodingKey { case entries, skipped, historyStart }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entries = try values.decode([String: Entry].self, forKey: .entries)
        skipped = try values.decodeIfPresent([String: SkippedGlucose].self, forKey: .skipped) ?? [:]
        historyStart = try values.decodeIfPresent(Date.self, forKey: .historyStart)
        for (key, entry) in entries {
            try entry.reading.validate()
            guard key == entry.reading.minute else { throw GlookoError.invalidResponse }
        }
        for (key, skip) in skipped {
            try skip.reading.validate()
            guard key == skip.reading.id else { throw GlookoError.invalidResponse }
        }
    }

    /// Never throws for a single reading: invalid and unrepresentable readings are counted or recorded
    /// and the rest of the page is staged.
    @discardableResult
    public mutating func stage(_ readings: [SourceGlucose]) -> StageResult {
        var result = StageResult()
        for reading in readings.sorted(by: { $0.priority == $1.priority ? $0.date < $1.date : $0.priority > $1.priority }) {
            guard (try? reading.validate()) != nil else { result.invalid += 1; continue }
            if skipped[reading.id] != nil { continue }
            if let start = historyStart, reading.date < start, entries[reading.minute] == nil { continue }
            if let old = entries[reading.minute] {
                // HealthKit may replay the same sensor sample under another UUID. Do not make a second
                // point. A different instant at the same clock minute (the repeated hour when clocks go
                // back) can't be told apart in CSV, so the earlier reading wins and this one is skipped.
                guard abs(old.reading.date.timeIntervalSince(reading.date)) < 60,
                      old.reading.utcOffset == reading.utcOffset else {
                    result.skipped.append(skip(reading, .repeatedMinute)); continue
                }
                // Manufacturer apps and direct BLE integrations can publish different copies within one
                // minute. Prefer the directly received measurement, keeping already reported values.
                if reading.priority < old.reading.priority { continue }
                if reading.priority > old.reading.priority {
                    if !old.confirmed && old.submitted == false && old.skipped == nil {
                        entries[reading.minute] = Entry(reading: reading, submitted: false)
                    }
                    continue // A possibly submitted copy is immutable, including after a restart.
                }
                if old.reading.encodedValue != reading.encodedValue { result.skipped.append(skip(reading, .changedValue)) }
            } else { entries[reading.minute] = Entry(reading: reading, submitted: false) }
        }
        return result
    }

    private mutating func skip(_ reading: SourceGlucose, _ reason: SkippedGlucose.Reason) -> SkippedGlucose {
        let record = SkippedGlucose(reading: reading, reason: reason)
        skipped[reading.id] = record
        return record
    }

    public var due: [SourceGlucose] {
        entries.values.filter { !$0.confirmed && $0.skipped == nil }.map(\.reading).sorted { $0.date < $1.date }
    }
    /// What to send next, oldest first. Readings not yet rejected go first, so a file Glooko keeps
    /// rejecting is never sent with them and can't hold them up.
    public func sendable(at now: Date) -> [SourceGlucose] {
        let waiting = entries.values.filter { !$0.confirmed && $0.skipped == nil }
        let fresh = waiting.filter { $0.retryAfter == nil }
        let batch = fresh.isEmpty ? waiting.filter { $0.retryAfter! <= now } : fresh
        return batch.map(\.reading).sorted { $0.date < $1.date }
    }
    /// Readings Glooko has rejected and not accepted since.
    public var rejected: [SourceGlucose] {
        entries.values.filter { !$0.confirmed && $0.skipped == nil && $0.retryAfter != nil }.map(\.reading)
    }
    public var nextRetry: Date? {
        entries.values.filter { !$0.confirmed && $0.skipped == nil }.compactMap(\.retryAfter).min()
    }
    public mutating func hold(_ readings: [SourceGlucose], until date: Date) {
        for reading in readings where entries[reading.minute]?.reading == reading {
            entries[reading.minute]?.retryAfter = date
        }
    }
    public mutating func retryRejectedNow() {
        for (minute, entry) in entries where entry.retryAfter != nil { entries[minute]?.retryAfter = .distantPast }
    }

    public mutating func confirm(_ reading: SourceGlucose) {
        guard entries[reading.minute]?.reading == reading else { return }
        entries[reading.minute]?.confirmed = true
    }

    /// Glooko already holds something else at this minute. Stop sending the reading and record why.
    @discardableResult
    public mutating func skipDifferentInGlooko(_ reading: SourceGlucose) -> SkippedGlucose? {
        guard entries[reading.minute]?.reading == reading, entries[reading.minute]?.confirmed == false else { return nil }
        entries[reading.minute]?.skipped = .differentInGlooko
        return skip(reading, .differentInGlooko)
    }

    public mutating func markSubmitted(_ readings: [SourceGlucose]) {
        for reading in readings where entries[reading.minute]?.reading == reading {
            entries[reading.minute]?.submitted = true
        }
    }

    /// Glooko keeps the imported history. Bound phone storage and future replay, while retaining every
    /// unconfirmed reading even if an outage lasts longer than the normal retention window.
    public mutating func pruneConfirmed(before cutoff: Date) {
        entries = entries.filter { !($0.value.confirmed || $0.value.skipped != nil) || $0.value.reading.date >= cutoff }
        skipped = skipped.filter { $0.value.reading.date >= cutoff }
        historyStart = max(historyStart ?? cutoff, cutoff)
    }

    /// Year-first dates: Glooko rejects a day-month file (HTTP 400) when every row falls on one day from the 1st to the 12th.
    public static func csv(_ readings: [SourceGlucose]) -> Data {
        var lines = ["Glucose Data,Generated on,,Generated by,Loop",
            "Device,Serial Number,Device Timestamp,Record Type,Historic Glucose mg/dL,Scan Glucose mg/dL,Non-numeric Rapid-Acting Insulin,Rapid-Acting Insulin (units),Non-numeric Food,Carbohydrates (grams),Carbohydrates (servings),Non-numeric Long-Acting Insulin,Long-Acting Insulin Value (units),Notes,Strip Glucose mg/dL,Ketone mmol/L,Meal Insulin (units),Correction Insulin (units),User Change Insulin (units)"]
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"
        for reading in readings.sorted(by: { $0.date < $1.date }) {
            f.timeZone = TimeZone(secondsFromGMT: reading.utcOffset)
            let value = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), reading.mgdl)
            var row = ["Loop CGM", "Loop", f.string(from: reading.date), "0", value]
            row += Array(repeating: "", count: 14)
            lines.append(row.joined(separator: ","))
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}

public struct GlucoseOutboxRepository {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    private func folder(_ accountID: String) -> URL {
        directory.appendingPathComponent(GlookoAccount(id: accountID, email: "").storageKey, isDirectory: true)
    }
    public func load(accountID: String, historyStart: Date?, required: Bool) throws -> GlucoseOutbox {
        let folder = folder(accountID)
        do { return try StoredJSON.decoder().decode(GlucoseOutbox.self, from: Data(contentsOf: folder.appendingPathComponent("glucose-v2.json"))) }
        catch CocoaError.fileReadNoSuchFile {
            guard !required, !FileManager.default.fileExists(atPath: folder.appendingPathComponent("glucose-v2-initialised").path) else {
                throw GlookoError.requestRejected("Saved glucose uploads are missing. Restore the outbox before continuing.")
            }
            return GlucoseOutbox(historyStart: historyStart)
        }
    }
    public func save(_ outbox: GlucoseOutbox, accountID: String) throws {
        let folder = folder(accountID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        try StoredJSON.encoder().encode(outbox).write(to: folder.appendingPathComponent("glucose-v2.json"), options: options)
        try Data().write(to: folder.appendingPathComponent("glucose-v2-initialised"), options: options)
    }
}

public struct GlucoseVerification: Codable, Equatable, Sendable {
    public var expected: Int
    public var matchedStored: Int
    public var matchedGraphed: Int
    public var duplicates: Int
    public var verified: Bool { expected == matchedStored && expected == matchedGraphed && duplicates == 0 }
}

public struct GlucoseSubmission: Equatable, Sendable {
    public var confirmed: [SourceGlucose] = []
    /// Glooko already holds a different, duplicate or incomplete reading at these minutes. Nothing was
    /// uploaded for them.
    public var differentInGlooko: [SourceGlucose] = []
    /// Glooko refused the file holding these readings. Readings already in Glooko are still confirmed above.
    public var rejected: [SourceGlucose] = []
    public var rejectedStatus: Int?
    public init() {}
}

public extension GlookoClient {
    /// Skip existing matching CGM points, set aside conflicting minutes, then verify both records and graphs.
    func submitGlucose(_ readings: [SourceGlucose]) async throws -> GlucoseSubmission {
        guard !readings.isEmpty else { return .init() }
        for reading in readings { try reading.validate() }
        let before = try await glucoseState(readings)
        var result = GlucoseSubmission(), pending: [SourceGlucose] = []
        for reading in readings {
            if before.stored[reading.minute]?.isEmpty == false || before.graph[reading.minute]?.isEmpty == false {
                if Self.glucoseMatches(reading, before) { result.confirmed.append(reading) }
                else if !Self.storedAwaitingGraph(reading, before) { result.differentInGlooko.append(reading) }
            } else { pending.append(reading) }
        }
        guard !pending.isEmpty else { return result }
        try Task.checkCancellation()
        let upload = try await send("POST", host: region.dataHost,
            path: "/api/v3/device/file/upload?extractorName=LibreviewCSV",
            body: GlucoseOutbox.csv(pending), authenticated: true,
            headers: ["Content-Type": "application/octet-stream"])
        if Self.fileWasRejected(upload.status) {
            result.rejected = pending; result.rejectedStatus = upload.status
            return result
        }
        try requireGlucoseSuccess(upload)
        var matched: [SourceGlucose] = []
        for delay in [0, 1, 2, 4] {
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000) }
            try Task.checkCancellation()
            let state = try await glucoseState(pending)
            matched = pending.filter { Self.glucoseMatches($0, state) }
            if matched.count == pending.count { break }
        }
        result.confirmed += matched
        return result
    }

    /// GETs only, including values previously acknowledged before this app launch.
    func verifyGlucose(_ readings: [SourceGlucose]) async throws -> GlucoseVerification {
        for reading in readings { try reading.validate() }
        let state = try await glucoseState(readings)
        var result = GlucoseVerification(expected: readings.count, matchedStored: 0, matchedGraphed: 0, duplicates: 0)
        for reading in readings {
            let stored = state.stored[reading.minute] ?? [], graph = state.graph[reading.minute] ?? []
            if stored.count == 1, (stored[0]["glucoseValue"] as? NSNumber)?.intValue == reading.encodedValue { result.matchedStored += 1 }
            if graph == [reading.encodedValue] { result.matchedGraphed += 1 }
            if stored.count > 1 || graph.count > 1 { result.duplicates += 1 }
        }
        return result
    }

    private typealias GlucoseState = (stored: [String: [[String: Any]]], graph: [String: [Int]])
    private static func glucoseMatches(_ reading: SourceGlucose, _ state: GlucoseState) -> Bool {
        guard let stored = state.stored[reading.minute], stored.count == 1,
              let guid = stored[0]["guid"] as? String, !guid.isEmpty,
              (stored[0]["glucoseValue"] as? NSNumber)?.intValue == reading.encodedValue,
              state.graph[reading.minute] == [reading.encodedValue] else { return false }
        return true
    }

    /// Glooko holds this exact reading but its graph doesn't show it yet. It stays due, and isn't uploaded again.
    private static func storedAwaitingGraph(_ reading: SourceGlucose, _ state: GlucoseState) -> Bool {
        guard let stored = state.stored[reading.minute], stored.count == 1,
              (stored[0]["glucoseValue"] as? NSNumber)?.intValue == reading.encodedValue else { return false }
        return state.graph[reading.minute]?.isEmpty != false
    }

    private func glucoseState(_ readings: [SourceGlucose]) async throws -> GlucoseState {
        guard let first = readings.map(\.date).min() else { return ([:], [:]) }
        let session = try await get("/api/v3/session/users")
        try requireGlucoseSuccess(session)
        guard let object = try JSONSerialization.jsonObject(with: session.body) as? [String: Any],
              let user = object["currentUser"] as? [String: Any],
              let code = user["glookoCode"] as? String, !code.isEmpty else { throw GlookoError.invalidResponse }
        // The cursor is update time, not measurement time. A day of margin also covers wall-clock offsets.
        let scan = await scan("cgm/egvs", since: Self.isoTimestamp(first.addingTimeInterval(-86400)))
        guard case .complete = scan.outcome else {
            throw GlookoError.requestRejected("Stored glucose readback is incomplete (\(scan.outcome))")
        }
        var stored: [String: [[String: Any]]] = [:]
        for row in scan.records where (row["softDeleted"] as? Bool) == false {
            guard let timestamp = row["displayTime"] as? String, timestamp.count >= 16,
                  row["glucoseValue"] is NSNumber else { throw GlookoError.invalidResponse }
            stored[String(timestamp.prefix(16)), default: []].append(row)
        }
        return (stored, try await glucoseGraph(days: Set(readings.map { String($0.minute.prefix(10)) }).sorted(), code: code))
    }

    private func glucoseGraph(days: [String], code: String) async throws -> [String: [Int]] {
        var points: [String: [Int]] = [:]
        for day in days {
            try Task.checkCancellation()
            var query = URLComponents()
            query.queryItems = [URLQueryItem(name: "patient", value: code),
                URLQueryItem(name: "startDate", value: day + "T00:00:00.000Z"),
                URLQueryItem(name: "endDate", value: day + "T23:59:59.999Z")]
                + ["cgmHigh", "cgmNormal", "cgmLow"].map { URLQueryItem(name: "series[]", value: $0) }
            let result = try await get("/api/v3/graph/data?" + query.percentEncodedQuery!)
            try requireGlucoseSuccess(result)
            guard let object = try JSONSerialization.jsonObject(with: result.body) as? [String: Any],
                  let series = object["series"] as? [String: Any] else { throw GlookoError.invalidResponse }
            for key in ["cgmHigh", "cgmNormal", "cgmLow"] {
                guard let rows = series[key] as? [[String: Any]] else { throw GlookoError.invalidResponse }
                for row in rows {
                    guard let timestamp = row["timestamp"] as? String, timestamp.count >= 16,
                          let value = row["value"] as? NSNumber else { throw GlookoError.invalidResponse }
                    points[String(timestamp.prefix(16)), default: []].append(value.intValue)
                }
            }
        }
        return points
    }

    /// Signing in again, or waiting a moment, can fix the other client errors. Server errors aren't about the file.
    private static func fileWasRejected(_ status: Int) -> Bool {
        (400..<500).contains(status) && ![401, 403, 408, 421, 429].contains(status)
    }

    private func requireGlucoseSuccess(_ result: HTTPResult) throws {
        if [301, 302, 303, 307, 308, 401, 403, 421].contains(result.status) { throw GlookoError.authenticationRequired(result.status) }
        guard (200..<300).contains(result.status), result.contentType?.lowercased().contains("text/html") != true else {
            throw GlookoError.requestRejected("Glooko glucose request failed (HTTP \(result.status))")
        }
    }
}
