import Foundation

public struct GlookoSyncHealth: Codable, Sendable {
    public enum Stream: String, Codable, CaseIterable, Sendable { case insulin, carbs, glucose }
    public struct Progress: Codable, Sendable {
        public var pendingSince: Date?
        public var submittedAt: Date?
        public var awaitingSince: Date?
        public init() {}
    }
    public struct Notice: Equatable, Sendable {
        public var id: String
        public var title: String
        public var message: String
    }
    public var streams: [String: Progress] = [:]
    public var authenticationRequired: String?
    public var lastAccountVerified: Date?
    public var activeNoticeIDs: Set<String> = []
    public init() {}
    public mutating func submitted(_ stream: Stream, at date: Date = Date()) {
        var progress = streams[stream.rawValue] ?? .init()
        progress.submittedAt = date
        if progress.awaitingSince == nil { progress.awaitingSince = date }
        streams[stream.rawValue] = progress
    }
    public mutating func notices(pending: Set<Stream>, pausedReason: String?, threshold: TimeInterval, now: Date = Date()) -> [Notice] {
        for stream in Stream.allCases {
            var progress = streams[stream.rawValue] ?? .init()
            if pending.contains(stream) {
                if progress.pendingSince == nil { progress.pendingSince = now }
            } else { progress.pendingSince = nil; progress.awaitingSince = nil }
            streams[stream.rawValue] = progress
        }
        if let reason = authenticationRequired {
            return [.init(id: "authentication-needed", title: "Glooko needs you to sign in", message: reason + " Open Loop Settings → Glooko and sign in again. Saved readings remain on this phone.")]
        }
        var result: [Notice] = []
        if let reason = pausedReason {
            result.append(.init(id: "uploads-paused", title: "Glooko uploads need review", message: reason + " Open Loop Settings → Glooko to review the saved history."))
        }
        for stream in pending.sorted(by: { $0.rawValue < $1.rawValue }) {
            let progress = streams[stream.rawValue]!
            let name = stream.rawValue == "carbs" ? "Carb" : stream.rawValue.capitalized
            if let awaiting = progress.awaitingSince, now.timeIntervalSince(awaiting) >= threshold {
                result.append(.init(id: "confirmation-overdue-" + stream.rawValue, title: "Glooko \(stream.rawValue) confirmation delayed",
                    message: "Glooko accepted a \(stream.rawValue) submission but has not confirmed all pending records for at least \(Int(threshold / 60)) minutes. Open Loop Settings → Glooko → Diagnostics."))
            } else if let since = progress.pendingSince,
                      now.timeIntervalSince(max(since, progress.submittedAt ?? since)) >= threshold {
                result.append(.init(id: "submission-overdue-" + stream.rawValue, title: "\(name) uploads to Glooko are delayed",
                    message: "Loop has eligible \(stream.rawValue) records waiting for at least \(Int(threshold / 60)) minutes without a successful submission or confirmation. Open Loop Settings → Glooko → Diagnostics."))
            }
        }
        return result
    }
    public struct Delivery: Sendable {
        public var issue: [Notice]
        public var retract: Set<String>
    }
    public mutating func notifications(pending: Set<Stream>, pausedReason: String?, threshold: TimeInterval,
                                      canDeliver: Bool, now: Date = Date()) -> Delivery {
        let desired = notices(pending: pending, pausedReason: pausedReason, threshold: threshold, now: now)
        guard canDeliver else { return .init(issue: [], retract: []) }
        let next = Set(desired.map(\.id)), prior = activeNoticeIDs
        activeNoticeIDs = next
        return .init(issue: desired.filter { !prior.contains($0.id) }, retract: prior.subtracting(next))
    }
    public static var allNoticeIDs: Set<String> {
        Set(["authentication-needed", "uploads-paused"] + Stream.allCases.flatMap { ["submission-overdue-" + $0.rawValue, "confirmation-overdue-" + $0.rawValue] })
    }
}
