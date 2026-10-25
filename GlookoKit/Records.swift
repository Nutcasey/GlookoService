import Foundation

/// Builders for the record shapes the Glooko app sends (see research/glooko/app-write-protocol.md).
public enum GlookoRecords {
    public static func newGuid() -> String { UUID().uuidString }

    /// The app's paged-sync read: `GET /api/v2/<resource>?lastUpdatedAt=…&lastGuid=…&limit=…&sendSoftDeleted=…`.
    public static func syncQuery(_ resource: String, since: String = "1970-01-01T00:00:00.000Z",
                                 lastGuid: String = "00000000-0000-0000-0000-000000000000", limit: Int = 100) -> String {
        "/api/v2/\(resource)?lastUpdatedAt=\(since)&lastGuid=\(lastGuid)&limit=\(limit)&sendSoftDeleted=true"
    }

    /// A manual insulin entry, as `PUT /api/v2/insulins` expects it.
    public static func insulin(guid: String, timestamp: Date, units: Double, type: String,
                               medicationGuid: String = "NOVO_NOVORAPID", deleted: Bool = false,
                               extra: [String: Any] = [:], timeZone: TimeZone = .current) -> [String: Any] {
        let now = GlookoClient.isoTimestamp(Date())
        var r: [String: Any] = [
            "guid": guid, "timestamp": WallClock(timeZone: timeZone).string(timestamp), "value": units,
            "insulinType": type, "medicationGuid": medicationGuid, "softDeleted": deleted ? 1 : 0,
            "deviceDelivered": 0, "manuallyEnteredText": false,
            "pumpGuid": NSNull(), "insulinPenGuid": NSNull(), "cgmDeviceGuid": NSNull(), "externalId": NSNull(),
            "updatedAt": now, "syncTimestamp": now,
        ]
        r.merge(extra) { _, new in new }
        return r
    }

    /// A Quick Add carb entry is a meal plus a food linked by `mealGuid`.
    public static func carbs(mealGuid: String, foodGuid: String, timestamp: Date, grams: Double,
                             mealType: String = "snack", deleted: Bool = false,
                             timeZone: TimeZone = .current) -> (meal: [String: Any], food: [String: Any]) {
        let now = GlookoClient.isoTimestamp(Date())
        let ts = WallClock(timeZone: timeZone).string(timestamp)
        let meal: [String: Any] = [
            "guid": mealGuid, "type": mealType, "timestamp": ts, "name": NSNull(), "favoriteGuid": NSNull(),
            "contextTagGuids": [String](), "softDeleted": deleted ? 1 : 0, "updatedAt": now,
        ]
        let food: [String: Any] = [
            "guid": foodGuid, "mealGuid": mealGuid, "source": "QuickAdd", "carbs": grams, "name": "",
            "calories": NSNull(), "fat": NSNull(), "protein": NSNull(), "servingQuantity": 0, "servingUnit": NSNull(),
            "brand": NSNull(), "locale": NSNull(), "imageUrl": NSNull(), "timestamp": ts, "favoriteGuid": NSNull(),
            "externalId": NSNull(), "manuallyEnteredText": false, "softDeleted": deleted ? 1 : 0,
            "updatedAt": now, "syncTimestamp": now,
        ]
        return (meal, food)
    }
}
