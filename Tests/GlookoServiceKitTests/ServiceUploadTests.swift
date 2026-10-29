import XCTest
import HealthKit
import LoopKit
import LoopAlgorithm
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

    private func signedIn(historyStart: Date = Date(timeIntervalSince1970: 0)) async throws -> GlookoService {
        let service = GlookoService(); services.append(service)
        _ = try await service.signIn(email: "offline@example.test", password: "invented", historyStart: historyStart, rememberPassword: true, insulinEnabled: true, allowCellular: true)
        return service
    }

    private func carb(_ grams: Double, version: Int = 1, operation: LoopKit.Operation = .create) -> SyncCarbObject {
        SyncCarbObject(absorptionTime: nil, createdByCurrentApp: true, foodType: nil, grams: grams,
                       startDate: start, uuid: nil, provenanceIdentifier: "offline.loop", syncIdentifier: "carb",
                       syncVersion: version, userCreatedDate: nil, userUpdatedDate: nil, userDeletedDate: nil,
                       operation: operation, addedDate: nil, supercededDate: nil)
    }

    private func stage(_ carb: SyncCarbObject, in service: GlookoService) async throws {
        try await service.uploadCarbData(created: carb.operation == .create ? [carb] : [], updated: carb.operation == .update ? [carb] : [],
                                         deleted: carb.operation == .delete ? [carb] : [])
    }

    private func eventually(timeout: TimeInterval = 5, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(predicate(), "Expected the observable operation to finish before its deadline")
    }

    private func completeSettings(insulinType: InsulinType? = nil, date: Date? = nil) -> StoredSettings {
        let zone = TimeZone(secondsFromGMT: 0)!
        let settings = StoredSettings(date: start.addingTimeInterval(-1), maximumBasalRatePerHour: 3, maximumBolus: 10,
            suspendThreshold: GlucoseThreshold(unit: .milligramsPerDeciliter, value: 75),
            basalRateSchedule: BasalRateSchedule(dailyItems: [.init(startTime: 0, value: 1)], timeZone: zone),
            insulinSensitivitySchedule: InsulinSensitivitySchedule(unit: .milligramsPerDeciliter, dailyItems: [.init(startTime: 0, value: 50)], timeZone: zone),
            carbRatioSchedule: CarbRatioSchedule(unit: .gram, dailyItems: [.init(startTime: 0, value: 12)], timeZone: zone),
            pumpDevice: HKDevice(name: "Offline", manufacturer: "Test", model: "Fixture", hardwareVersion: nil,
                                 firmwareVersion: nil, softwareVersion: nil, localIdentifier: "offline-pump", udiDeviceIdentifier: nil))
        // StoredSettings's target is supplied separately to keep its declaration-order arguments explicit.
        let target = GlucoseRangeSchedule(unit: .milligramsPerDeciliter, dailyItems: [.init(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 110))], timeZone: zone)!
        let complete = StoredSettings(date: date ?? settings.date, glucoseTargetRangeSchedule: target,
            maximumBasalRatePerHour: settings.maximumBasalRatePerHour, maximumBolus: settings.maximumBolus,
            suspendThreshold: settings.suspendThreshold, insulinType: insulinType, basalRateSchedule: settings.basalRateSchedule,
            insulinSensitivitySchedule: settings.insulinSensitivitySchedule, carbRatioSchedule: settings.carbRatioSchedule,
            pumpDevice: settings.pumpDevice)
        return complete
    }

    /// The adapter must retain per-dose insulin and time settings fallbacks to delivery, not upload time.
    func testSelectedInsulinUsesOriginalDosesAndHistoricalSettings() async throws {
        start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 3600) * 3600 - 10800)
        let service = try await signedIn(historyStart: start)
        try await service.uploadSettingsData([
            completeSettings(insulinType: .novolog),
            completeSettings(insulinType: .humalog, date: start.addingTimeInterval(3600))
        ])
        try await service.uploadSettingsData([])
        let doses = [
            DoseEntry(type: .bolus, startDate: start.addingTimeInterval(600), value: 2, unit: .units, decisionId: nil,
                      deliveredUnits: 2, syncIdentifier: "original-type", insulinType: .lyumjev),
            DoseEntry(type: .bolus, startDate: start.addingTimeInterval(1800), value: 1, unit: .units, decisionId: nil,
                      deliveredUnits: 1, syncIdentifier: "old-settings"),
            DoseEntry(type: .bolus, startDate: start.addingTimeInterval(5400), value: 3, unit: .units, decisionId: nil,
                      deliveredUnits: 3, syncIdentifier: "new-settings"),
            DoseEntry(type: .basal, startDate: start.addingTimeInterval(3000), endDate: start.addingTimeInterval(4200),
                      value: 1, unit: .unitsPerHour, decisionId: nil, syncIdentifier: "spans-drug-change")
        ]
        try await service.uploadDoseData(created: doses, deleted: [])
        try await service.uploadDoseData(created: [], deleted: [])
        await service.uploadIfNeeded(force: true)
        try await eventually { OfflineGlooko.insulinRecords.filter { $0["insulinType"] as? String == "bolus" }.count == 3 }
        let records = OfflineGlooko.insulinRecords
        for (units, name) in [(2.0, "Lyumjev"), (1.0, "Novolog"), (3.0, "Humalog")] {
            let row = try XCTUnwrap(records.first { $0["insulinType"] as? String == "bolus" && ($0["value"] as? NSNumber)?.doubleValue == units })
            XCTAssertEqual(row["name"] as? String, name + " via Loop")
            XCTAssertTrue(row["medicationGuid"] is NSNull)
        }
        let basal = records.filter { $0["insulinType"] as? String == "basal" }
        XCTAssertFalse(basal.isEmpty)
        XCTAssertTrue(basal.allSatisfy { $0["name"] as? String == "Insulin via Loop" }, "A dose spanning a settings change has no single known insulin")
    }

    private func sensor(_ id: String, _ value: Double, at offset: TimeInterval = 0, libre: Bool = false) -> StoredGlucoseSample {
        StoredGlucoseSample(syncIdentifier: id, startDate: start.addingTimeInterval(offset),
            quantity: LoopQuantity(unit: libre ? .millimolesPerLiter : .milligramsPerDeciliter, doubleValue: value),
            device: HKDevice(name: libre ? "Libre 3" : "G7", manufacturer: libre ? "Abbott" : "Dexcom",
                model: libre ? "Libre 3" : "G7", hardwareVersion: nil, firmwareVersion: nil,
                softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil))
    }

    func testGlucoseDefaultsOnSupportsDexcomLibreAndPersistsOffWithoutLosingPendingReadings() async throws {
        let service = try await signedIn(historyStart: start)
        service.configureUploads(insulin: false, cellular: true)
        XCTAssertTrue(service.options.glucoseEnabled)
        XCTAssertEqual(service.glucoseDataLimit, 500)
        let excluded = [
            StoredGlucoseSample(startDate: start.addingTimeInterval(600), quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: 200), wasUserEntered: true),
            StoredGlucoseSample(startDate: start.addingTimeInterval(660), quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: 201), isDisplayOnly: true),
            StoredGlucoseSample(provenanceIdentifier: "com.glooko.app", startDate: start.addingTimeInterval(720), quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: 202)),
            StoredGlucoseSample(startDate: start.addingTimeInterval(780), quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: 203),
                device: HKDevice(name: "MockCGMManager", manufacturer: "LoopKit", model: "Simulator", hardwareVersion: nil, firmwareVersion: nil, softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil))
        ]
        try await service.uploadGlucoseData([sensor("dexcom", 111), sensor("libre", 5.5, at: 120, libre: true)] + excluded)
        XCTAssertEqual(service.summary.pendingGlucose, 2)
        XCTAssertEqual(OfflineGlooko.glucoseWriteCount, 0, "Wait for the complete source query")
        try await service.uploadGlucoseData([])
        try await eventually { service.summary.pendingGlucose == 0 }
        XCTAssertEqual(OfflineGlooko.glucoseValues.sorted(), [9909, 11100])
        service.configureUploads(insulin: false, cellular: true, glucose: false)
        XCTAssertEqual(service.glucoseDataLimit, 0)
        try await service.uploadGlucoseData([sensor("in-flight", 125, at: 240)])
        try await service.uploadGlucoseData([])
        XCTAssertEqual(service.summary.pendingGlucose, 1)
        XCTAssertEqual(OfflineGlooko.glucoseWriteCount, 1)
        let restored = try XCTUnwrap(GlookoService(rawState: service.rawState)); services.append(restored)
        XCTAssertFalse(restored.options.glucoseEnabled)
        XCTAssertEqual(restored.summary.pendingGlucose, 1)
        OfflineGlooko.hideGlucoseGraph(true)
        restored.configureUploads(insulin: false, cellular: true, glucose: true)
        try await restored.uploadGlucoseData([])
        try await eventually(timeout: 15) { restored.status.glucoseDetail?.hasPrefix("0 of 1") == true }
        XCTAssertEqual(restored.summary.pendingGlucose, 1, "HTTP acceptance and raw records without the graph cannot acknowledge glucose")
        OfflineGlooko.hideGlucoseGraph(false)
        await restored.uploadIfNeeded(force: true)
        XCTAssertEqual(restored.summary.pendingGlucose, 0)
        XCTAssertEqual(OfflineGlooko.glucoseWriteCount, 2, "Readback of the accepted record must not upload a duplicate")
        await restored.checkGlookoNow()
        XCTAssertEqual(restored.diagnostics.state.lastInspection?.glucose?.matchedStored, 3)
        XCTAssertEqual(restored.diagnostics.state.lastInspection?.glucose?.matchedGraphed, 3)
        XCTAssertTrue(OfflineGlooko.insulinRecords.isEmpty)
    }

    func testDisablingGlucoseCancelsSubmissionAndReenableRetriesWithoutLosingTheReading() async throws {
        let service = try await signedIn(historyStart: start)
        OfflineGlooko.hold("POST /api/v3/device/file/upload")
        try await service.uploadGlucoseData([sensor("cancelled", 120)])
        try await service.uploadGlucoseData([])
        try await eventually { OfflineGlooko.hasHeldRequest }
        service.configureUploads(insulin: false, cellular: true, glucose: false)
        try await eventually { OfflineGlooko.heldRequestCancelled }
        OfflineGlooko.release()
        XCTAssertEqual(service.summary.pendingGlucose, 1)
        XCTAssertEqual(OfflineGlooko.glucoseWriteCount, 0)
        OfflineGlooko.failNextGlucoseWrite()
        service.configureUploads(insulin: false, cellular: true, glucose: true)
        try await eventually { service.status.glucoseError != nil }
        XCTAssertEqual(service.summary.pendingGlucose, 1)
        await service.uploadIfNeeded(force: true)
        XCTAssertEqual(service.summary.pendingGlucose, 0)
        XCTAssertEqual(OfflineGlooko.glucoseWriteCount, 2)
        XCTAssertEqual(OfflineGlooko.glucoseValues, [12000])
    }

    func testGlucoseAutomaticallyRetriesWithoutAnotherSourceCallback() async throws {
        let service = try await signedIn(historyStart: start)
        OfflineGlooko.failNextGlucoseWrite()
        try await service.uploadGlucoseData([sensor("retry", 121)])
        try await service.uploadGlucoseData([])
        try await eventually { service.status.glucoseError != nil }
        try await eventually(timeout: 40) { service.summary.pendingGlucose == 0 }
        XCTAssertEqual(OfflineGlooko.glucoseWriteCount, 2)
    }

    func testDamagedAcknowledgedGlucoseStorageRejectsCallbacksWithoutReplacingTheFile() async throws {
        let service = try await signedIn(historyStart: start)
        try await service.uploadGlucoseData([sensor("stored", 122)])
        try await service.uploadGlucoseData([])
        try await eventually { service.summary.pendingGlucose == 0 }
        let file = accountFolder.appendingPathComponent("glucose-v2.json")
        let damaged = Data("damaged confirmed glucose".utf8)
        try damaged.write(to: file)
        let restored = try XCTUnwrap(GlookoService(rawState: service.rawState)); services.append(restored)
        XCTAssertNotNil(restored.status.glucoseError)
        do { try await restored.uploadGlucoseData([sensor("next", 123, at: 120)]); XCTFail("Must retain the source anchor") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), damaged)
        XCTAssertEqual(OfflineGlooko.glucoseWriteCount, 1)
    }

    func testARestoredServiceDoesNotAlertWhileLoopDrainsAChangedDoseBatch() async throws {
        let original = try await signedIn()
        try await original.uploadSettingsData([completeSettings()])
        try await original.uploadSettingsData([])
        let basal = DoseEntry(type: .basal, startDate: start, endDate: start.addingTimeInterval(3600), value: 1, unit: .unitsPerHour, decisionId: nil, syncIdentifier: "basal")
        try await original.uploadDoseData(created: [basal], deleted: [])
        try await original.uploadDoseData(created: [], deleted: [])
        try await eventually { !OfflineGlooko.insulinRecords.isEmpty }
        // Relaunch long after the service was connected, with Loop restarting both source streams.
        var state = original.rawState
        state["connectedAt"] = Date().addingTimeInterval(-7200)
        let restored = try XCTUnwrap(GlookoService(rawState: state)); services.append(restored)
        let host = RecordingHost()
        restored.serviceDelegate = host
        await restored.uploadIfNeeded(force: true)
        XCTAssertNotNil(restored.status.lastError, "The initial upload must wait for both source queries")
        try await restored.uploadSettingsData([])
        try await restored.uploadDoseData(created: [], deleted: [])
        await restored.uploadIfNeeded(force: true)
        XCTAssertNil(restored.status.lastError, "A drained empty queue must clear its resolved source-wait message")
        await MainActor.run {}
        let next = DoseEntry(type: .basal, startDate: start.addingTimeInterval(3600), endDate: start.addingTimeInterval(4200), value: 0.5, unit: .unitsPerHour, decisionId: nil, syncIdentifier: "next-basal")
        try await restored.uploadDoseData(created: [next], deleted: [])
        await MainActor.run {}
        try await restored.uploadDoseData(created: [], deleted: [])
        try await Task.sleep(nanoseconds: 200_000_000)
        let issued = await MainActor.run { host.issued }
        XCTAssertFalse(issued.contains { $0.identifier.alertIdentifier == "uploads-paused" },
                       "A changed batch followed by Loop's drain is normal operation: \(issued.map(\.foregroundContent?.body))")
    }

    func testUploadAndLiveCheckShareOnePasswordRecoveryAndStopAfterCredentialRejection() async throws {
        let service = try await signedIn()
        OfflineGlooko.expireSessionAndRejectPassword()
        OfflineGlooko.hold("POST /api/v3/users/sign_in")
        try await stage(carb(20), in: service)
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
        XCTAssertTrue(OfflineGlooko.insulinRecords.isEmpty)
    }

    func testAnEditDuringSubmissionIsDrainedAndReadbackUsesRecentUpdateTime() async throws {
        let service = try await signedIn()
        OfflineGlooko.hold("PUT /api/v2/foods")
        try await stage(carb(20), in: service)
        try await eventually { OfflineGlooko.hasHeldRequest }
        try await stage(carb(45, version: 2, operation: .update), in: service)
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
        try await stage(carb(20), in: service)
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
        try await stage(carb(20), in: service)
        try await eventually { service.status.carbError != nil }
        try await eventually(timeout: 40) { service.summary.pendingCarbs == 0 }
        XCTAssertEqual(OfflineGlooko.foodWriteCount, 2)
    }

    func testDamagedOrMissingLegacyCarbStorageRejectsDeletionWithoutReplacingIt() async throws {
        let service = try await signedIn()
        try await stage(carb(20), in: service)
        try await eventually { service.summary.pendingCarbs == 0 }
        let file = accountFolder.appendingPathComponent("carbs.json")
        let damaged = Data("damaged acknowledged outbox".utf8)
        try damaged.write(to: file)
        let restored = try XCTUnwrap(GlookoService(rawState: service.rawState)); services.append(restored)
        XCTAssertNotNil(restored.status.carbError)
        do { try await stage(carb(20, operation: .delete), in: restored); XCTFail("Expected staging to be rejected") } catch {}
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
        do { try await stage(carb(20, operation: .delete), in: legacy); XCTFail("Expected staging to be rejected") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(OfflineGlooko.foodWriteCount, 1)
    }

    func testDeletionCancelsTheMultiRequestCarbOperation() async throws {
        let service = try await signedIn()
        try await stage(carb(20), in: service)
        try await eventually { service.summary.pendingCarbs == 0 }
        let file = accountFolder.appendingPathComponent("carbs.json")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        legacy["format"] = nil
        try JSONSerialization.data(withJSONObject: legacy).write(to: file)
        let restored = try XCTUnwrap(GlookoService(rawState: service.rawState)); services.append(restored)
        OfflineGlooko.hold("PUT /api/v2/meals")
        try await restored.uploadCarbData(created: [], updated: [], deleted: [])
        try await eventually { OfflineGlooko.hasHeldRequest }
        restored.completeDelete()
        OfflineGlooko.release()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(restored.isOnboarded)
        XCTAssertEqual(OfflineGlooko.foodWriteCount, 1, "No food PUT may follow deletion of the service")
        XCTAssertGreaterThan(OfflineGlooko.cancelledRequests, 0)
    }

    func testSourceDeletionDuringAuthenticationIsAppliedBeforeInsulinSubmission() async throws {
        let service = try await signedIn()
        try await service.uploadSettingsData([completeSettings()])
        try await service.uploadSettingsData([])
        try await service.uploadDoseData(created: [], deleted: [])
        await service.uploadIfNeeded(force: true)
        // Finish the initial empty-source callbacks before establishing the authentication interleaving.
        try await Task.sleep(nanoseconds: 100_000_000)
        let basal = DoseEntry(type: .basal, startDate: start, endDate: start.addingTimeInterval(3600), value: 1, unit: .unitsPerHour, decisionId: nil, syncIdentifier: "basal")
        let bolus = DoseEntry(type: .bolus, startDate: start.addingTimeInterval(600), value: 1, unit: .units, decisionId: nil, deliveredUnits: 1, syncIdentifier: "bolus")
        // Later delivery lets the basal's second clock hour finish; an hour is never sent past the latest evidence.
        let after = DoseEntry(type: .tempBasal, startDate: start.addingTimeInterval(3600), endDate: Date().addingTimeInterval(-1800), value: 0, unit: .unitsPerHour, decisionId: nil, syncIdentifier: "after")
        OfflineGlooko.hold("GET /api/v2/users")
        try await service.uploadDoseData(created: [basal, bolus, after], deleted: [])
        try await service.uploadDoseData(created: [], deleted: [])
        try await eventually { OfflineGlooko.hasHeldRequest }
        try await service.uploadDoseData(created: [], deleted: [bolus])
        try await service.uploadDoseData(created: [], deleted: [])
        OfflineGlooko.release()
        try await eventually { !OfflineGlooko.insulinRecords.isEmpty && service.summary.pendingDoses == 0 }
        let records = OfflineGlooko.insulinRecords
        XCTAssertFalse(records.contains { $0["insulinType"] as? String == "bolus" }, "The deleted bolus must never be sent")
        XCTAssertEqual(records.filter { $0["insulinType"] as? String == "basal" }.reduce(0) { $0 + (($1["value"] as? NSNumber)?.doubleValue ?? 0) }, 1, accuracy: 0.0005)
        XCTAssertTrue(records.allSatisfy { $0["medicationGuid"] is NSNull && ($0["deviceDelivered"] as? Int) == 1 })
    }

    func testDamagedLegacyPumpHistoryNeverCutsOverToAFreshInsulinOutbox() async throws {
        let service = try await signedIn()
        let state = service.rawState
        services.forEach { $0.completeDelete() }; services = []
        try FileManager.default.removeItem(at: accountFolder.appendingPathComponent("insulin.json"))
        try FileManager.default.removeItem(at: accountFolder.appendingPathComponent("insulin-initialised"))
        try Data("damaged history".utf8).write(to: accountFolder.appendingPathComponent("pump-history.json"))
        let restored = try XCTUnwrap(GlookoService(rawState: state)); services.append(restored)
        let bolus = DoseEntry(type: .bolus, startDate: start, value: 1, unit: .units, decisionId: nil, deliveredUnits: 1, syncIdentifier: "bolus")
        do {
            try await restored.uploadDoseData(created: [bolus], deleted: [])
            XCTFail("Loop must keep the dose until the history is restored")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: accountFolder.appendingPathComponent("insulin.json").path))
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
    private static var insulins: [String: [String: Any]] = [:]
    private static var cancellations = 0
    private static var glucose: [String: [String: Any]] = [:]
    private static var glucoseWrites = 0
    private static var failGlucoseWrite = false
    private static var glucoseGraphHidden = false
    private var stopped = false
    private static func access<T>(_ action: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return action() }

    static func reset(accountID: String) { access { account = accountID; rejectCredentials = false; signIns = 0; foods = [:]; writes = 0; failWrite = false; heldKey = nil; held = nil; since = nil; insulins = [:]; cancellations = 0; glucose = [:]; glucoseWrites = 0; failGlucoseWrite = false; glucoseGraphHidden = false } }
    static var glucoseWriteCount: Int { access { glucoseWrites } }
    static var glucoseValues: [Int] { access { glucose.values.compactMap { $0["glucoseValue"] as? Int } } }
    static func failNextGlucoseWrite() { access { failGlucoseWrite = true } }
    static func hideGlucoseGraph(_ hidden: Bool) { access { glucoseGraphHidden = hidden } }
    static var signInCount: Int { access { signIns } }
    static func expireSessionAndRejectPassword() { access { rejectCredentials = true } }
    static func hold(_ key: String) { access { heldKey = key } }
    static var hasHeldRequest: Bool { access { held != nil } }
    static var heldRequestCancelled: Bool { access { held?.stopped == true } }
    static var foodWriteCount: Int { access { writes } }
    static var foodGrams: Double? { access { (foods.values.first?["carbs"] as? NSNumber)?.doubleValue } }
    static var foodReadSince: Date? { access { since } }
    static var insulinRecords: [[String: Any]] { access { Array(insulins.values) } }
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
            else if path == "/api/v3/session/users" { payload = ["currentUser": ["glookoCode": "offline-patient"]] }
            else if path == "/api/v2/cgm/egvs" { payload = ["egvs": Array(Self.glucose.values)] }
            else if path == "/api/v3/graph/data" {
                let points = Self.glucoseGraphHidden ? [] : Self.glucose.values.map { ["timestamp": $0["displayTime"]!, "value": $0["glucoseValue"]!] }
                payload = ["series": ["cgmHigh": [], "cgmNormal": points, "cgmLow": []]]
            }
            else if path == "/api/v3/device/file/upload" {
                Self.glucoseWrites += 1
                if Self.failGlucoseWrite { Self.failGlucoseWrite = false; status = 500 }
                else {
                    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
                    let clock = DateFormatter(); clock.locale = Locale(identifier: "en_US_POSIX"); clock.timeZone = TimeZone(secondsFromGMT: 0); clock.dateFormat = "dd-MM-yyyy HH:mm"
                    for line in lines.dropFirst(2) {
                        let columns = line.split(separator: ",", omittingEmptySubsequences: false)
                        guard columns.count == 19, let instant = clock.date(from: String(columns[2])), let mgdl = Double(columns[4]) else { status = 400; break }
                        let timestamp = GlookoClient.isoTimestamp(instant)
                        if Self.glucose[timestamp] == nil {
                            Self.glucose[timestamp] = ["guid": UUID().uuidString, "displayTime": timestamp, "systemTime": timestamp,
                                "glucoseValue": Int((mgdl * 100).rounded()), "softDeleted": false]
                        }
                    }
                    if status == 200 { status = 204 }
                }
            }
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
            else if path == "/api/v2/insulins", request.httpMethod == "PUT" {
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                for entry in object?["insulins"] as? [[String: Any]] ?? [] {
                    // Like Glooko, a soft-deleted GUID is never revived by a later live upsert.
                    guard let id = entry["guid"] as? String, (Self.insulins[id]?["softDeleted"] as? Int) != 1 else { continue }
                    Self.insulins[id] = entry
                }
                status = 204
            } else if path == "/api/v2/insulins" { payload = ["insulins": Array(Self.insulins.values)] }
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
    func issueAlert(_ alert: Alert) async { issued.append(alert) }
    func retractAlert(identifier: Alert.Identifier) async {}
    func enactRemoteOverride(name: String, durationTime: TimeInterval?, remoteAddress: String) async throws {}
    func cancelRemoteOverride() async throws {}
    func deliverRemoteCarbs(amountInGrams: Double, absorptionTime: TimeInterval?, foodType: String?, startDate: Date?) async throws {}
    func deliverRemoteBolus(amountInUnits: Double, decisionId: UUID?) async throws {}
}
