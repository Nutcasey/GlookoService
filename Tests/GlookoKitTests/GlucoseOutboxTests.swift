import XCTest
import GlookoKit

final class GlucoseOutboxTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_792_580_571.125)

    func testReplaysStayConfirmedWhileCorrectionsAndRepeatedClockMinutesAreSkippedWithoutBlockingThePage() throws {
        let original = SourceGlucose(id: "sensor", date: instant, mgdl: 123, utcOffset: 3600)
        var outbox = GlucoseOutbox(historyStart: instant.addingTimeInterval(-1))
        outbox.stage([original]); outbox.confirm(original)
        var replay = original; replay.id = "healthkit-copy"; replay.date = replay.date.addingTimeInterval(2.5)
        XCTAssertEqual(outbox.stage([replay]), .init())
        XCTAssertTrue(outbox.due.isEmpty)
        XCTAssertEqual(outbox.entries.count, 1)
        let saved = outbox
        let appCopy = SourceGlucose(id: "dexcom-app-copy", date: instant.addingTimeInterval(2.5), mgdl: 124, utcOffset: 3600, origin: .manufacturerApp)
        outbox.stage([appCopy])
        XCTAssertEqual(outbox, saved, "An overlapping app copy cannot replace a directly received sensor measurement")
        let next = SourceGlucose(id: "next", date: instant.addingTimeInterval(300), mgdl: 125, utcOffset: 3600)
        var edited = original; edited.mgdl = 124
        let result = outbox.stage([next, edited])
        XCTAssertEqual(result.skipped.map(\.reason), [.changedValue])
        XCTAssertEqual(outbox.due, [next], "A changed value is skipped and the rest of the page still goes ahead")
        XCTAssertEqual(outbox.entries[original.minute]?.reading, original, "The original value is kept")
        let repeatedClock = SourceGlucose(id: "after-clock-change", date: instant.addingTimeInterval(3600), mgdl: 123, utcOffset: 0)
        XCTAssertEqual(outbox.stage([repeatedClock]).skipped.map(\.reason), [.repeatedMinute])
        XCTAssertEqual(outbox.stage([repeatedClock]), .init(), "A skipped reading is recorded once, not again on every replay")
        XCTAssertEqual(outbox.skipped.count, 2)
        XCTAssertEqual(outbox.due, [next])
        outbox = try JSONDecoder().decode(GlucoseOutbox.self, from: JSONEncoder().encode(outbox))
        XCTAssertEqual(outbox.skipped.count, 2, "Skipped readings survive a restart")
        XCTAssertEqual(outbox.stage([SourceGlucose(id: "bad", date: instant, mgdl: .nan, utcOffset: 3600)]).invalid, 1)
        var priority = GlucoseOutbox(historyStart: nil)
        priority.stage([appCopy])
        priority.stage([original])
        XCTAssertEqual(priority.due, [original], "A pending app copy can be replaced before a direct sample is submitted")
        var submitted = GlucoseOutbox(historyStart: nil)
        submitted.stage([appCopy])
        submitted.markSubmitted(submitted.due)
        submitted = try JSONDecoder().decode(GlucoseOutbox.self, from: JSONEncoder().encode(submitted))
        submitted.stage([original])
        XCTAssertEqual(submitted.due, [appCopy], "A possibly submitted copy stays immutable after a restart")
        submitted.confirm(appCopy)
        XCTAssertTrue(submitted.due.isEmpty)
        outbox.pruneConfirmed(before: next.date.addingTimeInterval(5))
        XCTAssertEqual(outbox.due, [next], "Retention cannot remove unconfirmed readings during a long outage")
        XCTAssertEqual(outbox.entries.count, 1)
        XCTAssertEqual(outbox.skipped.keys.sorted(), ["after-clock-change"], "Skipped records follow the same retention window")
        var changedPending = next; changedPending.id = "next-edited"; changedPending.mgdl = 130
        XCTAssertEqual(outbox.stage([changedPending]).skipped.map(\.reason), [.changedValue],
                       "An old retained pending reading still gets conflict detection")
        outbox.stage([original])
        XCTAssertEqual(outbox.entries.count, 1, "Pruned confirmed history must not be queued again on a source replay")
    }

    /// Europe/London falls back at 02:00 BST on 25 October 2026, repeating 01:00-01:59 as GMT.
    func testTheRepeatedHourKeepsTheFirstReadingsAndSkipsTheRepeatsSoLaterReadingsStillGo() throws {
        let london = TimeZone(identifier: "Europe/London")!
        let start = Date(timeIntervalSince1970: 1_792_887_600) // 25 October 2026 00:20 UTC, 01:20 BST
        let readings = stride(from: 0, to: 6 * 3600, by: 300).map { offset -> SourceGlucose in
            let date = start.addingTimeInterval(TimeInterval(offset))
            return SourceGlucose(id: "g\(offset)", date: date, mgdl: 100 + Double(offset / 300), utcOffset: london.secondsFromGMT(for: date))
        }
        var outbox = GlucoseOutbox(historyStart: start.addingTimeInterval(-60))
        let result = outbox.stage(readings)
        let repeated = readings.filter { reading in readings.contains { $0.date < reading.date && $0.minute == reading.minute } }
        XCTAssertFalse(repeated.isEmpty)
        XCTAssertEqual(result.skipped.map(\.reading), repeated.sorted { $0.date < $1.date })
        XCTAssertTrue(result.skipped.allSatisfy { $0.reason == .repeatedMinute && $0.reading.utcOffset == 0 })
        XCTAssertEqual(outbox.due.count, readings.count - repeated.count)
        XCTAssertEqual(outbox.due.last, readings.last, "Readings after the repeated hour are queued")
        XCTAssertTrue(repeated.allSatisfy { outbox.entries[$0.minute]?.reading.utcOffset == 3600 },
                      "At each repeated minute the first pass (BST) is the one kept")
    }

    func testAReadingGlookoAlreadyHoldsDifferentlyStopsBeingDueAndKeepsItsMinute() throws {
        let reading = SourceGlucose(id: "sensor", date: instant, mgdl: 123, utcOffset: 3600)
        let later = SourceGlucose(id: "later", date: instant.addingTimeInterval(300), mgdl: 124, utcOffset: 3600)
        var outbox = GlucoseOutbox(historyStart: nil)
        outbox.stage([reading, later])
        XCTAssertEqual(outbox.skipDifferentInGlooko(reading)?.reason, .differentInGlooko)
        XCTAssertEqual(outbox.due, [later])
        var copy = reading; copy.id = "healthkit-copy"
        XCTAssertEqual(outbox.stage([copy]), .init(), "A replay at the same minute is not queued again")
        XCTAssertEqual(outbox.due, [later])
        XCTAssertNil(outbox.skipDifferentInGlooko(later.withValue(1)), "Only the stored reading can be set aside")
    }

    /// Glooko rejects a day-month file (HTTP 400) when every row falls on one day from the 1st to the 12th.
    func testRejectedReadingsStayDueAndNeverTravelWithNewerOnes() throws {
        let old = SourceGlucose(id: "old", date: instant, mgdl: 123, utcOffset: 0)
        let new = SourceGlucose(id: "new", date: instant.addingTimeInterval(300), mgdl: 124, utcOffset: 0)
        var outbox = GlucoseOutbox(historyStart: instant.addingTimeInterval(-1))
        outbox.stage([old])
        outbox.hold([old], until: instant.addingTimeInterval(3600))
        XCTAssertEqual(outbox.due, [old], "It is still owed to Glooko")
        XCTAssertEqual(outbox.sendable(at: instant), [])
        XCTAssertEqual(outbox.nextRetry, instant.addingTimeInterval(3600))
        outbox.stage([new])
        XCTAssertEqual(outbox.sendable(at: instant), [new])
        XCTAssertEqual(outbox.sendable(at: instant.addingTimeInterval(4000)), [new], "A newer reading isn't sent in the file that was rejected")
        outbox.confirm(new)
        XCTAssertEqual(outbox.sendable(at: instant.addingTimeInterval(4000)), [old])
        outbox = try JSONDecoder().decode(GlucoseOutbox.self, from: JSONEncoder().encode(outbox))
        XCTAssertEqual(outbox.rejected, [old], "The hold survives a restart")
        outbox.retryRejectedNow()
        XCTAssertEqual(outbox.sendable(at: instant), [old])
        outbox.confirm(old)
        XCTAssertEqual(outbox.rejected, [])
        XCTAssertNil(outbox.nextRetry)
    }

    func testTheCSVDatesCantBeMisreadOnTheFirstTwelveDaysOfAMonth() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-05T00:06:00Z"))
        let csv = String(decoding: GlucoseOutbox.csv([SourceGlucose(id: "a", date: instant, mgdl: 123.45, utcOffset: 3600)]), as: UTF8.self)
        XCTAssertEqual(csv.split(separator: "\n").last.map { $0.split(separator: ",", omittingEmptySubsequences: false)[2] }, "2026-11-05 01:06")
    }

    func testStorageRetainsSensorPrecisionAndNeverReplacesMissingOrDamagedAcknowledgedHistory() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/glucose-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = GlookoAccount(id: "glucose-owner", email: "offline@example.test")
        let repository = GlucoseOutboxRepository(directory: root)
        var outbox = try repository.load(accountID: account.id, historyStart: instant, required: false)
        let reading = SourceGlucose(id: "sensor", date: instant, mgdl: 123, utcOffset: 3600)
        outbox.stage([reading]); try repository.save(outbox, accountID: account.id)
        XCTAssertEqual(try repository.load(accountID: account.id, historyStart: nil, required: true), outbox)
        XCTAssertTrue(try repository.load(accountID: "another-patient", historyStart: nil, required: false).due.isEmpty)
        let file = root.appendingPathComponent(account.storageKey).appendingPathComponent("glucose-v2.json")
        for damaged in [Data("not JSON".utf8), Data(#"{"entries":{"wrong-minute":{"reading":{"id":"sensor","date":0,"mgdl":123,"utcOffset":999999},"confirmed":true}}}"#.utf8)] {
            try damaged.write(to: file)
            XCTAssertThrowsError(try repository.load(accountID: account.id, historyStart: nil, required: true))
            XCTAssertEqual(try Data(contentsOf: file), damaged)
        }
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try repository.load(accountID: account.id, historyStart: nil, required: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}

private extension SourceGlucose {
    func withValue(_ mgdl: Double) -> SourceGlucose { var copy = self; copy.mgdl = mgdl; return copy }
}
