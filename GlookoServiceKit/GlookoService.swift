import Foundation
import os.log
import LoopKit

/// Reporting-only Loop service that sends Loop's pump insulin history to Glooko.
///
/// Glooko accepts pump history as an Insulet PDM download (IBF) posted to the patient web upload route,
/// so this service keeps a durable virtual-PDM history (`PumpHistoryLog`) and uploads it. It never
/// doses, changes settings or acts on remote commands.
public final class GlookoService: Service {
    public static let pluginIdentifier = "GlookoService"
    public static let localizedTitle = "Glooko"

    public weak var serviceDelegate: ServiceDelegate?
    public weak var stateDelegate: StatefulPluggableDelegate?

    /// Glooko account e-mail; the password and session live in the Keychain.
    public private(set) var email: String?
    public private(set) var isOnboarded: Bool
    public private(set) var status: Status

    public struct Status: Equatable {
        public var lastUploadAt: Date?
        public var lastAttemptAt: Date?
        public var lastError: String?
        public var uploadedThrough: Date?
    }

    private let log = OSLog(subsystem: "com.loopkit.GlookoService", category: "GlookoService")
    private let queue = DispatchQueue(label: "com.loopkit.GlookoService")
    private var history: PumpHistoryLog
    private var basalProgram: [Double]?
    private var uploading = false
    private var client: GlookoClient?
    /// Minimum spacing between automatic uploads. Loop calls in every five minutes.
    private let uploadInterval: TimeInterval = 15 * 60
    public static let region = GlookoClient.Region(signInHosts: ["eu.api.glooko.com", "global.api.glooko.com"],
                                                   dataHost: "eu.api.glooko.com")

    public init() {
        isOnboarded = false
        status = Status()
        history = Self.loadHistory() ?? PumpHistoryLog.newIdentity()
    }

    public init?(rawState: RawStateValue) {
        email = rawState["email"] as? String
        isOnboarded = rawState["isOnboarded"] as? Bool ?? false
        status = Status(lastUploadAt: rawState["lastUploadAt"] as? Date, lastAttemptAt: rawState["lastAttemptAt"] as? Date,
                        lastError: rawState["lastError"] as? String, uploadedThrough: rawState["uploadedThrough"] as? Date)
        basalProgram = rawState["basalProgram"] as? [Double]
        history = Self.loadHistory() ?? PumpHistoryLog.newIdentity()
        if let cookie = try? KeychainManager().getGenericPasswordForService(Self.sessionKeychainService) {
            client = GlookoClient(region: Self.region, sessionCookie: cookie)
        }
    }

    public var rawState: RawStateValue {
        var state: RawStateValue = ["isOnboarded": isOnboarded]
        state["email"] = email
        state["lastUploadAt"] = status.lastUploadAt
        state["lastAttemptAt"] = status.lastAttemptAt
        state["lastError"] = status.lastError
        state["uploadedThrough"] = status.uploadedThrough
        state["basalProgram"] = basalProgram
        return state
    }

    // MARK: Account

    /// Signs in and verifies the account the session belongs to. Credentials are kept only in the Keychain.
    public func signIn(email: String, password: String, historyStart: Date? = nil) async throws -> String {
        let client = GlookoClient(region: Self.region)
        try await client.signIn(email: email, password: password)
        let identity = try await Self.accountEmail(client)
        try KeychainManager().replaceGenericPassword(password, forService: Self.passwordKeychainService)
        try KeychainManager().replaceGenericPassword(client.sessionCookie, forService: Self.sessionKeychainService)
        try queue.sync {
            // The start only applies to a history that has not been uploaded, so sent records never change.
            if let historyStart, history.lastUploadedIndex == nil {
                history = PumpHistoryLog.newIdentity()
                history.historyStart = historyStart
                try saveHistory()
            }
            self.email = identity
            self.client = client
            self.isOnboarded = true
            self.status.lastError = nil
        }
        stateDelegate?.pluginDidUpdateState(self)
        return identity
    }

    public func completeDelete() {
        try? KeychainManager().replaceGenericPassword(nil as String?, forService: Self.passwordKeychainService)
        try? KeychainManager().replaceGenericPassword(nil as String?, forService: Self.sessionKeychainService)
        // Once anything is uploaded the history file is kept: re-adding the service continues the same virtual
        // PDM instead of sending a second copy of the delivery under a new serial. Never-uploaded history is
        // discarded, and Loop resends its retained doses to a re-added service.
        if queue.sync(execute: { history.lastUploadedIndex == nil }) { try? FileManager.default.removeItem(at: Self.historyURL) }
        stateDelegate?.pluginWantsDeletion(self)
    }

    static func accountEmail(_ client: GlookoClient) async throws -> String {
        let result = try await client.get("/api/v2/users")
        guard result.status == 200,
              let object = try? JSONSerialization.jsonObject(with: result.body) as? [String: Any],
              let users = object["users"] as? [[String: Any]], users.count == 1,
              let email = users[0]["email"] as? String else { throw ServiceError.accountNotVerified(result.status) }
        return email
    }

    // MARK: History

    public struct Summary {
        public var serial: UInt32
        public var historyStart: Date?
        public var records: Int
        public var pendingDoses: Int
        public var committedThrough: Date?
        public var lateDoses: Int
        public var hasUnuploadedRecords: Bool
    }

    public var summary: Summary {
        queue.sync {
            Summary(serial: history.serial, historyStart: history.historyStart, records: history.records.count, pendingDoses: history.pending.count,
                    committedThrough: history.committedThrough, lateDoses: history.lateDoses,
                    hasUnuploadedRecords: history.hasUnuploadedRecords)
        }
    }

    /// Takes responsibility for doses: they are durable in the history file before Loop's cursor advances.
    func ingest(created: [DoseEntry], deleted: [DoseEntry]) throws {
        try queue.sync {
            history.ingest(created: created.compactMap(\.sourceDose), deleted: deleted.compactMap(\.sourceDose))
            history.commit(now: Date(), timeZone: .current)
            try saveHistory()
        }
    }

    func updateBasalProgram(_ schedule: BasalRateSchedule) {
        var slots = [Double](repeating: 0, count: 48)
        for slot in 0..<48 {
            let offset = TimeInterval(slot * 1800)
            slots[slot] = schedule.items.last(where: { $0.startTime <= offset })?.value ?? schedule.items.first?.value ?? 0
        }
        let changed = queue.sync { () -> Bool in
            guard basalProgram != slots else { return false }
            basalProgram = slots
            return true
        }
        if changed { stateDelegate?.pluginDidUpdateState(self) }
    }

    /// Uploads committed history when due. `force` ignores the spacing interval.
    public func uploadIfNeeded(force: Bool = false) async {
        let prepared: (data: Data, lastIndex: UInt32, through: Date?)? = queue.sync {
            guard isOnboarded, !uploading, history.hasUnuploadedRecords else { return nil }
            if !force, let last = status.lastAttemptAt, Date().timeIntervalSince(last) < uploadInterval { return nil }
            do {
                guard let file = try history.exportFile(timeZone: .current, basalProgram: basalProgram) else { return nil }
                try saveHistory()
                uploading = true
                status.lastAttemptAt = Date()
                return (file.data, file.lastIndex, history.committedThrough)
            } catch {
                status.lastError = "Could not build the upload: \(error)"
                return nil
            }
        }
        guard let prepared else { return }
        var error: String?
        do {
            let result = try await post(prepared.data)
            if (200..<300).contains(result.status) {
                os_log("Uploaded %d bytes of pump history through index %d", log: log, type: .default, prepared.data.count, prepared.lastIndex)
            } else {
                error = "Glooko rejected the upload (HTTP \(result.status))"
            }
        } catch let failure {
            error = String(describing: failure)
        }
        queue.sync {
            uploading = false
            status.lastError = error
            if error == nil {
                history.lastUploadedIndex = prepared.lastIndex
                status.lastUploadAt = Date()
                status.uploadedThrough = prepared.through
                try? saveHistory()
            }
        }
        if let error { os_log("Upload failed: %{public}@", log: log, type: .error, error) }
        stateDelegate?.pluginDidUpdateState(self)
    }

    /// Posts with the stored session, signing in again once if the session has expired.
    private func post(_ data: Data) async throws -> GlookoClient.HTTPResult {
        if let client = queue.sync(execute: { self.client }) {
            let result = try await client.uploadDeviceFile(data, extractorName: "InsuletOmnipod")
            if ![401, 403, 302].contains(result.status) { return result }
        }
        guard let email = queue.sync(execute: { self.email }),
              let password = try? KeychainManager().getGenericPasswordForService(Self.passwordKeychainService) else {
            throw ServiceError.signInRequired
        }
        let fresh = GlookoClient(region: Self.region)
        try await fresh.signIn(email: email, password: password)
        guard try await Self.accountEmail(fresh).caseInsensitiveCompare(email) == .orderedSame else {
            throw ServiceError.accountChanged
        }
        try? KeychainManager().replaceGenericPassword(fresh.sessionCookie, forService: Self.sessionKeychainService)
        queue.sync { self.client = fresh }
        return try await fresh.uploadDeviceFile(data, extractorName: "InsuletOmnipod")
    }

    private static var historyURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("GlookoService", isDirectory: true).appendingPathComponent("pump-history.json")
    }

    private static func loadHistory() -> PumpHistoryLog? {
        guard let data = try? Data(contentsOf: historyURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PumpHistoryLog.self, from: data)
    }

    private func saveHistory() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = Self.historyURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(history).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static let passwordKeychainService = "GlookoServicePassword"
    private static let sessionKeychainService = "GlookoServiceSession"

    public enum ServiceError: Error, CustomStringConvertible {
        case accountNotVerified(Int), signInRequired, accountChanged
        public var description: String {
            switch self {
            case .accountNotVerified(let status): return "Could not confirm the Glooko account (HTTP \(status))"
            case .signInRequired: return "Sign in to Glooko again"
            case .accountChanged: return "The Glooko session belongs to a different account; sign in again"
            }
        }
    }
}

extension GlookoService: RemoteDataService {
    public var doseDataLimit: Int? { 1000 }

    public func uploadDoseData(created: [DoseEntry], deleted: [DoseEntry], completion: @escaping (Result<Bool, Error>) -> Void) {
        do {
            try ingest(created: created, deleted: deleted)
            completion(.success(true))
        } catch {
            os_log("Could not store doses: %{public}@", log: log, type: .error, String(describing: error))
            completion(.failure(error))
            return
        }
        Task { await uploadIfNeeded() }
    }

    public func uploadSettingsData(_ stored: [StoredSettings], completion: @escaping (Result<Bool, Error>) -> Void) {
        if let schedule = stored.last?.basalRateSchedule { updateBasalProgram(schedule) }
        completion(.success(true))
    }

    // Glucose reaches Glooko through Dexcom; the other streams have no verified Glooko pump-file record.
    public func uploadAlertData(_ stored: [SyncAlertObject], completion: @escaping (Result<Bool, Error>) -> Void) { completion(.success(true)) }
    public func uploadCarbData(created: [SyncCarbObject], updated: [SyncCarbObject], deleted: [SyncCarbObject], completion: @escaping (Result<Bool, Error>) -> Void) { completion(.success(true)) }
    public func uploadTemporaryOverrideData(updated: [TemporaryScheduleOverride], deleted: [TemporaryScheduleOverride], completion: @escaping (Result<Bool, Error>) -> Void) { completion(.success(true)) }
    public func uploadDosingDecisionData(_ stored: [StoredDosingDecision], completion: @escaping (Result<Bool, Error>) -> Void) { completion(.success(true)) }
    public func uploadGlucoseData(_ stored: [StoredGlucoseSample], completion: @escaping (Result<Bool, Error>) -> Void) { completion(.success(true)) }
    public func uploadPumpEventData(_ stored: [PersistedPumpEvent], completion: @escaping (Result<Bool, Error>) -> Void) { completion(.success(true)) }
    public func uploadCgmEventData(_ stored: [PersistedCgmEvent], completion: @escaping (Result<Bool, Error>) -> Void) { completion(.success(true)) }
    public func remoteNotificationWasReceived(_ notification: [String: AnyObject]) async throws {}
}

extension DoseEntry {
    /// Pump-delivered doses only: manually entered (pen) doses are not PDM history.
    var sourceDose: SourceDose? {
        guard !manuallyEntered else { return nil }
        let id = syncIdentifier ?? "\(type.rawValue)-\(startDate.timeIntervalSince1970)"
        switch type {
        case .basal:
            return SourceDose(id: id, kind: .basal, start: startDate, end: endDate, rate: unitsPerHour,
                              automatic: automatic, isMutable: isMutable)
        case .tempBasal:
            return SourceDose(id: id, kind: .tempBasal, start: startDate, end: endDate, rate: unitsPerHour,
                              automatic: automatic, isMutable: isMutable)
        case .suspend:
            return SourceDose(id: id, kind: .suspend, start: startDate, end: endDate, isMutable: isMutable)
        case .resume:
            return nil
        case .bolus:
            return SourceDose(id: id, kind: .bolus, start: startDate, end: endDate, programmed: programmedUnits,
                              delivered: deliveredUnits, automatic: automatic, isMutable: isMutable)
        }
    }
}
