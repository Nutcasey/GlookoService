import XCTest
import GlookoKit

/// Histories saved by the retired pump-file uploader, written by the code before its removal together with
/// the cut-over it produced then. Existing installations must still load them and cut over identically.
final class LegacyHistoryTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }

    func testSavedHistoriesStillLoadRoundTripAndCutOverAsBefore() throws {
        for name in ["unsent", "submitted", "staged"] {
            let history = try JSONDecoder().decode(PumpHistoryLog.self, from: fixture("\(name)-history"))
            let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("\(name)-expected")) as? [String: Any])
            XCTAssertEqual(history.submittedBoundary?.timeIntervalSince1970, expected["submittedBoundary"] as? Double, name)
            XCTAssertEqual(history.historyStart?.timeIntervalSince1970, expected["historyStart"] as? Double, name)
            let resaved = try JSONDecoder().decode(PumpHistoryLog.self, from: JSONEncoder().encode(history))
            XCTAssertEqual(resaved, history, "\(name): saving the history again keeps every field")
            let now = Date(timeIntervalSince1970: try XCTUnwrap(expected["now"] as? Double))
            for source in [history, resaved] {
                var outbox = InsulinOutbox.cutOver(from: source, now: now)
                outbox.refresh(now: now, utcOffset: { _ in 0 })
                XCTAssertEqual(outbox.reportingStart.timeIntervalSince1970, expected["reportingStart"] as? Double, name)
                let rows = try XCTUnwrap(expected["due"] as? [[String: Any]])
                XCTAssertEqual(outbox.due.map(\.guid), rows.map { $0["guid"] as! String }, name)
                XCTAssertEqual(outbox.due.map(\.units), rows.map { $0["units"] as! Double }, name)
                XCTAssertEqual(outbox.due.map(\.kind.rawValue), rows.map { $0["kind"] as! String }, name)
                XCTAssertEqual(outbox.due.map(\.start.timeIntervalSince1970), rows.map { $0["start"] as! Double }, name)
            }
        }
    }
}
