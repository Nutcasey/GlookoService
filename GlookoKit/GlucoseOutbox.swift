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

/// Account-scoped, immutable CGM readings. A changed reading is never silently acknowledged as an edit:
/// the CSV importer deduplicates existing timestamps without applying a changed value.
public struct GlucoseOutbox: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var reading: SourceGlucose
        public var confirmed: Bool = false
        /// Nil is a legacy queue: a previously attempted request cannot be ruled out.
        public var submitted: Bool? = nil
    }
    public private(set) var entries: [String: Entry] = [:]
    public var historyStart: Date?
    public init(historyStart: Date?) { self.historyStart = historyStart }

    private enum CodingKeys: String, CodingKey { case entries, historyStart }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entries = try values.decode([String: Entry].self, forKey: .entries)
        historyStart = try values.decodeIfPresent(Date.self, forKey: .historyStart)
        for (key, entry) in entries {
            try entry.reading.validate()
            guard key == entry.reading.minute else { throw GlookoError.invalidResponse }
        }
    }

    public mutating func stage(_ readings: [SourceGlucose]) throws {
        var staged = self
        for reading in readings.sorted(by: { $0.priority == $1.priority ? $0.date < $1.date : $0.priority > $1.priority }) {
            try reading.validate()
            if let start = historyStart, reading.date < start, staged.entries[reading.minute] == nil { continue }
            if let old = staged.entries[reading.minute] {
                // HealthKit may replay the same sensor sample under another UUID. Do not make a second
                // point, but reject different instants in a repeated DST minute or a conflicting value.
                guard abs(old.reading.date.timeIntervalSince(reading.date)) < 60,
                      old.reading.utcOffset == reading.utcOffset else {
                    throw GlookoError.requestRejected("Two glucose readings conflict at \(reading.minute). CSV cannot correct or distinguish them; review the original readings.")
                }
                // Manufacturer apps and direct BLE integrations can publish different copies within one
                // minute. Prefer the directly received measurement, keeping already reported values.
                if reading.priority < old.reading.priority { continue }
                if reading.priority > old.reading.priority {
                    if !old.confirmed && old.submitted == false {
                        staged.entries[reading.minute] = Entry(reading: reading, submitted: false)
                    }
                    continue // A possibly submitted copy is immutable, including after a restart.
                }
                guard old.reading.encodedValue == reading.encodedValue else {
                    throw GlookoError.requestRejected("Two glucose readings conflict at \(reading.minute). CSV cannot correct them; review the original readings.")
                }
            } else { staged.entries[reading.minute] = Entry(reading: reading, submitted: false) }
        }
        self = staged
    }

    public var due: [SourceGlucose] {
        entries.values.filter { !$0.confirmed }.map(\.reading).sorted { $0.date < $1.date }
    }
    public mutating func confirm(_ reading: SourceGlucose) {
        guard entries[reading.minute]?.reading == reading else { return }
        entries[reading.minute]?.confirmed = true
    }

    public mutating func markSubmitted(_ readings: [SourceGlucose]) {
        for reading in readings where entries[reading.minute]?.reading == reading {
            entries[reading.minute]?.submitted = true
        }
    }

    /// Glooko keeps the imported history. Bound phone storage and future replay, while retaining every
    /// unconfirmed reading even if an outage lasts longer than the normal retention window.
    public mutating func pruneConfirmed(before cutoff: Date) {
        entries = entries.filter { !$0.value.confirmed || $0.value.reading.date >= cutoff }
        historyStart = max(historyStart ?? cutoff, cutoff)
    }

    public static func csv(_ readings: [SourceGlucose]) -> Data {
        var lines = ["Glucose Data,Generated on,,Generated by,Loop",
            "Device,Serial Number,Device Timestamp,Record Type,Historic Glucose mg/dL,Scan Glucose mg/dL,Non-numeric Rapid-Acting Insulin,Rapid-Acting Insulin (units),Non-numeric Food,Carbohydrates (grams),Carbohydrates (servings),Non-numeric Long-Acting Insulin,Long-Acting Insulin Value (units),Notes,Strip Glucose mg/dL,Ketone mmol/L,Meal Insulin (units),Correction Insulin (units),User Change Insulin (units)"]
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "dd-MM-yyyy HH:mm"
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

public extension GlookoClient {
    /// Skip existing matching CGM points, reject conflicts, then verify both records and graphs.
    func submitGlucose(_ readings: [SourceGlucose]) async throws -> [SourceGlucose] {
        guard !readings.isEmpty else { return [] }
        for reading in readings { try reading.validate() }
        let before = try await glucoseState(readings)
        var confirmed: [SourceGlucose] = [], pending: [SourceGlucose] = []
        for reading in readings {
            if before.stored[reading.minute]?.isEmpty == false || before.graph[reading.minute]?.isEmpty == false {
                guard Self.glucoseMatches(reading, before) else {
                    throw GlookoError.requestRejected("Glooko has a different, duplicate or incomplete glucose reading at \(reading.minute). No replacement was uploaded.")
                }
                confirmed.append(reading)
            } else { pending.append(reading) }
        }
        guard !pending.isEmpty else { return confirmed }
        try Task.checkCancellation()
        let result = try await send("POST", host: region.dataHost,
            path: "/api/v3/device/file/upload?extractorName=LibreviewCSV",
            body: GlucoseOutbox.csv(pending), authenticated: true,
            headers: ["Content-Type": "application/octet-stream"])
        try requireGlucoseSuccess(result)
        var matched: [SourceGlucose] = []
        for delay in [0, 1, 2, 4] {
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000) }
            try Task.checkCancellation()
            let state = try await glucoseState(pending)
            matched = pending.filter { Self.glucoseMatches($0, state) }
            if matched.count == pending.count { break }
        }
        return confirmed + matched
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

    private func requireGlucoseSuccess(_ result: HTTPResult) throws {
        if [301, 302, 303, 307, 308, 401, 403, 421].contains(result.status) { throw GlookoError.authenticationRequired(result.status) }
        guard (200..<300).contains(result.status), result.contentType?.lowercased().contains("text/html") != true else {
            throw GlookoError.requestRejected("Glooko glucose request failed (HTTP \(result.status))")
        }
    }
}
