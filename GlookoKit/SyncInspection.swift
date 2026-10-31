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
