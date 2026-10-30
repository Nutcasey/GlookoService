import Foundation
import CryptoKit

public struct GlookoAccount: Codable, Equatable, Sendable {
    public let id: String
    public let email: String
    public init(id: String, email: String) { self.id = id; self.email = email }
    public var storageKey: String { SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() }
}

public extension GlookoClient {
    func verifiedAccount(expectedID: String? = nil, expectedEmail: String? = nil) async throws -> GlookoAccount {
        let result = try await get("/api/v2/users")
        if [301, 302, 303, 307, 308, 401, 403, 421].contains(result.status) { throw GlookoError.authenticationRequired(result.status) }
        guard result.status == 200 else {
            throw GlookoError.requestRejected("Glooko account check failed (HTTP \(result.status)); it will be retried")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: result.body) as? [String: Any],
              let users = obj["users"] as? [[String: Any]], users.count == 1,
              let id = users[0]["guid"] as? String, !id.isEmpty,
              let email = users[0]["email"] as? String, !email.isEmpty else {
            throw GlookoError.invalidResponse
        }
        guard (users[0]["softDeleted"] as? Bool) != true,
              expectedID.map({ $0.caseInsensitiveCompare(id) == .orderedSame }) ?? true,
              expectedEmail.map({ $0.caseInsensitiveCompare(email) == .orderedSame }) ?? true else {
            throw HistoryRepository.Failure.accountMismatch
        }
        return GlookoAccount(id: id.lowercased(), email: email)
    }
}

/// Files are partitioned by the verified patient GUID. Read/decode failures always propagate.
public struct HistoryRepository {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public enum Failure: Error, CustomStringConvertible {
        case missingHistory, accountMismatch, unownedLegacyHistory
        public var description: String {
            switch self {
            case .missingHistory: return "The saved pump history is missing. Uploads are paused; restore its backup before continuing."
            case .accountMismatch: return "The verified Glooko account does not match this history. Remove the service before choosing another account."
            case .unownedLegacyHistory: return "Existing pump history has no verified owner. Restore the previous service account to migrate it."
            }
        }
    }

    /// User-requested removal covers every account, archive and legacy backup in this plugin's directory.
    /// Returns existing account storage keys so the caller can remove their corresponding credentials too.
    public func localAccountStorageKeys() throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent).filter { $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }
    }
    public func eraseAllLocalData() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// Retired glucose uploader cache only; never remove Loop's primary glucose store.
    public func removeRetiredGlucoseData(accountID: String) throws {
        let folder = directory.appendingPathComponent(GlookoAccount(id: accountID, email: "").storageKey)
        for name in ["glucose.json", "glucose-initialised"] {
            let file = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }

    private var legacyURL: URL { directory.appendingPathComponent("pump-history.json") }
    private func url(accountID: String) -> URL {
        directory.appendingPathComponent(GlookoAccount(id: accountID, email: "").storageKey, isDirectory: true)
            .appendingPathComponent("pump-history.json")
    }

    public func loadExisting(accountID: String?, legacyEmail: String?) throws -> PumpHistoryLog {
        let location = accountID.map(url(accountID:)) ?? legacyURL
        guard FileManager.default.fileExists(atPath: location.path) else { throw Failure.missingHistory }
        var history = try Self.decode(Data(contentsOf: location))
        if let accountID {
            guard history.ownerID == accountID else { throw Failure.accountMismatch }
        } else if let legacyEmail {
            if let email = history.ownerEmail, email.caseInsensitiveCompare(legacyEmail) != .orderedSame { throw Failure.accountMismatch }
            history.ownerEmail = legacyEmail
        } else { throw Failure.unownedLegacyHistory }
        return history
    }

    public func bind(_ account: GlookoAccount, legacyEmail: String? = nil) throws -> PumpHistoryLog {
        let location = url(accountID: account.id)
        if FileManager.default.fileExists(atPath: location.path) {
            return try loadExisting(accountID: account.id, legacyEmail: nil)
        }
        var history: PumpHistoryLog
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            history = try Self.decode(Data(contentsOf: legacyURL))
            if let owner = history.ownerID {
                if owner != account.id {
                    // Another patient's migrated legacy file is retained but never inherited.
                    history = .newIdentity()
                }
            } else {
                let ownerEmail = history.ownerEmail ?? legacyEmail
                guard ownerEmail?.caseInsensitiveCompare(account.email) == .orderedSame else { throw Failure.unownedLegacyHistory }
                let backup = directory.appendingPathComponent("legacy-backup-\(history.serial).json")
                if !FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.copyItem(at: legacyURL, to: backup) }
                history.ownerID = account.id; history.ownerEmail = account.email
                // Bind the retained legacy file too, so another account cannot claim it after deletion.
                try write(history, to: legacyURL)
            }
        } else { history = .newIdentity() }
        history.ownerID = account.id; history.ownerEmail = account.email
        try save(history)
        return history
    }

    public func save(_ history: PumpHistoryLog) throws {
        if let owner = history.ownerID { try write(history, to: url(accountID: owner)) }
        else if history.ownerEmail != nil { try write(history, to: legacyURL) }
        else { throw Failure.unownedLegacyHistory }
    }

    public func archive(_ history: PumpHistoryLog) throws {
        let location = directory.appendingPathComponent("archive-\(history.serial)-\(UUID().uuidString).json")
        try write(history, to: location)
    }

    public func archiveUnreadable(accountID: String) throws {
        let original = url(accountID: accountID)
        if FileManager.default.fileExists(atPath: original.path) {
            try FileManager.default.copyItem(at: original,
                                            to: directory.appendingPathComponent("unreadable-\(UUID().uuidString).json"))
        }
    }

    private func write(_ history: PumpHistoryLog, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try StoredJSON.encoder().encode(history).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public static func decode(_ data: Data) throws -> PumpHistoryLog {
        try StoredJSON.decoder().decode(PumpHistoryLog.self, from: data)
    }
}

/// Preserve the source's complete Date value; accept the ISO strings used by earlier versions.
enum StoredJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            try value.encode(date.timeIntervalSinceReferenceDate)
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let seconds = try? value.decode(Double.self), seconds.isFinite { return Date(timeIntervalSinceReferenceDate: seconds) }
            let text = try value.decode(String.self)
            let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) else {
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid saved date")
            }
            return date
        }
        return decoder
    }
}
