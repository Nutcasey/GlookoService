import XCTest
@testable import GlookoKit

final class SyncDiagnosticsTests: XCTestCase {
    func testDiagnosticsAreBoundedAccountScopedAndPreserveUnreadableEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = GlookoDiagnosticsRepository(directory: root)
        let now = Date()
        var journal = GlookoDiagnostics()
        journal.record(.init(category: "old", message: "Outside retention", date: now.addingTimeInterval(-49 * 3600)))
        journal.record(.init(category: "current", message: "Inside retention", date: now))
        XCTAssertEqual(journal.events.count, 1)
        for i in 0..<260 { journal.record(.init(category: "HTTP", message: "GET /api/v2/users HTTP 200 #\(i)", date: now)) }
        try repository.save(journal, accountID: "one")
        let restored = try repository.load(accountID: "one")
        XCTAssertEqual(restored.events.count, 250)
        XCTAssertEqual(restored.events.first?.message, "GET /api/v2/users HTTP 200 #10")
        XCTAssertTrue(try repository.load(accountID: "two").events.isEmpty)
        let file = root.appendingPathComponent(GlookoAccount(id: "one", email: "").storageKey).appendingPathComponent("diagnostics.json")
        let damaged = Data("unreadable diagnostic evidence".utf8)
        try damaged.write(to: file)
        XCTAssertThrowsError(try repository.load(accountID: "one"))
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }

    func testReadbackRequiresExactStoredAndGraphedValuesAndDoesNotTurnMissingDataGreen() throws {
        let start = ISO8601DateFormatter().date(from: "2026-10-27T12:00:00Z")!
        let readings = [SourceGlucose(id: "one", date: start, mgdl: 100, utcOffset: 0),
                        SourceGlucose(id: "two", date: start.addingTimeInterval(300), mgdl: 110, utcOffset: 0)]
        let rows: [[String: Any]] = [["softDeleted": false, "displayTime": "2026-10-27T12:00:00.000Z", "glucoseValue": 10000],
                                     ["softDeleted": false, "displayTime": "2026-10-27T12:05:00.000Z", "glucoseValue": 11000]]
        let graph = ["2026-10-27T12:00": [10000], "2026-10-27T12:05": [11000]]
        XCTAssertTrue(try glucoseEvidence(readings, stored: rows, graph: graph, day: "2026-10-27").verified)
        var wrong = graph; wrong["2026-10-27T12:05"] = [12000]
        let mismatch = try glucoseEvidence(readings, stored: rows, graph: wrong, day: "2026-10-27")
        XCTAssertEqual(mismatch.matchedStored, 2); XCTAssertEqual(mismatch.matchedGraphed, 1); XCTAssertFalse(mismatch.verified)
        XCTAssertFalse(try glucoseEvidence(readings, stored: [], graph: graph, day: "2026-10-27").verified)
        var duplicate = rows; duplicate.append(rows[0])
        let duplicated = try glucoseEvidence(readings, stored: duplicate, graph: graph, day: "2026-10-27")
        XCTAssertEqual(duplicated.duplicates, 1); XCTAssertFalse(duplicated.verified)
        XCTAssertFalse(try glucoseEvidence([], stored: [], graph: [:], day: "2026-10-27").verified)
        XCTAssertThrowsError(try glucoseEvidence(readings, stored: [["softDeleted": false]], graph: graph, day: "2026-10-27"))
    }
}
