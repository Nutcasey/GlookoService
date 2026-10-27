import Foundation

public struct GlookoDiagnosticEvent: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let category: String
    public let message: String
    public init(category: String, message: String, date: Date = Date()) {
        id = UUID(); self.date = date; self.category = category
        self.message = GlookoClient.redact(message.prefix(512))
    }
}

/// Request metadata only. No headers, bodies, credentials, query parameters or patient identifiers.
public struct GlookoRequestTrace: Sendable {
    public let method: String
    public let route: String
    public let status: Int?
    public let duration: TimeInterval
    public let sentBytes: Int
    public let receivedBytes: Int
    public let errorCode: Int?
    public var message: String {
        "\(method) \(route) — \(status.map { "HTTP \($0)" } ?? "network error \(errorCode ?? -1)"), \(Int(duration * 1000)) ms, \(sentBytes) B sent, \(receivedBytes) B received"
    }
}

public struct GlookoDiagnostics: Codable, Sendable {
    public private(set) var events: [GlookoDiagnosticEvent] = []
    public var lastDoseCallback: Date?
    public var lastSettingsCallback: Date?
    public var lastGlucoseCallback: Date?
    public var latestGlucoseReceived: Date?
    public var lastInspection: GlookoSyncInspection?
    public var inspectionError: String?
    public init() {}
    public mutating func record(_ event: GlookoDiagnosticEvent) {
        events.append(event)
        trim(now: event.date)
    }
    fileprivate mutating func trim(now: Date) {
        events = Array(events.filter { $0.date >= now.addingTimeInterval(-48 * 3600) }.suffix(250))
    }
}

public struct GlookoDiagnosticsRepository {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    private func url(_ accountID: String) -> URL {
        directory.appendingPathComponent(GlookoAccount(id: accountID, email: "").storageKey)
            .appendingPathComponent("diagnostics.json")
    }
    public func load(accountID: String) throws -> GlookoDiagnostics {
        do {
            var state = try JSONDecoder().decode(GlookoDiagnostics.self, from: Data(contentsOf: url(accountID)))
            state.trim(now: Date()); return state
        }
        catch CocoaError.fileReadNoSuchFile { return .init() }
    }
    public func save(_ state: GlookoDiagnostics, accountID: String) throws {
        let file = url(accountID)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
