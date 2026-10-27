import Foundation

/// Checks the report contract separately from device ingestion. It never changes a device's quantities
/// to compensate for an overall-summary bug or combines different devices into a synthetic dose.
public struct GlookoReportAudit: Sendable {
    public var checkedAt: Date
    public var warnings: [String]
}

public extension GlookoClient {
    func auditReports(history: PumpHistoryLog, timeZone: TimeZone, now: Date = Date()) async throws -> GlookoReportAudit {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let wall = WallClock(timeZone: timeZone)
        let todayKey = String(wall.string(today).prefix(10))
        let dayParser = DateFormatter(); dayParser.locale = Locale(identifier: "en_US_POSIX"); dayParser.timeZone = TimeZone(secondsFromGMT: 0); dayParser.dateFormat = "yyyy-MM-dd"
        let dayDisplay = DateFormatter(); dayDisplay.locale = Locale(identifier: "en_GB"); dayDisplay.timeZone = TimeZone(secondsFromGMT: 0); dayDisplay.dateFormat = "d MMMM yyyy"
        let days = Set([history.historyStart, yesterday, today].compactMap { $0 }.filter { $0 <= now }
            .map { String(wall.string($0).prefix(10)) }).sorted()
        let scan = await scan("pumps/daily_insulin_summaries", since: Self.isoTimestamp((history.historyStart ?? yesterday).addingTimeInterval(-86400)))
        guard case .complete = scan.outcome else { throw GlookoError.requestRejected("Glooko daily-summary readback is incomplete") }
        // A device can have multiple cumulative snapshots on one date. Count only its latest snapshot.
        var latest: [String: [String: Any]] = [:]
        for row in scan.records where (row["softDeleted"] as? Bool) == false {
            guard let stamp = row["pumpTimestamp"] as? String, stamp.count >= 10,
                  let pump = row["pumpGuid"] as? String else { throw GlookoError.invalidResponse }
            let day = String(stamp.prefix(10)); guard days.contains(day) else { continue }
            let key = day + "|" + pump
            let previous = latest[key]?["pumpTimestamp"] as? String ?? ""
            if stamp >= previous { latest[key] = row }
        }
        var warnings: [String] = []
        for day in days {
            let label = dayParser.date(from: day).map(dayDisplay.string(from:)) ?? day
            try Task.checkCancellation()
            var query = URLComponents()
            query.queryItems = [URLQueryItem(name: "patient", value: history.ownerID),
                URLQueryItem(name: "startDate", value: day + "T00:00:00.000Z"), URLQueryItem(name: "endDate", value: day + "T23:59:59.999Z"),
                URLQueryItem(name: "includeInsulin", value: "true"), URLQueryItem(name: "includePumpModes", value: "true"),
                URLQueryItem(name: "egv", value: "true"), URLQueryItem(name: "excludeManual", value: "false"),
                URLQueryItem(name: "dow", value: "monday,tuesday,wednesday,thursday,friday,saturday,sunday")]
            let response = try await get("/api/v3/graph/statistics/overall?" + query.percentEncodedQuery!)
            if [401, 403, 421].contains(response.status) { throw GlookoError.authenticationRequired(response.status) }
            guard response.status == 200,
                  let stats = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  let displayed = (stats["totalInsulinPerDay"] as? NSNumber)?.doubleValue, displayed.isFinite else {
                throw GlookoError.invalidResponse
            }
            let snapshots = latest.filter { $0.key.hasPrefix(day + "|") }.map(\.value)
            if day < todayKey, !snapshots.isEmpty {
                var total = 0.0
                for row in snapshots {
                    guard let value = (row["totalInsulin"] as? NSNumber)?.doubleValue, value.isFinite, value >= 0 else { throw GlookoError.invalidResponse }
                    total += value
                }
                if abs(total - displayed) > 0.051 {
                    warnings.append("\(label): Glooko Summary shows \(String(format: "%.1f", displayed)) U; stored device summaries total \(String(format: "%.2f", total)) U. Review this device-transition day in Graphs.")
                }
            }
            let automatic = history.sourceDoses.values.filter {
                $0.kind == .bolus && $0.automatic == true && String(wall.string($0.start).prefix(10)) == day && !$0.isMutable
            }.count
            if automatic > 0, (stats["automaticBolusUnitsPerDay"] as? NSNumber)?.doubleValue == 0 {
                warnings.append("\(label): \(automatic) automatic boluses are retained on this phone; Glooko's pump importer does not retain their automatic labels.")
            }
            if day == todayKey, displayed == 0,
               history.exportedEvents.contains(where: { event in
                   if case .bolus = event.record { return !event.inProgress && String(wall.string(event.date).prefix(10)) == day }
                   return false
               }) {
                warnings.append("\(label): Glooko's current-day insulin summary is still zero although uploaded bolus records exist. Use Graphs for today's records.")
            }
        }
        return .init(checkedAt: now, warnings: warnings)
    }
}
