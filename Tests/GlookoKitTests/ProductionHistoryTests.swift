import XCTest
import GlookoKit

/// Explicit synthetic configuration for offline tests; production must receive actual Loop settings.
func fixtureSettings() -> IBFPumpSettings {
    IBFPumpSettings(basal: Array(repeating: 0.75, count: 48), carbRatio: Array(repeating: 12, count: 48),
                    sensitivityMGDL: Array(repeating: 72, count: 48), targetMGDL: Array(repeating: 108, count: 48),
                    correctionThresholdMGDL: Array(repeating: 126, count: 48), maximumBolus: 7.5,
                    maximumBasal: 2, insulinActionMinutes: 360, minimumGlucoseMGDL: 76)
}

final class ProductionHistoryTests: XCTestCase {
    let zone = TimeZone(secondsFromGMT: 0)!
    let origin = Date(timeIntervalSince1970: 1_790_812_800) // 1 October 2026, UTC
    func at(_ hours: Double) -> Date { origin.addingTimeInterval(hours * 3600) }
    func fresh() -> PumpHistoryLog { PumpHistoryLog(serial: 999000999, powerUp: PumpHistoryLog.defaultPowerUp, podLot: 42, podSerial: 7, firstIndex: 1000) }
    func basal(_ id: String, _ start: Double, _ end: Double, rate: Double = 1) -> SourceDose {
        SourceDose(id: id, kind: .basal, start: at(start), end: at(end), rate: rate)
    }
    func bolus(_ id: String, _ time: Double, units: Double = 1) -> SourceDose {
        SourceDose(id: id, kind: .bolus, start: at(time), end: at(time), programmed: units, delivered: units)
    }
    func file(_ log: inout PumpHistoryLog) throws -> Data {
        try XCTUnwrap(log.exportFile(timeZone: zone, settings: fixtureSettings())).data
    }

    func testUnsubmittedBackfillCorrectionsAndDeletionsRebuildInsteadOfDisappearing() throws {
        var log = fresh()
        log.ingest(created: [basal("basal", 0, 3)])
        log.commit(now: at(4), timeZone: zone, settleDelay: 0)
        log.ingest(created: [bolus("backfill", 1)])
        log.commit(now: at(4), timeZone: zone, settleDelay: 0)
        XCTAssertEqual(try DecodedIBF(file(&log)).bolus, 1)
        log.ingest(created: [bolus("backfill", 1, units: 2)])
        log.commit(now: at(4), timeZone: zone, settleDelay: 0)
        XCTAssertEqual(try DecodedIBF(file(&log)).bolus, 2)
        log.ingest(created: [], deleted: [bolus("backfill", 1)])
        log.commit(now: at(4), timeZone: zone, settleDelay: 0)
        XCTAssertEqual(try DecodedIBF(file(&log)).bolus, 0)
        XCTAssertTrue(log.conflicts.isEmpty)
    }

    func testSubmittedMutationsAreRetainedAsConflictsAndLateResendsCountOnce() throws {
        var log = fresh()
        log.ingest(created: [basal("basal", 0, 3), bolus("original", 1)])
        log.commit(now: at(4), timeZone: zone, settleDelay: 0)
        let exported = try XCTUnwrap(log.exportFile(timeZone: zone, settings: fixtureSettings()))
        log.lastSubmittedIndex = exported.lastIndex
        let original = log.records
        log.ingest(created: [bolus("original", 1, units: 2), bolus("late", 2)])
        log.ingest(created: [bolus("late", 2)])
        XCTAssertEqual(log.lateDoses, 1)
        XCTAssertEqual(log.conflicts["original"]?.replacement?.delivered, 2)
        XCTAssertEqual(log.records, original)
        log.ingest(created: [], deleted: [bolus("original", 1)])
        XCTAssertEqual(log.conflicts["original"]?.deletion, true)
        let roundTrip = try HistoryRepository.decode(JSONEncoder.iso.encode(log))
        XCTAssertEqual(roundTrip.conflicts.count, 2)
        XCTAssertEqual(roundTrip.lateDoses, 1)
        XCTAssertThrowsError(try log.exportFile(timeZone: zone, settings: fixtureSettings()))
    }

    func testUnsubmittedTailCorrectionsAndDeletionsPreserveTheSubmittedPrefix() throws {
        var log = fresh()
        log.ingest(created: [basal("first", 0, 1), bolus("submitted", 0.5)])
        log.commit(now: at(1), timeZone: zone, settleDelay: 0)
        let submitted = try XCTUnwrap(log.exportFile(timeZone: zone, settings: fixtureSettings()))
        log.markSubmitted(through: submitted.lastIndex)
        let prefix = log.records
        for delete in [false, true] {
            log.ingest(created: [basal("next", 1, 2), bolus("unsent", 1.5)])
            log.commit(now: at(2), timeZone: zone, settleDelay: 0)
            if delete { log.ingest(created: [], deleted: [bolus("unsent", 1.5)]) }
            else { log.ingest(created: [bolus("unsent", 1.5, units: 2)]) }
            log.commit(now: at(2), timeZone: zone, settleDelay: 0)
            XCTAssertTrue(log.conflicts.isEmpty)
            XCTAssertEqual(Array(log.records.prefix(prefix.count)), prefix)
            XCTAssertEqual(try DecodedIBF(file(&log)).bolus, delete ? 1 : 3)
        }
        log.ingest(created: [bolus("submitted", 0.5, units: 2)])
        XCTAssertNotNil(log.blockedReason(now: at(3)))
        log.ingest(created: [bolus("submitted", 0.5)])
        XCTAssertNil(log.blockedReason(now: at(3)))
    }

    func testSavedMeasuredDosesReplayWithoutConflictsAndValidSourceCorrectionsUnblock() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/measured-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = HistoryRepository(directory: folder)
        var log = fresh(); log.ownerID = "offline-patient"; log.ownerEmail = "offline@example.test"
        let dose = SourceDose(id: "measured", kind: .tempBasal, start: origin.addingTimeInterval(0.123456),
                              end: origin.addingTimeInterval(300.654321), rate: 1.2, delivered: 0.1)
        log.ingest(created: [dose, basal("close", 1, 2, rate: 0)])
        log.commit(now: at(3), timeZone: zone, settleDelay: 0)
        let exported = try XCTUnwrap(log.exportFile(timeZone: zone, settings: fixtureSettings()))
        log.markSubmitted(through: exported.lastIndex)
        try repository.save(log)
        var restored = try repository.loadExisting(accountID: "offline-patient", legacyEmail: nil)
        XCTAssertEqual(restored.sourceDoses[dose.id]?.start, dose.start)
        restored.ingest(created: [dose])
        XCTAssertTrue(restored.conflicts.isEmpty)
        // Also accept a v2 store's rounded timestamps without treating the unchanged measured units as a new rate.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer(); try value.encode(GlookoClient.isoTimestamp(date))
        }
        var old = try HistoryRepository.decode(encoder.encode(log))
        old.ingest(created: [dose])
        XCTAssertTrue(old.conflicts.isEmpty)
        restored.ingest(created: [basal("invalid-unsent", 3, 4, rate: -1)])
        XCTAssertNotNil(restored.blockedReason(now: at(5)))
        restored.ingest(created: [basal("invalid-unsent", 3, 4)])
        XCTAssertNil(restored.blockedReason(now: at(5)))
    }

    func testTailAmendmentsCannotMoveIntoSubmittedTimeAndLegacyDeletionDoesNotSubmitTheDeletedID() throws {
        var log = fresh()
        log.ingest(created: [basal("prefix", 0, 1)])
        log.commit(now: at(1), timeZone: zone, settleDelay: 0)
        let file = try XCTUnwrap(log.exportFile(timeZone: zone, settings: fixtureSettings()))
        log.lastSubmittedIndex = file.lastIndex // A v2 checkpoint has no explicit membership snapshot.
        log.ingest(created: [basal("tail", 1, 2), bolus("unsent", 1.5)])
        log.commit(now: at(2), timeZone: zone, settleDelay: 0)
        // Exercise migration from an actual old-format store with a committed, unsubmitted tail.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(log)) as? [String: Any])
        old["schemaVersion"] = 2
        for key in ["submittedIDs", "submittedThrough", "submittedState"] { old[key] = nil }
        var restored = try HistoryRepository.decode(JSONSerialization.data(withJSONObject: old))
        restored.ingest(created: [], deleted: [bolus("unsent", 1.5)])
        restored.ingest(created: [bolus("unsent", 1.5, units: 2)])
        restored.commit(now: at(2), timeZone: zone, settleDelay: 0)
        XCTAssertTrue(restored.conflicts.isEmpty)
        XCTAssertEqual(try DecodedIBF(self.file(&restored)).bolus, 2)
        let before = restored.records
        restored.ingest(created: [bolus("unsent", 0.5, units: 2)])
        XCTAssertNotNil(restored.blockedReason(now: at(3)))
        XCTAssertEqual(restored.records, before)
    }

    func testReverseOrderedReadbackFitsTheBackgroundExecutionBudget() throws {
        let events = (0..<500).map { IBFHistoryEvent(index: UInt32($0 + 1), date: at(Double($0) / 12), record: .bolus(delivered: 1, immediateSeconds: 20)) }
        let manifest = IngestionManifest(serial: 999000999, events: events, timeZone: zone, committedThrough: at(42))
        let rows = events.reversed().map { event -> [String: Any] in
            ["guid": "row-\(event.index)", "pumpGuid": "offline-pump", "softDeleted": false,
             "pumpTimestamp": WallClock(timeZone: zone).string(event.date), "insulinDelivered": 1]
        }
        let start = Date()
        let report = manifest.evaluate(pumps: [["serialNumber": "999000999", "guid": "offline-pump", "softDeleted": false]], rows: ["normal_boluses": rows])
        XCTAssertTrue(report.confirmed)
        XCTAssertEqual(report.matchedRecords, 500)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "Verification must leave time for networking and persistence within a background task")
        XCTAssertFalse(manifest.evaluate(pumps: [["serialNumber": "999000999", "guid": "offline-pump", "softDeleted": false]], rows: ["normal_boluses": Array(rows.dropLast())]).confirmed)
    }

    func testInterruptedBolusCannotAppendFutureTerminationAheadOfNextWindow() throws {
        var log = fresh()
        log.ingest(created: [basal("background", 0, 4),
                             SourceDose(id: "interrupted", kind: .bolus, start: at(0.9), end: at(1.1), programmed: 1, delivered: 0.4)])
        log.commit(now: at(2), timeZone: zone)
        _ = try file(&log)
        log = try HistoryRepository.decode(JSONEncoder.iso.encode(log))
        log.ingest(created: [SourceDose(id: "replacement", kind: .tempBasal, start: at(1.05), end: at(1.2), rate: 2)])
        log.commit(now: at(2.2), timeZone: zone)
        let result = try DecodedIBF(file(&log))
        XCTAssertEqual(result.bolus, 0.4, accuracy: 0.00001)
        XCTAssertTrue(zip(result.events, result.events.dropFirst()).allSatisfy { $0.date <= $1.date })
    }

    func testNeverConfirmedHistorySurvivesAnOutageLongerThanRetention() throws {
        var log = fresh()
        log.ingest(created: [basal("basal", 0, 20 * 24), bolus("old", 12), bolus("recent", 19 * 24)])
        log.commit(now: at(21 * 24), timeZone: zone, settleDelay: 0)
        XCTAssertEqual(try DecodedIBF(file(&log)).bolus, 2)
        XCTAssertNil(log.lastUploadedIndex)
        XCTAssertNotNil(log.sourceDoses["old"])
        let firstFile = try XCTUnwrap(log.exportFile(timeZone: zone, settings: fixtureSettings()))
        log.markVerified(fileIndex: firstFile.lastIndex, through: 1001, at: at(21 * 24))
        log.ingest(created: [basal("continued", 20 * 24, 22 * 24)])
        log.commit(now: at(23 * 24), timeZone: zone, settleDelay: 0)
        XCTAssertEqual(try DecodedIBF(file(&log)).bolus, 2, "Verifying a file's final subset must not prune its unconfirmed prefix")
    }

    func testMutableZeroDurationSuspensionRemainsUntilItsSourceFinalisesIt() throws {
        var log = fresh()
        let marker = SourceDose(id: "suspension", kind: .suspend, start: at(0.5), end: at(0.5), isMutable: true)
        log.ingest(created: [basal("basal", 0, 3), marker])
        log.commit(now: at(4), timeZone: zone, settleDelay: 0)
        XCTAssertNotNil(log.pending[marker.id])
        XCTAssertNotNil(log.blockedReason(now: at(48)))
        log.ingest(created: [SourceDose(id: marker.id, kind: .suspend, start: at(0.5), end: at(1)), basal("resumed", 1, 3)])
        log.commit(now: at(4), timeZone: zone, settleDelay: 0)
        XCTAssertNil(log.blockedReason(now: at(48)))
        XCTAssertTrue(log.records.contains { $0.record == .suspend && $0.date == at(0.5) })
    }

    func testProductionBytesPreserveDeliveryAcrossGapsShortTempsAndFractionalRates() throws {
        let cases: [(String, [SourceDose], Double, Double)] = [
            ("one-minute gap", [basal("first", 0, 1, rate: 3), basal("second", 1 + 1.0 / 60, 2, rate: 3), basal("end", 2, 3, rate: 0)], 4, 5.95),
            ("cancelled temp", [SourceDose(id: "temp", kind: .tempBasal, start: at(0), end: at(4.4 / 60), rate: 3), basal("end", 4.4 / 60, 1, rate: 0)], 2, 0.22),
            ("measured temp volume", [SourceDose(id: "temp", kind: .tempBasal, start: at(0), end: at(5.0 / 60), rate: 3, delivered: 0.1), basal("end", 5.0 / 60, 1, rate: 0)], 2, 0.1),
            ("fractional rate", [basal("first", 0, 24, rate: 0.4449), basal("end", 24, 25, rate: 0)], 26, 10.6776),
        ]
        for (name, doses, now, expected) in cases {
            var log = fresh(); log.ingest(created: doses); log.commit(now: at(now), timeZone: zone, settleDelay: 0)
            XCTAssertEqual(try DecodedIBF(file(&log)).basal, expected, accuracy: 0.000002, name)
        }
    }

    func testProductionSettingsComeFromTheProvidedSourceAndMissingSettingsFailClosed() throws {
        var log = fresh(); log.ingest(created: [basal("basal", 0, 2)]); log.commit(now: at(3), timeZone: zone)
        XCTAssertThrowsError(try log.exportFile(timeZone: zone))
        let parsed = try DecodedIBF(file(&log))
        XCTAssertEqual(parsed.maximumBolus, 7.5)
        XCTAssertEqual(parsed.profiles[11]?.first, 12)
        XCTAssertEqual(parsed.profiles[12]?.first, 72)
        XCTAssertEqual(parsed.profiles[13]?.first, 108)
        XCTAssertEqual(parsed.profiles[14]?.first, 126)
    }

    func testFractionalSourceArrivalsAcrossSavedSubmissionPreserveContinuousDeliveryAndRealGaps() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/fractional-windows-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = HistoryRepository(directory: directory)
        for gap in [0.0, 1.0] {
            var log = fresh(); log.ownerID = "fractional-\(gap)"; log.ownerEmail = "offline@example.test"
            let end = origin.addingTimeInterval(300.972785)
            log.ingest(created: [SourceDose(id: "temp", kind: .tempBasal, start: origin.addingTimeInterval(0.718017),
                                          end: end, rate: 0, delivered: 0)])
            log.commit(now: origin.addingTimeInterval(7500), timeZone: zone)
            let first = try XCTUnwrap(log.exportFile(timeZone: zone, settings: fixtureSettings()))
            log.markSubmitted(through: first.lastIndex)
            let prefix = log.records
            try repository.save(log)
            log = try repository.loadExisting(accountID: log.ownerID, legacyEmail: nil)
            let resumed = end.addingTimeInterval(gap), finished = resumed.addingTimeInterval(3600)
            log.ingest(created: [SourceDose(id: "resumed", kind: .basal, start: resumed, end: finished, rate: 0.43),
                                 SourceDose(id: "close", kind: .basal, start: finished, end: finished.addingTimeInterval(3600), rate: 0)])
            log.commit(now: origin.addingTimeInterval(15000), timeZone: zone)
            XCTAssertEqual(Array(log.records.prefix(prefix.count)), prefix)
            let decoded = try DecodedIBF(file(&log))
            XCTAssertEqual(decoded.basal, 0.43, accuracy: 0.000002)
            XCTAssertEqual(decoded.events.filter { $0.kind == 16 }.count, gap == 0 ? 0 : 1)
            XCTAssertEqual(decoded.events.filter { $0.kind == 65536 }.count, gap == 0 ? 0 : 1)
        }
    }

    func testReadbackDefersAnIntervalUntilItsClosingBasalIsFinal() throws {
        let events = [IBFHistoryEvent(index: 1, date: at(0), record: .basal(rate: 0.49, tempMinutes: 0)),
                      IBFHistoryEvent(index: 2, date: origin.addingTimeInterval(815), record: .basal(rate: 0.5, tempMinutes: 0)),
                      IBFHistoryEvent(index: 3, date: origin.addingTimeInterval(841), record: .basal(rate: 0.49, tempMinutes: 0), inProgress: true)]
        let pumps: [[String: Any]] = [["serialNumber": "999000999", "guid": "offline-pump", "softDeleted": false]]
        // Literal readback follows the independently observed native importer response.
        let first: [String: Any] = ["guid": "first", "pumpGuid": "offline-pump", "softDeleted": false,
                                    "pumpTimestamp": "2026-10-01T00:00:00.000Z", "duration": 815, "rate": 0.49]
        let manifest = IngestionManifest(serial: 999000999, events: events, timeZone: zone, committedThrough: origin.addingTimeInterval(1100))
        let report = manifest.evaluate(pumps: pumps, rows: ["scheduled_basals": [first]])
        XCTAssertTrue(report.confirmed)
        XCTAssertEqual(report.deferredRecords, 1)
        XCTAssertEqual(report.confirmedThrough, origin.addingTimeInterval(815))
        XCTAssertEqual(manifest.verifiedThroughIndex, 1)
        var advanced = events; advanced[2].inProgress = false
        advanced.append(.init(index: 4, date: origin.addingTimeInterval(1500), record: .basal(rate: 0.48, tempMinutes: 0), inProgress: true))
        let next = IngestionManifest(serial: 999000999, events: advanced, timeZone: zone, committedThrough: origin.addingTimeInterval(1600))
        XCTAssertFalse(next.evaluate(pumps: pumps, rows: ["scheduled_basals": [first]]).confirmed)
        let second: [String: Any] = ["guid": "second", "pumpGuid": "offline-pump", "softDeleted": false,
                                     "pumpTimestamp": "2026-10-01T00:13:35.000Z", "duration": 26, "rate": 0.5]
        XCTAssertTrue(next.evaluate(pumps: pumps, rows: ["scheduled_basals": [first, second]]).confirmed)
    }

    func testPatientScopedMigrationPreservesIndicesAndNeverFallsBackAfterCorruption() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/history-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = #"{"serial":999000123,"powerUp":"2020-01-01T00:00:00Z","podLot":42,"podSerial":7,"nextIndex":1003,"records":[{"index":1000,"date":"2026-10-01T00:00:00Z","record":{"activate":{"lot":42,"serial":7}},"inProgress":false,"utcOffset":0},{"index":1001,"date":"2026-10-01T00:00:00Z","record":{"basal":{"rate":1,"tempMinutes":0}},"inProgress":false,"utcOffset":0},{"index":1002,"date":"2026-10-01T01:00:00Z","record":{"download":{}},"inProgress":false,"utcOffset":0}],"pending":{},"committed":{"basal":"2026-10-01T01:00:00Z"},"lateDoses":0,"lastUploadedIndex":1002,"committedThrough":"2026-10-01T01:00:00Z","state":{"delivery":{"scheduled":{"rate":1}},"id":"basal"},"historyStart":"2026-10-01T00:00:00Z"}"#
        try Data(legacy.utf8).write(to: root.appendingPathComponent("pump-history.json"))
        let repository = HistoryRepository(directory: root)
        let patientA = GlookoAccount(id: "patient-a", email: "a@example.test")
        XCTAssertThrowsError(try repository.bind(patientA))
        let migrated = try repository.bind(patientA, legacyEmail: patientA.email)
        XCTAssertEqual(migrated.serial, 999000123)
        XCTAssertEqual(migrated.records.map(\.index), [1000, 1001, 1002])
        XCTAssertEqual(migrated.lastSubmittedIndex, 1002)
        XCTAssertNil(migrated.lastUploadedIndex, "A legacy HTTP acknowledgement is not ingestion confirmation")
        let patientB = GlookoAccount(id: "patient-b", email: "b@example.test")
        let other = try repository.bind(patientB)
        XCTAssertEqual(other.ownerID, patientB.id)
        XCTAssertTrue(other.records.isEmpty)
        let location = root.appendingPathComponent(patientA.storageKey).appendingPathComponent("pump-history.json")
        let corrupt = Data("broken history".utf8)
        try corrupt.write(to: location)
        XCTAssertThrowsError(try repository.loadExisting(accountID: patientA.id, legacyEmail: nil))
        XCTAssertThrowsError(try repository.bind(patientA))
        XCTAssertEqual(try Data(contentsOf: location), corrupt)
    }

    func testReadbackRequiresCorrectPatientDeviceQuantitiesAndEveryFinalRecord() throws {
        let start = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!
        let events = [IBFHistoryEvent(index: 1, date: start, record: .basal(rate: 1, tempMinutes: 0)),
                      IBFHistoryEvent(index: 2, date: start.addingTimeInterval(1800), record: .bolus(delivered: 0.5, immediateSeconds: 20)),
                      IBFHistoryEvent(index: 3, date: start.addingTimeInterval(3600), record: .basal(rate: 0, tempMinutes: 0))]
        let manifest = IngestionManifest(serial: 999000999, events: events, timeZone: zone, committedThrough: start.addingTimeInterval(3600))
        let pumps: [[String: Any]] = [["serialNumber": "999000999", "guid": "patient-pump", "softDeleted": false]]
        let basal: [String: Any] = ["guid": "basal-row", "pumpGuid": "patient-pump", "softDeleted": false,
                                    "pumpTimestamp": "2026-10-01T00:00:00.000Z", "duration": 3600, "rate": 1]
        let bolus: [String: Any] = ["guid": "bolus-row", "pumpGuid": "patient-pump", "softDeleted": false,
                                    "pumpTimestamp": "2026-10-01T00:30:00.000Z", "insulinDelivered": 0.5]
        XCTAssertTrue(manifest.evaluate(pumps: pumps, rows: ["scheduled_basals": [basal], "normal_boluses": [bolus]]).confirmed)
        for field in ["pumpGuid", "insulinDelivered", "softDeleted"] {
            var invalid = bolus; invalid[field] = nil
            XCTAssertFalse(manifest.evaluate(pumps: pumps, rows: ["scheduled_basals": [basal], "normal_boluses": [invalid]]).confirmed, field)
        }
        XCTAssertFalse(manifest.evaluate(pumps: pumps, rows: ["scheduled_basals": [basal]]).confirmed)
        XCTAssertFalse(manifest.evaluate(pumps: [], rows: ["scheduled_basals": [basal], "normal_boluses": [bolus]]).confirmed)
        var wrongRate = basal; wrongRate["rate"] = 0
        XCTAssertEqual(manifest.evaluate(pumps: pumps, rows: ["scheduled_basals": [wrongRate], "normal_boluses": [bolus]]).mismatchedRecords, 1)
        var duplicate = basal; duplicate["guid"] = "duplicate"
        let duplicated = manifest.evaluate(pumps: pumps, rows: ["scheduled_basals": [basal, duplicate], "normal_boluses": [bolus]])
        XCTAssertFalse(duplicated.confirmed)
        XCTAssertEqual(duplicated.duplicateRecords, 1)
    }

    func testMalformedResourcesReturnErrorsBeforeNetworkAndManualBuildersUseExplicitZone() async throws {
        let client = GlookoClient()
        let scan = await client.scan("_")
        guard case .invalidResponse = scan.outcome else { return XCTFail("Malformed resources must fail before network access") }
        do { _ = try await client.put(resource: "", records: []); XCTFail("Expected invalid resource") }
        catch GlookoError.invalidResource { }
        let date = ISO8601DateFormatter().date(from: "2026-06-01T12:00:00Z")!
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        XCTAssertEqual(GlookoRecords.insulin(guid: "fixture", timestamp: date, units: 1, type: "bolus", timeZone: berlin)["timestamp"] as? String,
                       "2026-06-01T14:00:00.000Z")
        XCTAssertEqual(GlookoRecords.carbs(mealGuid: "meal", foodGuid: "food", timestamp: date, grams: 10, timeZone: berlin).meal["timestamp"] as? String,
                       "2026-06-01T14:00:00.000Z")
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder }
}

/// Independent reader of the public IBF framing/history layout (Tidepool insuletDriver and the genuine
/// IBF 0.1.7 reference). It does not call the production encoder's flags, timeline or total calculator.
private struct DecodedIBF {
    struct Event { var date: Date; var kind: Int; var flags: Int; var rate: Double; var minutes: Int; var units: Double }
    var events: [Event] = []
    var profiles: [Int: [Int]] = [:]
    var maximumBolus = 0.0
    var basal = 0.0
    var bolus = 0.0
    enum Failure: Error { case invalidFile }

    init(_ data: Data) throws {
        let bytes = Array(data)
        func number(_ b: [UInt8], _ offset: Int, _ count: Int, big: Bool = false) -> Int {
            (0..<count).reduce(0) { $0 | (Int(b[offset + $1]) << (8 * (big ? count - 1 - $1 : $1))) }
        }
        var cursor = 0
        var indexed: [(Int, Event)] = []
        while cursor < bytes.count {
            guard cursor + 2 <= bytes.count else { throw Failure.invalidFile }
            let size = number(bytes, cursor, 2, big: true)
            guard size >= 2, cursor + size + 2 <= bytes.count else { throw Failure.invalidFile }
            let body = Array(bytes[(cursor + 2)..<(cursor + size)])
            guard !body.isEmpty, body.reduce(0, { $0 + Int($1) }) & 65535 == number(bytes, cursor + size, 2, big: true) else { throw Failure.invalidFile }
            if body.count == 120 { maximumBolus = Double(number(body, 17, 4)) / 100 }
            if body.count == 205, (11...21).contains(Int(body[0])) {
                profiles[Int(body[0])] = (0..<48).map { number(body, 13 + $0 * 4, 4) }
            }
            if body[0] == 3, body.count >= 39, number(body, 1, 4, big: true) != Int(UInt32.max) {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                let date = try XCTUnwrap(calendar.date(from: DateComponents(year: number(body, 11, 2), month: Int(body[10]), day: Int(body[9]),
                                                                          hour: Int(body[15]), minute: Int(body[14]), second: Int(body[13]))))
                indexed.append((number(body, 1, 4, big: true), .init(date: date, kind: number(body, 21, 4), flags: number(body, 25, 2),
                                                                         rate: Double(number(body, 29, 4)) / 100, minutes: number(body, 33, 2),
                                                                         units: Double(number(body, 29, 4)) / 100)))
            }
            cursor += size + 2
        }
        events = indexed.sorted { $0.0 < $1.0 }.map(\.1)
        var rate: Double?
        var since: Date?
        var expiry: Date?
        for event in events {
            if [8, 16, 1, 0x20000].contains(event.kind), let start = since, let active = rate {
                basal += max(0, min(event.date, expiry ?? event.date).timeIntervalSince(start)) * active / 3600
                since = event.date
            }
            if event.kind == 8 {
                rate = event.flags & 4 == 0 ? event.rate : nil
                since = event.date
                expiry = event.minutes > 0 ? event.date.addingTimeInterval(Double(event.minutes * 60)) : nil
            } else if [16, 1].contains(event.kind) { rate = nil }
            else if event.kind == 4 { bolus += event.units }
        }
    }
}
