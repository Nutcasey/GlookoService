import Foundation
import CryptoKit

/// One version of a source carbohydrate entry, keyed by its stable source identifier.
public struct SourceCarb: Codable, Equatable, Sendable {
    public var id: String
    public var start: Date
    public var grams: Double
    public var version: Int
    public var deleted: Bool
    public var provenanceIdentifier: String?
    /// The legacy GUID seed, retained when an existing unnamespaced entry is bound to its source.
    public var destinationID: String?

    public init(id: String, start: Date, grams: Double, version: Int, deleted: Bool, provenanceIdentifier: String? = nil) {
        self.id = id; self.start = start; self.grams = grams; self.version = version; self.deleted = deleted
        self.provenanceIdentifier = provenanceIdentifier
    }

    public var storageID: String {
        provenanceIdentifier.map { CarbOutbox.guid("loop-carb-source|\($0.utf8.count):\($0)\(id)") } ?? id
    }
    public var guids: (meal: String, food: String) { CarbOutbox.guids(for: destinationID ?? storageID) }
}

/// Durable carbohydrate outbox. Glooko's meal/food records are upserts keyed by a client GUID, so each source
/// entry maps to fixed GUIDs: resends overwrite, edits update and deletions soft-delete the same records.
/// Carbs are sent as foods with no meal, which Glooko lists as "Food"; a meal must be breakfast, lunch, dinner or snack.
public struct CarbOutbox: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var carb: SourceCarb
        /// The version Glooko has confirmed holding, if any.
        public var confirmedVersion: Int?
        public var confirmedDeleted: Bool?
        /// Set before any request that may create it in Glooko; such an entry is deleted there, never just dropped.
        public var submitted: Bool?
        /// Sent by the first version inside a "snack" meal; that meal is soft-deleted on the next submission.
        public var retireMeal: Bool?
        public var confirmedCarb: SourceCarb?
    }

    public private(set) var entries: [String: Entry] = [:]
    /// Entries before this are not reported (they predate the service's history start).
    public var historyStart: Date?
    /// 3: confirmation includes the complete source value. 2: standalone foods. nil: snack meals.
    public var format: Int?

    public init(historyStart: Date? = nil) { self.historyStart = historyStart; format = 3 }

    /// Resends entries submitted as snack meals so they become standalone foods, and retires their meals.
    public mutating func migrateToStandaloneFoods() {
        guard format != 3 else { return }
        for (id, entry) in entries {
            if format != 2, entry.submitted == true {
                entries[id]?.retireMeal = true
                entries[id]?.confirmedVersion = nil
                entries[id]?.confirmedCarb = nil
            } else if entry.confirmedVersion == entry.carb.version, entry.confirmedDeleted == entry.carb.deleted {
                entries[id]?.confirmedCarb = entry.carb
            }
        }
        format = 3
    }

    public var retiringMeals: Set<String> { Set(entries.filter { $0.value.retireMeal == true }.keys) }

    public enum Failure: Error, CustomStringConvertible {
        case ambiguousLegacyIdentity(String)
        public var description: String { "A saved carb entry cannot yet be matched to one source. Its original Glooko identity has been retained." }
    }

    /// Applies source versions in order. A migration must prove ownership before reusing a legacy GUID.
    public mutating func stage(_ carbs: [SourceCarb]) throws {
        var staged = self
        for (id, sources) in Dictionary(grouping: carbs, by: \.id) {
            guard let legacy = staged.entries[id], legacy.carb.provenanceIdentifier == nil,
                  sources.contains(where: { $0.provenanceIdentifier != nil }) else { continue }
            let matches = sources.filter {
                floor($0.start.timeIntervalSince1970) == floor(legacy.carb.start.timeIntervalSince1970) &&
                $0.grams == legacy.carb.grams && $0.version == legacy.carb.version
            }
            let owners = Set(matches.compactMap(\.provenanceIdentifier))
            guard owners.count == 1, let owner = owners.first else { throw Failure.ambiguousLegacyIdentity(id) }
            var entry = legacy
            entry.carb.provenanceIdentifier = owner; entry.carb.destinationID = id
            if entry.confirmedCarb != nil {
                entry.confirmedCarb?.provenanceIdentifier = owner; entry.confirmedCarb?.destinationID = id
            }
            // A replay may already have stored the namespaced entry. Never overwrite either identity.
            guard staged.entries[entry.carb.storageID] == nil else { throw Failure.ambiguousLegacyIdentity(id) }
            staged.entries[id] = nil; staged.entries[entry.carb.storageID] = entry
        }
        for var carb in carbs.sorted(by: { $0.version < $1.version }) {
            let key = carb.storageID
            if let historyStart, carb.start < historyStart, staged.entries[key] == nil { continue }
            if let existing = staged.entries[key], existing.carb.version > carb.version { continue }
            if carb.deleted, let existing = staged.entries[key], existing.submitted != true {
                staged.entries[key] = nil // Never reached Glooko, so there is nothing to delete there.
                continue
            }
            if carb.deleted, staged.entries[key] == nil { continue }
            carb.destinationID = staged.entries[key]?.carb.destinationID
            staged.entries[key, default: Entry(carb: carb)].carb = carb
        }
        self = staged
    }

    /// Entries whose current version Glooko has not confirmed.
    public var due: [SourceCarb] {
        entries.values.filter { $0.confirmedCarb != $0.carb }
            .map(\.carb).sorted { $0.start < $1.start }
    }

    public mutating func markSubmitted(_ carbs: [SourceCarb]) {
        for carb in carbs { entries[carb.storageID]?.submitted = true }
    }

    public mutating func confirm(_ carb: SourceCarb) {
        guard var entry = entries[carb.storageID], entry.carb == carb else { return }
        entry.confirmedVersion = carb.version; entry.confirmedDeleted = carb.deleted; entry.retireMeal = nil
        entry.confirmedCarb = carb
        entries[carb.storageID] = entry
    }

    /// Deterministic RFC 4122-shaped GUIDs for the meal and food made from one source entry.
    public static func guids(for id: String) -> (meal: String, food: String) {
        (guid("loop-carb-meal|\(id)"), guid("loop-carb-food|\(id)"))
    }

    static func guid(_ seed: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // name-based version
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.joined(separator: "-").uppercased()
    }
}

public extension GlookoClient {
    /// Upserts the meal and food for each carb, then reads `foods` back and returns the carbs Glooko holds as sent.
    func submitCarbs(_ carbs: [SourceCarb], retiringMeals: Set<String> = [], timeZone: TimeZone) async throws -> (confirmed: [SourceCarb], detail: String) {
        guard !carbs.isEmpty else { return ([], "No carbs to send") }
        try Task.checkCancellation()
        let started = Date()
        var readbackFrom = started.addingTimeInterval(-300)
        var meals: [[String: Any]] = [], foods: [[String: Any]] = []
        for carb in carbs {
            let ids = carb.guids
            var records = GlookoRecords.carbs(mealGuid: ids.meal, foodGuid: ids.food, timestamp: carb.start, grams: carb.grams,
                                              deleted: carb.deleted, timeZone: timeZone)
            records.food["mealGuid"] = NSNull()
            if retiringMeals.contains(carb.storageID) {
                records.meal["softDeleted"] = 1
                meals.append(records.meal)
            }
            foods.append(records.food)
        }
        // Retire old meals before re-linking their foods; one invalid record fails a whole batch, so send separately.
        for (resource, records) in [("meals", meals), ("foods", foods)] where !records.isEmpty {
            try Task.checkCancellation()
            let uptime = ProcessInfo.processInfo.systemUptime
            let result = try await put(resource: resource, records: records)
            try Task.checkCancellation()
            if [301, 302, 303, 307, 308, 401, 403, 421].contains(result.status) { throw GlookoError.authenticationRequired(result.status) }
            guard (200..<300).contains(result.status) else {
                throw GlookoError.requestRejected("Glooko rejected the carb \(resource) (HTTP \(result.status))")
            }
            if let serverDate = result.serverDate {
                // The cursor is server update time, not the food's clinical timestamp. Include the whole
                // request and clock skew; each retry upserts again before looking for its current rows.
                readbackFrom = min(readbackFrom, serverDate.addingTimeInterval(-(ProcessInfo.processInfo.systemUptime - uptime) - 300))
            }
        }
        try Task.checkCancellation()
        _ = try? await send("POST", host: region.dataHost,
                            path: "/api/v3/users/activities_and_event_data_sync/complete?syncTimestamp=\(Self.isoTimestamp(Date()))",
                            body: nil, authenticated: true)
        try Task.checkCancellation()
        let scan = await scan("foods", since: Self.isoTimestamp(readbackFrom))
        try Task.checkCancellation()
        guard case .complete = scan.outcome else { return ([], "Carbs sent; Glooko readback incomplete (\(scan.outcome))") }
        let wall = WallClock(timeZone: timeZone)
        let confirmed = carbs.filter { carb in
            let (outcome, record) = scan.match(guid: carb.guids.food)
            switch outcome {
            case .foundDeleted: return carb.deleted
            case .foundLive:
                let grams = (record?["carbs"] as? NSNumber)?.doubleValue
                let stamp = (record?["timestamp"] as? String)?.prefix(19)
                let standalone = record?["mealGuid"] == nil || record?["mealGuid"] is NSNull
                return !carb.deleted && standalone && grams.map { abs($0 - carb.grams) < 0.01 } == true && stamp == wall.string(carb.start).prefix(19)
            default: return false
            }
        }
        return (confirmed, "\(confirmed.count) of \(carbs.count) carb entries confirmed in Glooko")
    }
}
