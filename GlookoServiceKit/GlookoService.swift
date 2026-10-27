import Foundation
import HealthKit
import os.log
import LoopKit

/// Reporting only. All owned state and disk transactions share one queue; external callbacks run outside it.
public final class GlookoService: Service {
    public static let pluginIdentifier = "GlookoService"
    public static let localizedTitle = "Glooko"
    public static let stateDidChange = Notification.Name("GlookoServiceStateDidChange")
    public weak var serviceDelegate: ServiceDelegate?
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
        public var lastGlucoseConfirmedAt: Date?
        public var glucoseThrough: Date?
        public var glucoseDetail: String?
        public var glucoseError: String?
        public var glucoseBackfillDetail: String?
        public var glucoseBackfillError: String?
        public var lastReportCheckedAt: Date?
        public var reportWarnings: [String] = []
        public var reportError: String?
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
        public var canStartNewPeriod: Bool
        public var pendingCarbs: Int
        public var correctedBasalIntervals: Int
        public var pendingGlucose: Int
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
    private var carbAnchorReset = false
    private var carbIdentityVersion = 1
    private var glucose: GlucoseOutbox?
    private var glucoseStorageError: String?
    private var glucoseStorageCreated = false
    private var glucoseAnchorReset = false
    private var glucoseTask: Task<Void, Never>?
    private var glucoseTaskID: UUID?
    private var glucoseRetryTask: Task<Void, Never>?
    private var glucoseRetryID: UUID?
    private var glucoseRetryDelay: TimeInterval = 30
    private var glucoseWakeRequested = false
    private var glucoseBackfillCompleted = false
    private var glucoseBackfillTask: Task<Void, Never>?
    private var glucoseBackfillID: UUID?
    private let glucoseHealthStore = HKHealthStore()
    private var glucoseRepository: GlucoseOutboxRepository { .init(directory: repository.directory) }
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
        currentStatus.lastUploadAt = rawState["lastUploadAt"] as? Date
        currentStatus.lastAttemptAt = rawState["lastAttemptAt"] as? Date
        currentStatus.lastError = rawState["lastError"] as? String
        currentStatus.verificationDetail = rawState["verificationDetail"] as? String
        currentStatus.lastCarbConfirmedAt = rawState["lastCarbConfirmedAt"] as? Date
        carbAnchorReset = rawState["carbAnchorReset"] as? Bool ?? false
        carbIdentityVersion = rawState["carbIdentityVersion"] as? Int ?? 0
        // Older builds lack the marker, but a confirmation proves that an outbox already existed.
        carbStorageCreated = (rawState["carbStorageCreated"] as? Bool ?? false) || currentStatus.lastCarbConfirmedAt != nil
        glucoseStorageCreated = rawState["glucoseStorageCreated"] as? Bool ?? false
        glucoseAnchorReset = rawState["glucoseAnchorReset"] as? Bool ?? false
        currentStatus.lastGlucoseConfirmedAt = rawState["lastGlucoseConfirmedAt"] as? Date
        currentStatus.glucoseThrough = rawState["glucoseThrough"] as? Date
        glucoseBackfillCompleted = rawState["glucoseBackfillVersion"] as? Int == 1
        currentStatus.glucoseBackfillDetail = rawState["glucoseBackfillDetail"] as? String
        currentStatus.lastReportCheckedAt = rawState["lastReportCheckedAt"] as? Date
        currentStatus.reportWarnings = rawState["reportWarnings"] as? [String] ?? []
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
        if let accountID { restoreGlucose(accountID) }
        if onboarded && !glucoseAnchorReset {
            // Earlier builds acknowledged glucose without sending it. Replay Loop's retained cache once.
            Self.resetLoopGlucoseAnchor(); glucoseAnchorReset = true
        }
        if onboarded && (!carbAnchorReset || carbIdentityVersion < 1) {
            // Replay retained sources once when adding provenance, so legacy GUIDs can be bound from
            // the original version's clinical contents instead of guessing ownership from an identifier.
            Self.resetLoopCarbAnchor()
            carbAnchorReset = true; carbIdentityVersion = 1
        }
        let service = accountID.map { Self.sessionService($0) } ?? Self.legacySessionService
        let cookie = (try? KeychainManager().getGenericPasswordForService(service)) ??
            (ownsLegacyCredentials ? try? KeychainManager().getGenericPasswordForService(Self.legacySessionService) : nil)
        if let cookie {
            client = GlookoClient(region: Self.region, sessionCookie: cookie)
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
                                      canStartNewPeriod: accountID != nil && contexts.last?.isRealPump == true && contexts.last?.settings != nil &&
                                        (storageError != nil || history?.blockedReason(now: Date()) != nil ||
                                         (history?.sourceID != nil && history?.sourceID != contexts.last?.sourceID)),
                                      pendingCarbs: carbs?.due.count ?? 0,
                                      correctedBasalIntervals: Set(history?.ingestionCorrections.values.filter { $0.confirmedAt != nil }.map(\.index) ?? []).count,
                                      pendingGlucose: glucose?.due.count ?? 0))
        }
    }

    public var rawState: RawStateValue {
        queue.sync {
            var value: RawStateValue = ["isOnboarded": onboarded, "verificationVersion": 1]
            value["email"] = storedEmail; value["accountID"] = accountID
            value["legacyCredentialsOwned"] = ownsLegacyCredentials
            value["lastUploadAt"] = currentStatus.lastUploadAt; value["lastAttemptAt"] = currentStatus.lastAttemptAt
            value["lastError"] = currentStatus.lastError; value["uploadedThrough"] = currentStatus.uploadedThrough
            value["verificationDetail"] = currentStatus.verificationDetail
            value["lastConfirmedAt"] = currentStatus.lastConfirmedAt
            value["lastCarbConfirmedAt"] = currentStatus.lastCarbConfirmedAt
            value["carbAnchorReset"] = carbAnchorReset
            value["carbIdentityVersion"] = carbIdentityVersion
            value["carbStorageCreated"] = carbStorageCreated
            value["glucoseStorageCreated"] = glucoseStorageCreated
            value["glucoseAnchorReset"] = glucoseAnchorReset
            value["lastGlucoseConfirmedAt"] = currentStatus.lastGlucoseConfirmedAt
            value["glucoseThrough"] = currentStatus.glucoseThrough
            value["glucoseBackfillVersion"] = glucoseBackfillCompleted ? 1 : 0
            value["glucoseBackfillDetail"] = currentStatus.glucoseBackfillDetail
            value["lastReportCheckedAt"] = currentStatus.lastReportCheckedAt
            value["reportWarnings"] = currentStatus.reportWarnings
            value["reportingContexts"] = try? JSONEncoder().encode(contexts)
            return value
        }
    }

    private func changed() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateDelegate?.pluginDidUpdateState(self)
            NotificationCenter.default.post(name: Self.stateDidChange, object: self)
        }
    }

    @discardableResult
    public func signIn(email: String, password: String, historyStart: Date? = nil) async throws -> String {
        let request = UUID()
        let generation = try queue.sync { () throws -> UUID in
            guard !deleted else { throw CancellationError() }
            signInRequest = request
            return lifecycle
        }
        let fresh = GlookoClient(region: Self.region)
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
            try KeychainManager().replaceGenericPassword(password, forService: Self.passwordService(verified.id))
            try KeychainManager().replaceGenericPassword(fresh.sessionCookie, forService: Self.sessionService(verified.id))
            removeOwnedLegacyCredentials()
            history = owned; account = verified; accountID = verified.id; storedEmail = verified.email
            if carbs == nil { restoreCarbs(verified.id) }
            if glucose == nil { restoreGlucose(verified.id) }
            if !glucoseAnchorReset { Self.resetLoopGlucoseAnchor(); glucoseAnchorReset = true }
            carbAnchorReset = true
            client = fresh; onboarded = true; signInRequest = nil; currentStatus.lastError = nil
        }
        changed()
        return verified.email
    }

    public func cancelSignIn() { queue.sync { signInRequest = nil } }

    public func completeDelete() {
        let keys = queue.sync { () -> (String, String, Bool) in
            deleted = true; onboarded = false; lifecycle = UUID(); signInRequest = nil
            cancelUploads(); client = nil
            return (accountID.map(Self.passwordService) ?? Self.legacyPasswordService,
                    accountID.map(Self.sessionService) ?? Self.legacySessionService, ownsLegacyCredentials)
        }
        do {
            try KeychainManager().deleteGenericPassword(forService: keys.0)
            try KeychainManager().deleteGenericPassword(forService: keys.1)
            if keys.2 {
                try KeychainManager().deleteGenericPassword(forService: Self.legacyPasswordService)
                try KeychainManager().deleteGenericPassword(forService: Self.legacySessionService)
            }
        } catch { os_log("Could not remove Glooko credentials", log: log, type: .error) }
        // Every patient's history, including unconfirmed work, remains partitioned on disk for reconnection.
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
            currentStatus.carbError = carbStorageError
        }
        changed()
        Task { await sendCarbs(force: true) }
        Task { await sendGlucose(force: true) }
    }

    /// Called on the state queue. Every request-owning task belongs to this lifecycle.
    private func cancelUploads() {
        uploadTask?.cancel(); uploadTask = nil; uploading = false
        uploadWakeRequested = false; forcedUploadRequested = false
        carbTask?.cancel(); carbTask = nil; carbTaskID = nil
        carbRetryTask?.cancel(); carbRetryTask = nil; carbRetryID = nil
        carbWakeRequested = false
        glucoseTask?.cancel(); glucoseTask = nil; glucoseTaskID = nil
        glucoseRetryTask?.cancel(); glucoseRetryTask = nil; glucoseRetryID = nil
        glucoseWakeRequested = false
        glucoseBackfillTask?.cancel(); glucoseBackfillTask = nil; glucoseBackfillID = nil
    }

    private func check(_ generation: UUID) throws {
        try Task.checkCancellation()
        try queue.sync {
            guard !deleted, onboarded, lifecycle == generation else { throw CancellationError() }
        }
    }

    /// Account identity is verified before every submission, including after restoring a stored cookie.
    private func authenticatedClient(_ generation: UUID, renew: Bool = false) async throws -> GlookoClient {
        try check(generation)
        let saved = queue.sync { (client, accountID, storedEmail, ownsLegacyCredentials) }
        guard let email = saved.2 else { throw ServiceError.signInRequired }
        var fresh = saved.0
        var verified: GlookoAccount?
        if !renew, let existing = fresh {
            do { verified = try await existing.verifiedAccount(expectedID: saved.1, expectedEmail: saved.1 == nil ? email : nil) }
            catch GlookoError.authenticationRequired { fresh = nil }
            catch GlookoError.notSignedIn { fresh = nil }
        } else { fresh = nil }
        if fresh == nil {
            let service = saved.1.map(Self.passwordService) ?? Self.legacyPasswordService
            let password = (try? KeychainManager().getGenericPasswordForService(service)) ??
                (saved.3 ? try? KeychainManager().getGenericPasswordForService(Self.legacyPasswordService) : nil)
            guard let password else { throw ServiceError.signInRequired }
            let replacement = GlookoClient(region: Self.region)
            try await replacement.signIn(email: email, password: password)
            verified = try await replacement.verifiedAccount(expectedID: saved.1, expectedEmail: saved.1 == nil ? email : nil)
            fresh = replacement
        }
        guard let fresh, let verified else { throw ServiceError.signInRequired }
        try check(generation)
        try queue.sync {
            guard lifecycle == generation, !deleted else { throw CancellationError() }
            if accountID == nil || ownsLegacyCredentials {
                guard storageError == nil, history != nil else { throw ServiceError.blocked(storageError ?? "History is unavailable") }
                let migrated = try repository.bind(verified, legacyEmail: storedEmail)
                if (try? KeychainManager().getGenericPasswordForService(Self.passwordService(verified.id))) == nil,
                   let password = try? KeychainManager().getGenericPasswordForService(Self.legacyPasswordService) {
                    try KeychainManager().replaceGenericPassword(password, forService: Self.passwordService(verified.id))
                }
                history = migrated; accountID = verified.id
                if carbs == nil { restoreCarbs(verified.id) }
            }
            try KeychainManager().replaceGenericPassword(fresh.sessionCookie, forService: Self.sessionService(verified.id))
            removeOwnedLegacyCredentials()
            account = verified; storedEmail = verified.email; client = fresh
        }
        return fresh
    }

    /// Called on the state queue after scoped credentials have been saved. Keep the retry flag on failure.
    private func removeOwnedLegacyCredentials() {
        guard ownsLegacyCredentials else { return }
        do {
            try KeychainManager().deleteGenericPassword(forService: Self.legacyPasswordService)
            try KeychainManager().deleteGenericPassword(forService: Self.legacySessionService)
            ownsLegacyCredentials = false
        } catch { os_log("Legacy credential cleanup will be retried", log: log, type: .error) }
    }

    public func uploadIfNeeded(force: Bool = false) async {
        // Carbs are independent of pump eligibility and must also be drained by Upload now.
        async let carbUpload: Void = sendCarbs(force: force)
        async let glucoseUpload: Void = backfillAndSendGlucose(force: force)
        let task = queue.sync { () -> Task<Void, Never>? in
            guard onboarded, !deleted else { return nil }
            if uploading {
                uploadWakeRequested = true; forcedUploadRequested = forcedUploadRequested || force
                return uploadTask
            }
            if !force, let last = currentStatus.lastAttemptAt, Date().timeIntervalSince(last) < uploadInterval { return nil }
            return beginUpload(force: force, generation: lifecycle)
        }
        await task?.value
        await carbUpload
        await glucoseUpload
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
            guard queue.sync(execute: { history?.hasUnuploadedRecords == true }) else { return }
            var transport = try await authenticatedClient(generation)
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
                let manifest = IngestionManifest(serial: owned.serial, events: owned.exportedEvents,
                                                 timeZone: context.timeZone, committedThrough: owned.committedThrough,
                                                 repairedBasalIndices: owned.repairedBasalIndices)
                let needsRecovery = manifest.repairedBasalIndices.contains { $0 > (owned.lastUploadedIndex ?? 0) }
                owned.markSubmitted(through: file.lastIndex)
                try repository.save(owned)
                history = owned; currentStatus.lastAttemptAt = Date()
                uploadWakeRequested = false; forcedUploadRequested = false
                return (file.data, file.lastIndex, manifest, needsRecovery)
            }
            guard let prepared else { return }
            try check(generation)
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
                    transport = try await authenticatedClient(generation, renew: true)
                    try check(generation)
                    try await transport.repairZeroDurationBasals(prepared.2, recordIntent: journal)
                }
                try check(generation)
            }
            var result = try await transport.uploadDeviceFile(prepared.0, extractorName: "InsuletOmnipod")
            if Self.sessionExpiredStatuses.contains(result.status) {
                transport = try await authenticatedClient(generation, renew: true)
                try check(generation)
                result = try await transport.uploadDeviceFile(prepared.0, extractorName: "InsuletOmnipod")
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
                currentStatus.lastError = owned.blockedReason(now: Date()) ??
                    ((verification.mismatchedRecords > 0 || verification.duplicateRecords > 0) ? verification.detail : nil)
                if verification.confirmed {
                    owned.markVerified(fileIndex: prepared.1, through: prepared.2.verifiedThroughIndex, at: Date())
                    try repository.save(owned)
                    history = owned; currentStatus.lastConfirmedAt = Date(); currentStatus.uploadedThrough = verification.confirmedThrough
                }
            }
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
            queue.sync { if lifecycle == generation && !deleted { currentStatus.lastError = String(describing: error) } }
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
                    transport = try await authenticatedClient(generation, renew: true)
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
                if !shouldContinue { return }
            }
        } catch is CancellationError { }
        catch {
            queue.sync {
                if lifecycle == generation, !deleted { currentStatus.carbError = "Carbs not sent yet: \(error)" }
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

    /// Loop keeps each service's carb query position in its app-group defaults (RemoteDataServicesManager).
    private static func resetLoopCarbAnchor() {
        guard let suite = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String else { return }
        UserDefaults(suiteName: suite)?.removeObject(forKey: "com.loopkit.Loop.RemoteDataServicesManager.\(pluginIdentifier).CarbQueryAnchor")
    }

    private static func resetLoopGlucoseAnchor() {
        guard let suite = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String else { return }
        UserDefaults(suiteName: suite)?.removeObject(forKey: "com.loopkit.Loop.RemoteDataServicesManager.\(pluginIdentifier).GlucoseQueryAnchor")
    }

    // MARK: Glucose

    private func backfillAndSendGlucose(force: Bool) async {
        let task = queue.sync { () -> Task<Void, Never>? in
            guard onboarded, !deleted, !glucoseBackfillCompleted, glucoseStorageError == nil else { return nil }
            if let task = glucoseBackfillTask { return task }
            let generation = lifecycle, id = UUID()
            glucoseBackfillID = id
            let task = Task<Void, Never> { [weak self] in await self?.backfillGlucose(generation: generation, id: id) }
            glucoseBackfillTask = task
            return task
        }
        await task?.value
        await sendGlucose(force: force)
    }

    /// Loop's incremental glucose cache is shorter than its HealthKit history. Read the existing app's
    /// authorised samples once; this does not request permissions or write anything to HealthKit.
    private func backfillGlucose(generation: UUID, id: UUID) async {
        defer {
            queue.sync { if glucoseBackfillID == id { glucoseBackfillTask = nil; glucoseBackfillID = nil } }
            changed()
        }
        do {
            try check(generation)
            let start = queue.sync { max(history?.historyStart ?? Date().addingTimeInterval(-14 * 86400), Date().addingTimeInterval(-14 * 86400)) }
            let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
                let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
                let query = HKSampleQuery(sampleType: HKQuantityType.quantityType(forIdentifier: .bloodGlucose)!, predicate: predicate,
                                          limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: samples as? [HKQuantitySample] ?? []) }
                }
                glucoseHealthStore.execute(query)
            }
            try check(generation)
            try queue.sync {
                guard lifecycle == generation, glucoseBackfillID == id, !deleted else { throw CancellationError() }
                let count = try stageGlucose(samples.map(StoredGlucoseSample.init(sample:)))
                guard count > 0 else {
                    throw ServiceError.blocked("No retained numeric Dexcom G7 readings were readable from HealthKit. Recent uploads continue; historical backfill is not confirmed.")
                }
                glucoseBackfillCompleted = true
                currentStatus.glucoseBackfillError = nil
                currentStatus.glucoseBackfillDetail = "\(count) retained Dexcom G7 readings staged from HealthKit"
            }
        } catch is CancellationError { }
        catch { queue.sync { if lifecycle == generation, !deleted { currentStatus.glucoseBackfillError = "Historical glucose: \(error)" } } }
    }

    /// Called on the state queue, both by Loop's callback and the historical HealthKit read.
    @discardableResult private func stageGlucose(_ samples: [StoredGlucoseSample]) throws -> Int {
        guard !deleted, let accountID else { throw ServiceError.signInRequired }
        if glucose == nil { restoreGlucose(accountID) }
        guard var outbox = glucose else { throw ServiceError.blocked(glucoseStorageError ?? "Glucose storage is unavailable") }
        let readings = samples.filter {
            !$0.wasUserEntered && !$0.isDisplayOnly && $0.condition == nil &&
            !$0.provenanceIdentifier.lowercased().contains("glooko") &&
            (($0.device?.manufacturer?.caseInsensitiveCompare("Dexcom") == .orderedSame && $0.device?.model == "G7") ||
             $0.provenanceIdentifier.lowercased() == "com.dexcom.g7app")
        }.map {
            SourceGlucose(id: $0.syncIdentifier ?? $0.uuid?.uuidString ?? "glucose-\($0.startDate.timeIntervalSince1970)",
                          date: $0.startDate, mgdl: $0.quantity.doubleValue(for: HKUnit(from: "mg/dL")),
                          utcOffset: TimeZone.current.secondsFromGMT(for: $0.startDate),
                          origin: $0.provenanceIdentifier.lowercased() == "com.dexcom.g7app" ? .dexcomApp : .directSensor)
        }
        try outbox.stage(readings)
        try saveGlucose(outbox); glucose = outbox
        return readings.count
    }

    private func restoreGlucose(_ accountID: String) {
        do {
            glucose = try glucoseRepository.load(accountID: accountID, historyStart: history?.historyStart,
                                                  required: glucoseStorageCreated)
            glucoseStorageError = nil; currentStatus.glucoseError = nil
        } catch {
            glucose = nil; glucoseStorageError = "Could not restore glucose uploads: \(error)"
            currentStatus.glucoseError = glucoseStorageError
        }
    }

    private func saveGlucose(_ outbox: GlucoseOutbox) throws {
        guard let accountID else { throw ServiceError.signInRequired }
        try glucoseRepository.save(outbox, accountID: accountID)
        glucoseStorageCreated = true
    }

    private func sendGlucose(force: Bool = false) async {
        let task = queue.sync { () -> Task<Void, Never>? in
            guard onboarded, !deleted, accountID != nil else { return nil }
            if force { glucoseRetryTask?.cancel(); glucoseRetryTask = nil; glucoseRetryID = nil }
            if let task = glucoseTask { glucoseWakeRequested = true; return task }
            guard force || glucoseRetryTask == nil, glucoseStorageError == nil, glucose?.due.isEmpty == false else { return nil }
            let generation = lifecycle, id = UUID()
            glucoseTaskID = id; glucoseWakeRequested = false
            let task = Task<Void, Never> { [weak self] in await self?.performGlucoseUploads(generation: generation, id: id) }
            glucoseTask = task
            return task
        }
        await task?.value
    }

    private func performGlucoseUploads(generation: UUID, id: UUID) async {
        defer {
            queue.sync {
                guard lifecycle == generation, glucoseTaskID == id else { return }
                glucoseTask = nil; glucoseTaskID = nil
                if !deleted, onboarded, glucose?.due.isEmpty == false {
                    let delay = glucoseWakeRequested ? 0 : glucoseRetryDelay
                    let retry = UUID(); glucoseRetryID = retry
                    glucoseRetryTask = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                        guard let self else { return }
                        let ready = self.queue.sync { () -> Bool in
                            guard self.lifecycle == generation, self.glucoseRetryID == retry, !self.deleted else { return false }
                            self.glucoseRetryTask = nil; self.glucoseRetryID = nil
                            return true
                        }
                        if ready { await self.sendGlucose() }
                    }
                    glucoseRetryDelay = min(glucoseRetryDelay * 2, uploadInterval)
                } else { glucoseRetryDelay = 30 }
                glucoseWakeRequested = false
            }
            changed()
        }
        do {
            var transport = try await authenticatedClient(generation)
            while true {
                try check(generation)
                let batch = queue.sync { Array(glucose?.due.prefix(500) ?? []) }
                guard !batch.isEmpty else { return }
                let confirmed: [SourceGlucose]
                do { confirmed = try await transport.submitGlucose(batch) }
                catch GlookoError.authenticationRequired {
                    transport = try await authenticatedClient(generation, renew: true)
                    try check(generation)
                    confirmed = try await transport.submitGlucose(batch)
                }
                try check(generation)
                try queue.sync {
                    guard lifecycle == generation, glucoseTaskID == id, !deleted, var outbox = glucose else { throw CancellationError() }
                    for reading in confirmed { outbox.confirm(reading) }
                    outbox.pruneConfirmed(before: Date().addingTimeInterval(-14 * 86400))
                    try saveGlucose(outbox); glucose = outbox
                    currentStatus.glucoseError = nil
                    currentStatus.glucoseDetail = "\(confirmed.count) of \(batch.count) readings verified in Glooko records and graphs"
                    if !confirmed.isEmpty {
                        currentStatus.lastGlucoseConfirmedAt = Date()
                        let latest = confirmed.map(\.date).max()!
                        let minute = Date(timeIntervalSince1970: floor(latest.timeIntervalSince1970 / 60) * 60)
                        currentStatus.glucoseThrough = max(currentStatus.glucoseThrough ?? minute, minute)
                    }
                }
                changed()
                if confirmed.count < batch.count { return }
            }
        } catch is CancellationError { }
        catch { queue.sync { if lifecycle == generation, !deleted { currentStatus.glucoseError = "Glucose not confirmed: \(error)" } } }
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
    public var glucoseDataLimit: Int? { 500 }

    public func uploadDoseData(created: [DoseEntry], deleted: [DoseEntry], completion: @escaping (Result<Bool, Error>) -> Void) {
        do {
            try queue.sync {
                guard !self.deleted, var owned = history else { throw ServiceError.blocked(storageError ?? "Sign in before storing pump history") }
                owned.stage(created: created.compactMap(\.sourceDose), deleted: deleted.compactMap(\.sourceDose))
                try repository.save(owned)
                history = owned
                doseQueryDrained = created.isEmpty && deleted.isEmpty
            }
            completion(.success(true))
            changed()
            if created.isEmpty && deleted.isEmpty { Task { await uploadIfNeeded() } }
        } catch {
            queue.sync { currentStatus.lastError = "Could not store source history: \(error)" }
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
            }
            changed(); completion(.success(true))
            if stored.isEmpty { Task { await uploadIfNeeded() } }
        } catch {
            queue.sync { currentStatus.lastError = "Could not store source settings: \(error)" }
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
    public func uploadGlucoseData(_ stored: [StoredGlucoseSample], completion: @escaping (Result<Bool, Error>) -> Void) {
        do {
            try queue.sync { _ = try stageGlucose(stored) }
            completion(.success(true)); changed()
            Task { await sendGlucose() }
        } catch {
            queue.sync { currentStatus.glucoseError = "Could not store glucose: \(error)" }
            changed(); completion(.failure(error))
        }
    }
    public func uploadPumpEventData(_ stored: [PersistedPumpEvent], completion: @escaping (Result<Bool, Error>) -> Void) { completion(.success(true)) }
    public func uploadCgmEventData(_ stored: [PersistedCgmEvent], completion: @escaping (Result<Bool, Error>) -> Void) { completion(.success(true)) }
    public func remoteNotificationWasReceived(_ notification: [String: AnyObject]) async throws {}
}
