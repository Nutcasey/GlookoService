import XCTest
import GlookoKit

final class GlucoseOutboxTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_792_580_571.125)

    func testReplaysStayConfirmedButCorrectionsAndRepeatedClockMinutesAreRejectedAtomically() throws {
        let original = SourceGlucose(id: "sensor", date: instant, mgdl: 123, utcOffset: 3600)
        var outbox = GlucoseOutbox(historyStart: instant.addingTimeInterval(-1))
        try outbox.stage([original]); outbox.confirm(original)
        var replay = original; replay.id = "healthkit-copy"; replay.date = replay.date.addingTimeInterval(2.5)
        try outbox.stage([replay])
        XCTAssertTrue(outbox.due.isEmpty)
        XCTAssertEqual(outbox.entries.count, 1)
        let saved = outbox
        let appCopy = SourceGlucose(id: "dexcom-app-copy", date: instant.addingTimeInterval(2.5), mgdl: 124, utcOffset: 3600, origin: .dexcomApp)
        try outbox.stage([appCopy])
        XCTAssertEqual(outbox, saved, "An overlapping app copy cannot replace a directly received sensor measurement")
        let next = SourceGlucose(id: "next", date: instant.addingTimeInterval(300), mgdl: 125, utcOffset: 3600)
        var edited = original; edited.mgdl = 124
        XCTAssertThrowsError(try outbox.stage([next, edited]))
        XCTAssertEqual(outbox, saved, "The earlier valid item must not be acknowledged from a rejected source page")
        let repeatedClock = SourceGlucose(id: "after-clock-change", date: instant.addingTimeInterval(3600), mgdl: 123, utcOffset: 0)
        XCTAssertThrowsError(try outbox.stage([repeatedClock]))
        XCTAssertEqual(outbox, saved, "Equal glucose values cannot collapse two different instants during a repeated hour")
        try outbox.stage([next])
        outbox.pruneConfirmed(before: next.date.addingTimeInterval(5))
        XCTAssertEqual(outbox.due, [next], "Retention cannot remove unconfirmed readings during a long outage")
        XCTAssertEqual(outbox.entries.count, 1)
        var changedPending = next; changedPending.mgdl = 130
        XCTAssertThrowsError(try outbox.stage([changedPending]), "An old retained pending reading still requires conflict detection")
        try outbox.stage([original])
        XCTAssertEqual(outbox.entries.count, 1, "Pruned confirmed history must not be queued again on a source replay")
    }

    func testStorageRetainsSensorPrecisionAndNeverReplacesMissingOrDamagedAcknowledgedHistory() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/glucose-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = GlookoAccount(id: "glucose-owner", email: "offline@example.test")
        let repository = GlucoseOutboxRepository(directory: root)
        var outbox = try repository.load(accountID: account.id, historyStart: instant, required: false)
        let reading = SourceGlucose(id: "sensor", date: instant, mgdl: 123, utcOffset: 3600)
        try outbox.stage([reading]); try repository.save(outbox, accountID: account.id)
        XCTAssertEqual(try repository.load(accountID: account.id, historyStart: nil, required: true), outbox)
        XCTAssertTrue(try repository.load(accountID: "another-patient", historyStart: nil, required: false).due.isEmpty)
        let file = root.appendingPathComponent(account.storageKey).appendingPathComponent("glucose.json")
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
