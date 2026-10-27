import Foundation

public struct IngestionReport: Sendable {
    public var confirmed: Bool
    public var matchedRecords: Int
    public var missingRecords: Int
    public var confirmedThrough: Date?
    public var detail: String
    public var mismatchedRecords: Int = 0
    public var duplicateRecords: Int = 0
    public var deferredRecords: Int = 0
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
    public let deferredRecords: Int
    public let repairedBasalIndices: Set<UInt32>
    public let verifiedThroughIndex: UInt32

    public init(serial: UInt32, events: [IBFHistoryEvent], timeZone: TimeZone, committedThrough: Date?, repairedBasalIndices: Set<UInt32> = []) {
        self.serial = serial
        earliestDate = events.first?.date
        let lastDelivery = events.last { event in
            switch event.record { case .basal, .suspend, .deactivate: return true; default: return false }
        }
        var finalThrough: Date?
        if let lastDelivery, case .deactivate = lastDelivery.record { finalThrough = committedThrough }
        else { finalThrough = lastDelivery?.date ?? committedThrough }
        var expected: [Expected] = []
        var deferred = 0
        var finalIndex = events.last?.index ?? 0
        if let open = events.first(where: \.inProgress) { finalIndex = open.index > 0 ? open.index - 1 : 0 }
        var followingDelivery: [Int: IBFHistoryEvent] = [:]
        var nextDelivery: IBFHistoryEvent?
        for i in events.indices.reversed() {
            followingDelivery[i] = nextDelivery
            switch events[i].record { case .basal, .suspend, .deactivate: nextDelivery = events[i]; default: break }
        }
        for (i, event) in events.enumerated() where !event.inProgress {
            let zone = event.utcOffset.flatMap(TimeZone.init(secondsFromGMT:)) ?? timeZone
            let timestamp = WallClock(timeZone: zone).string(Date(timeIntervalSince1970: floor(event.date.timeIntervalSince1970)))
            let next = followingDelivery[i]
            switch event.record {
            case let .bolus(units, _):
                expected.append(.init(index: event.index, resource: "normal_boluses", timestamp: timestamp,
                                      duration: nil, rate: nil, units: (units * 100).rounded() / 100))
            case let .basal(rate, minutes):
                guard let next else { continue }
                // Glooko does not finalise the interval ending at an IN_PROGRESS basal until a
                // later transition. Its timestamp is a boundary, not evidence of final ingestion.
                if next.inProgress {
                    deferred += 1; finalThrough = min(finalThrough ?? event.date, event.date)
                    finalIndex = min(finalIndex, event.index > 0 ? event.index - 1 : 0); continue
                }
                let duration = Int(floor(next.date.timeIntervalSince1970) - floor(event.date.timeIntervalSince1970))
                guard duration > 0 else { continue }
                expected.append(.init(index: event.index, resource: minutes == 0 ? "scheduled_basals" : "temporary_basals",
                                      timestamp: timestamp, duration: minutes == 0 ? duration : min(duration, minutes * 60),
                                      rate: (rate * 100).rounded() / 100, units: nil))
            case .suspend:
                guard let next else { continue }
                if next.inProgress {
                    deferred += 1; finalThrough = min(finalThrough ?? event.date, event.date)
                    finalIndex = min(finalIndex, event.index > 0 ? event.index - 1 : 0); continue
                }
                let duration = Int(floor(next.date.timeIntervalSince1970) - floor(event.date.timeIntervalSince1970))
                guard duration > 0 else { continue }
                expected.append(.init(index: event.index, resource: "suspend_basals", timestamp: timestamp,
                                      duration: duration, rate: nil, units: nil))
            default: break
            }
        }
        records = expected
        through = finalThrough.map { Date(timeIntervalSince1970: floor($0.timeIntervalSince1970)) }
        deferredRecords = deferred
        verifiedThroughIndex = finalIndex
        self.repairedBasalIndices = repairedBasalIndices.intersection(Set(expected.map(\.index)))
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
                         detail: "Waiting for the first final clinical record", deferredRecords: deferredRecords)
        }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        func timestamp(_ value: String) -> Double? {
            (fractional.date(from: value) ?? whole.date(from: value))?.timeIntervalSince1970
        }
        struct Candidate {
            var guid: String
            var time: Double
            var row: [String: Any]
        }
        var indexed: [String: [Int64: [Candidate]]] = [:]
        for (resource, records) in rows {
            for row in records {
                guard let guid = row["guid"] as? String, !guid.isEmpty,
                      let owner = row["pumpGuid"] as? String, owner.caseInsensitiveCompare(pump) == .orderedSame,
                      (row["softDeleted"] as? Bool) == false,
                      let text = row["pumpTimestamp"] as? String, let time = timestamp(text) else { continue }
                indexed[resource, default: [:]][Int64((time * 1000).rounded()), default: []]
                    .append(Candidate(guid: guid, time: time, row: row))
            }
        }
        struct Key: Hashable { var resource: String; var time: Int64 }
        var used = Set<String>(), expectedCounts: [Key: Int] = [:], matchedCounts: [Key: Int] = [:]
        var matched = 0
        for expected in records {
            guard let time = timestamp(expected.timestamp) else { continue }
            let key = Int64((time * 1000).rounded())
            let group = Key(resource: expected.resource, time: key)
            expectedCounts[group, default: 0] += 1
            // Adjacent buckets preserve the original sub-millisecond tolerance at rounding boundaries.
            let candidates = (-1...1).flatMap { indexed[expected.resource]?[key + Int64($0)] ?? [] }
            let match = candidates.first { candidate in
                guard !used.contains(candidate.guid), abs(candidate.time - time) < 0.001 else { return false }
                let row = candidate.row
                if let duration = expected.duration, (row["duration"] as? NSNumber)?.intValue != duration { return false }
                if let rate = expected.rate, abs(((row["rate"] as? NSNumber)?.doubleValue ?? -.infinity) - rate) > 0.00001 { return false }
                if let units = expected.units, abs(((row["insulinDelivered"] as? NSNumber)?.doubleValue ?? -.infinity) - units) > 0.00001 { return false }
                return true
            }
            if let match { used.insert(match.guid); matched += 1; matchedCounts[group, default: 0] += 1 }
        }
        var mismatched = 0, duplicates = 0
        for (key, count) in expectedCounts {
            var candidates: [Candidate] = []
            for offset in -1...1 { candidates += indexed[key.resource]?[key.time + Int64(offset)] ?? [] }
            let eligible = candidates.filter { abs($0.time - Double(key.time) / 1000) < 0.001 }
            let unused = Set(eligible.map { $0.guid }).subtracting(used).count
            let unmatched = count - (matchedCounts[key] ?? 0)
            mismatched += min(unused, unmatched)
            duplicates += max(0, unused - unmatched)
        }
        let missing = records.count - matched
        let confirmed = missing == 0 && duplicates == 0
        var details: [String] = []
        if confirmed { details.append("Final records verified in Glooko") }
        if mismatched > 0 { details.append("\(mismatched) Glooko record(s) differ from the saved history") }
        if duplicates > 0 { details.append("\(duplicates) duplicate Glooko record(s) need review") }
        if missing > mismatched { details.append("Waiting for Glooko to ingest \(missing - mismatched) final record(s)") }
        if deferredRecords > 0 { details.append("\(deferredRecords) recent interval(s) await later pump history") }
        return .init(confirmed: confirmed, matchedRecords: matched, missingRecords: missing,
                     confirmedThrough: confirmed ? through : nil, detail: details.joined(separator: ". "),
                     mismatchedRecords: mismatched, duplicateRecords: duplicates, deferredRecords: deferredRecords)
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
