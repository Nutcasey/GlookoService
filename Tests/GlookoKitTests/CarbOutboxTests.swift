import XCTest
import GlookoKit

final class CarbOutboxTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_812_800.75)

    private func carb(_ grams: Double = 20, provenance: String? = nil) -> SourceCarb {
        SourceCarb(id: "shared-id", start: start, grams: grams, version: 0, deleted: false, provenanceIdentifier: provenance)
    }

    func testSameVersionEditsAndDeletionRemainDueUntilTheirExactValueIsConfirmed() throws {
        var outbox = CarbOutbox()
        let original = carb()
        try outbox.stage([original]); outbox.markSubmitted([original]); outbox.confirm(original)
        XCTAssertTrue(outbox.due.isEmpty)
        var edited = carb(45); edited.start = start.addingTimeInterval(60)
        try outbox.stage([edited])
        outbox.confirm(original) // An in-flight response cannot acknowledge the edit.
        XCTAssertEqual(outbox.due, [edited])
        outbox.confirm(edited)
        var deleted = edited; deleted.deleted = true
        try outbox.stage([deleted])
        XCTAssertEqual(outbox.due, [deleted])
        outbox.confirm(deleted)
        XCTAssertTrue(outbox.due.isEmpty)
    }

    func testProvenanceSeparatesIdenticalSourceIdentifiersAndLegacyBindingKeepsRemoteGUIDs() throws {
        let a = carb(provenance: "app.a"), b = carb(provenance: "app.b")
        var independent = CarbOutbox()
        try independent.stage([a, b])
        XCTAssertEqual(independent.due.count, 2)
        XCTAssertNotEqual(a.guids.food, b.guids.food)
        independent.markSubmitted([a, b]); independent.confirm(a)
        XCTAssertEqual(independent.due, [b])

        var legacy = CarbOutbox()
        let original = carb()
        try legacy.stage([original]); legacy.markSubmitted([original]); legacy.confirm(original)
        let beforeAmbiguity = legacy
        XCTAssertThrowsError(try legacy.stage([a, b]))
        XCTAssertEqual(legacy, beforeAmbiguity)
        try legacy.stage([a])
        XCTAssertEqual(legacy.entries.count, 1)
        let bound = try XCTUnwrap(legacy.entries[a.storageID]?.carb)
        XCTAssertEqual(bound.guids.food, original.guids.food)
        XCTAssertTrue(legacy.due.isEmpty)
        var edited = a; edited.version = 1; edited.grams = 45
        try legacy.stage([edited])
        XCTAssertEqual(legacy.due.first?.guids.food, original.guids.food)
        XCTAssertEqual(legacy.due.first?.grams, 45)
    }

    func testCorruptUnreadableAndMissingAcknowledgedStorageNeverBecomesAnEmptyOutbox() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/carb-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let account = GlookoAccount(id: "offline-patient", email: "offline@example.test")
        let repository = CarbOutboxRepository(directory: folder)
        var outbox = try repository.load(accountID: account.id, historyStart: start)
        try outbox.stage([carb()])
        outbox.markSubmitted(outbox.due)
        try repository.save(outbox, accountID: account.id)
        let restored = try repository.load(accountID: account.id, historyStart: nil)
        XCTAssertEqual(restored, outbox)
        let file = folder.appendingPathComponent(account.storageKey).appendingPathComponent("carbs.json")
        let damaged = Data("damaged acknowledged carbs".utf8)
        try damaged.write(to: file)
        XCTAssertThrowsError(try repository.load(accountID: account.id, historyStart: nil))
        XCTAssertEqual(try Data(contentsOf: file), damaged)
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try repository.load(accountID: account.id, historyStart: nil))
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try repository.load(accountID: account.id, historyStart: nil))
    }

    func testLegacySnackConfirmationIsRetiredAndTheStandaloneMigrationPersists() throws {
        let json = #"{"entries":{"shared-id":{"carb":{"id":"shared-id","start":"2026-10-01T00:00:00Z","grams":20,"version":0,"deleted":false},"submitted":true,"confirmedVersion":0,"confirmedDeleted":false}}}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var outbox = try decoder.decode(CarbOutbox.self, from: Data(json.utf8))
        outbox.migrateToStandaloneFoods()
        XCTAssertEqual(outbox.due.count, 1)
        XCTAssertEqual(outbox.retiringMeals, ["shared-id"])
        outbox.confirm(try XCTUnwrap(outbox.due.first))
        outbox.migrateToStandaloneFoods()
        XCTAssertTrue(outbox.due.isEmpty)
        XCTAssertTrue(outbox.retiringMeals.isEmpty)
    }
}
