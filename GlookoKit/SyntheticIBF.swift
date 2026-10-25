import Foundation

/// Native Swift reproduction of the synthetic files accepted by Glooko's Eros importer.
/// Test fixtures only: settings and PDM identity are invented. This is not a Loop dose adapter.
/// Structural reference: balshor/ibf-file-reader b705fa1, ibf-test (Insulet IBF 0.1.7).
public enum SyntheticIBF {
    public enum Scenario: String { case smoke, closedDay = "closed-day" }

    public static func encode(scenario: Scenario, localDay: String, serial: UInt32,
                              calculator: Bool = false) throws -> Data {
        guard (900_000_000...999_999_999).contains(serial) else { throw EncodingError.invalidSerial }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let day = formatter.date(from: localDay), formatter.string(from: day) == localDay else {
            throw EncodingError.invalidDay
        }
        // Dates here carry synthetic wall-clock components, not clinical UTC instants.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        struct Event { var seconds: Int; var kind: UInt32; var payload: [UInt8]; var flags: UInt16 = 0 }
        var events: [Event] = []
        func add(_ seconds: Int, _ kind: UInt32, _ payload: [UInt8] = []) {
            events.append(Event(seconds: seconds, kind: kind, payload: payload))
        }
        func basal(_ rate: UInt32, _ minutes: UInt16 = 0) -> [UInt8] { le32(rate) + le16(minutes) + le16(0) }
        func bolus(_ units: UInt32, _ seconds: UInt16) -> [UInt8] { le32(units) + le16(0) + le16(0) + le16(seconds) }
        let activation = be16(999) + be16(999) + [2, 0, 0, 2, 0, 0]
        switch scenario {
        case .smoke:
            add(9 * 3600 + 55 * 60, 0x8000, activation)
            add(10 * 3600, 8, basal(60))
            add(10 * 3600 + 15 * 60, 4, bolus(85, 34))
            add(10 * 3600 + 30 * 60, 8, basal(80, 30))
            add(11 * 3600, 16)
            add(11 * 3600 + 15 * 60, 0x10000)
            add(11 * 3600 + 15 * 60, 8, basal(60))
            add(12 * 3600, 1)
            add(12 * 3600 + 60, 0x20000)
        case .closedDay:
            add(-300, 0x8000, activation)
            add(0, 8, basal(60))
            add(8 * 3600, 4, bolus(200, 80))
            add(10 * 3600, 8, basal(120, 60))
            add(11 * 3600, 8, basal(60))
            add(12 * 3600, 16)
            add(12 * 3600 + 30 * 60, 0x10000)
            add(12 * 3600 + 30 * 60, 8, basal(60))
            add(13 * 3600, 4, bolus(25, 10))
            add(18 * 3600, 4, bolus(40, 16))
            add(18 * 3600 + 16, 0x2000, le32(60) + le16(0))
            add(86400, 1)
            add(86460, 0x20000)
        }
        if calculator {
            var linked: [Event] = []
            for var event in events {
                if event.kind == 4 {
                    let delivered = event.payload.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
                    let interrupted = scenario == .closedDay && event.seconds == 18 * 3600
                    let meal = scenario == .closedDay && event.seconds == 8 * 3600
                    let programmed: UInt32 = interrupted ? 100 : delivered
                    let values: [UInt32] = meal ? [0, delivered, 0, programmed, 0, programmed, 0, 0]
                                                : [delivered, 0, programmed, 0, programmed, 0, 0, 0]
                    let shorts: [UInt16] = [50, 65535, 100, 120, meal ? 30 : 0, 15]
                    let payload = values.flatMap(le32) + shorts.flatMap(le16)
                    linked.append(Event(seconds: event.seconds, kind: 0x40, payload: payload))
                    event.payload.replaceSubrange(6..<8, with: le16(1))
                }
                linked.append(event)
            }
            events = linked
        }

        var records: [[UInt8]] = []
        records.append([0, 1, 7, 0, 1, 7].flatMap { be16(UInt16($0)) } + string("Insulet", 8) + string("OmniPod", 8))
        records.append([0, 2, 0, 5, 0, 0, 2, 0, 0, 2, 2, 0, 2, 1, 0])
        records.append(string("LOOP SYNTHETIC TEST", 23))
        var names = be16(7) + be16(0) + be16(32)
        for index in 0..<7 { names += be16(UInt16(index)) + string("LOOP TEST \(index)", 32) }
        records.append(names)
        var eeprom = [UInt8](repeating: 0, count: 120)
        eeprom.replaceSubrange(13..<31, with: [5, 1000, 300, 10].flatMap { le32(UInt32($0)) } + [0, 0])
        eeprom.replaceSubrange(53..<57, with: le32(serial))
        eeprom.replaceSubrange(76..<90, with: [0, 0, 0, 1, 1, 0, 0] + [70, 100, 120].flatMap { le16(UInt16($0)) } + [8])
        records.append(eeprom)
        for index in Array(15...21) + [12, 11, 13, 14] {
            let value: UInt32 = [11: 15, 12: 50, 13: 100, 14: 120][index] ?? 60
            let header = [UInt8(index)] + be32(1) + be16(196) + be16(0) + le32(86400)
            records.append(header + Array(repeating: value, count: 48).flatMap(le32))
        }
        let exported = calendar.dateComponents([.day, .month, .year, .second, .minute, .hour], from: day.addingTimeInterval(Double(events.last!.seconds)))
        var logHeader: [UInt8] = [2, 1, 1, 1, 1, UInt8(exported.day!), UInt8(exported.month!)]
        logHeader += be16(UInt16(exported.year!)) + [UInt8(exported.second!), UInt8(exported.minute!), UInt8(exported.hour!), 0] + be16(26)
        var descriptors: [(UInt16, UInt16, UInt16, UInt16)] = [(0,2,0,16),(0,2,0,76),(2,1,0,76),(1,0,0,76),
            (0,2,0,41),(2,1,0,41),(0,2,0,16),(0,2,0,10),(0,2,1,20),(0,2,1,20),(0,2,0,8)]
        descriptors += Array(repeating: (0,1,0,196), count: 11)
        descriptors += [(0,2,0,20),(0,2,0,12),(0,2,0,18),(0,2,1,22)]
        for (index, descriptor) in descriptors.enumerated() {
            let active = (1...3).contains(index)
            logHeader += [UInt16(index), descriptor.0, descriptor.1, descriptor.2, descriptor.3].flatMap(be16)
            logHeader += be32(active ? 1 : .max) + be32(active ? UInt32(events.count) : .max)
        }
        records.append(logHeader)
        for (index, event) in events.enumerated().reversed() {
            let c = calendar.dateComponents([.day, .month, .year, .second, .minute, .hour], from: day.addingTimeInterval(Double(event.seconds)))
            var bytes = [UInt8(3)] + be32(UInt32(index + 1)) + be16(76) + be16(0)
            bytes += [UInt8(c.day!), UInt8(c.month!)] + le16(UInt16(c.year!))
            bytes += [UInt8(c.second!), UInt8(c.minute!), UInt8(c.hour!), 0]
            bytes += le32(UInt32(event.seconds + 86400)) + le32(event.kind) + le16(event.flags) + [0, 0] + event.payload
            bytes += Array(repeating: 0, count: 85 - bytes.count)
            records.append(bytes)
        }
        for (logID, size) in [(3, 76), (5, 41)] {
            records.append([UInt8(logID)] + be32(.max) + be16(UInt16(size)) + be16(0) + Array(repeating: 0, count: size))
        }
        return Data(records.flatMap { payload in
            let checksum = payload.reduce(UInt32(0)) { $0 + UInt32($1) }
            return be16(UInt16(payload.count + 2)) + payload + be16(UInt16(truncatingIfNeeded: checksum))
        })
    }

    public enum EncodingError: Error { case invalidSerial, invalidDay }
    private static func be16(_ n: UInt16) -> [UInt8] { [UInt8(n >> 8), UInt8(n & 255)] }
    private static func le16(_ n: UInt16) -> [UInt8] { be16(n).reversed() }
    private static func be32(_ n: UInt32) -> [UInt8] { [UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)] }
    private static func le32(_ n: UInt32) -> [UInt8] { be32(n).reversed() }
    private static func string(_ value: String, _ count: Int) -> [UInt8] { Array(value.utf8) + Array(repeating: 0, count: count - value.utf8.count) }
}
