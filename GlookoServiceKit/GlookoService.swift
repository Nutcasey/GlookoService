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
    }

    public init?(rawState: RawStateValue) {
        repository = HistoryRepository(directory: Self.historyDirectory)
        carbRepository = CarbOutboxRepository(directory: Self.historyDirectory)
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
                     summary: Summary(serial: history?.serial ?? 0, historyStart: history?.historyStart,
                                      records: history?.records.count ?? 0,
                                      pendingDoses: (history?.pending.count ?? 0) + (history?.unclassified.count ?? 0),
                                      committedThrough: history?.committedThrough, lateDoses: history?.lateDoses ?? 0,
                                      conflictCount: history?.conflicts.count ?? 0,
                                      hasUnuploadedRecords: history?.hasUnuploadedRecords ?? false,
                                      sourceName: contexts.last?.sourceName,
                                      pumpUploadName: contexts.last.flatMap { $0.isRealPump ? PumpAttribution(serial: history?.serial ?? 0, sourceName: $0.sourceName).displayName : nil },
                                      canStartNewPeriod: accountID != nil && contexts.last?.isRealPump == true && contexts.last?.settings != nil &&
                                        (storageError != nil || history?.blockedReason(now: Date()) != nil ||
                                         (history?.sourceID != nil && history?.sourceID != contexts.last?.sourceID)),
                                      pendingCarbs: carbs?.due.count ?? 0,
                                      correctedBasalIntervals: Set(history?.ingestionCorrections.values.filter { $0.confirmedAt != nil }.map(\.index) ?? []).count))
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
        for id in GlookoSyncHealth.allNoticeIDs.union(["diagnostic-test"]) {
            serviceDelegate?.retractAlert(identifier: .init(managerIdentifier: Self.pluginIdentifier, alertIdentifier: id))
        }
        stateDelegate?.pluginWantsDeletion(self)
        changed()
    }

    /// An explicit recovery action archives unresolved history; it never rewrites submitted PDM indices.
    public func startNewReportingPeriod() throws {
        try queue.sync {
            guard !deleted, let accountID, let context = contexts.last, let source = context.sourceID,
                  context.settings != nil else { throw ServiceError.blocked("Connect a real pump and wait for its settings first") }
            if let history { try repository.archive(history) }
            else { try repository.archiveUnreadable(accountID: accountID) }
            var fresh = PumpHistoryLog.newIdentity()
            fresh.ownerID = accountID; fresh.ownerEmail = storedEmail; fresh.sourceID = source; fresh.historyStart = Date()
            fresh.reportingContextData = try JSONEncoder().encode(contexts)
            try repository.save(fresh)
            cancelUploads(); lifecycle = UUID()
            history = fresh; storageError = nil; currentStatus = Status()
            diagnosticState.lastInspection = nil; diagnosticState.inspectionError = nil
            recordDiagnostic("history", "Started a new reporting period; previous history remains archived")
            currentStatus.carbError = carbStorageError
        }
        changed()
        Task { await sendCarbs(force: true) }
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
            try queue.sync {
                try reconcileHistory()
            }
            let needsSubmission = queue.sync { history?.hasUnuploadedRecords == true }
            guard needsSubmission || force || queue.sync(execute: { currentStatus.pumpSourceLabelVerifiedAt == nil }) else { return }
            var transport = try await authenticatedClient(generation)
            if !needsSubmission {
                try await updatePumpSourceLabel(transport, generation: generation)
                return
            }
            try check(generation)
            let prepared = try queue.sync { () throws -> (Data, UInt32, IngestionManifest, Bool)? in
                guard lifecycle == generation, !deleted else { throw CancellationError() }
                // Authentication is an await boundary. Include every source change received during it
                // before creating the immutable submitted prefix, including deletions and settings.
                try reconcileHistory()
                guard lifecycle == generation, !deleted, doseQueryDrained, settingsQueryDrained,
                      let context = contexts.last, context.sourceID == history?.sourceID,
                      let settings = context.settings, var owned = history else { throw CancellationError() }
                guard let file = try owned.exportFile(timeZone: context.timeZone, settings: settings) else { return nil }
                let manifest = IngestionManifest(serial: owned.serial, events: file.events,
                                                 timeZone: context.timeZone, committedThrough: owned.committedThrough,
                                                 repairedBasalIndices: owned.repairedBasalIndices)
                let needsRecovery = manifest.repairedBasalIndices.contains { $0 > (owned.lastUploadedIndex ?? 0) }
                owned.markSubmitted(through: file.lastIndex)
                try repository.save(owned)
                history = owned; currentStatus.lastAttemptAt = Date()
                uploadWakeRequested = false; forcedUploadRequested = false
                return (file.data, file.lastIndex, manifest, needsRecovery)
            }
            guard let prepared else {
                try await updatePumpSourceLabel(transport, generation: generation)
                return
            }
            try check(generation)
            queue.sync { recordDiagnostic("insulin", "Submitting \(prepared.0.count) bytes; \(prepared.2.records.count) final records, \(prepared.2.deferredRecords) deferred intervals") }
            os_log("Submitting history: %d bytes, %d final records, %d deferred intervals", log: log, type: .default,
                   prepared.0.count, prepared.2.records.count, prepared.2.deferredRecords)
            if prepared.3 {
                let journal: (IngestionCorrection) throws -> Void = { correction in
                    try self.queue.sync {
                        guard self.lifecycle == generation, !self.deleted, var owned = self.history else { throw CancellationError() }
                        owned.recordCorrectionIntent(correction)
                        try self.repository.save(owned)
                        self.history = owned
                    }
                }
                do { try await transport.repairZeroDurationBasals(prepared.2, recordIntent: journal) }
                catch GlookoError.authenticationRequired {
                    transport = try await authenticatedClient(generation, replacing: transport)
                    try check(generation)
                    try await transport.repairZeroDurationBasals(prepared.2, recordIntent: journal)
                }
                try check(generation)
            }
            var result = try await transport.uploadDeviceFile(prepared.0)
            if Self.sessionExpiredStatuses.contains(result.status) {
                transport = try await authenticatedClient(generation, replacing: transport)
                try check(generation)
                result = try await transport.uploadDeviceFile(prepared.0)
            }
            try check(generation)
            guard (200..<300).contains(result.status), result.contentType?.lowercased().contains("text/html") != true else {
                throw ServiceError.blocked("Glooko rejected the submission (HTTP \(result.status)); history is retained")
            }
            queue.sync {
                if lifecycle == generation { currentStatus.lastUploadAt = Date(); currentStatus.verificationDetail = "Submitted; checking Glooko records" }
            }
            changed()
            var verification = try await transport.verifyIngestion(prepared.2)
            // Give asynchronous ingestion a bounded chance to finish without posting the file again.
            // Wrong values and duplicates require review/recovery, so they are not polled as worker lag.
            for delay in [1, 2, 4] {
                guard !verification.confirmed, verification.missingRecords > 0,
                      verification.mismatchedRecords == 0, verification.duplicateRecords == 0 else { break }
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                try check(generation)
                verification = try await transport.verifyIngestion(prepared.2)
            }
            try check(generation)
            os_log("Readback: %d matched, %d missing, %d mismatched, %d duplicate, %d deferred", log: log, type: .default,
                   verification.matchedRecords, verification.missingRecords, verification.mismatchedRecords,
                   verification.duplicateRecords, verification.deferredRecords)
            try queue.sync {
                guard lifecycle == generation, !deleted, var owned = history else { throw CancellationError() }
                currentStatus.verificationDetail = verification.detail
                recordDiagnostic("insulin", "Readback: \(verification.matchedRecords) matched, \(verification.missingRecords) missing, \(verification.mismatchedRecords) mismatched, \(verification.duplicateRecords) duplicate, \(verification.deferredRecords) deferred")
                currentStatus.lastError = owned.blockedReason(now: Date()) ??
                    ((verification.mismatchedRecords > 0 || verification.duplicateRecords > 0) ? verification.detail : nil)
                if verification.confirmed {
                    owned.markVerified(fileIndex: prepared.1, through: prepared.2.verifiedThroughIndex, at: Date())
                    try repository.save(owned)
                    history = owned; currentStatus.lastConfirmedAt = Date(); currentStatus.uploadedThrough = verification.confirmedThrough
                }
            }
            if verification.confirmed { try await updatePumpSourceLabel(transport, generation: generation) }
            if verification.confirmed, let owned = queue.sync(execute: { history }),
               let timeZone = queue.sync(execute: { contexts.last?.timeZone }) {
                do {
                    let audit = try await transport.auditReports(history: owned, timeZone: timeZone)
                    try check(generation)
                    queue.sync {
                        currentStatus.lastReportCheckedAt = audit.checkedAt
                        currentStatus.reportWarnings = audit.warnings; currentStatus.reportError = nil
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { queue.sync { if lifecycle == generation, !deleted { currentStatus.reportError = "Could not check Glooko reports: \(error)" } } }
            }
        } catch is CancellationError { }
        catch {
            queue.sync { if lifecycle == generation && !deleted { currentStatus.lastError = String(describing: error); recordDiagnostic("insulin error", String(describing: error)) } }
        }
    }

    /// Metadata verification is independent of clinical confirmation: its failure never retracts a verified upload.
    private func updatePumpSourceLabel(_ transport: GlookoClient, generation: UUID) async throws {
        do {
            try check(generation)
            let attribution = try queue.sync { () throws -> PumpAttribution in
                guard let owned = history, let context = contexts.last, context.isRealPump,
                      let sourceID = context.sourceID, sourceID == owned.sourceID else { throw CancellationError() }
                return PumpAttribution(serial: owned.serial, sourceName: context.sourceName)
            }
            _ = try await transport.identifyLoopPump(attribution)
            try check(generation)
            queue.sync {
                guard lifecycle == generation, !deleted, history?.serial == attribution.serial,
                      let sourceID = history?.sourceID, contexts.last?.sourceID == sourceID,
                      contexts.last?.sourceName == attribution.sourceName else { return }
                currentStatus.pumpSourceLabel = attribution.displayName
                currentStatus.pumpSourceLabelVerifiedAt = Date(); currentStatus.pumpSourceLabelError = nil
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            queue.sync {
                guard lifecycle == generation, !deleted else { return }
                currentStatus.pumpSourceLabelError = "Could not verify the Loop source label: \(error)"
            }
        }
    }

    /// Called on the state queue, both before authentication and at the submission-intent boundary.
    private func reconcileHistory() throws {
        guard storageError == nil else { throw ServiceError.blocked(storageError!) }
        guard doseQueryDrained, settingsQueryDrained else { throw ServiceError.blocked("Waiting for Loop to finish reading source history and settings") }
        guard let context = contexts.last, context.isRealPump else { throw ServiceError.blocked("Uploads are paused while a real pump source is unavailable") }
        guard context.settings != nil else { throw ServiceError.blocked(context.problem ?? "Waiting for complete Loop settings") }
        guard var owned = history else { throw HistoryRepository.Failure.missingHistory }
        if owned.sourceID == nil { owned.sourceID = context.sourceID }
        guard owned.sourceID == context.sourceID else { throw ServiceError.blocked("The connected pump has changed. Review the source before starting a new reporting period.") }
        let captured = contexts
        owned.classifyStaged { dose in
            let source = captured.last(where: { $0.date <= dose.start }) ?? captured.first
            if captured.contains(where: { $0.date > dose.start && $0.date < dose.end && $0.sourceID != source?.sourceID }) {
                return "unverified-pump-source"
            }
            return source?.sourceID ?? (source == nil ? nil : "unverified-pump-source")
        }
        owned.commit(now: Date(), timeZone: context.timeZone)
        try repository.save(owned)
        history = owned
        currentStatus.lastError = owned.blockedReason(now: Date())
        if let reason = currentStatus.lastError { throw ServiceError.blocked(reason) }
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
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.queue.sync(execute: { self.deleted }) else { return }
            self.serviceDelegate?.issueAlert(Alert(identifier: .init(managerIdentifier: Self.pluginIdentifier, alertIdentifier: "diagnostic-test"),
                foregroundContent: content, backgroundContent: content, trigger: .immediate))
        }
    }

    private func publishHealthAlerts() {
        let evaluation = queue.sync { () -> GlookoSyncHealth.Delivery in
            guard !deleted, onboarded else { return .init(issue: [], retract: []) }
            var pending = Set<GlookoSyncHealth.Stream>()
            if insulinEnabled, history?.hasUnuploadedRecords == true || history?.pending.values.contains(where: { !$0.isMutable && $0.end < Date().addingTimeInterval(-3600) }) == true { pending.insert(.insulin) }
            if carbs?.due.isEmpty == false { pending.insert(.carbs) }
            var reason = storageError ?? carbStorageError
            if sourceReplayRequired { reason = currentStatus.sourceReplayDetail }
            if insulinEnabled {
                reason = reason ?? history?.blockedReason(now: Date())
                if Date().timeIntervalSince(connectedAt) > 300 {
                    if contexts.last?.isRealPump != true { reason = reason ?? "A real pump source is unavailable. Insulin uploads are paused." }
                    else if contexts.last?.settings == nil { reason = reason ?? contexts.last?.problem ?? "Complete pump settings are unavailable. Insulin uploads are paused." }
                }
                if let source = history?.sourceID, let latest = contexts.last?.sourceID, source != latest { reason = "The connected pump source changed. Insulin uploads are paused." }
                if let waiting = sourceStreamsWaitingSince, Date().timeIntervalSince(waiting) > alertThreshold { reason = "Loop has not finished reading the dose and settings streams. Insulin uploads are paused." }
            }
            let delivery = syncHealth.notifications(pending: pending, pausedReason: reason, threshold: alertThreshold, canDeliver: serviceDelegate != nil)
            scheduleHealthCheck()
            return delivery
        }
        guard let issuer = serviceDelegate else { return }
        for id in evaluation.retract {
            issuer.retractAlert(identifier: .init(managerIdentifier: Self.pluginIdentifier, alertIdentifier: id))
        }
        for notice in evaluation.issue {
            let content = Alert.Content(title: notice.title, body: notice.message, acknowledgeActionButtonLabel: "OK")
            issuer.issueAlert(Alert(identifier: .init(managerIdentifier: Self.pluginIdentifier, alertIdentifier: notice.id),
                foregroundContent: content, backgroundContent: content, trigger: .immediate))
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
                pendingDoses: (history?.pending.count ?? 0) + (history?.unclassified.count ?? 0),
                latestSourceDose: history?.sourceDoses.values.map(\.start).max(),
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
                    let captured = try self.queue.sync { () throws -> (PumpHistoryLog, TimeZone) in
                        guard self.lifecycle == generation, !self.deleted, let history = self.history,
                              let context = self.contexts.last else { throw ServiceError.blocked("Source history or pump settings are unavailable") }
                        self.recordDiagnostic("live check", "Starting read-only pump record verification")
                        return (history, context.timeZone)
                    }
                    let report = try await transport.inspectSync(history: captured.0, timeZone: captured.1)
                    try self.check(generation)
                    self.queue.sync {
                        guard self.lifecycle == generation, !self.deleted else { return }
                        self.diagnosticState.lastInspection = report; self.diagnosticState.inspectionError = nil
                        self.recordDiagnostic("live check", "Insulin: \(report.insulinMatched) matched, \(report.insulinMissing) missing, \(report.insulinMismatched) different, \(report.insulinDuplicates) duplicate")
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
    // Loop follows each changed query with an empty callback. Commit only after that drain boundary.
    public var doseDataLimit: Int? { nil }
    public var glucoseDataLimit: Int? { 0 }

    public func uploadDoseData(created: [DoseEntry], deleted: [DoseEntry], completion: @escaping (Result<Bool, Error>) -> Void) {
        do {
            try queue.sync {
                guard !self.deleted, var owned = history else { throw ServiceError.blocked(storageError ?? "Sign in before storing pump history") }
                owned.stage(created: created.compactMap(\.sourceDose), deleted: deleted.compactMap(\.sourceDose))
                try repository.save(owned)
                history = owned
                doseQueryDrained = created.isEmpty && deleted.isEmpty
                noteSourceDrain()
                diagnosticState.lastDoseCallback = Date()
                recordDiagnostic("source", "Dose callback: \(created.count) created, \(deleted.count) deleted; drained \(doseQueryDrained)")
            }
            completion(.success(true))
            changed()
            if created.isEmpty && deleted.isEmpty { Task { await uploadIfNeeded() } }
        } catch {
            queue.sync { currentStatus.lastError = "Could not store source history: \(error)"; recordDiagnostic("source error", String(describing: error)) }
            changed(); completion(.failure(error))
        }
    }

    public func uploadSettingsData(_ stored: [StoredSettings], completion: @escaping (Result<Bool, Error>) -> Void) {
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
            changed(); completion(.success(true))
            if stored.isEmpty { Task { await uploadIfNeeded() } }
        } catch {
            queue.sync { currentStatus.lastError = "Could not store source settings: \(error)"; recordDiagnostic("source error", String(describing: error)) }
            changed(); completion(.failure(error))
        }
    }

    public func uploadAlertData(_ stored: [SyncAlertObject], completion: @escaping (Result<Bool, Error>) -> Void) { completion(.success(true)) }
    public func uploadCarbData(created: [SyncCarbObject], updated: [SyncCarbObject], deleted: [SyncCarbObject], completion: @escaping (Result<Bool, Error>) -> Void) {
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
            completion(.success(true))
            changed()
            Task { await sendCarbs() }
        } catch {
            queue.sync { currentStatus.carbError = "Could not store carbs: \(error)" }
            changed(); completion(.failure(error))
        }
    }
    public func uploadTemporaryOverrideData(updated: [TemporaryScheduleOverride], deleted: [TemporaryScheduleOverride], completion: @escaping (Result<Bool, Error>) -> Void) { completion(.success(true)) }
    public func uploadDosingDecisionData(_ stored: [StoredDosingDecision], completion: @escaping (Result<Bool, Error>) -> Void) { completion(.success(true)) }
    /// This service reports insulin and carbs only. A zero limit makes Loop return an empty query
    /// without reading its glucose cache; even an unexpected callback cannot store or send samples.
    public func uploadGlucoseData(_ stored: [StoredGlucoseSample], completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(false))
    }
    public func uploadPumpEventData(_ stored: [PersistedPumpEvent], completion: @escaping (Result<Bool, Error>) -> Void) { completion(.success(true)) }
    public func uploadCgmEventData(_ stored: [PersistedCgmEvent], completion: @escaping (Result<Bool, Error>) -> Void) { completion(.success(true)) }
    public func remoteNotificationWasReceived(_ notification: [String: AnyObject]) async throws {}
}
