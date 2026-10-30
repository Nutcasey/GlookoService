import XCTest
@testable import GlookoKit

final class SyncDiagnosticsTests: XCTestCase {
    func testNetworkErrorsAndOlderSavedEventsNeverExposeURLQueriesOrCredentials() throws {
        let url = URL(string: "https://user:password@eu.glooko.test/api/v3/graph/data?patient=private-code&startDate=private-date#private-fragment")!
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSURLErrorFailingURLErrorKey: url])
        let raw = String(describing: error)
        let event = GlookoDiagnosticEvent(category: "glucose error", message: raw)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        json["message"] = raw // A journal written by the previous version.
        let restored = try JSONDecoder().decode(GlookoDiagnosticEvent.self, from: JSONSerialization.data(withJSONObject: json))
        for message in [event.message, restored.message, GlookoClient.redact(raw)] {
            for secret in ["private-code", "private-date", "private-fragment", "user:password"] {
                XCTAssertFalse(message.contains(secret))
            }
            XCTAssertTrue(message.contains("/api/v3/graph/data"))
        }
    }

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
