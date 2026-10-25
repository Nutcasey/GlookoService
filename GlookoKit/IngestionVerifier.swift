import Foundation

public struct IngestionReport: Sendable {
    public var confirmed: Bool
    public var matchedRecords: Int
    public var missingRecords: Int
    public var confirmedThrough: Date?
    public var detail: String
}

/// A manifest of final clinical records. Submission receipts and pump metadata alone cannot satisfy it.
public struct IngestionManifest: Sendable {
    public struct Expected: Sendable {
        public var index: UInt32
        public var resource: String
        public var timestamp: String
        public var duration: Int?
        public var rate: Double?
        public var units: Double?
    }
    public let serial: UInt32
    public let records: [Expected]
    public let through: Date?
    public let earliestDate: Date?

    public init(serial: UInt32, events: [IBFHistoryEvent], timeZone: TimeZone, committedThrough: Date?) {
        self.serial = serial
        earliestDate = events.first?.date
        let lastDelivery = events.last { event in
            switch event.record { case .basal, .suspend, .deactivate: return true; default: return false }
        }
        if let lastDelivery, case .deactivate = lastDelivery.record { through = committedThrough }
        else { through = lastDelivery?.date ?? committedThrough }
        var expected: [Expected] = []
        for (i, event) in events.enumerated() where !event.inProgress {
            let zone = event.utcOffset.flatMap(TimeZone.init(secondsFromGMT:)) ?? timeZone
            let timestamp = WallClock(timeZone: zone).string(Date(timeIntervalSince1970: floor(event.date.timeIntervalSince1970)))
            let next = events.dropFirst(i + 1).first { later in
                switch later.record { case .basal, .suspend, .deactivate: return true; default: return false }
            }
            switch event.record {
            case let .bolus(units, _):
                expected.append(.init(index: event.index, resource: "normal_boluses", timestamp: timestamp,
                                      duration: nil, rate: nil, units: (units * 100).rounded() / 100))
            case let .basal(rate, minutes):
                guard let next else { continue }
                let duration = Int(floor(next.date.timeIntervalSince1970) - floor(event.date.timeIntervalSince1970))
                guard duration > 0 else { continue }
                expected.append(.init(index: event.index, resource: minutes == 0 ? "scheduled_basals" : "temporary_basals",
                                      timestamp: timestamp, duration: minutes == 0 ? duration : min(duration, minutes * 60),
                                      rate: (rate * 100).rounded() / 100, units: nil))
            case .suspend:
                guard let next else { continue }
                let duration = Int(floor(next.date.timeIntervalSince1970) - floor(event.date.timeIntervalSince1970))
                guard duration > 0 else { continue }
                expected.append(.init(index: event.index, resource: "suspend_basals", timestamp: timestamp,
                                      duration: duration, rate: nil, units: nil))
            default: break
            }
        }
        records = expected
    }

    /// Public so offline tools can reconcile a captured response using the exact production contract.
    public func evaluate(pumps: [[String: Any]], rows: [String: [[String: Any]]]) -> IngestionReport {
        let matches = pumps.filter {
            ($0["serialNumber"] as? String) == String(serial) && ($0["softDeleted"] as? Bool) != true
        }
        guard matches.count == 1, let pump = matches.first?["guid"] as? String else {
            return .init(confirmed: false, matchedRecords: 0, missingRecords: records.count,
                         confirmedThrough: nil, detail: "Waiting for one unambiguous Glooko reporting device")
        }
        guard !records.isEmpty else {
            return .init(confirmed: false, matchedRecords: 0, missingRecords: 0, confirmedThrough: nil,
                         detail: "Waiting for the first final clinical record")
        }
        var used = Set<String>()
        var matched = 0
        for expected in records {
            let match = rows[expected.resource, default: []].first { row in
                guard let guid = row["guid"] as? String, !guid.isEmpty, !used.contains(guid),
                      let owner = row["pumpGuid"] as? String, owner.caseInsensitiveCompare(pump) == .orderedSame,
                      (row["softDeleted"] as? Bool) == false,
                      let timestamp = row["pumpTimestamp"] as? String, Self.sameSecond(timestamp, expected.timestamp) else { return false }
                if let duration = expected.duration, (row["duration"] as? NSNumber)?.intValue != duration { return false }
                if let rate = expected.rate, abs(((row["rate"] as? NSNumber)?.doubleValue ?? -.infinity) - rate) > 0.00001 { return false }
                if let units = expected.units, abs(((row["insulinDelivered"] as? NSNumber)?.doubleValue ?? -.infinity) - units) > 0.00001 { return false }
                return true
            }
            if let guid = match?["guid"] as? String { used.insert(guid); matched += 1 }
        }
        let missing = records.count - matched
        return .init(confirmed: missing == 0, matchedRecords: matched, missingRecords: missing,
                     confirmedThrough: missing == 0 ? through : nil,
                     detail: missing == 0 ? "Final records verified in Glooko" : "Waiting for Glooko to finalise \(missing) clinical record(s)")
    }

    private static func sameSecond(_ lhs: String, _ rhs: String) -> Bool {
        func date(_ value: String) -> Date? {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        }
        guard let a = date(lhs), let b = date(rhs) else { return false }
        return abs(a.timeIntervalSince(b)) < 0.001
    }
}

public extension GlookoClient {
    func verifyIngestion(_ manifest: IngestionManifest) async throws -> IngestionReport {
        let pumps = await scan("pumps")
        guard case .complete = pumps.outcome else { throw GlookoError.invalidResponse }
        var rows: [String: [[String: Any]]] = [:]
        let since = GlookoClient.isoTimestamp((manifest.earliestDate ?? Date()).addingTimeInterval(-86400))
        for resource in Set(manifest.records.map(\.resource)).sorted() {
            try Task.checkCancellation()
            let result = await scan("pumps/\(resource)", since: since)
            guard case .complete = result.outcome else { throw GlookoError.invalidResponse }
            rows[resource] = result.records
        }
        return manifest.evaluate(pumps: pumps.records, rows: rows)
    }
}
