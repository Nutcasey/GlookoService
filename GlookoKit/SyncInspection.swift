import Foundation

public struct GlookoGlucoseEvidence: Codable, Sendable {
    public var expected: Int
    public var stored: Int
    public var graphed: Int
    public var matchedStored: Int
    public var matchedGraphed: Int
    public var duplicates: Int
    public var latestSource: Date?
    public var latestStoredMinute: String?
    public var latestGraphMinute: String?
    public var verified: Bool { expected > 0 && matchedStored == expected && matchedGraphed == expected && duplicates == 0 }
}

public struct GlookoSyncInspection: Codable, Sendable {
    public var checkedAt: Date
    public var sourceSnapshotAt: Date
    public var day: String
    public var glucose: GlookoGlucoseEvidence
    public var insulinVerified: Bool
    public var insulinMatched: Int
    public var insulinMissing: Int
    public var insulinMismatched: Int
    public var insulinDuplicates: Int
    public var insulinDeferred: Int
    public var reportWarnings: [String]
}

/// Evaluate the independently fetched stored readings and chart points against Loop's captured values.
func glucoseEvidence(_ expected: [SourceGlucose], stored: [[String: Any]], graph: [String: [Int]], day: String) throws -> GlookoGlucoseEvidence {
    var indexed: [String: [Int]] = [:]
    for row in stored where (row["softDeleted"] as? Bool) == false {
        guard let stamp = row["displayTime"] as? String, stamp.count >= 16,
              let value = row["glucoseValue"] as? NSNumber else { throw GlookoError.invalidResponse }
        guard stamp.hasPrefix(day) else { continue }
        indexed[String(stamp.prefix(16)), default: []].append(value.intValue)
    }
    let readings = expected.filter { $0.minute.hasPrefix(day) }
    var storedMatches = 0, graphMatches = 0, duplicates = 0
    for reading in readings {
        let values = indexed[reading.minute] ?? [], points = graph[reading.minute] ?? []
        if values.count == 1 && values[0] == reading.encodedValue { storedMatches += 1 }
        if points.count == 1 && points[0] == reading.encodedValue { graphMatches += 1 }
        duplicates += max(0, values.count - 1) + max(0, points.count - 1)
    }
    let todayGraph = graph.filter { $0.key.hasPrefix(day) }
    return .init(expected: readings.count, stored: indexed.values.reduce(0) { $0 + $1.count },
        graphed: todayGraph.values.reduce(0) { $0 + $1.count }, matchedStored: storedMatches, matchedGraphed: graphMatches,
        duplicates: duplicates, latestSource: readings.map(\.date).max(), latestStoredMinute: indexed.keys.max(),
        latestGraphMinute: todayGraph.keys.max())
}

public extension GlookoClient {
    /// GETs only. Completion is distinct from file submission and from visibility in a particular app screen.
    func inspectSync(history: PumpHistoryLog, glucose: [SourceGlucose], timeZone: TimeZone, now: Date = Date()) async throws -> GlookoSyncInspection {
        let day = String(WallClock(timeZone: timeZone).string(now).prefix(10))
        let manifest = IngestionManifest(serial: history.serial, events: history.exportedEvents, timeZone: timeZone,
            committedThrough: history.committedThrough, repairedBasalIndices: history.repairedBasalIndices)
        let insulin = try await verifyIngestion(manifest)
        let egvs = await scan("cgm/egvs", since: Self.isoTimestamp(now.addingTimeInterval(-2 * 86400)))
        guard case .complete = egvs.outcome else { throw GlookoError.requestRejected("Stored glucose readback is incomplete") }
        let session = try await get("/api/v3/session/users")
        guard session.status == 200,
              let object = try JSONSerialization.jsonObject(with: session.body) as? [String: Any],
              let user = object["currentUser"] as? [String: Any], let code = user["glookoCode"] as? String else { throw GlookoError.invalidResponse }
        let graph = try await glucoseGraph(days: [day], code: code)
        let evidence = try glucoseEvidence(glucose, stored: egvs.records, graph: graph, day: day)
        let audit = try await auditReports(history: history, timeZone: timeZone, now: now)
        return .init(checkedAt: Date(), sourceSnapshotAt: now, day: day, glucose: evidence,
            insulinVerified: insulin.confirmed, insulinMatched: insulin.matchedRecords, insulinMissing: insulin.missingRecords,
            insulinMismatched: insulin.mismatchedRecords, insulinDuplicates: insulin.duplicateRecords,
            insulinDeferred: insulin.deferredRecords, reportWarnings: audit.warnings)
    }
}
