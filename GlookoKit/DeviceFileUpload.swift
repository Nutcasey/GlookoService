import Foundation

public extension GlookoClient {
    /// The current web app posts the file itself, not a multipart form or an SSV2 record envelope.
    /// A successful response acknowledges submission only; history/report readback must prove ingestion.
    func uploadDeviceFile(_ data: Data, extractorName: String) async throws -> HTTPResult {
        guard extractorName.range(of: #"^[A-Za-z][A-Za-z0-9_]{0,63}$"#, options: .regularExpression) != nil else {
            throw DeviceUploadError.invalidExtractor
        }
        return try await send("POST", host: region.dataHost,
                              path: "/api/v3/device/file/upload?extractorName=\(extractorName)",
                              body: data, authenticated: true,
                              headers: ["Content-Type": "application/octet-stream",
                                        "Origin": "https://eu.my.glooko.com",
                                        "Referer": "https://eu.my.glooko.com/"])
    }

    /// Verify the server's account identity before a probe mutation. A Keychain profile is only a label.
    func requireAccount(email expectedEmail: String) async throws {
        let result = try await get("/api/v2/users")
        guard result.status == 200,
              let object = try? JSONSerialization.jsonObject(with: result.body) as? [String: Any],
              let users = object["users"] as? [[String: Any]], users.count == 1,
              let email = users[0]["email"] as? String,
              email.caseInsensitiveCompare(expectedEmail) == .orderedSame,
              (users[0]["softDeleted"] as? Bool) == false else {
            throw DeviceUploadError.accountNotVerified(status: result.status)
        }
    }
}

public enum DeviceUploadError: Error, CustomStringConvertible {
    case invalidExtractor
    case accountNotVerified(status: Int)

    public var description: String {
        switch self {
        case .invalidExtractor:
            return "Extractor must start with a letter and contain at most 64 letters, digits or underscores"
        case .accountNotVerified(let status):
            return "Refusing mutation: the session did not verify as the allowlisted test account (HTTP \(status))"
        }
    }
}
