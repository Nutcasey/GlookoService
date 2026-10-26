import Foundation

/// Missing, unreadable and malformed acknowledged storage must never become a new empty outbox.
public struct CarbOutboxRepository {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public enum Failure: Error, CustomStringConvertible {
        case missingOutbox
        public var description: String { "The saved carb outbox is missing. Restore its backup before continuing." }
    }

    private func folder(_ accountID: String) -> URL {
        directory.appendingPathComponent(GlookoAccount(id: accountID, email: "").storageKey, isDirectory: true)
    }

    public func load(accountID: String, historyStart: Date?, required: Bool = false) throws -> CarbOutbox {
        let folder = folder(accountID)
        let data: Data
        do { data = try Data(contentsOf: folder.appendingPathComponent("carbs.json")) }
        catch CocoaError.fileReadNoSuchFile {
            if required || FileManager.default.fileExists(atPath: folder.appendingPathComponent("carbs-initialised").path) {
                throw Failure.missingOutbox
            }
            return CarbOutbox(historyStart: historyStart)
        }
        var outbox = try StoredJSON.decoder().decode(CarbOutbox.self, from: data)
        outbox.migrateToStandaloneFoods()
        return outbox
    }

    public func save(_ outbox: CarbOutbox, accountID: String) throws {
        let folder = folder(accountID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        try StoredJSON.encoder().encode(outbox).write(to: folder.appendingPathComponent("carbs.json"), options: options)
        // Write before acknowledging a source callback, so deletion of the outbox cannot hide a prior store.
        try Data().write(to: folder.appendingPathComponent("carbs-initialised"), options: options)
    }
}
