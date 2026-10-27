import XCTest
@testable import GlookoKit

final class SyncHealthTests: XCTestCase {
    func testOverdueSubmissionAndConfirmationAreDistinctDeduplicatedAndRetractedOnRecovery() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var health = GlookoSyncHealth()
        XCTAssertTrue(health.notifications(pending: [.insulin], pausedReason: nil, threshold: 3600, canDeliver: true, now: start).issue.isEmpty)
        let stalled = health.notifications(pending: [.insulin], pausedReason: nil, threshold: 3600, canDeliver: true, now: start.addingTimeInterval(3600))
        XCTAssertEqual(stalled.issue.map(\.id), ["submission-overdue-insulin"])
        health = try JSONDecoder().decode(GlookoSyncHealth.self, from: JSONEncoder().encode(health))
        XCTAssertTrue(health.notifications(pending: [.insulin], pausedReason: nil, threshold: 3600, canDeliver: true, now: start.addingTimeInterval(3700)).issue.isEmpty)
        health.submitted(.insulin, at: start.addingTimeInterval(3800))
        let accepted = health.notifications(pending: [.insulin], pausedReason: nil, threshold: 3600, canDeliver: true, now: start.addingTimeInterval(3800))
        XCTAssertEqual(accepted.retract, ["submission-overdue-insulin"])
        let unconfirmed = health.notifications(pending: [.insulin], pausedReason: nil, threshold: 3600, canDeliver: true, now: start.addingTimeInterval(7400))
        XCTAssertEqual(unconfirmed.issue.map(\.id), ["confirmation-overdue-insulin"])
        XCTAssertEqual(health.notifications(pending: [], pausedReason: nil, threshold: 3600, canDeliver: true, now: start.addingTimeInterval(7500)).retract, ["confirmation-overdue-insulin"])
    }
    func testAuthAndReviewAlertsAreImmediateAndWaitForAnIssuerWithoutBeingLost() {
        var health = GlookoSyncHealth(); let now = Date()
        health.authenticationRequired = "Glooko rejected this account"
        XCTAssertTrue(health.notifications(pending: [], pausedReason: nil, threshold: 3600, canDeliver: false, now: now).issue.isEmpty)
        let auth = health.notifications(pending: [], pausedReason: nil, threshold: 3600, canDeliver: true, now: now)
        XCTAssertEqual(auth.issue.map(\.id), ["authentication-needed"])
        health.authenticationRequired = nil
        let review = health.notifications(pending: [], pausedReason: "A submitted dose changed", threshold: 3600, canDeliver: true, now: now)
        XCTAssertEqual(review.issue.map(\.id), ["uploads-paused"]); XCTAssertEqual(review.retract, ["authentication-needed"])
        XCTAssertEqual(health.notifications(pending: [], pausedReason: nil, threshold: 3600, canDeliver: true, now: now).retract, ["uploads-paused"])
    }
    func testIdleStreamsAndDisabledWorkDoNotAlertAndPartialReceiptsDoNotResetOldPendingWork() {
        var health = GlookoSyncHealth(); let now = Date()
        health.submitted(.insulin, at: now.addingTimeInterval(-86400))
        XCTAssertTrue(health.notifications(pending: [], pausedReason: nil, threshold: 3600, canDeliver: true, now: now).issue.isEmpty)
        _ = health.notifications(pending: [.carbs], pausedReason: nil, threshold: 3600, canDeliver: true, now: now)
        health.submitted(.carbs, at: now)
        health.submitted(.carbs, at: now.addingTimeInterval(3500))
        XCTAssertEqual(health.notifications(pending: [.carbs], pausedReason: nil, threshold: 3600, canDeliver: true, now: now.addingTimeInterval(3600)).issue.map(\.id), ["confirmation-overdue-carbs"])
    }
    func testRetiredGlucoseCacheCleanupPreservesPumpCarbAndOtherAccountHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = HistoryRepository(directory: root)
        for owner in ["one", "two"] {
            let folder = root.appendingPathComponent(GlookoAccount(id: owner, email: "").storageKey)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["pump-history.json", "carbs.json", "glucose.json", "glucose-initialised"] {
                try Data(name.utf8).write(to: folder.appendingPathComponent(name))
            }
        }
        try repository.removeRetiredGlucoseData(accountID: "one")
        try repository.removeRetiredGlucoseData(accountID: "one")
        let own = root.appendingPathComponent(GlookoAccount(id: "one", email: "").storageKey)
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.appendingPathComponent("glucose.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.appendingPathComponent("glucose-initialised").path))
        XCTAssertEqual(try String(contentsOf: own.appendingPathComponent("pump-history.json")), "pump-history.json")
        XCTAssertEqual(try String(contentsOf: own.appendingPathComponent("carbs.json")), "carbs.json")
        let other = root.appendingPathComponent(GlookoAccount(id: "two", email: "").storageKey)
        XCTAssertEqual(try String(contentsOf: other.appendingPathComponent("glucose.json")), "glucose.json")
    }

    func testExplicitPurgeRemovesAllPluginHistoryAndBackupsWithoutTouchingSiblingData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = root.appendingPathComponent("GlookoService"), other = root.appendingPathComponent("OtherService")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("leave this alone".utf8).write(to: other.appendingPathComponent("history.json"))
        for owner in ["one", "two"] {
            let folder = plugin.appendingPathComponent(GlookoAccount(id: owner, email: "").storageKey).appendingPathComponent("archives")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("private history".utf8).write(to: folder.appendingPathComponent("saved.json"))
        }
        try Data("legacy backup".utf8).write(to: plugin.appendingPathComponent("legacy-backup.json"))
        let repository = HistoryRepository(directory: plugin)
        XCTAssertEqual(try repository.localAccountStorageKeys().count, 2)
        try repository.eraseAllLocalData(); try repository.eraseAllLocalData()
        XCTAssertFalse(FileManager.default.fileExists(atPath: plugin.path))
        XCTAssertEqual(try String(contentsOf: other.appendingPathComponent("history.json")), "leave this alone")
    }
}
