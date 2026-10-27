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

}
