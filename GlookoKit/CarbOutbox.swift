import Foundation
import CryptoKit

/// One version of a source carbohydrate entry, keyed by its stable source identifier.
public struct SourceCarb: Codable, Equatable, Sendable {
    public var id: String
    public var start: Date
    public var grams: Double
    public var version: Int
    public var deleted: Bool

    public init(id: String, start: Date, grams: Double, version: Int, deleted: Bool) {
        self.id = id; self.start = start; self.grams = grams; self.version = version; self.deleted = deleted
    }
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
    }

    public private(set) var entries: [String: Entry] = [:]
    /// Entries before this are not reported (they predate the service's history start).
    public var historyStart: Date?
    /// 2: standalone foods. nil: written by the version that wrapped each food in a snack meal.
    public var format: Int?

    public init(historyStart: Date? = nil) { self.historyStart = historyStart; format = 2 }

    /// Resends entries submitted as snack meals so they become standalone foods, and retires their meals.
    public mutating func migrateToStandaloneFoods() {
        guard format != 2 else { return }
        for (id, entry) in entries where entry.submitted == true {
            entries[id]?.retireMeal = true
            entries[id]?.confirmedVersion = nil
        }
        format = 2
    }

    public var retiringMeals: Set<String> { Set(entries.filter { $0.value.retireMeal == true }.keys) }

    /// Applies source versions in order; an older version never replaces a newer one.
    public mutating func stage(_ carbs: [SourceCarb]) {
        for carb in carbs.sorted(by: { $0.version < $1.version }) {
            if let historyStart, carb.start < historyStart, entries[carb.id] == nil { continue }
            if let existing = entries[carb.id], existing.carb.version > carb.version { continue }
            if carb.deleted, let existing = entries[carb.id], existing.submitted != true {
                entries[carb.id] = nil // Never reached Glooko, so there is nothing to delete there.
                continue
            }
            if carb.deleted, entries[carb.id] == nil { continue }
            entries[carb.id, default: Entry(carb: carb)].carb = carb
        }
    }

    /// Entries whose current version Glooko has not confirmed.
    public var due: [SourceCarb] {
        entries.values.filter { $0.confirmedVersion != $0.carb.version || $0.confirmedDeleted != $0.carb.deleted }
            .map(\.carb).sorted { $0.start < $1.start }
    }

    public mutating func markSubmitted(_ carbs: [SourceCarb]) {
        for carb in carbs { entries[carb.id]?.submitted = true }
    }

    public mutating func confirm(_ carb: SourceCarb) {
        guard var entry = entries[carb.id], entry.carb == carb else { return }
        entry.confirmedVersion = carb.version; entry.confirmedDeleted = carb.deleted; entry.retireMeal = nil
        entries[carb.id] = entry
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
        var meals: [[String: Any]] = [], foods: [[String: Any]] = []
        for carb in carbs {
            let ids = CarbOutbox.guids(for: carb.id)
            var records = GlookoRecords.carbs(mealGuid: ids.meal, foodGuid: ids.food, timestamp: carb.start, grams: carb.grams,
                                              deleted: carb.deleted, timeZone: timeZone)
            records.food["mealGuid"] = NSNull()
            if retiringMeals.contains(carb.id) {
                records.meal["softDeleted"] = 1
                meals.append(records.meal)
            }
            foods.append(records.food)
        }
        // Retire old meals before re-linking their foods; one invalid record fails a whole batch, so send separately.
        for (resource, records) in [("meals", meals), ("foods", foods)] where !records.isEmpty {
            let result = try await put(resource: resource, records: records)
            if [301, 302, 303, 307, 308, 401, 403, 421].contains(result.status) { throw GlookoError.authenticationRequired(result.status) }
            guard (200..<300).contains(result.status) else {
                throw GlookoError.requestRejected("Glooko rejected the carb \(resource) (HTTP \(result.status))")
            }
        }
        _ = try? await send("POST", host: region.dataHost,
                            path: "/api/v3/users/activities_and_event_data_sync/complete?syncTimestamp=\(Self.isoTimestamp(Date()))",
                            body: nil, authenticated: true)
        let scan = await scan("foods")
        guard case .complete = scan.outcome else { return ([], "Carbs sent; Glooko readback incomplete (\(scan.outcome))") }
        let wall = WallClock(timeZone: timeZone)
        let confirmed = carbs.filter { carb in
            let (outcome, record) = scan.match(guid: CarbOutbox.guids(for: carb.id).food)
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
