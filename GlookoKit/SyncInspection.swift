import Foundation

public struct GlookoSyncInspection: Codable, Sendable {
    public var checkedAt: Date
    public var sourceSnapshotAt: Date
    public var day: String
    public var insulinVerified: Bool
    public var insulinMatched: Int
    public var insulinMissing: Int
    public var insulinMismatched: Int
    public var insulinDuplicates: Int
    public var insulinDeferred: Int
    public var reportWarnings: [String]
    public var glucose: GlucoseVerification? = nil
}

public extension GlookoClient {
    /// GETs only. Completion is distinct from file submission and from visibility in a particular app screen.
    func inspectSync(history: PumpHistoryLog, timeZone: TimeZone, now: Date = Date()) async throws -> GlookoSyncInspection {
        let day = String(WallClock(timeZone: timeZone).string(now).prefix(10))
        let manifest = IngestionManifest(serial: history.serial, events: history.exportedEvents, timeZone: timeZone,
            committedThrough: history.committedThrough, repairedBasalIndices: history.repairedBasalIndices)
        let insulin = try await verifyIngestion(manifest)
        let audit = try await auditReports(history: history, timeZone: timeZone, now: now)
        return .init(checkedAt: Date(), sourceSnapshotAt: now, day: day,
            insulinVerified: insulin.confirmed, insulinMatched: insulin.matchedRecords, insulinMissing: insulin.missingRecords,
            insulinMismatched: insulin.mismatchedRecords, insulinDuplicates: insulin.duplicateRecords,
            insulinDeferred: insulin.deferredRecords, reportWarnings: audit.warnings)
    }
}
