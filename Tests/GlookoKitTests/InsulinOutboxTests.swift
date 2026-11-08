import XCTest
import GlookoKit

final class InsulinOutboxTests: XCTestCase {
    private let hour = Date(timeIntervalSince1970: 1_793_134_800) // 27 October 2026 21:00 UTC
    private func at(_ minutes: Double) -> Date { hour.addingTimeInterval(minutes * 60) }
    /// Most cases are about quantities and identities, so they report in UTC whatever the Mac's zone.
    private let utc: (Date) -> Int = { _ in 0 }
    private func temp(_ id: String, _ from: Double, _ to: Double, _ units: Double) -> SourceDose {
        SourceDose(id: id, kind: .tempBasal, start: at(from), end: at(to), rate: 0, delivered: units)
    }
    private func bolus(_ id: String, _ minute: Double, _ units: Double) -> SourceDose {
        SourceDose(id: id, kind: .bolus, start: at(minute), end: at(minute + 1), programmed: units, delivered: units)
    }
    func testBasalHoursGetAnAccountIDWithoutChangingOrDuplicatingOnesAlreadyQueued() throws {
        let from = InsulinOutbox.accountIDsFrom, earlier = from.addingTimeInterval(-3600)
        func outbox(_ start: Date) -> InsulinOutbox {
            var result = InsulinOutbox(reportingStart: start)
            result.stage(created: [SourceDose(id: "basal", kind: .tempBasal, start: start, end: start.addingTimeInterval(3600), rate: 1, delivered: 1)], deleted: [])
            return result
        }
        let now = from.addingTimeInterval(7200)

        var mine = outbox(from), theirs = outbox(from)
        mine.refresh(now: now, utcOffset: utc, accountKey: "aaaaaaaa11111111")
        theirs.refresh(now: now, utcOffset: utc, accountKey: "bbbbbbbb22222222")
        XCTAssertEqual(mine.due.count, 1)
        XCTAssertNotEqual(mine.due[0].guid, theirs.due[0].guid, "Two accounts never share an hour's ID")
        XCTAssertEqual(mine.due[0].externalID, "loop:basal:aaaaaaaa:\(Int(from.timeIntervalSince1970))")
        let stable = mine.due[0].guid
        mine.refresh(now: now, utcOffset: utc, accountKey: "aaaaaaaa11111111")
        XCTAssertEqual(mine.due.map(\.guid), [stable])
        XCTAssertFalse(mine.canMoveToAccountID(mine.due[0]), "An entry already on the account's ID has nowhere to move")

        var older = outbox(earlier)
        older.refresh(now: now, utcOffset: utc, accountKey: "aaaaaaaa11111111")
        XCTAssertEqual(older.due[0].externalID, "loop:basal:\(Int(earlier.timeIntervalSince1970))", "Re-sending an older hour can't make a second row")

        // Queued by a version before account IDs, even for an hour after the change.
        var queued = outbox(from)
        queued.refresh(now: now, utcOffset: utc)
        let shared = try XCTUnwrap(queued.due.first)
        queued.refresh(now: now, utcOffset: utc, accountKey: "aaaaaaaa11111111")
        XCTAssertEqual(queued.due, [shared], "A queued hour stays on its ID")

        queued.markSubmitted([shared])
        XCTAssertTrue(queued.moveToAccountID(shared))
        queued = try JSONDecoder().decode(InsulinOutbox.self, from: JSONEncoder().encode(queued))
        queued.refresh(now: now, utcOffset: utc, accountKey: "aaaaaaaa11111111")
        XCTAssertEqual(queued.due.count, 1, "No deletion is queued for the refused ID")
        XCTAssertEqual(queued.due[0].units, shared.units)
        XCTAssertEqual(queued.due[0].start, shared.start)
        XCTAssertFalse(queued.due[0].deleted)
        XCTAssertNotEqual(queued.due[0].guid, shared.guid)

        var confirmed = outbox(from)
        confirmed.refresh(now: now, utcOffset: utc)
        let sent = try XCTUnwrap(confirmed.due.first)
        sendAll(&confirmed)
        XCTAssertFalse(confirmed.canMoveToAccountID(sent), "Glooko holds it, so a second ID would double it")
        XCTAssertFalse(confirmed.moveToAccountID(sent))
    }

    private func sendAll(_ outbox: inout InsulinOutbox) {
        let due = outbox.due
        outbox.markSubmitted(due)
        due.forEach { outbox.confirm($0) }
    }

    func testRetentionNeverRecreatesPartialBasalHoursAcrossRestartsOrAnOldPrunedCache() throws {
        let midnight = Date(timeIntervalSince1970: floor(hour.timeIntervalSince1970 / 86400) * 86400)
        let now = midnight.addingTimeInterval(14 * 86400 + 1800)
        let segments = (0..<3).map { index in
            SourceDose(id: "segment-\(index)", kind: .tempBasal,
                       start: midnight.addingTimeInterval(Double(index) * 1200),
                       end: midnight.addingTimeInterval(Double(index + 1) * 1200), delivered: 1.0 / 3)
        }
        var outbox = InsulinOutbox(reportingStart: midnight)
        outbox.stage(created: segments + [SourceDose(id: "recent", kind: .tempBasal,
            start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600), delivered: 0)], deleted: [])
        outbox.refresh(now: now, utcOffset: utc)
        XCTAssertEqual(outbox.due.map(\.units), [1])
        sendAll(&outbox)
        let confirmed = outbox.confirmedEntries
        for offset in [0.0, 3600, 86400] {
            outbox.prune(now: now.addingTimeInterval(offset), utcOffset: utc)
            outbox = try JSONDecoder().decode(InsulinOutbox.self, from: JSONEncoder().encode(outbox))
            outbox.refresh(now: now.addingTimeInterval(offset), utcOffset: utc)
            XCTAssertTrue(outbox.due.isEmpty, "Pruning is not a clinical correction")
        }

        // An older build already lost the first segment and the tracked hour. Do not reconstruct
        // a smaller hour from those fragments on the first launch of the corrected build.
        var legacy = InsulinOutbox(reportingStart: midnight)
        legacy.stage(created: segments + [SourceDose(id: "retained", kind: .tempBasal,
            start: midnight.addingTimeInterval(86400), end: midnight.addingTimeInterval(90000), delivered: 1), SourceDose(id: "recent", kind: .tempBasal,
            start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600), delivered: 0)], deleted: [])
        legacy.refresh(now: now, utcOffset: utc); sendAll(&legacy)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json.removeValue(forKey: "recomputeFrom")
        var doses = try XCTUnwrap(json["doses"] as? [String: Any]); doses.removeValue(forKey: "segment-0")
        json["doses"] = doses
        var entries = try XCTUnwrap(json["entries"] as? [String: Any]); entries.removeValue(forKey: confirmed[0].guid)
        json["entries"] = entries
        legacy = try JSONDecoder().decode(InsulinOutbox.self, from: JSONSerialization.data(withJSONObject: json))
        legacy.refresh(now: now, utcOffset: utc)
        XCTAssertFalse(legacy.due.contains { $0.guid == confirmed[0].guid }, "Lost source data must not rewrite a pruned hour")
        XCTAssertTrue(legacy.due.isEmpty)
    }

    /// A pulse split across two hours keeps its measured volume, and whole and partial hours never share an identity.
    func testHoursPreserveMeasuredVolumeAndPartialHoursHaveTheirOwnIdentity() {
        var whole = InsulinOutbox(reportingStart: hour)
        whole.stage(created: [temp("pulse", 50, 70, 0.025), temp("after", 70, 125, 0)], deleted: [])
        whole.refresh(now: at(180), utcOffset: utc)
        XCTAssertEqual(whole.due.map(\.units), [0.013, 0.012])

        var partial = InsulinOutbox(reportingStart: at(30))
        partial.stage(created: [temp("pulse", 50, 70, 0.025), temp("after", 70, 125, 0)], deleted: [])
        partial.refresh(now: at(180), utcOffset: utc)
        XCTAssertNotEqual(partial.due.first?.guid, whole.due.first?.guid)
        XCTAssertEqual(partial.due.last?.guid, whole.due.last?.guid)
        XCTAssertEqual(InsulinOutbox.hourEnd(partial.due[0]), at(60))
    }

    /// Glooko never revives a soft-deleted GUID, so an entry wanted again must move to a new identity.
    func testAnEntryWantedAgainAfterDeletionUsesANewIdentity() throws {
        var outbox = InsulinOutbox(reportingStart: hour)
        let dose = bolus("b", 10, 2)
        outbox.stage(created: [dose], deleted: [])
        outbox.refresh(now: at(60), utcOffset: { _ in 3600 })
        let first = try XCTUnwrap(outbox.due.first)
        sendAll(&outbox)
        outbox.stage(created: [], deleted: [dose])
        outbox.refresh(now: at(61), utcOffset: utc)
        XCTAssertEqual(outbox.due.map(\.deleted), [true])
        sendAll(&outbox)
        outbox.stage(created: [dose], deleted: [])
        outbox.refresh(now: at(62), utcOffset: { _ in -18000 })
        let revived = try XCTUnwrap(outbox.due.first)
        XCTAssertNotEqual(revived.guid, first.guid)
        XCTAssertFalse(revived.deleted)
        XCTAssertEqual(revived.utcOffset, first.utcOffset, "A replacement identity must keep the original reporting clock")

        // The same applies when Glooko already holds a live entry's GUID as deleted.
        outbox.supersede(revived)
        outbox.refresh(now: at(63), utcOffset: utc)
        XCTAssertEqual(outbox.due.count, 1)
        XCTAssertNotEqual(outbox.due.first?.guid, revived.guid)
    }

    /// Edits update the sent entry; an entry that never left the phone is dropped rather than deleted remotely.
    func testEditsUpdateTheSameEntryAndUnsentEntriesAreDropped() {
        var outbox = InsulinOutbox(reportingStart: hour)
        outbox.stage(created: [bolus("sent", 5, 1), bolus("unsent", 20, 1)], deleted: [])
        outbox.refresh(now: at(60), utcOffset: utc)
        let sent = outbox.due.first { $0.start == at(5) }!
        outbox.markSubmitted([sent]); outbox.confirm(sent)
        outbox.stage(created: [bolus("sent", 5, 1.5)], deleted: [bolus("unsent", 20, 1)])
        outbox.refresh(now: at(61), utcOffset: utc)
        XCTAssertEqual(outbox.due.map(\.guid), [sent.guid])
        XCTAssertEqual(outbox.due.map(\.units), [1.5])
    }

    /// Another app can save a basal injection as a single moment. It counts once, in the hour containing it.
    func testAnInstantBasalCountsInTheHourContainingIt() {
        var outbox = InsulinOutbox(reportingStart: hour)
        outbox.stage(created: [temp("pump", 0, 120, 1), SourceDose(id: "pen", kind: .basal, start: at(60), end: at(60), delivered: 20)], deleted: [])
        outbox.refresh(now: at(180), utcOffset: utc)
        XCTAssertEqual(outbox.due.map(\.units), [0.5, 20.5])
    }

    /// A running temporary basal holds back its hour until Loop finalises the delivered volume.
    func testARunningDeliveryHoldsBackItsHour() {
        var outbox = InsulinOutbox(reportingStart: hour)
        outbox.stage(created: [temp("done", 0, 50, 0.5),
                               SourceDose(id: "running", kind: .tempBasal, start: at(50), end: at(80), rate: 1, isMutable: true)], deleted: [])
        outbox.refresh(now: at(180), utcOffset: utc)
        XCTAssertTrue(outbox.due.isEmpty)
        outbox.stage(created: [temp("running", 50, 80, 0.5)], deleted: [])
        outbox.refresh(now: at(180), utcOffset: utc)
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
        outbox.refresh(now: at(180), utcOffset: utc)
        let original = outbox.due
        let zone = TimeZone(secondsFromGMT: 0)!
        let labels = original.compactMap { GlookoRecords.deliveredInsulin($0, timeZone: zone)["name"] as? String }
        XCTAssertEqual(Set(labels), ["Basal hour · Fiasp / Humalog via Loop", "Bolus · Fiasp via Loop", "Basal hour · Insulin via Loop"])
        sendAll(&outbox)
        var restored = try JSONDecoder().decode(InsulinOutbox.self, from: JSONEncoder().encode(outbox))
        restored.refresh(now: at(180), utcOffset: utc)
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
        restored.refresh(now: at(180), utcOffset: utc)
        XCTAssertEqual(restored.due.count, original.count)
        for entry in restored.due {
            let old = try XCTUnwrap(original.first { $0.guid == entry.guid })
            XCTAssertEqual(entry.units, old.units)
            XCTAssertEqual(entry.start, old.start)
            XCTAssertEqual(entry.kind, old.kind)
            XCTAssertEqual(GlookoRecords.deliveredInsulin(entry, timeZone: zone)["name"] as? String,
                           entry.kind == .basal ? "Basal hour · Insulin via Loop" : "Bolus · Insulin via Loop")
        }
    }

    // MARK: Local clock hours

    private let india: (Date) -> Int = { _ in 19800 } // UTC+05:30
    private func basal(_ id: String, from: Date, hours: Double, rate: Double = 1) -> SourceDose {
        SourceDose(id: id, kind: .tempBasal, start: from, end: from.addingTimeInterval(hours * 3600), rate: rate, delivered: rate * hours)
    }
    private func clock(_ date: Date, _ offset: Int) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: offset); f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    func testBasalHoursFollowTheLocalClockInAHalfHourZone() {
        // 21:10 UTC is 02:40 in India; that local hour is reported from the start of reporting.
        var outbox = InsulinOutbox(reportingStart: at(10))
        outbox.stage(created: [basal("day", from: at(0), hours: 30)], deleted: [])
        outbox.refresh(now: at(0).addingTimeInterval(30 * 3600), utcOffset: india)
        let hours = outbox.due.filter { $0.kind == .basal }
        XCTAssertEqual(hours.prefix(3).map { clock($0.start, 19800) }, ["02:40", "03:00", "04:00"])
        XCTAssertEqual(hours.prefix(3).map { clock(InsulinOutbox.hourEnd($0), 19800) }, ["03:00", "04:00", "05:00"])
        XCTAssertEqual(hours.first?.units, 0.333)
        XCTAssertTrue(hours.dropFirst().allSatisfy { $0.units == 1 && clock($0.start, 19800).hasSuffix(":00") })
        XCTAssertEqual(hours.reduce(0) { $0 + $1.units }, InsulinOutboxTests.round(hours.count > 0 ? (InsulinOutbox.hourEnd(hours.last!).timeIntervalSince(at(10)) / 3600) : 0), accuracy: 0.0005)
        XCTAssertTrue(hours.allSatisfy { $0.utcOffset == 19800 })
    }

    func testAQueueSavedBeforeLocalHoursKeepsItsEntriesAndSwitchesAfterTheLastHourItSent() throws {
        // A queue from the previous build: UTC-aligned hours already confirmed in Glooko.
        var outbox = InsulinOutbox(reportingStart: at(0))
        outbox.stage(created: [basal("day", from: at(0), hours: 6)], deleted: [])
        outbox.refresh(now: at(0).addingTimeInterval(3 * 3600 + 900), utcOffset: utc)
        sendAll(&outbox)
        let sent = outbox.confirmedEntries.sorted { $0.start < $1.start }
        XCTAssertEqual(sent.map { clock($0.start, 0) }, ["21:00", "22:00", "23:00"])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(outbox)) as? [String: Any])
        json.removeValue(forKey: "localHoursFrom")
        var entries = try XCTUnwrap(json["entries"] as? [String: [String: Any]])
        for guid in entries.keys {
            for key in ["current", "confirmed"] {
                var entry = try XCTUnwrap(entries[guid]?[key] as? [String: Any]); entry.removeValue(forKey: "end"); entries[guid]?[key] = entry
            }
        }
        json["entries"] = entries
        var upgraded = try JSONDecoder().decode(InsulinOutbox.self, from: JSONSerialization.data(withJSONObject: json))
        // The phone is in India now. Nothing already in Glooko may change.
        upgraded.refresh(now: at(0).addingTimeInterval(6 * 3600 + 900), utcOffset: india)
        XCTAssertEqual(upgraded.localHoursFrom, at(180))
        let due = upgraded.due
        XCTAssertFalse(due.contains { entry in sent.contains { $0.guid == entry.guid } }, "Hours already sent keep their UTC alignment and identity")
        XCTAssertEqual(due.map { clock($0.start, 19800) }, ["05:30", "06:00", "07:00"],
                       "After the cut-over, a short hour reaches the local clock, then hours follow it")
        XCTAssertEqual(due.map(\.units), [0.5, 1, 1])
        upgraded.prune(now: at(0).addingTimeInterval(6 * 3600 + 900), utcOffset: india)
        upgraded.refresh(now: at(0).addingTimeInterval(6 * 3600 + 900), utcOffset: india)
        XCTAssertEqual(upgraded.due, due)
    }

    func testWholeHourZonesKeepTheSameHourIdentitiesAfterTheUpgrade() throws {
        let london: (Date) -> Int = { TimeZone(identifier: "Europe/London")!.secondsFromGMT(for: $0) }
        var reference = InsulinOutbox(reportingStart: at(0))
        reference.stage(created: [basal("day", from: at(0), hours: 6)], deleted: [])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reference)) as? [String: Any])
        json.removeValue(forKey: "localHoursFrom")
        var legacy = try JSONDecoder().decode(InsulinOutbox.self, from: JSONSerialization.data(withJSONObject: json))
        legacy.refresh(now: at(0).addingTimeInterval(2 * 3600 + 900), utcOffset: london)
        sendAll(&legacy)
        legacy.refresh(now: at(0).addingTimeInterval(6 * 3600 + 900), utcOffset: london)
        reference.refresh(now: at(0).addingTimeInterval(6 * 3600 + 900), utcOffset: london)
        XCTAssertEqual(Set(legacy.entries.keys), Set(reference.entries.keys), "Local and UTC hours coincide, so identities match")
        XCTAssertEqual(legacy.due.map(\.start), reference.due.filter { entry in !legacy.confirmedEntries.contains { $0.guid == entry.guid } }.map(\.start))
    }

    func testTheRepeatedHourWhenClocksGoBackIsReportedOnceWithoutLosingInsulin() {
        let london: (Date) -> Int = { TimeZone(identifier: "Europe/London")!.secondsFromGMT(for: $0) }
        let bstMidnight = Date(timeIntervalSince1970: 1_792_882_800) // 25 October 2026 00:00 BST (23:00 UTC on the 24th)
        var outbox = InsulinOutbox(reportingStart: bstMidnight)
        outbox.stage(created: [basal("day", from: bstMidnight, hours: 30, rate: 0.6)], deleted: [])
        outbox.refresh(now: bstMidnight.addingTimeInterval(30 * 3600), utcOffset: london)
        let hours = outbox.due.sorted { $0.start < $1.start }
        let day = hours.filter { $0.start < bstMidnight.addingTimeInterval(25 * 3600) }
        XCTAssertEqual(day.count, 25, "The local day has 25 hours")
        XCTAssertEqual(day.filter { clock($0.start, $0.utcOffset!) == "01:00" }.count, 2, "01:00 BST and 01:00 GMT are separate hours")
        XCTAssertEqual(day.reduce(0) { $0 + $1.units }, 15, accuracy: 0.0005)
        XCTAssertEqual(Set(hours.map(\.guid)).count, hours.count)
        for (a, b) in zip(hours, hours.dropFirst()) { XCTAssertEqual(InsulinOutbox.hourEnd(a), b.start) }
    }

    func testRetentionAtLocalMidnightNeverRewritesSentHoursInAHalfHourZone() {
        let istMidnight = Date(timeIntervalSince1970: 1_792_866_600) // 25 October 2026 00:00 IST (18:30 UTC on the 24th)
        var outbox = InsulinOutbox(reportingStart: istMidnight.addingTimeInterval(600))
        let pulses = (0..<(16 * 24)).map { index in
            SourceDose(id: "p\(index)", kind: .tempBasal, start: istMidnight.addingTimeInterval(Double(index) * 3600 + 1500),
                       end: istMidnight.addingTimeInterval(Double(index) * 3600 + 2100), delivered: 0.025)
        }
        outbox.stage(created: pulses, deleted: [])
        let now = istMidnight.addingTimeInterval(16 * 86400)
        outbox.refresh(now: now, utcOffset: india); sendAll(&outbox)
        for step in stride(from: 0.0, through: 86400, by: 5400) {
            outbox.prune(now: now.addingTimeInterval(step), utcOffset: india)
            outbox.refresh(now: now.addingTimeInterval(step), utcOffset: india)
            XCTAssertTrue(outbox.due.isEmpty, "Pruning at \(clock(now.addingTimeInterval(step), 19800)) IST is not a clinical correction")
        }
        XCTAssertNotNil(outbox.recomputeFrom)
        XCTAssertEqual(clock(outbox.recomputeFrom!, 19800), "00:00", "Recomputation restarts at local midnight")
    }

    private static func round(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
}
