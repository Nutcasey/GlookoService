import XCTest
import GlookoKit

final class InsulinOutboxTests: XCTestCase {
    private let hour = Date(timeIntervalSince1970: 1_793_134_800) // 27 October 2026 21:00 UTC
    private func at(_ minutes: Double) -> Date { hour.addingTimeInterval(minutes * 60) }
    private func temp(_ id: String, _ from: Double, _ to: Double, _ units: Double) -> SourceDose {
        SourceDose(id: id, kind: .tempBasal, start: at(from), end: at(to), rate: 0, delivered: units)
    }
    private func bolus(_ id: String, _ minute: Double, _ units: Double) -> SourceDose {
        SourceDose(id: id, kind: .bolus, start: at(minute), end: at(minute + 1), programmed: units, delivered: units)
    }
    private func sendAll(_ outbox: inout InsulinOutbox) {
        let due = outbox.due
        outbox.markSubmitted(due)
        due.forEach { outbox.confirm($0) }
    }

    /// History committed locally but never submitted has not reached Glooko and must still be reported.
    func testCutOverStartsAtTheSubmittedBoundaryAndNeverDropsUnsubmittedHistory() {
        var log = PumpHistoryLog.newIdentity()
        log.historyStart = hour
        log.ingest(created: [bolus("unsent", 10, 1), temp("unsent-basal", 0, 120, 0)])
        log.commit(now: at(180), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertNotNil(log.committedThrough)
        XCTAssertNil(log.submittedBoundary)
        var outbox = InsulinOutbox.cutOver(from: log, now: at(180))
        XCTAssertEqual(outbox.reportingStart, hour)
        outbox.refresh(now: at(180))
        XCTAssertEqual(outbox.due.map(\.units), [1])
    }

    /// A pulse split across two hours keeps its measured volume, and whole and partial hours never share an identity.
    func testHoursPreserveMeasuredVolumeAndPartialHoursHaveTheirOwnIdentity() {
        var whole = InsulinOutbox(reportingStart: hour)
        whole.stage(created: [temp("pulse", 50, 70, 0.025), temp("after", 70, 125, 0)], deleted: [])
        whole.refresh(now: at(180))
        XCTAssertEqual(whole.due.map(\.units), [0.013, 0.012])

        var partial = InsulinOutbox(reportingStart: at(30))
        partial.stage(created: [temp("pulse", 50, 70, 0.025), temp("after", 70, 125, 0)], deleted: [])
        partial.refresh(now: at(180))
        XCTAssertNotEqual(partial.due.first?.guid, whole.due.first?.guid)
        XCTAssertEqual(partial.due.last?.guid, whole.due.last?.guid)
        XCTAssertEqual(InsulinOutbox.hourEnd(partial.due[0]), at(60))
    }

    /// Glooko never revives a soft-deleted GUID, so an entry wanted again must move to a new identity.
    func testAnEntryWantedAgainAfterDeletionUsesANewIdentity() throws {
        var outbox = InsulinOutbox(reportingStart: hour)
        let dose = bolus("b", 10, 2)
        outbox.stage(created: [dose], deleted: [])
        outbox.refresh(now: at(60))
        let first = try XCTUnwrap(outbox.due.first)
        sendAll(&outbox)
        outbox.stage(created: [], deleted: [dose])
        outbox.refresh(now: at(61))
        XCTAssertEqual(outbox.due.map(\.deleted), [true])
        sendAll(&outbox)
        outbox.stage(created: [dose], deleted: [])
        outbox.refresh(now: at(62))
        let revived = try XCTUnwrap(outbox.due.first)
        XCTAssertNotEqual(revived.guid, first.guid)
        XCTAssertFalse(revived.deleted)

        // The same applies when Glooko already holds a live entry's GUID as deleted.
        outbox.supersede(revived)
        outbox.refresh(now: at(63))
        XCTAssertEqual(outbox.due.count, 1)
        XCTAssertNotEqual(outbox.due.first?.guid, revived.guid)
    }

    /// Edits update the sent entry; an entry that never left the phone is dropped rather than deleted remotely.
    func testEditsUpdateTheSameEntryAndUnsentEntriesAreDropped() {
        var outbox = InsulinOutbox(reportingStart: hour)
        outbox.stage(created: [bolus("sent", 5, 1), bolus("unsent", 20, 1)], deleted: [])
        outbox.refresh(now: at(60))
        let sent = outbox.due.first { $0.start == at(5) }!
        outbox.markSubmitted([sent]); outbox.confirm(sent)
        outbox.stage(created: [bolus("sent", 5, 1.5)], deleted: [bolus("unsent", 20, 1)])
        outbox.refresh(now: at(61))
        XCTAssertEqual(outbox.due.map(\.guid), [sent.guid])
        XCTAssertEqual(outbox.due.map(\.units), [1.5])
    }

    /// A running temporary basal holds back its hour until Loop finalises the delivered volume.
    func testARunningDeliveryHoldsBackItsHour() {
        var outbox = InsulinOutbox(reportingStart: hour)
        outbox.stage(created: [temp("done", 0, 50, 0.5),
                               SourceDose(id: "running", kind: .tempBasal, start: at(50), end: at(80), rate: 1, isMutable: true)], deleted: [])
        outbox.refresh(now: at(180))
        XCTAssertTrue(outbox.due.isEmpty)
        outbox.stage(created: [temp("running", 50, 80, 0.5)], deleted: [])
        outbox.refresh(now: at(180))
        XCTAssertEqual(outbox.due.map(\.units), [0.667])
    }

    /// Drug names survive restarts; upgrading an older cache updates labels without duplicating delivery.
    func testInsulinNamesAndLegacyUpgradePreserveDeliveryIdentitiesAndQuantities() throws {
        func named(_ dose: SourceDose, _ name: String) throws -> SourceDose {
            // Exercise the persisted source contract, including an older reader which ignores the new field.
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(dose)) as? [String: Any])
            json["insulinName"] = name
            return try JSONDecoder().decode(SourceDose.self, from: JSONSerialization.data(withJSONObject: json))
        }
        var outbox = InsulinOutbox(reportingStart: hour)
        outbox.stage(created: [try named(temp("first", 0, 30, 0.6), "Fiasp"),
                               try named(temp("second", 30, 60, 0.9), "Humalog"),
                               temp("unknown", 60, 120, 0.3),
                               try named(bolus("b", 10, 1.25), "Fiasp")], deleted: [])
        outbox.refresh(now: at(180))
        let original = outbox.due
        let zone = TimeZone(secondsFromGMT: 0)!
        let labels = original.compactMap { GlookoRecords.deliveredInsulin($0, timeZone: zone)["name"] as? String }
        XCTAssertEqual(Set(labels), ["Fiasp / Humalog via Loop", "Fiasp via Loop", "Insulin via Loop"])
        sendAll(&outbox)
        var restored = try JSONDecoder().decode(InsulinOutbox.self, from: JSONEncoder().encode(outbox))
        restored.refresh(now: at(180))
        XCTAssertTrue(restored.due.isEmpty, "A restart must not resend confirmed labels")

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(outbox)) as? [String: Any])
        var entries = try XCTUnwrap(legacy["entries"] as? [String: [String: Any]])
        for id in entries.keys {
            for field in ["current", "confirmed"] {
                var entry = try XCTUnwrap(entries[id]?[field] as? [String: Any])
                entry.removeValue(forKey: "name")
                entries[id]?[field] = entry
            }
        }
        var doses = try XCTUnwrap(legacy["doses"] as? [String: [String: Any]])
        for id in doses.keys { doses[id]?.removeValue(forKey: "insulinName") }
        legacy["entries"] = entries; legacy["doses"] = doses
        restored = try JSONDecoder().decode(InsulinOutbox.self, from: JSONSerialization.data(withJSONObject: legacy))
        restored.refresh(now: at(180))
        XCTAssertEqual(restored.due.count, original.count)
        for entry in restored.due {
            let old = try XCTUnwrap(original.first { $0.guid == entry.guid })
            XCTAssertEqual(entry.units, old.units)
            XCTAssertEqual(entry.start, old.start)
            XCTAssertEqual(entry.kind, old.kind)
            XCTAssertEqual(GlookoRecords.deliveredInsulin(entry, timeZone: zone)["name"] as? String, "Insulin via Loop")
        }
    }
}
