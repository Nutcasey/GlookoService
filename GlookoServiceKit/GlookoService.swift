import Foundation
import HealthKit
import os.log
import LoopKit

/// Reporting only. All owned state and disk transactions share one queue; external callbacks run outside it.
public final class GlookoService: Service {
    public static let pluginIdentifier = "GlookoService"
    public static let localizedTitle = "Glooko"
    public static let stateDidChange = Notification.Name("GlookoServiceStateDidChange")
    public weak var serviceDelegate: ServiceDelegate? { didSet { changed() } }
    public weak var stateDelegate: StatefulPluggableDelegate?
    public weak var remoteDataServiceDelegate: RemoteDataServiceDelegate?

    public struct Status: Equatable {
        public var lastUploadAt: Date?
        public var lastAttemptAt: Date?
        public var lastError: String?
        public var uploadedThrough: Date?
        public var lastConfirmedAt: Date?
        public var verificationDetail: String?
        public var lastCarbConfirmedAt: Date?
        public var carbDetail: String?
        public var carbError: String?
        public var sourceReplayDetail: String?
        public var lastReportCheckedAt: Date?
        public var reportWarnings: [String] = []
        public var reportError: String?
        public var pumpSourceLabel: String?
        public var pumpSourceLabelVerifiedAt: Date?
        public var pumpSourceLabelError: String?
    }
    public struct Summary {
        public var serial: UInt32
        public var historyStart: Date?
        public var records: Int
        public var pendingDoses: Int
        public var committedThrough: Date?
        public var lateDoses: Int
        public var conflictCount: Int
        public var hasUnuploadedRecords: Bool
        public var sourceName: String?
        public var pumpUploadName: String?
        public var canStartNewPeriod: Bool
        public var pendingCarbs: Int
        public var correctedBasalIntervals: Int
    }
    public struct Snapshot {
        public var email: String?
        public var isOnboarded: Bool
        public var status: Status
        public var summary: Summary
    }

    private let queue = DispatchQueue(label: "com.loopkit.GlookoService")
    private let log = OSLog(subsystem: "com.loopkit.GlookoService", category: "GlookoService")
    private let repository: HistoryRepository
    private let carbRepository: CarbOutboxRepository
    private let insulinRepository: InsulinOutboxRepository
    private var insulin: InsulinOutbox?
    private var insulinStorageError: String?
    private var account: GlookoAccount?
    private var accountID: String?
    private var storedEmail: String?
    private var onboarded = false
    private var currentStatus = Status()
    private var history: PumpHistoryLog?
    private var storageError: String?
    private var contexts: [ReportingContext] = []
    private var doseQueryDrained = false
    private var settingsQueryDrained = false
    /// Process-local like the drain flags: Loop restarts both streams on each launch, and every changed
    /// dose batch is followed by an empty drain callback. Only a continuous wait is a paused stream.
    private var sourceStreamsWaitingSince: Date? = Date()
    private var deleted = false
    private var lifecycle = UUID()
    private var signInRequest: UUID?
    private var uploadTask: Task<Void, Never>?
    private var uploading = false
    private var uploadWakeRequested = false
    private var forcedUploadRequested = false
    private var client: GlookoClient?
    private var ownsLegacyCredentials = false
    private var carbs: CarbOutbox?
    private var carbStorageError: String?
    private var carbStorageCreated = false
    private var carbTask: Task<Void, Never>?
    private var carbTaskID: UUID?
    private var carbRetryTask: Task<Void, Never>?
    private var carbRetryID: UUID?
    private var carbWakeRequested = false
    private var carbRetryDelay: TimeInterval = 30
    private var carbIdentityVersion = 1
    private var retiredDataCleanupError: String?
    private let credentials = GlookoCredentials()
    private var rememberPassword = false
    private var credentialProtectionMigrated = false
    private var insulinEnabled = false
    private var allowCellular = false
    private var sourceReplayRequired = false
    private var alertThreshold: TimeInterval = 3600
    private var syncHealth = GlookoSyncHealth()
    private var authenticationTask: Task<GlookoClient, Error>?
    private var authenticationID: UUID?
    private var lastAutomaticAuthentication: Date?
    private var healthTask: Task<Void, Never>?
    private var healthTaskID: UUID?
    private var connectedAt = Date()
    private var diagnosticState = GlookoDiagnostics()
    private var diagnosticStorageError: String?
    private var diagnosticPersistenceAvailable = true
    private var inspectionTask: Task<Void, Never>?
    private var inspectionID: UUID?
    private var diagnosticRepository: GlookoDiagnosticsRepository { .init(directory: repository.directory) }
    private let uploadInterval: TimeInterval = 15 * 60
    public static let region = GlookoClient.Region(signInHosts: ["eu.api.glooko.com", "global.api.glooko.com"], dataHost: "eu.api.glooko.com")

    private static var historyDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlookoService", isDirectory: true)
    }

    public init() {
        repository = HistoryRepository(directory: Self.historyDirectory)
        carbRepository = CarbOutboxRepository(directory: Self.historyDirectory)
        insulinRepository = InsulinOutboxRepository(directory: Self.historyDirectory)
    }

    public init?(rawState: RawStateValue) {
        repository = HistoryRepository(directory: Self.historyDirectory)
        carbRepository = CarbOutboxRepository(directory: Self.historyDirectory)
        insulinRepository = InsulinOutboxRepository(directory: Self.historyDirectory)
        storedEmail = rawState["email"] as? String
        accountID = rawState["accountID"] as? String
        ownsLegacyCredentials = rawState["legacyCredentialsOwned"] as? Bool ?? (accountID == nil && storedEmail != nil)
        onboarded = rawState["isOnboarded"] as? Bool ?? false
        rememberPassword = rawState["rememberPassword"] as? Bool ?? onboarded
        credentialProtectionMigrated = rawState["credentialProtectionMigrated"] as? Bool ?? false
        insulinEnabled = rawState["insulinEnabled"] as? Bool ?? onboarded
        allowCellular = rawState["allowCellular"] as? Bool ?? onboarded
        alertThreshold = max(900, rawState["alertThreshold"] as? TimeInterval ?? 3600)
        connectedAt = rawState["connectedAt"] as? Date ?? Date()
        lastAutomaticAuthentication = rawState["lastAutomaticAuthentication"] as? Date
        if let data = rawState["syncHealth"] as? Data, let stored = try? JSONDecoder().decode(GlookoSyncHealth.self, from: data) { syncHealth = stored }
        syncHealth.streams["glucose"] = nil
        currentStatus.lastUploadAt = rawState["lastUploadAt"] as? Date
        currentStatus.lastAttemptAt = rawState["lastAttemptAt"] as? Date
        currentStatus.lastError = rawState["lastError"] as? String
        currentStatus.verificationDetail = rawState["verificationDetail"] as? String
        currentStatus.lastCarbConfirmedAt = rawState["lastCarbConfirmedAt"] as? Date
        carbIdentityVersion = rawState["carbIdentityVersion"] as? Int ?? 0
        // Older builds lack the marker, but a confirmation proves that an outbox already existed.
        carbStorageCreated = (rawState["carbStorageCreated"] as? Bool ?? false) || currentStatus.lastCarbConfirmedAt != nil
        currentStatus.lastReportCheckedAt = rawState["lastReportCheckedAt"] as? Date
        currentStatus.reportWarnings = rawState["reportWarnings"] as? [String] ?? []
        currentStatus.pumpSourceLabel = rawState["pumpSourceLabel"] as? String
        currentStatus.pumpSourceLabelVerifiedAt = rawState["pumpSourceLabelVerifiedAt"] as? Date
        currentStatus.pumpSourceLabelError = rawState["pumpSourceLabelError"] as? String
        if rawState["verificationVersion"] as? Int == 1 {
            currentStatus.lastConfirmedAt = rawState["lastConfirmedAt"] as? Date
            currentStatus.uploadedThrough = rawState["uploadedThrough"] as? Date
        }
        if let data = rawState["reportingContexts"] as? Data {
            do { contexts = try JSONDecoder().decode([ReportingContext].self, from: data) }
            catch { currentStatus.lastError = "Could not restore pump settings. Waiting for a fresh settings snapshot." }
        }
        if onboarded {
            do {
                history = try repository.loadExisting(accountID: accountID, legacyEmail: storedEmail)
                if accountID == nil { accountID = history?.ownerID }
                if let data = history?.reportingContextData { contexts = try JSONDecoder().decode([ReportingContext].self, from: data) }
            }
            catch { storageError = "Could not restore pump history: \(error)"; currentStatus.lastError = storageError }
        }
        if let accountID { restoreCarbs(accountID) }
        if let accountID { restoreDiagnostics(accountID); removeRetiredGlucoseData(accountID) }
        if let accountID, onboarded { restoreInsulin(accountID) }
        sourceReplayRequired = onboarded && carbIdentityVersion < 1
        if sourceReplayRequired {
            currentStatus.sourceReplayDetail = "Legacy carb ownership needs source replay. Remove and re-add this service, keeping local history, so Loop can supply its available cache."
        }
        let service = accountID.map { Self.sessionService($0) } ?? Self.legacySessionService
        let cookie = (try? credentials.get(service)) ??
            (ownsLegacyCredentials ? try? credentials.get(Self.legacySessionService) : nil)
        if let cookie {
            client = makeClient(cookie: cookie, cellular: allowCellular)
            if let client { observeRequests(client, generation: lifecycle) }
        }
    }

    public var email: String? { queue.sync { storedEmail } }
    public var isOnboarded: Bool { queue.sync { onboarded } }
    public var status: Status { queue.sync { currentStatus } }
    public var summary: Summary { snapshot.summary }
    public var snapshot: Snapshot {
        queue.sync {
            Snapshot(email: storedEmail, isOnboarded: onboarded, status: currentStatus,
                     summary: Summary(serial: 0, historyStart: insulin?.reportingStart ?? history?.historyStart,
                                      records: insulin?.confirmedEntries.count ?? 0,
                                      pendingDoses: insulin?.due.count ?? 0,
                                      committedThrough: insulin?.basalHorizon(now: Date()), lateDoses: 0, conflictCount: 0,
                                      hasUnuploadedRecords: insulin?.due.isEmpty == false,
                                      sourceName: contexts.last?.sourceName, pumpUploadName: nil, canStartNewPeriod: false,
                                      pendingCarbs: carbs?.due.count ?? 0, correctedBasalIntervals: 0))
        }
    }

    public var rawState: RawStateValue {
        queue.sync {
            var value: RawStateValue = ["isOnboarded": onboarded, "verificationVersion": 1]
            value["rememberPassword"] = rememberPassword; value["credentialProtectionMigrated"] = credentialProtectionMigrated
            value["insulinEnabled"] = insulinEnabled
            value["allowCellular"] = allowCellular
            value["sourceReplayRequired"] = sourceReplayRequired; value["alertThreshold"] = alertThreshold
            value["connectedAt"] = connectedAt; value["lastAutomaticAuthentication"] = lastAutomaticAuthentication
            value["syncHealth"] = try? JSONEncoder().encode(syncHealth)
            value["email"] = storedEmail; value["accountID"] = accountID
            value["legacyCredentialsOwned"] = ownsLegacyCredentials
            value["lastUploadAt"] = currentStatus.lastUploadAt; value["lastAttemptAt"] = currentStatus.lastAttemptAt
            value["lastError"] = currentStatus.lastError; value["uploadedThrough"] = currentStatus.uploadedThrough
            value["verificationDetail"] = currentStatus.verificationDetail
            value["lastConfirmedAt"] = currentStatus.lastConfirmedAt
            value["lastCarbConfirmedAt"] = currentStatus.lastCarbConfirmedAt
            value["carbIdentityVersion"] = carbIdentityVersion
            value["carbStorageCreated"] = carbStorageCreated
            value["lastReportCheckedAt"] = currentStatus.lastReportCheckedAt
            value["reportWarnings"] = currentStatus.reportWarnings
            value["pumpSourceLabel"] = currentStatus.pumpSourceLabel
            value["pumpSourceLabelVerifiedAt"] = currentStatus.pumpSourceLabelVerifiedAt
            value["pumpSourceLabelError"] = currentStatus.pumpSourceLabelError
            value["reportingContexts"] = try? JSONEncoder().encode(contexts)
            return value
        }
    }

    private func changed() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.publishHealthAlerts()
            self.stateDelegate?.pluginDidUpdateState(self)
            NotificationCenter.default.post(name: Self.stateDidChange, object: self)
        }
    }

    @discardableResult
    public func signIn(email: String, password: String, historyStart: Date? = nil, rememberPassword: Bool = false, insulinEnabled: Bool = false, allowCellular: Bool = false) async throws -> String {
        let request = UUID()
        let generation = try queue.sync { () throws -> UUID in
            guard !deleted else { throw CancellationError() }
            signInRequest = request
            return lifecycle
        }
        let fresh = makeClient(cellular: allowCellular)
        try await fresh.signIn(email: email, password: password)
        let verified = try await fresh.verifiedAccount(expectedEmail: email)
        try Task.checkCancellation()
        try queue.sync {
            guard !deleted, lifecycle == generation, signInRequest == request else { throw CancellationError() }
            if let accountID, accountID != verified.id { throw HistoryRepository.Failure.accountMismatch }
            if accountID == nil, onboarded, storedEmail?.caseInsensitiveCompare(verified.email) != .orderedSame {
                throw HistoryRepository.Failure.accountMismatch
            }
            if let storageError { throw ServiceError.blocked(storageError) }
            var owned = try repository.bind(verified, legacyEmail: onboarded ? storedEmail : nil)
            if let data = owned.reportingContextData { contexts = try JSONDecoder().decode([ReportingContext].self, from: data) }
            if owned.records.isEmpty && owned.pending.isEmpty && owned.unclassified.isEmpty { owned.historyStart = historyStart ?? Date() }
            try repository.save(owned)
            try credentials.set(rememberPassword ? password : nil, service: Self.passwordService(verified.id))
            try credentials.set(fresh.sessionCookie, service: Self.sessionService(verified.id))
            removeOwnedLegacyCredentials()
            history = owned; account = verified; accountID = verified.id; storedEmail = verified.email
            if carbs == nil { restoreCarbs(verified.id) }
            restoreDiagnostics(verified.id)
            if insulin == nil { restoreInsulin(verified.id) }
            removeRetiredGlucoseData(verified.id)
            observeRequests(fresh, generation: generation)
            cancelUploads(); lifecycle = UUID()
            self.rememberPassword = rememberPassword; credentialProtectionMigrated = true; self.insulinEnabled = insulinEnabled
            self.allowCellular = allowCellular
            syncHealth.authenticationRequired = nil; syncHealth.lastAccountVerified = Date()
            lastAutomaticAuthentication = nil
            observeRequests(fresh, generation: lifecycle)
            client = fresh; onboarded = true; signInRequest = nil; currentStatus.lastError = nil
        }
        changed()
        return verified.email
    }

    public func cancelSignIn() { queue.sync { signInRequest = nil } }

    /// Disconnect keeps local history for reconnection. The UI offers a separate explicit erase action.
    public func completeDelete() {
        do { try removeService(eraseLocalData: false) }
        catch { queue.sync { currentStatus.lastError = "Service removal failed: \(error)" }; changed() }
    }

    public func removeService(eraseLocalData: Bool) throws {
        let keys = try queue.sync { () throws -> Set<String> in
            var keys = Set<String>()
            if let accountID { keys.formUnion([Self.passwordService(accountID), Self.sessionService(accountID)]) }
            if ownsLegacyCredentials || eraseLocalData { keys.formUnion([Self.legacyPasswordService, Self.legacySessionService]) }
            if eraseLocalData {
                for key in try repository.localAccountStorageKeys() {
                    keys.formUnion(["GlookoService.\(key).Password", "GlookoService.\(key).Session"])
                }
            }
            deleted = true; onboarded = false; lifecycle = UUID(); signInRequest = nil
            cancelUploads(); client = nil
            return keys
        }
        for key in keys { try credentials.remove(key) }
        if eraseLocalData { try repository.eraseAllLocalData() }
        if let issuer = serviceDelegate {
            Task { @MainActor in
                for id in GlookoSyncHealth.allNoticeIDs.union(["diagnostic-test"]) {
                    await issuer.retractAlert(identifier: .init(managerIdentifier: Self.pluginIdentifier, alertIdentifier: id))
                }
            }
        }
        stateDelegate?.pluginWantsDeletion(self)
        changed()
    }

    /// Called on the state queue. Every request-owning task belongs to this lifecycle.
    private func cancelUploads() {
        uploadTask?.cancel(); uploadTask = nil; uploading = false
        authenticationTask?.cancel(); authenticationTask = nil; authenticationID = nil
        healthTask?.cancel(); healthTask = nil; healthTaskID = nil
        inspectionTask?.cancel(); inspectionTask = nil; inspectionID = nil
        uploadWakeRequested = false; forcedUploadRequested = false
        carbTask?.cancel(); carbTask = nil; carbTaskID = nil
        carbRetryTask?.cancel(); carbRetryTask = nil; carbRetryID = nil
        carbWakeRequested = false
    }

    private func check(_ generation: UUID) throws {
        try Task.checkCancellation()
        try queue.sync {
            guard !deleted, onboarded, lifecycle == generation else { throw CancellationError() }
        }
    }

    public struct Options {
        public var rememberPassword: Bool
        public var insulinEnabled: Bool
        public var allowCellular: Bool
        public var alertThreshold: TimeInterval
        public var authenticationRequired: String?
    }
    public var options: Options {
        queue.sync { .init(rememberPassword: rememberPassword, insulinEnabled: insulinEnabled,
            allowCellular: allowCellular, alertThreshold: alertThreshold,
            authenticationRequired: syncHealth.authenticationRequired) }
    }
    public func configureUploads(insulin: Bool, cellular: Bool) {
        queue.sync {
            let cookie = client?.sessionCookie
            cancelUploads(); lifecycle = UUID()
            insulinEnabled = insulin; allowCellular = cellular
            client = makeClient(cookie: cookie, cellular: allowCellular)
            if let client { observeRequests(client, generation: lifecycle) }
        }
        changed()
        Task { await uploadIfNeeded(force: true) }
    }
    public func stopRememberingPassword() throws {
        try queue.sync {
            if let accountID { try credentials.remove(Self.passwordService(accountID)) }
            if ownsLegacyCredentials { try credentials.remove(Self.legacyPasswordService) }
            rememberPassword = false
        }
        changed()
    }
    public func setAlertThreshold(_ seconds: TimeInterval) {
        queue.sync { alertThreshold = min(86400, max(900, seconds)) }
        changed()
    }
    private func makeClient(cookie: String? = nil, cellular: Bool) -> GlookoClient {
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = cellular
        config.allowsExpensiveNetworkAccess = cellular
        config.allowsConstrainedNetworkAccess = false
        return GlookoClient(region: Self.region, sessionCookie: cookie, configuration: config)
    }

    private func authenticatedClient(_ generation: UUID, replacing failed: GlookoClient? = nil) async throws -> GlookoClient {
        try check(generation)
        let owned = try queue.sync { () throws -> (Task<GlookoClient, Error>, UUID) in
            if syncHealth.authenticationRequired != nil { throw ServiceError.signInRequired }
            if let task = authenticationTask, let id = authenticationID { return (task, id) }
            let id = UUID(), renew = failed != nil && failed === client
            let task = Task<GlookoClient, Error> { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.establishClient(generation, renew: renew)
            }
            authenticationTask = task; authenticationID = id
            return (task, id)
        }
        defer { queue.sync { if authenticationID == owned.1 { authenticationTask = nil; authenticationID = nil } } }
        do {
            let result = try await owned.0.value
            try check(generation)
            // A concurrent validation can finish before a caller reports an expired data request.
            // Join an actual renewal, but never retry the rejected client itself.
            if let failed, result === failed {
                queue.sync { if authenticationID == owned.1 { authenticationTask = nil; authenticationID = nil } }
                return try await authenticatedClient(generation, replacing: failed)
            }
            return result
        } catch {
            var reason: String?
            switch error {
            case GlookoError.credentialRejected: reason = String(describing: error)
            case GlookoError.twoFactorRequired: reason = "Glooko now requires an authentication method this session cannot use."
            case ServiceError.signInRequired: reason = "The Glooko session is no longer authorised and automatic password recovery is unavailable."
            case HistoryRepository.Failure.accountMismatch: reason = "Glooko no longer confirms this account's identity. It may be restricted, closed or signed into another account."
            default: break
            }
            if let reason {
                queue.sync { if lifecycle == generation, !deleted { syncHealth.authenticationRequired = reason; client = nil } }
                changed()
            }
            throw error
        }
    }

    /// Account identity is verified before every submission, including after restoring a stored cookie.
    private func establishClient(_ generation: UUID, renew: Bool = false) async throws -> GlookoClient {
        try check(generation)
        let saved = queue.sync { (client, accountID, storedEmail, ownsLegacyCredentials, allowCellular) }
        guard let email = saved.2 else { throw ServiceError.signInRequired }
        var fresh = saved.0
        var verified: GlookoAccount?
        if !renew, let existing = fresh {
            do { verified = try await existing.verifiedAccount(expectedID: saved.1, expectedEmail: saved.1 == nil ? email : nil) }
            catch GlookoError.authenticationRequired { fresh = nil }
            catch GlookoError.notSignedIn { fresh = nil }
        } else { fresh = nil }
        if fresh == nil {
            try queue.sync {
                guard rememberPassword else { throw ServiceError.signInRequired }
                if let last = lastAutomaticAuthentication, Date().timeIntervalSince(last) < 300 {
                    throw ServiceError.blocked("Automatic sign-in is cooling down after a recent attempt. Try Sign in again to update the account.")
                }
                lastAutomaticAuthentication = Date()
            }
            let service = saved.1.map(Self.passwordService) ?? Self.legacyPasswordService
            let password = (try? credentials.get(service)) ??
                (saved.3 ? try? credentials.get(Self.legacyPasswordService) : nil)
            guard let password else { throw ServiceError.signInRequired }
            let replacement = makeClient(cellular: saved.4)
            observeRequests(replacement, generation: generation)
            try await replacement.signIn(email: email, password: password)
            verified = try await replacement.verifiedAccount(expectedID: saved.1, expectedEmail: saved.1 == nil ? email : nil)
            fresh = replacement
        }
        guard let fresh, let verified else { throw ServiceError.signInRequired }
        observeRequests(fresh, generation: generation)
        try check(generation)
        try queue.sync {
            guard lifecycle == generation, !deleted else { throw CancellationError() }
            if accountID == nil || ownsLegacyCredentials {
                guard storageError == nil, history != nil else { throw ServiceError.blocked(storageError ?? "History is unavailable") }
                let migrated = try repository.bind(verified, legacyEmail: storedEmail)
                if (try? credentials.get(Self.passwordService(verified.id))) == nil,
                   let password = try? credentials.get(Self.legacyPasswordService) {
                    try credentials.set(rememberPassword ? password : nil, service: Self.passwordService(verified.id))
                }
                history = migrated; accountID = verified.id
                if carbs == nil { restoreCarbs(verified.id) }
                restoreDiagnostics(verified.id)
                if insulin == nil { restoreInsulin(verified.id) }
            }
            try credentials.set(fresh.sessionCookie, service: Self.sessionService(verified.id))
            if !credentialProtectionMigrated {
                let password = rememberPassword ? try credentials.get(Self.passwordService(verified.id)) : nil
                try credentials.set(password, service: Self.passwordService(verified.id))
                credentialProtectionMigrated = true
            }
            removeOwnedLegacyCredentials()
            account = verified; storedEmail = verified.email; client = fresh; syncHealth.lastAccountVerified = Date()
        }
        return fresh
    }

    /// Called on the state queue after scoped credentials have been saved. Keep the retry flag on failure.
    private func removeOwnedLegacyCredentials() {
        guard ownsLegacyCredentials else { return }
        do {
            try credentials.remove(Self.legacyPasswordService)
            try credentials.remove(Self.legacySessionService)
            ownsLegacyCredentials = false
        } catch { os_log("Legacy credential cleanup will be retried", log: log, type: .error) }
    }

    public func uploadIfNeeded(force: Bool = false) async {
        // Carbs are independent of pump eligibility and must also be drained by Upload now.
        async let carbUpload: Void = sendCarbs(force: force)
        let task = queue.sync { () -> Task<Void, Never>? in
            guard onboarded, !deleted, insulinEnabled else { return nil }
            if uploading {
                uploadWakeRequested = true; forcedUploadRequested = forcedUploadRequested || force
                return uploadTask
            }
            if !force, let last = currentStatus.lastAttemptAt, Date().timeIntervalSince(last) < uploadInterval { return nil }
            return beginUpload(force: force, generation: lifecycle)
        }
        await task?.value
        await carbUpload
    }

    /// Called on the state queue so cancellation and a follow-up drain cannot lose ownership of a task.
    private func beginUpload(force: Bool, generation: UUID) -> Task<Void, Never> {
        uploading = true; uploadWakeRequested = false; forcedUploadRequested = false
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performUpload(force: force, generation: generation)
        }
        uploadTask = task
        return task
    }

    private func performUpload(force: Bool, generation: UUID) async {
        defer {
            queue.sync {
                guard lifecycle == generation else { return }
                let retry = uploadWakeRequested, forced = forcedUploadRequested
                uploading = false; uploadTask = nil; uploadWakeRequested = false; forcedUploadRequested = false
                if retry, !deleted, onboarded,
                   forced || (currentStatus.lastAttemptAt.map({ Date().timeIntervalSince($0) >= uploadInterval }) ?? true) {
                    _ = beginUpload(force: forced, generation: generation)
                }
            }
            changed()
        }
        do {
            try check(generation)
            let needsSubmission = try queue.sync { () throws -> Bool in
                try reconcileInsulin()
                return insulin?.due.isEmpty == false
            }
            guard needsSubmission else { return }
            var transport = try await authenticatedClient(generation)
            for _ in 0..<50 {
                try check(generation)
                let batch = try queue.sync { () throws -> ([InsulinOutbox.Entry], TimeZone)? in
                    guard lifecycle == generation, !deleted else { throw CancellationError() }
                    // Authentication is an await boundary: include every source change received during it.
                    try reconcileInsulin()
                    guard var outbox = insulin else { throw ServiceError.blocked(insulinStorageError ?? "Insulin storage is unavailable") }
                    let due = Array(outbox.due.prefix(100))
                    guard !due.isEmpty else { return nil }
                    outbox.markSubmitted(due)
                    try saveInsulin(outbox)
                    currentStatus.lastAttemptAt = Date()
                    uploadWakeRequested = false; forcedUploadRequested = false
                    return (due, contexts.last?.timeZone ?? .current)
                }
                guard let (due, timeZone) = batch else { return }
                queue.sync { recordDiagnostic("insulin", "Sending \(due.count) entries: \(due.filter { $0.kind == .basal }.count) basal hours, \(due.filter { $0.kind == .bolus }.count) boluses, \(due.filter(\.deleted).count) deletions") }
                let result: (confirmed: [InsulinOutbox.Entry], heldDeleted: [InsulinOutbox.Entry], detail: String)
                do { result = try await transport.submitInsulin(due, timeZone: timeZone) }
                catch GlookoError.authenticationRequired {
                    transport = try await authenticatedClient(generation, replacing: transport)
                    try check(generation)
                    result = try await transport.submitInsulin(due, timeZone: timeZone)
                }
                try check(generation)
                let progressed = try queue.sync { () throws -> Bool in
                    guard lifecycle == generation, !deleted, var outbox = insulin else { throw CancellationError() }
                    for entry in result.confirmed { outbox.confirm(entry) }
                    for entry in result.heldDeleted { outbox.supersede(entry) }
                    if !result.heldDeleted.isEmpty { outbox.refresh(now: Date(), insulinName: reportedInsulinName(for:)) }
                    try saveInsulin(outbox)
                    currentStatus.lastUploadAt = Date(); currentStatus.verificationDetail = result.detail
                    recordDiagnostic("insulin", result.detail)
                    if !result.confirmed.isEmpty {
                        currentStatus.lastConfirmedAt = Date()
                        currentStatus.uploadedThrough = outbox.confirmedEntries.filter { $0.kind == .basal }.map(InsulinOutbox.hourEnd).max()
                    }
                    currentStatus.lastError = result.confirmed.count == due.count ? nil : "Glooko has not yet confirmed every insulin entry; they will be sent again"
                    return result.confirmed.count == due.count || !result.heldDeleted.isEmpty
                }
                changed()
                if !progressed { return }
            }
        } catch is CancellationError { }
        catch {
            queue.sync { if lifecycle == generation && !deleted { currentStatus.lastError = String(describing: error); recordDiagnostic("insulin error", String(describing: error)) } }
        }
    }

    /// Called on the state queue. Only doses from a real pump are reported; simulator and unknown sources are dropped.
    private func reconcileInsulin() throws {
        guard let accountID else { throw ServiceError.signInRequired }
        if insulin == nil { restoreInsulin(accountID) }
        guard var outbox = insulin else { throw ServiceError.blocked(insulinStorageError ?? "Insulin storage is unavailable") }
        let waitingForSource = "Waiting for Loop to finish reading source history and settings"
        guard doseQueryDrained, settingsQueryDrained else { throw ServiceError.blocked(waitingForSource) }
        if currentStatus.lastError == waitingForSource { currentStatus.lastError = nil }
        guard !contexts.isEmpty else { throw ServiceError.blocked("Waiting for Loop's pump settings") }
        let captured = contexts
        let before = outbox.doses.count
        outbox.retainDoses { dose in
            let source = captured.last(where: { $0.date <= dose.start }) ?? captured.first
            return source?.isRealPump == true
        }
        if outbox.doses.count < before {
            recordDiagnostic("source", "Excluded \(before - outbox.doses.count) doses from a simulator or unknown pump")
        }
        outbox.refresh(now: Date(), insulinName: reportedInsulinName(for:))
        outbox.prune(now: Date())
        if outbox != insulin { try saveInsulin(outbox) }
        guard contexts.last?.isRealPump == true || outbox.due.isEmpty == false else {
            throw ServiceError.blocked("Uploads are paused while a real pump source is unavailable")
        }
    }

    /// An original dose wins. A settings fallback must cover its own delivery time without a drug change.
    private func reportedInsulinName(for dose: SourceDose) -> String? {
        if let name = dose.insulinName { return name }
        guard let context = contexts.last(where: { $0.date <= dose.start }), let name = context.insulinName,
              !contexts.contains(where: { $0.date > dose.start && $0.date < dose.end && $0.insulinName != name }) else { return nil }
        return name
    }

    /// A failed restoration remains visible. A first run cuts over from the retired pump-file history.
    private func restoreInsulin(_ accountID: String) {
        do {
            if let saved = try insulinRepository.load(accountID: accountID) { insulin = saved }
            else {
                // Never cut over from damaged or missing history: that would silently abandon its unsent doses.
                if let storageError { throw ServiceError.blocked(storageError) }
                guard let history else { throw HistoryRepository.Failure.missingHistory }
                let outbox = InsulinOutbox.cutOver(from: history, now: Date())
                try insulinRepository.save(outbox, accountID: accountID)
                insulin = outbox
                // Status from the retired pump-file route does not describe these entries.
                currentStatus.verificationDetail = nil; currentStatus.uploadedThrough = nil; currentStatus.lastConfirmedAt = nil
                currentStatus.lastUploadAt = nil; currentStatus.reportWarnings = []; currentStatus.lastReportCheckedAt = nil
                currentStatus.pumpSourceLabel = nil; currentStatus.pumpSourceLabelVerifiedAt = nil; currentStatus.pumpSourceLabelError = nil
                recordDiagnostic("insulin", "Insulin entries start at \(GlookoClient.isoTimestamp(outbox.reportingStart)); earlier delivery stays with the previous upload route")
            }
            insulinStorageError = nil
        } catch {
            insulin = nil
            insulinStorageError = "Could not restore insulin uploads: \(error)"
            currentStatus.lastError = insulinStorageError
        }
    }

    /// Called on the state queue.
    private func saveInsulin(_ outbox: InsulinOutbox) throws {
        guard let accountID else { throw ServiceError.signInRequired }
        try insulinRepository.save(outbox, accountID: accountID)
        insulin = outbox
    }

    // MARK: Carbs

    /// Carbs use Glooko's meal/food upserts, independent of the pump file: they are sent as soon as Loop reports them.
    private func sendCarbs(force: Bool = false) async {
        let task = queue.sync { () -> Task<Void, Never>? in
            guard onboarded, !deleted, accountID != nil else { return nil }
            if force {
                carbRetryTask?.cancel(); carbRetryTask = nil; carbRetryID = nil
            }
            if let task = carbTask { carbWakeRequested = true; return task }
            guard force || carbRetryTask == nil else { return nil }
            if carbs == nil, let accountID { restoreCarbs(accountID) }
            guard carbStorageError == nil, carbs?.due.isEmpty == false else { return nil }
            let generation = lifecycle, id = UUID()
            carbTaskID = id; carbWakeRequested = false
            let task = Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.performCarbUploads(generation: generation, id: id)
            }
            carbTask = task
            return task
        }
        await task?.value
    }

    private func performCarbUploads(generation: UUID, id: UUID) async {
        defer {
            queue.sync {
                guard lifecycle == generation, carbTaskID == id else { return }
                carbTask = nil; carbTaskID = nil
                if !deleted, onboarded, carbs?.due.isEmpty == false {
                    scheduleCarbRetry(generation: generation, delay: carbWakeRequested ? 0 : carbRetryDelay)
                    carbRetryDelay = min(carbRetryDelay * 2, uploadInterval)
                } else { carbRetryDelay = 30 }
                carbWakeRequested = false
            }
            changed()
        }
        do {
            var transport = try await authenticatedClient(generation)
            while true {
                try check(generation)
                let batch = try queue.sync { () throws -> ([SourceCarb], Set<String>, TimeZone)? in
                    guard lifecycle == generation, carbTaskID == id, !deleted else { throw CancellationError() }
                    guard var outbox = carbs else { throw ServiceError.blocked(carbStorageError ?? "Carb storage is unavailable") }
                    let due = Array(outbox.due.prefix(100))
                    guard !due.isEmpty else { return nil }
                    outbox.markSubmitted(due)
                    try saveCarbs(outbox)
                    carbs = outbox; carbWakeRequested = false
                    return (due, outbox.retiringMeals, contexts.last?.timeZone ?? .current)
                }
                guard let (due, retiring, timeZone) = batch else { return }
                let result: (confirmed: [SourceCarb], detail: String)
                do { result = try await transport.submitCarbs(due, retiringMeals: retiring, timeZone: timeZone) }
                catch GlookoError.authenticationRequired {
                    transport = try await authenticatedClient(generation, replacing: transport)
                    try check(generation)
                    result = try await transport.submitCarbs(due, retiringMeals: retiring, timeZone: timeZone)
                }
                try check(generation)
                let shouldContinue = try queue.sync { () throws -> Bool in
                    guard lifecycle == generation, carbTaskID == id, !deleted else { throw CancellationError() }
                    guard var outbox = carbs else { throw ServiceError.blocked("Carb storage is unavailable") }
                    for carb in result.confirmed { outbox.confirm(carb) }
                    try saveCarbs(outbox)
                    carbs = outbox; currentStatus.carbError = nil; currentStatus.carbDetail = result.detail
                    if !result.confirmed.isEmpty { currentStatus.lastCarbConfirmedAt = Date() }
                    let sent = Dictionary(uniqueKeysWithValues: due.map { ($0.storageID, $0) })
                    // Drain edits/new entries immediately. Unchanged unconfirmed rows wait for backoff.
                    return outbox.due.contains { sent[$0.storageID] != $0 }
                }
                changed()
                queue.sync { recordDiagnostic("carbs", currentStatus.carbDetail ?? "Carb readback completed") }
                if !shouldContinue { return }
            }
        } catch is CancellationError { }
        catch {
            queue.sync {
                if lifecycle == generation, !deleted { currentStatus.carbError = "Carbs not sent yet: \(error)"; recordDiagnostic("carb error", String(describing: error)) }
            }
        }
    }

    /// Called on the state queue. The delayed task holds no service while sleeping and is cancelled on deletion.
    private func scheduleCarbRetry(generation: UUID, delay: TimeInterval) {
        carbRetryTask?.cancel()
        let id = UUID(); carbRetryID = id
        carbRetryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard let self else { return }
            let ready = self.queue.sync { () -> Bool in
                guard self.lifecycle == generation, self.carbRetryID == id, !self.deleted else { return false }
                self.carbRetryTask = nil; self.carbRetryID = nil
                return true
            }
            if ready { await self.sendCarbs() }
        }
    }

    /// A failed restoration remains visible and never supplies an empty replacement to a source callback.
    private func restoreCarbs(_ accountID: String) {
        do {
            carbs = try carbRepository.load(accountID: accountID, historyStart: history?.historyStart, required: carbStorageCreated)
            carbStorageError = nil; currentStatus.carbError = nil
        } catch {
            carbs = nil
            carbStorageError = "Could not restore carb uploads: \(error)"
            currentStatus.carbError = carbStorageError
        }
    }

    /// Called on the state queue.
    private func saveCarbs(_ outbox: CarbOutbox) throws {
        guard let accountID else { throw ServiceError.signInRequired }
        try carbRepository.save(outbox, accountID: accountID)
        carbStorageCreated = true
    }

    /// Remove only the retired uploader's own cache; Loop's glucose store is never touched.
    private func removeRetiredGlucoseData(_ accountID: String) {
        do { try repository.removeRetiredGlucoseData(accountID: accountID); retiredDataCleanupError = nil }
        catch { retiredDataCleanupError = "Retired upload cache could not be removed: \(error)" }
    }

    public func sendTestAlert() {
        let content = Alert.Content(title: "Glooko test alert", body: "This checks Loop's Glooko alert delivery. No account or upload failure is being reported.", acknowledgeActionButtonLabel: "OK")
        Task { @MainActor [weak self] in
            guard let self, !self.queue.sync(execute: { self.deleted }) else { return }
            await self.serviceDelegate?.issueAlert(Alert(identifier: .init(managerIdentifier: Self.pluginIdentifier, alertIdentifier: "diagnostic-test"),
                foregroundContent: content, backgroundContent: content, trigger: .immediate))
        }
    }

    private func publishHealthAlerts() {
        let evaluation = queue.sync { () -> GlookoSyncHealth.Delivery in
            guard !deleted, onboarded else { return .init(issue: [], retract: []) }
            var pending = Set<GlookoSyncHealth.Stream>()
            if insulinEnabled, insulin?.due.isEmpty == false { pending.insert(.insulin) }
            if carbs?.due.isEmpty == false { pending.insert(.carbs) }
            var reason = insulinStorageError ?? carbStorageError
            if sourceReplayRequired { reason = currentStatus.sourceReplayDetail }
            if insulinEnabled {
                if Date().timeIntervalSince(connectedAt) > 300, contexts.last?.isRealPump != true {
                    reason = reason ?? "A real pump source is unavailable. Insulin uploads are paused."
                }
                if let waiting = sourceStreamsWaitingSince, Date().timeIntervalSince(waiting) > alertThreshold { reason = "Loop has not finished reading the dose and settings streams. Insulin uploads are paused." }
            }
            let delivery = syncHealth.notifications(pending: pending, pausedReason: reason, threshold: alertThreshold, canDeliver: serviceDelegate != nil)
            scheduleHealthCheck()
            return delivery
        }
        guard let issuer = serviceDelegate else { return }
        // One task keeps this evaluation's retractions ahead of its issues.
        Task { @MainActor in
            for id in evaluation.retract {
                await issuer.retractAlert(identifier: .init(managerIdentifier: Self.pluginIdentifier, alertIdentifier: id))
            }
            for notice in evaluation.issue {
                let content = Alert.Content(title: notice.title, body: notice.message, acknowledgeActionButtonLabel: "OK")
                await issuer.issueAlert(Alert(identifier: .init(managerIdentifier: Self.pluginIdentifier, alertIdentifier: notice.id),
                    foregroundContent: content, backgroundContent: content, trigger: .immediate))
            }
        }
    }
    /// Called on the state queue after a source stream callback.
    private func noteSourceDrain() {
        if doseQueryDrained && settingsQueryDrained { sourceStreamsWaitingSince = nil }
        else if sourceStreamsWaitingSince == nil { sourceStreamsWaitingSince = Date() }
    }
    /// One owned wake-up at a time. BLE/foreground source activity also evaluates health; iOS may suspend
    /// this task while the host is not executing, so it does not replace Loop's own not-running alerts.
    private func scheduleHealthCheck() {
        guard healthTask == nil, !deleted, onboarded, serviceDelegate != nil else { return }
        let id = UUID(), generation = lifecycle; healthTaskID = id
        healthTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
            guard let self else { return }
            let ready = self.queue.sync { () -> Bool in
                guard self.lifecycle == generation, self.healthTaskID == id, !self.deleted else { return false }
                self.healthTask = nil; self.healthTaskID = nil; return true
            }
            guard ready else { return }
            self.changed()
        }
    }

    public struct DiagnosticSnapshot {
        public var state: GlookoDiagnostics
        public var storageError: String?
        public var checking: Bool
        public var doseQueryDrained: Bool
        public var settingsQueryDrained: Bool
        public var pendingCarbs: Int
        public var pendingDoses: Int
        public var latestSourceDose: Date?
        public var nextPumpAttempt: Date?
    }

    public var diagnostics: DiagnosticSnapshot {
        queue.sync {
            return .init(state: diagnosticState, storageError: diagnosticStorageError ?? retiredDataCleanupError, checking: inspectionTask != nil,
                doseQueryDrained: doseQueryDrained, settingsQueryDrained: settingsQueryDrained,
                pendingCarbs: carbs?.due.count ?? 0,
                pendingDoses: insulin?.due.count ?? 0,
                latestSourceDose: insulin?.doses.values.map(\.start).max(),
                nextPumpAttempt: currentStatus.lastAttemptAt?.addingTimeInterval(uploadInterval))
        }
    }

    /// Called on the state queue. Logging failures never block clinical storage or uploads.
    private func restoreDiagnostics(_ accountID: String) {
        do { diagnosticState = try diagnosticRepository.load(accountID: accountID); diagnosticStorageError = nil; diagnosticPersistenceAvailable = true }
        catch {
            diagnosticStorageError = "Saved diagnostics could not be read: \(error)"
            diagnosticPersistenceAvailable = false // Preserve the unreadable file for investigation.
        }
    }

    private func recordDiagnostic(_ category: String, _ message: String) {
        guard !deleted else { return }
        diagnosticState.record(.init(category: category, message: message))
        guard let accountID, diagnosticPersistenceAvailable else { return }
        do { try diagnosticRepository.save(diagnosticState, accountID: accountID); diagnosticStorageError = nil }
        catch { diagnosticStorageError = "Diagnostics could not be saved: \(error)" }
    }

    private func observeRequests(_ transport: GlookoClient, generation: UUID) {
        transport.requestObserver = { [weak self] trace in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, self.lifecycle == generation, !self.deleted else { return }
                self.recordDiagnostic("HTTP", trace.message)
                if let status = trace.status, (200..<300).contains(status), let upload = trace.upload,
                   let stream = GlookoSyncHealth.Stream(rawValue: upload.rawValue) { self.syncHealth.submitted(stream) }
                self.changed()
            }
        }
    }

    /// A fresh read-only comparison; it neither uploads files nor advances clinical acknowledgements.
    public func checkGlookoNow() async {
        let task = queue.sync { () -> Task<Void, Never>? in
            guard onboarded, !deleted else { return nil }
            if let inspectionTask { return inspectionTask }
            let generation = lifecycle, id = UUID(); inspectionID = id
            let task = Task<Void, Never> { [weak self] in
                guard let self else { return }
                defer {
                    self.queue.sync { if self.inspectionID == id { self.inspectionTask = nil; self.inspectionID = nil } }
                    self.changed()
                }
                do {
                    let transport = try await self.authenticatedClient(generation)
                    let captured = try self.queue.sync { () throws -> ([InsulinOutbox.Entry], TimeZone) in
                        guard self.lifecycle == generation, !self.deleted, let outbox = self.insulin else {
                            throw ServiceError.blocked(self.insulinStorageError ?? "Insulin history is unavailable")
                        }
                        self.recordDiagnostic("live check", "Starting read-only insulin entry verification")
                        return (outbox.confirmedEntries, self.contexts.last?.timeZone ?? .current)
                    }
                    let found = try await transport.verifyInsulin(captured.0, timeZone: captured.1)
                    try self.check(generation)
                    let report = GlookoSyncInspection(checkedAt: Date(), sourceSnapshotAt: Date(),
                        day: String(WallClock(timeZone: captured.1).string(Date()).prefix(10)),
                        insulinVerified: found.missing == 0 && found.different == 0, insulinMatched: found.matched,
                        insulinMissing: found.missing, insulinMismatched: found.different, insulinDuplicates: 0,
                        insulinDeferred: 0, reportWarnings: [])
                    self.queue.sync {
                        guard self.lifecycle == generation, !self.deleted else { return }
                        self.diagnosticState.lastInspection = report; self.diagnosticState.inspectionError = nil
                        self.recordDiagnostic("live check", "Insulin: \(report.insulinMatched) matched, \(report.insulinMissing) missing, \(report.insulinMismatched) different")
                    }
                } catch is CancellationError { }
                catch {
                    self.queue.sync {
                        guard self.lifecycle == generation, !self.deleted else { return }
                        self.diagnosticState.inspectionError = GlookoClient.redact(String(describing: error))
                        self.recordDiagnostic("live check error", String(describing: error))
                    }
                }
            }
            inspectionTask = task; return task
        }
        await task?.value
    }

    private static let sessionExpiredStatuses: Set<Int> = [301, 302, 303, 307, 308, 401, 403, 421]
    private static let legacyPasswordService = "GlookoServicePassword"
    private static let legacySessionService = "GlookoServiceSession"
    private static func passwordService(_ id: String) -> String { "GlookoService.\(GlookoAccount(id: id, email: "").storageKey).Password" }
    private static func sessionService(_ id: String) -> String { "GlookoService.\(GlookoAccount(id: id, email: "").storageKey).Session" }

    public enum ServiceError: Error, CustomStringConvertible {
        case signInRequired, blocked(String)
        public var description: String {
            switch self { case .signInRequired: return "Sign in to Glooko again"; case let .blocked(reason): return reason }
        }
    }
}

extension GlookoService: RemoteDataService {
    public var pluginIdentifier: String { Self.pluginIdentifier }

    // Loop follows each changed query with an empty callback. Commit only after that drain boundary.
    public var doseDataLimit: Int? { nil }
    public var glucoseDataLimit: Int? { 0 }

    public func uploadDoseData(created: [DoseEntry], deleted: [DoseEntry]) async throws {
        do {
            try queue.sync {
                guard !self.deleted, let accountID else { throw ServiceError.blocked("Sign in before storing pump history") }
                if insulin == nil { restoreInsulin(accountID) }
                guard var outbox = insulin else { throw ServiceError.blocked(insulinStorageError ?? "Insulin storage is unavailable") }
                outbox.stage(created: created.compactMap(\.sourceDose), deleted: deleted.compactMap(\.sourceDose))
                try saveInsulin(outbox)
                doseQueryDrained = created.isEmpty && deleted.isEmpty
                noteSourceDrain()
                diagnosticState.lastDoseCallback = Date()
                recordDiagnostic("source", "Dose callback: \(created.count) created, \(deleted.count) deleted; drained \(doseQueryDrained)")
            }
            changed()
            if created.isEmpty && deleted.isEmpty { Task { await uploadIfNeeded() } }
        } catch {
            queue.sync { currentStatus.lastError = "Could not store source history: \(error)"; recordDiagnostic("source error", String(describing: error)) }
            changed(); throw error
        }
    }

    public func uploadSettingsData(_ stored: [StoredSettings]) async throws {
        do {
            try queue.sync {
                guard !deleted else { throw CancellationError() }
                var updated = contexts
                for settings in stored.sorted(by: { $0.date < $1.date }) {
                    let context = ReportingContext(settings)
                    if updated.last.map({ context.date >= $0.date && !context.hasSameConfiguration(as: $0) }) ?? true { updated.append(context) }
                }
                guard var owned = history else {
                    contexts = updated // Retain live context so recovery can archive the failed file explicitly.
                    throw HistoryRepository.Failure.missingHistory
                }
                owned.reportingContextData = try JSONEncoder().encode(updated)
                try repository.save(owned)
                history = owned; contexts = updated; settingsQueryDrained = stored.isEmpty
                noteSourceDrain()
                diagnosticState.lastSettingsCallback = Date()
                recordDiagnostic("source", "Settings callback: \(stored.count) snapshots; drained \(settingsQueryDrained)")
            }
            changed()
            if stored.isEmpty { Task { await uploadIfNeeded() } }
        } catch {
            queue.sync { currentStatus.lastError = "Could not store source settings: \(error)"; recordDiagnostic("source error", String(describing: error)) }
            changed(); throw error
        }
    }

    public func uploadAlertData(_ stored: [SyncAlertObject]) async throws {}
    public func uploadCarbData(created: [SyncCarbObject], updated: [SyncCarbObject], deleted: [SyncCarbObject]) async throws {
        do {
            try queue.sync {
                guard !self.deleted, accountID != nil else { throw ServiceError.blocked("Sign in before storing carbs") }
                if carbs == nil, let accountID { restoreCarbs(accountID) }
                guard var outbox = carbs else { throw ServiceError.blocked(carbStorageError ?? "Carb storage is unavailable") }
                // Entries Glooko itself wrote to Health would come back as duplicates.
                let source = (created + updated + deleted).filter { !$0.provenanceIdentifier.lowercased().contains("glooko") }
                try outbox.stage(source.map { carb in
                    SourceCarb(id: carb.syncIdentifier ?? carb.uuid?.uuidString ?? "carb-\(carb.startDate.timeIntervalSince1970)",
                               start: carb.startDate, grams: carb.grams, version: carb.syncVersion ?? 0, deleted: carb.operation == .delete,
                               provenanceIdentifier: carb.provenanceIdentifier)
                })
                try saveCarbs(outbox)
                carbs = outbox
            }
            changed()
            Task { await sendCarbs() }
        } catch {
            queue.sync { currentStatus.carbError = "Could not store carbs: \(error)" }
            changed(); throw error
        }
    }
    public func uploadTemporaryOverrideData(updated: [TemporaryScheduleOverride], deleted: [TemporaryScheduleOverride]) async throws {}
    public func uploadDosingDecisionData(_ stored: [StoredDosingDecision]) async throws {}
    /// This service reports insulin and carbs only. A zero limit makes Loop return an empty query
    /// without reading its glucose cache; even an unexpected callback cannot store or send samples.
    public func uploadGlucoseData(_ stored: [StoredGlucoseSample]) async throws {}
    public func uploadPumpEventData(_ stored: [PersistedPumpEvent]) async throws {}
    public func uploadCgmEventData(_ stored: [PersistedCgmEvent]) async throws {}
    public func remoteNotificationWasReceived(_ notification: [String: AnyObject]) async throws {}
}
