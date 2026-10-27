import XCTest
import HealthKit
import LoopKit
import ObjectiveC.runtime
import GlookoServiceKit

/// Exercise the real adapter, LoopKit values, filesystem and URLSession in an isolated XCTest runner.
/// Only the session's transport is intercepted; no production injection hooks or copied service logic.
final class ServiceUploadTests: XCTestCase {
    private var services: [GlookoService] = []
    private var accountID = ""
    private var start = Date()
    private var accountFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlookoService")
            .appendingPathComponent(GlookoAccount(id: accountID, email: "").storageKey)
    }

    override class func setUp() {
        super.setUp()
        let original = class_getClassMethod(URLSessionConfiguration.self, #selector(getter: URLSessionConfiguration.ephemeral))!
        let intercepted = class_getClassMethod(URLSessionConfiguration.self, #selector(URLSessionConfiguration.glookoOfflineConfiguration))!
        method_exchangeImplementations(original, intercepted)
    }

    override class func tearDown() {
        let original = class_getClassMethod(URLSessionConfiguration.self, #selector(getter: URLSessionConfiguration.ephemeral))!
        let intercepted = class_getClassMethod(URLSessionConfiguration.self, #selector(URLSessionConfiguration.glookoOfflineConfiguration))!
        method_exchangeImplementations(original, intercepted)
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        accountID = "offline-\(UUID().uuidString.lowercased())"
        start = Date().addingTimeInterval(-10800)
        OfflineGlooko.reset(accountID: accountID)
    }

    override func tearDown() async throws {
        services.forEach { $0.completeDelete() }
        services = []
        try await Task.sleep(nanoseconds: 100_000_000)
        try? FileManager.default.removeItem(at: accountFolder)
        try await super.tearDown()
    }

    private func signedIn() async throws -> GlookoService {
        let service = GlookoService(); services.append(service)
        _ = try await service.signIn(email: "offline@example.test", password: "invented", historyStart: Date(timeIntervalSince1970: 0), rememberPassword: true, insulinEnabled: true, allowCellular: true)
        return service
    }

    private func carb(_ grams: Double, version: Int = 1, operation: LoopKit.Operation = .create) -> SyncCarbObject {
        SyncCarbObject(absorptionTime: nil, createdByCurrentApp: true, foodType: nil, grams: grams,
                       startDate: start, uuid: nil, provenanceIdentifier: "offline.loop", syncIdentifier: "carb",
                       syncVersion: version, userCreatedDate: nil, userUpdatedDate: nil, userDeletedDate: nil,
                       operation: operation, addedDate: nil, supercededDate: nil)
    }

    private func stage(_ carb: SyncCarbObject, in service: GlookoService) throws {
        var outcome: Result<Bool, Error>?
        service.uploadCarbData(created: carb.operation == .create ? [carb] : [], updated: carb.operation == .update ? [carb] : [],
                               deleted: carb.operation == .delete ? [carb] : []) { outcome = $0 }
        _ = try XCTUnwrap(outcome).get()
    }

    private func eventually(timeout: TimeInterval = 5, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(predicate(), "Expected the observable operation to finish before its deadline")
    }

    private func completeSettings() -> StoredSettings {
        let zone = TimeZone(secondsFromGMT: 0)!
        let settings = StoredSettings(date: start.addingTimeInterval(-1), maximumBasalRatePerHour: 3, maximumBolus: 10,
            suspendThreshold: GlucoseThreshold(unit: HKUnit(from: "mg/dL"), value: 75),
            basalRateSchedule: BasalRateSchedule(dailyItems: [.init(startTime: 0, value: 1)], timeZone: zone),
            insulinSensitivitySchedule: InsulinSensitivitySchedule(unit: HKUnit(from: "mg/dL"), dailyItems: [.init(startTime: 0, value: 50)], timeZone: zone),
            carbRatioSchedule: CarbRatioSchedule(unit: .gram(), dailyItems: [.init(startTime: 0, value: 12)], timeZone: zone),
            pumpDevice: HKDevice(name: "Offline", manufacturer: "Test", model: "Fixture", hardwareVersion: nil,
                                 firmwareVersion: nil, softwareVersion: nil, localIdentifier: "offline-pump", udiDeviceIdentifier: nil))
        // StoredSettings's target is supplied separately to keep its declaration-order arguments explicit.
        let target = GlucoseRangeSchedule(unit: HKUnit(from: "mg/dL"), dailyItems: [.init(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 110))], timeZone: zone)!
        let complete = StoredSettings(date: settings.date, glucoseTargetRangeSchedule: target,
            maximumBasalRatePerHour: settings.maximumBasalRatePerHour, maximumBolus: settings.maximumBolus,
            suspendThreshold: settings.suspendThreshold, basalRateSchedule: settings.basalRateSchedule,
            insulinSensitivitySchedule: settings.insulinSensitivitySchedule, carbRatioSchedule: settings.carbRatioSchedule,
            pumpDevice: settings.pumpDevice)
        return complete
    }

    func testLegacyGlucoseSettingCannotSubscribeStoreOrUploadReadings() async throws {
        let original = try await signedIn()
        var legacy = original.rawState; legacy["glucoseEnabled"] = true
        let restored = try XCTUnwrap(GlookoService(rawState: legacy)); services.append(restored)
        let device = HKDevice(name: "Offline sensor", manufacturer: "Dexcom", model: "G7", hardwareVersion: nil,
            firmwareVersion: nil, softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil)
        let sample = StoredGlucoseSample(syncIdentifier: "retired-upload", startDate: start,
            quantity: HKQuantity(unit: HKUnit(from: "mg/dL"), doubleValue: 100), device: device)
        var result: Result<Bool, Error>?
        restored.uploadGlucoseData([sample]) { result = $0 }
        XCTAssertEqual(restored.glucoseDataLimit, 0, "Loop must not query glucose for this service")
        XCTAssertFalse(try XCTUnwrap(result).get(), "The service must not claim to upload glucose")
        await restored.uploadIfNeeded(force: true)
        XCTAssertNil(OfflineGlooko.uploadedFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: accountFolder.appendingPathComponent("glucose.json").path))
    }

    func testARestoredServiceDoesNotAlertWhileLoopDrainsAChangedDoseBatch() async throws {
        let original = try await signedIn()
        original.uploadSettingsData([completeSettings()]) { _ in }
        original.uploadSettingsData([]) { _ in }
        let basal = DoseEntry(type: .basal, startDate: start, endDate: start.addingTimeInterval(3600), value: 1, unit: .unitsPerHour, syncIdentifier: "basal")
        original.uploadDoseData(created: [basal], deleted: []) { _ in }
        original.uploadDoseData(created: [], deleted: []) { _ in }
        try await eventually { OfflineGlooko.uploadedFile != nil }
        // Relaunch long after the service was connected, with Loop restarting both source streams.
        var state = original.rawState
        state["connectedAt"] = Date().addingTimeInterval(-7200)
        let restored = try XCTUnwrap(GlookoService(rawState: state)); services.append(restored)
        let host = RecordingHost()
        restored.serviceDelegate = host
        restored.uploadSettingsData([]) { _ in }
        restored.uploadDoseData(created: [], deleted: []) { _ in }
        await MainActor.run {}
        let next = DoseEntry(type: .basal, startDate: start.addingTimeInterval(3600), endDate: start.addingTimeInterval(4200), value: 0.5, unit: .unitsPerHour, syncIdentifier: "next-basal")
        restored.uploadDoseData(created: [next], deleted: []) { _ in }
        await MainActor.run {}
        restored.uploadDoseData(created: [], deleted: []) { _ in }
        await MainActor.run {}
        let issued = await MainActor.run { host.issued }
        XCTAssertFalse(issued.contains { $0.identifier.alertIdentifier == "uploads-paused" },
                       "A changed batch followed by Loop's drain is normal operation: \(issued.map(\.foregroundContent?.body))")
    }

    func testUploadAndLiveCheckShareOnePasswordRecoveryAndStopAfterCredentialRejection() async throws {
        let service = try await signedIn()
        OfflineGlooko.expireSessionAndRejectPassword()
        OfflineGlooko.hold("POST /api/v3/users/sign_in")
        try stage(carb(20), in: service)
        try await eventually { OfflineGlooko.hasHeldRequest }
        let check = Task { await service.checkGlookoNow() }
        try await eventually { service.diagnostics.checking }
        OfflineGlooko.release()
        await check.value
        try await eventually { service.options.authenticationRequired != nil }
        await service.uploadIfNeeded(force: true)
        XCTAssertEqual(OfflineGlooko.signInCount, 2, "One interactive login and one shared recovery; no replay after rejection")
        XCTAssertEqual(service.summary.pendingCarbs, 1)
        XCTAssertEqual(OfflineGlooko.foodWriteCount, 0)
        XCTAssertNil(OfflineGlooko.uploadedFile)
    }

    func testAnEditDuringSubmissionIsDrainedAndReadbackUsesRecentUpdateTime() async throws {
        let service = try await signedIn()
        OfflineGlooko.hold("PUT /api/v2/foods")
        try stage(carb(20), in: service)
        try await eventually { OfflineGlooko.hasHeldRequest }
        try stage(carb(45, version: 2, operation: .update), in: service)
        OfflineGlooko.release()
        try await eventually { service.summary.pendingCarbs == 0 }
        XCTAssertEqual(OfflineGlooko.foodWriteCount, 2)
        XCTAssertEqual(OfflineGlooko.foodGrams, 45)
        XCTAssertGreaterThan(try XCTUnwrap(OfflineGlooko.foodReadSince), Date().addingTimeInterval(-600))
        XCTAssertGreaterThan(try XCTUnwrap(OfflineGlooko.foodReadSince), start)
    }

    func testUploadNowRetriesCarbsEvenWithoutAnEligiblePump() async throws {
        let service = try await signedIn()
        OfflineGlooko.failNextFoodWrite()
        try stage(carb(20), in: service)
        try await eventually { service.status.carbError != nil }
        XCTAssertEqual(service.summary.pendingCarbs, 1)
        await service.uploadIfNeeded(force: true)
        XCTAssertEqual(service.summary.pendingCarbs, 0)
        XCTAssertEqual(OfflineGlooko.foodWriteCount, 2)
        XCTAssertEqual(OfflineGlooko.foodGrams, 20)
    }

    func testFailedCarbsRetryWithoutAnotherSourceCallback() async throws {
        let service = try await signedIn()
        OfflineGlooko.failNextFoodWrite()
        try stage(carb(20), in: service)
        try await eventually { service.status.carbError != nil }
        try await eventually(timeout: 40) { service.summary.pendingCarbs == 0 }
        XCTAssertEqual(OfflineGlooko.foodWriteCount, 2)
    }

    func testDamagedOrMissingLegacyCarbStorageRejectsDeletionWithoutReplacingIt() async throws {
        let service = try await signedIn()
        try stage(carb(20), in: service)
        try await eventually { service.summary.pendingCarbs == 0 }
        let file = accountFolder.appendingPathComponent("carbs.json")
        let damaged = Data("damaged acknowledged outbox".utf8)
        try damaged.write(to: file)
        let restored = try XCTUnwrap(GlookoService(rawState: service.rawState)); services.append(restored)
        XCTAssertNotNil(restored.status.carbError)
        XCTAssertThrowsError(try stage(carb(20, operation: .delete), in: restored))
        XCTAssertEqual(try Data(contentsOf: file), damaged)
        XCTAssertEqual(OfflineGlooko.foodWriteCount, 1)

        // The deployed version has a confirmation timestamp but no storage marker or raw-state flag.
        // Losing its file during an upgrade must not re-create confirmed foods under fresh GUIDs.
        var legacyState = service.rawState
        legacyState["carbStorageCreated"] = nil
        XCTAssertNotNil(legacyState["lastCarbConfirmedAt"])
        try FileManager.default.removeItem(at: file)
        try FileManager.default.removeItem(at: accountFolder.appendingPathComponent("carbs-initialised"))
        let legacy = try XCTUnwrap(GlookoService(rawState: legacyState)); services.append(legacy)
        XCTAssertNotNil(legacy.status.carbError)
        XCTAssertThrowsError(try stage(carb(20, operation: .delete), in: legacy))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(OfflineGlooko.foodWriteCount, 1)
    }

    func testDeletionCancelsTheMultiRequestCarbOperation() async throws {
        let service = try await signedIn()
        try stage(carb(20), in: service)
        try await eventually { service.summary.pendingCarbs == 0 }
        let file = accountFolder.appendingPathComponent("carbs.json")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        legacy["format"] = nil
        try JSONSerialization.data(withJSONObject: legacy).write(to: file)
        let restored = try XCTUnwrap(GlookoService(rawState: service.rawState)); services.append(restored)
        OfflineGlooko.hold("PUT /api/v2/meals")
        restored.uploadCarbData(created: [], updated: [], deleted: []) { _ in }
        try await eventually { OfflineGlooko.hasHeldRequest }
        restored.completeDelete()
        OfflineGlooko.release()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(restored.isOnboarded)
        XCTAssertEqual(OfflineGlooko.foodWriteCount, 1, "No food PUT may follow deletion of the service")
        XCTAssertGreaterThan(OfflineGlooko.cancelledRequests, 0)
    }

    func testSourceDeletionDuringAuthenticationIsAppliedBeforeFileSubmission() async throws {
        let service = try await signedIn()
        let complete = completeSettings()
        service.uploadSettingsData([complete]) { _ in }
        service.uploadSettingsData([]) { _ in }
        service.uploadDoseData(created: [], deleted: []) { _ in }
        await service.uploadIfNeeded(force: true)
        // Finish the initial empty-source callbacks before establishing the authentication interleaving.
        try await Task.sleep(nanoseconds: 100_000_000)
        let basal = DoseEntry(type: .basal, startDate: start, endDate: start.addingTimeInterval(3600), value: 1, unit: .unitsPerHour, syncIdentifier: "basal")
        let bolus = DoseEntry(type: .bolus, startDate: start.addingTimeInterval(600), value: 1, unit: .units, deliveredUnits: 1, syncIdentifier: "bolus")
        OfflineGlooko.hold("GET /api/v2/users")
        service.uploadDoseData(created: [basal, bolus], deleted: []) { _ in }
        service.uploadDoseData(created: [], deleted: []) { _ in }
        try await eventually { OfflineGlooko.hasHeldRequest }
        service.uploadDoseData(created: [], deleted: [bolus]) { _ in }
        service.uploadDoseData(created: [], deleted: []) { _ in }
        OfflineGlooko.release()
        try await eventually { OfflineGlooko.uploadedFile != nil }
        let bytes = Array(try XCTUnwrap(OfflineGlooko.uploadedFile))
        var offset = 0, bolusRecords = 0
        while offset + 2 < bytes.count {
            let size = Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
            guard size > 2, offset + size + 2 <= bytes.count else { return XCTFail("Invalid submitted IBF framing") }
            let body = offset + 2
            if size >= 31, bytes[body] == 3 {
                let kind = (0..<4).reduce(0) { $0 | (Int(bytes[body + 21 + $1]) << (8 * $1)) }
                if kind == 4 { bolusRecords += 1 }
            }
            offset += size + 2
        }
        XCTAssertEqual(bolusRecords, 0)
        XCTAssertEqual(service.summary.conflictCount, 0)
    }


}

private extension URLSessionConfiguration {
    @objc dynamic class func glookoOfflineConfiguration() -> URLSessionConfiguration {
        let configuration = glookoOfflineConfiguration() // The original method after exchange.
        configuration.protocolClasses = [OfflineGlooko.self]
        return configuration
    }
}

private final class OfflineGlooko: URLProtocol {
    private static let lock = NSLock()
    private static var account = ""
    private static var foods: [String: [String: Any]] = [:]
    private static var writes = 0
    private static var failWrite = false
    private static var rejectCredentials = false
    private static var signIns = 0
    private static var heldKey: String?
    private static var held: OfflineGlooko?
    private static var since: Date?
    private static var uploaded: Data?
    private static var cancellations = 0
    private var stopped = false
    private static func access<T>(_ action: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return action() }

    static func reset(accountID: String) { access { account = accountID; rejectCredentials = false; signIns = 0; foods = [:]; writes = 0; failWrite = false; heldKey = nil; held = nil; since = nil; uploaded = nil; cancellations = 0 } }
    static var signInCount: Int { access { signIns } }
    static func expireSessionAndRejectPassword() { access { rejectCredentials = true } }
    static func hold(_ key: String) { access { heldKey = key } }
    static var hasHeldRequest: Bool { access { held != nil } }
    static var foodWriteCount: Int { access { writes } }
    static var foodGrams: Double? { access { (foods.values.first?["carbs"] as? NSNumber)?.doubleValue } }
    static var foodReadSince: Date? { access { since } }
    static var uploadedFile: Data? { access { uploaded } }
    static var cancelledRequests: Int { access { cancellations } }
    static func failNextFoodWrite() { access { failWrite = true } }
    static func release() { let request = access { () -> OfflineGlooko? in let old = held; held = nil; heldKey = nil; return old }; request?.reply() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
        if Self.access({ if Self.heldKey == key { Self.held = self; return true }; return false }) { return }
        reply()
    }
    override func stopLoading() { Self.access { stopped = true; Self.cancellations += 1 } }
    private func body() -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; result.append(buffer, count: count) }
        return result
    }
    private func reply() {
        guard !Self.access({ stopped }) else { return }
        let url = request.url!, path = url.path, data = body()
        var status = 200, payload: [String: Any] = [:]
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        var headers = ["Content-Type": "application/json", "Date": date.string(from: Date())]
        Self.access {
            if path.contains("sign_in") { Self.signIns += 1; if Self.rejectCredentials { status = 401 } else { headers["Set-Cookie"] = "_logbook-web_session=invented; Path=/; Secure" } }
            else if path == "/api/v2/users", Self.rejectCredentials { status = 401 }
            else if path == "/api/v2/users" { payload = ["users": [["guid": Self.account, "email": "offline@example.test", "softDeleted": false]]] }
            else if path == "/api/v2/foods", request.httpMethod == "PUT" {
                Self.writes += 1
                if Self.failWrite { Self.failWrite = false; status = 500 }
                else {
                    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    for food in object?["foods"] as? [[String: Any]] ?? [] { if let id = food["guid"] as? String { Self.foods[id] = food } }
                    status = 204
                }
            } else if path == "/api/v2/foods" {
                let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "lastUpdatedAt" }?.value
                let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                Self.since = value.flatMap(parser.date(from:))
                payload = ["foods": Array(Self.foods.values)]
            } else if path == "/api/v2/meals" { status = 204 }
            else if path == "/api/v3/device/file/upload" {
                Self.uploaded = data
            }
            else if path == "/api/v2/pumps" { payload = ["pumps": []] }
            else if path != "/api/v3/users/activities_and_event_data_sync/complete" { status = 500 }
            payload["lastPage"] = true; payload["lastUpdatedAt"] = GlookoClient.isoTimestamp(Date()); payload["lastGuid"] = "offline"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class RecordingHost: ServiceDelegate {
    var issued: [Alert] = []
    let hostIdentifier = "com.loopkit.GlookoServiceKitTests"
    let hostVersion = "1"
    func issueAlert(_ alert: Alert) { issued.append(alert) }
    func retractAlert(identifier: Alert.Identifier) {}
    func enactRemoteOverride(name: String, durationTime: TimeInterval?, remoteAddress: String) async throws {}
    func cancelRemoteOverride() async throws {}
    func deliverRemoteCarbs(amountInGrams: Double, absorptionTime: TimeInterval?, foodType: String?, startDate: Date?) async throws {}
    func deliverRemoteBolus(amountInUnits: Double) async throws {}
}
