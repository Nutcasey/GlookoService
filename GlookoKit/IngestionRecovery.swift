import Foundation

/// Durable before-image for the narrow zero-second-marker repair. Kept with the account's history.
public struct IngestionCorrection: Codable, Equatable, Sendable {
    public var index: UInt32
    public var guid: String
    public var original: Data
    public var replacement: Data
    public var attemptedAt: Date
    public var confirmedAt: Date?
}

public extension GlookoClient {
    /// Only repair scheduled basals proven to follow the encoder's zero-second suspend/resume bug.
    /// Persist the before-image before each request; retry by the same GUID and require actual readback.
    /// An unrelated non-zero discrepancy is never overwritten by this recovery.
    func repairZeroDurationBasals(_ manifest: IngestionManifest, recordIntent: (IngestionCorrection) throws -> Void) async throws {
        let expected = manifest.records.filter {
            manifest.repairedBasalIndices.contains($0.index) && $0.resource == "scheduled_basals" && ($0.rate ?? 0) > 0
        }
        guard !expected.isEmpty else { return }
        let pumps = await scan("pumps")
        guard case .complete = pumps.outcome else { throw GlookoError.requestRejected("Could not read Glooko devices before recovery") }
        let devices = pumps.records.filter { ($0["serialNumber"] as? String) == String(manifest.serial) && ($0["softDeleted"] as? Bool) == false }
        guard devices.count == 1, let pump = devices.first?["guid"] as? String else {
            throw GlookoError.requestRejected("Recovery requires one verified Glooko reporting device")
        }
        let since = Self.isoTimestamp((manifest.earliestDate ?? Date()).addingTimeInterval(-86400))
        var snapshot = await scan("pumps/scheduled_basals", since: since)
        guard case .complete = snapshot.outcome else { throw GlookoError.requestRejected("Could not read Glooko basal history before recovery") }
        for item in expected {
            try Task.checkCancellation()
            let candidates = snapshot.records.filter {
                ($0["pumpGuid"] as? String)?.caseInsensitiveCompare(pump) == .orderedSame &&
                ($0["softDeleted"] as? Bool) == false && ($0["pumpTimestamp"] as? String) == item.timestamp &&
                ($0["duration"] as? NSNumber)?.intValue == item.duration
            }
            let correct = candidates.filter { abs((($0["rate"] as? NSNumber)?.doubleValue ?? -.infinity) - item.rate!) < 0.00001 }
            let zeros = candidates.filter { ($0["rate"] as? NSNumber)?.doubleValue == 0 }
            guard correct.count <= 1, correct.count + zeros.count == candidates.count else {
                throw GlookoError.requestRejected("Unexpected basal values or duplicates at history index \(item.index); recovery stopped")
            }
            for (position, row) in zeros.enumerated() {
                guard let guid = row["guid"] as? String, !guid.isEmpty else { throw GlookoError.invalidResponse }
                var replacement = row
                let deletingDuplicate = !correct.isEmpty || position > 0
                if deletingDuplicate { replacement["softDeleted"] = 1 }
                else { replacement["rate"] = item.rate! }
                replacement["updatedAt"] = Self.isoTimestamp(Date())
                let correction = IngestionCorrection(index: item.index, guid: guid,
                    original: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
                    replacement: try JSONSerialization.data(withJSONObject: replacement, options: [.sortedKeys]), attemptedAt: Date())
                try recordIntent(correction)
                try Task.checkCancellation()
                let result = try await put(resource: "pumps/scheduled_basals", records: [replacement])
                if [301, 302, 303, 307, 308, 401, 403, 421].contains(result.status) { throw GlookoError.authenticationRequired(result.status) }
                guard (200..<300).contains(result.status) else { throw GlookoError.requestRejected("Glooko rejected basal recovery (HTTP \(result.status))") }
                snapshot = await scan("pumps/scheduled_basals", since: since)
                guard case .complete = snapshot.outcome,
                      let actual = snapshot.records.first(where: { ($0["guid"] as? String)?.caseInsensitiveCompare(guid) == .orderedSame }),
                      (actual["softDeleted"] as? Bool) == deletingDuplicate,
                      (actual["pumpGuid"] as? String)?.caseInsensitiveCompare(pump) == .orderedSame,
                      (actual["pumpTimestamp"] as? String) == item.timestamp,
                      (actual["duration"] as? NSNumber)?.intValue == item.duration,
                      deletingDuplicate || abs(((actual["rate"] as? NSNumber)?.doubleValue ?? -.infinity) - item.rate!) < 0.00001 else {
                    throw GlookoError.requestRejected("Glooko has not confirmed basal recovery; saved history and the recovery journal are retained")
                }
            }
        }
    }
}
