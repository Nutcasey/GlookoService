import Foundation

/// A record kept by the retired pump-file uploader. Only decoded from saved history; never written to Glooko.
public enum LegacyPumpRecord: Equatable, Codable, Sendable {
    /// `tempMinutes == 0` is a scheduled rate; otherwise a temporary rate that a later record may supersede.
    case basal(rate: Double, tempMinutes: Int)
    case suspend, resume
    case bolus(delivered: Double, immediateSeconds: Int)
    case terminateBolus(undelivered: Double)
    case carb(grams: Int)
    case activate(lot: UInt16, serial: UInt16)
    case deactivate, download
}

public struct LegacyPumpEvent: Equatable, Codable, Sendable {
    public var index: UInt32
    public var date: Date
    public var record: LegacyPumpRecord
    public var inProgress: Bool
    public var utcOffset: Int?

    public init(index: UInt32, date: Date, record: LegacyPumpRecord, inProgress: Bool = false, utcOffset: Int? = nil) {
        self.index = index; self.date = date; self.record = record; self.inProgress = inProgress; self.utcOffset = utcOffset
    }
}

/// Delivery in effect at the end of the retired uploader's last converted window, as saved in its history.
public enum DeliveryTimeline {
    public enum Delivery: Equatable, Codable, Sendable { case scheduled(rate: Double), temporary(rate: Double), suspended }

    public struct State: Equatable, Codable, Sendable {
        public var delivery: Delivery
        public var id: String?
        public init(delivery: Delivery, id: String? = nil) { self.delivery = delivery; self.id = id }
    }
}
