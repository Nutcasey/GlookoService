import XCTest
import GlookoKit

final class PumpHistoryLogTests: XCTestCase {
    /// The dose stream the phone's first Glooko session received on 25 October 2026: Loop's basal overlay
    /// reached back to the previous afternoon (Pump Simulator / no pump) before the pod activated at 16:17.
    func testHistoryStartExcludesPrePairingDeliveryAndExports() throws {
        let iso = ISO8601DateFormatter()
        func d(_ s: String) -> Date { iso.date(from: s)! }
        let doses = [
            SourceDose(id: "b1", kind: .basal, start: d("2026-10-24T15:56:09Z"), end: d("2026-10-25T00:00:00Z"), rate: 0.4526),
            SourceDose(id: "b2", kind: .basal, start: d("2026-10-25T00:00:00Z"), end: d("2026-10-25T16:56:08Z"), rate: 0.4488),
            SourceDose(id: "bolus", kind: .bolus, start: d("2026-10-25T16:20:41Z"), end: d("2026-10-25T16:24:35Z"), programmed: 5.85, delivered: 5.85),
            SourceDose(id: "t1", kind: .tempBasal, start: d("2026-10-25T16:56:08Z"), end: d("2026-10-25T17:00:41Z"), rate: 0),
            SourceDose(id: "b3", kind: .basal, start: d("2026-10-25T17:00:41Z"), end: d("2026-10-25T17:01:06Z"), rate: 0),
            SourceDose(id: "t2", kind: .tempBasal, start: d("2026-10-25T17:01:06Z"), end: d("2026-10-25T17:25:57Z"), rate: 0),
        ]
        let zone = TimeZone(identifier: "Europe/London")!
        let start = d("2026-10-25T16:17:00Z")
        var log = PumpHistoryLog.newIdentity()
        log.historyStart = start
        log.ingest(created: doses)
        log.commit(now: d("2026-10-25T18:30:00Z"), timeZone: zone)
        XCTAssertEqual(log.records.first?.date, start)
        XCTAssertTrue(log.records.allSatisfy { $0.date >= start })
        XCTAssertTrue(log.records.contains { $0.record == .bolus(delivered: 5.85, immediateSeconds: 234) })
        XCTAssertNotNil(try log.exportFile(timeZone: zone))
    }
}
