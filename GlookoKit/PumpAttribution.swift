import Foundation

/// Software provenance for Loop's own virtual pump. The catalogue identity and clinical data stay intact.
public struct PumpAttribution: Sendable {
    public let serial: UInt32
    public let sourceName: String
    public var displayName: String { sourceName + " via Loop" }
    public var externalID: String { "loop:glookoservice:\(serial)" }

    public init(serial: UInt32, sourceName: String) {
        self.serial = serial
        self.sourceName = sourceName
    }
}

public extension GlookoClient {
    /// The caller must verify the account and bind the serial to its saved Loop history first.
    /// Never creates a device, changes its catalogue identity, or labels the shared CSV glucose source.
    @discardableResult
    func identifyLoopPump(_ attribution: PumpAttribution) async throws -> String {
        guard (1...999_999_999).contains(attribution.serial),
              !attribution.sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GlookoError.requestRejected("A real Loop pump source is required before labelling uploads")
        }
        func reportingPump() async throws -> [String: Any] {
            let result = await scan("pumps")
            guard case .complete = result.outcome else {
                throw GlookoError.requestRejected("Could not read Glooko devices to verify the Loop source label")
            }
            let matches = result.records.filter {
                ($0["serialNumber"] as? String) == String(attribution.serial) && ($0["softDeleted"] as? Bool) == false
            }
            guard matches.count == 1, let pump = matches.first,
                  let guid = pump["guid"] as? String, !guid.isEmpty,
                  (pump["referenceDeviceId"] as? String) == "INSULET_OMNIPOD" else {
                throw GlookoError.requestRejected("The Loop source label requires one existing virtual Omnipod reporting device")
            }
            let external = pump["externalId"]
            guard external == nil || external is NSNull || (external as? String) == "" ||
                    (external as? String) == attribution.externalID else {
                throw GlookoError.requestRejected("The reporting device already has another source identifier; its label was left intact")
            }
            return pump
        }
        let before = try await reportingPump()
        let guid = before["guid"] as! String
        if (before["model"] as? String) != attribution.displayName || (before["externalId"] as? String) != attribution.externalID {
            // Sparse metadata update: do not replay read-only counters or overwrite unrelated device properties.
            let replacement: [String: Any] = ["guid": guid, "model": attribution.displayName,
                "externalId": attribution.externalID, "updatedAt": Self.isoTimestamp(Date())]
            try Task.checkCancellation()
            let response = try await put(resource: "pumps", records: [replacement])
            if [301, 302, 303, 307, 308, 401, 403, 421].contains(response.status) {
                throw GlookoError.authenticationRequired(response.status)
            }
            guard (200..<300).contains(response.status) else {
                throw GlookoError.requestRejected("Glooko rejected the Loop source label (HTTP \(response.status))")
            }
        }
        let after = try await reportingPump()
        guard (after["guid"] as? String) == guid,
              (after["brand"] as? String) == (before["brand"] as? String),
              (after["model"] as? String) == attribution.displayName,
              (after["externalId"] as? String) == attribution.externalID else {
            throw GlookoError.requestRejected("Glooko has not confirmed the Loop source label")
        }
        return guid
    }
}
