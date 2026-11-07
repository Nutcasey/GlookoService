import Foundation

/// A dose as Loop's reconciled insulin-delivery stream reports it, without LoopKit types.
public struct SourceDose: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case basal, tempBasal, suspend, resume, bolus }

    /// Loop `syncIdentifier`; stable across updates of the same dose.
    public var id: String
    public var kind: Kind
    public var start: Date
    public var end: Date
    /// U/h for basal and temporary basal.
    public var rate: Double?
    /// Programmed units for a bolus.
    public var programmed: Double
    /// Delivered units when the pump reported them.
    public var delivered: Double?
    public var automatic: Bool?
    public var sourceID: String?
    /// The insulin attached to this delivery in Loop, rather than the pump's current selection.
    public var insulinName: String?
    /// Still changing (running temp basal, bolus in progress); never committed to history.
    public var isMutable: Bool
    /// True for a dose someone logged by hand, such as a pen injection. Nil for recorded delivery.
    public var manual: Bool? = nil

    public init(id: String, kind: Kind, start: Date, end: Date, rate: Double? = nil, programmed: Double = 0,
                delivered: Double? = nil, automatic: Bool? = nil, isMutable: Bool = false, sourceID: String? = nil,
                insulinName: String? = nil, manual: Bool? = nil) {
        self.id = id; self.kind = kind; self.start = start; self.end = end; self.rate = rate
        self.programmed = programmed; self.delivered = delivered; self.automatic = automatic; self.isMutable = isMutable; self.sourceID = sourceID
        self.insulinName = insulinName; self.manual = manual
    }
}

/// A recoverable source mutation which cannot safely change already submitted PDM indices.
public struct HistoryConflict: Codable, Equatable, Sendable {
    public var original: SourceDose?
    public var replacement: SourceDose?
    public var deletion: Bool
    public var reason: String
}

/// Before-image of a retired repair, decoded so saved history keeps loading.
public struct IngestionCorrection: Codable, Equatable, Sendable {
    public var index: UInt32
    public var guid: String
    public var original: Data
    public var replacement: Data
    public var attemptedAt: Date
    public var confirmedAt: Date?
}

/// The account record, and the pump history kept by the retired pump-file uploader. New delivery goes through
/// `InsulinOutbox`; this history is only decoded, carried forward when saved, and used once to cut over
/// (`submittedBoundary`, `sourceDoses`, `pending`, `unclassified`). Every stored field still round-trips.
public struct PumpHistoryLog: Codable, Equatable, Sendable {
    public var schemaVersion = 4
    public var ownerID: String?
    public var ownerEmail: String?
    public var sourceID: String?
    public var reportingContextData: Data?
    public var serial: UInt32
    public var powerUp: Date
    public var podLot: UInt16
    public var podSerial: UInt16
    public var nextIndex: UInt32
    public private(set) var records: [LegacyPumpEvent]
    public private(set) var committedThrough: Date?
    public private(set) var state: DeliveryTimeline.State?
    public private(set) var pending: [String: SourceDose]
    public private(set) var committed: [String: Date]
    public private(set) var sourceDoses: [String: SourceDose] = [:]
    public private(set) var conflicts: [String: HistoryConflict] = [:]
    public private(set) var unclassified: [String: SourceDose] = [:]
    public private(set) var stagedDeletions: [String: SourceDose] = [:]
    private var droppedIDs: Set<String> = []
    private var legacyIDs: Set<String> = []
    private var legacyLateDoses = 0
    /// Submission intent is persisted before the request, including ambiguous network failures.
    public var lastSubmittedIndex: UInt32? {
        didSet { submittedThrough = nil; submittedState = nil; submittedIDs = nil }
    }
    private var submittedThrough: Date?
    private var submittedState: DeliveryTimeline.State?
    private var submittedIDs: Set<String>?
    /// Highest contiguous native prefix verified by readback; deferred intervals remain protected from pruning.
    public var lastUploadedIndex: UInt32?
    /// A file may have passed verification of its final rows while its newest interval is deferred.
    public private(set) var lastVerifiedFileIndex: UInt32?
    public var historyStart: Date?
    /// Native marker repairs change only the exported view; original submitted records remain here.
    public private(set) var repairedBasalIndices: Set<UInt32> = []
    public private(set) var ingestionCorrections: [String: IngestionCorrection] = [:]
    public var lateDoses: Int { legacyLateDoses + droppedIDs.count }

    public init(serial: UInt32, powerUp: Date, podLot: UInt16, podSerial: UInt16, firstIndex: UInt32 = 1) {
        self.serial = serial; self.powerUp = powerUp; self.podLot = podLot; self.podSerial = podSerial
        nextIndex = firstIndex; records = []; pending = [:]; committed = [:]
    }

    public static let defaultPowerUp = Date(timeIntervalSince1970: 1_577_836_800)
    public static func newIdentity() -> PumpHistoryLog {
        PumpHistoryLog(serial: UInt32.random(in: 900_000_000...999_999_999), powerUp: defaultPowerUp,
                       podLot: UInt16.random(in: 1000...65000), podSerial: UInt16.random(in: 1000...65000), firstIndex: 1000)
    }

    /// The last boundary which may have reached Glooko through a submitted file.
    public var submittedBoundary: Date? { submissionBoundary }

    private var submissionBoundary: Date? {
        if let submittedThrough { return submittedThrough }
        // Migration of old files whose lastSubmittedIndex was recorded without an explicit checkpoint.
        guard let index = lastSubmittedIndex else { return nil }
        return records.last(where: { $0.index <= index && $0.record == .download })?.date
    }

    private func wasSubmitted(_ id: String) -> Bool {
        guard lastSubmittedIndex != nil else { return false }
        if let submittedIDs { return submittedIDs.contains(id) }
        guard let dose = sourceDoses[id], let boundary = submissionBoundary else { return true }
        return dose.start < boundary
    }

    /// Migrate membership from the original source snapshots, before a deletion or edit removes them.
    private mutating func captureSubmissionCheckpoint() {
        guard submittedIDs == nil, let index = lastSubmittedIndex, let boundary = submissionBoundary else { return }
        let ids = Set(committed.keys.filter { wasSubmitted($0) })
        submittedIDs = ids; submittedThrough = boundary
        if let record = records.last(where: {
            guard $0.index <= index else { return false }
            switch $0.record { case .basal, .suspend: return true; default: return false }
        })?.record {
            switch record {
            case let .basal(rate, minutes): submittedState = .init(delivery: minutes == 0 ? .scheduled(rate: rate) : .temporary(rate: rate))
            case .suspend: submittedState = .init(delivery: .suspended)
            default: break
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, ownerID, ownerEmail, sourceID, reportingContextData, serial, powerUp, podLot, podSerial, nextIndex, records, committedThrough
        case state, pending, committed, sourceDoses, conflicts, unclassified, stagedDeletions, droppedIDs, legacyIDs, legacyLateDoses, lateDoses, lastSubmittedIndex, lastUploadedIndex, lastVerifiedFileIndex, historyStart, submittedThrough, submittedState, submittedIDs, repairedBasalIndices, ingestionCorrections
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serial = try c.decode(UInt32.self, forKey: .serial); powerUp = try c.decode(Date.self, forKey: .powerUp)
        podLot = try c.decode(UInt16.self, forKey: .podLot); podSerial = try c.decode(UInt16.self, forKey: .podSerial)
        nextIndex = try c.decode(UInt32.self, forKey: .nextIndex); records = try c.decode([LegacyPumpEvent].self, forKey: .records)
        committedThrough = try c.decodeIfPresent(Date.self, forKey: .committedThrough)
        state = try c.decodeIfPresent(DeliveryTimeline.State.self, forKey: .state)
        pending = try c.decode([String: SourceDose].self, forKey: .pending)
        committed = try c.decode([String: Date].self, forKey: .committed)
        historyStart = try c.decodeIfPresent(Date.self, forKey: .historyStart)
        ownerID = try c.decodeIfPresent(String.self, forKey: .ownerID); sourceID = try c.decodeIfPresent(String.self, forKey: .sourceID)
        ownerEmail = try c.decodeIfPresent(String.self, forKey: .ownerEmail)
        reportingContextData = try c.decodeIfPresent(Data.self, forKey: .reportingContextData)
        sourceDoses = try c.decodeIfPresent([String: SourceDose].self, forKey: .sourceDoses) ?? pending
        conflicts = try c.decodeIfPresent([String: HistoryConflict].self, forKey: .conflicts) ?? [:]
        unclassified = try c.decodeIfPresent([String: SourceDose].self, forKey: .unclassified) ?? [:]
        stagedDeletions = try c.decodeIfPresent([String: SourceDose].self, forKey: .stagedDeletions) ?? [:]
        droppedIDs = try c.decodeIfPresent(Set<String>.self, forKey: .droppedIDs) ?? []
        legacyLateDoses = try c.decodeIfPresent(Int.self, forKey: .legacyLateDoses) ?? c.decodeIfPresent(Int.self, forKey: .lateDoses) ?? 0
        let previousIndex = try c.decodeIfPresent(UInt32.self, forKey: .lastUploadedIndex)
        lastSubmittedIndex = try c.decodeIfPresent(UInt32.self, forKey: .lastSubmittedIndex) ?? previousIndex
        submittedThrough = try c.decodeIfPresent(Date.self, forKey: .submittedThrough)
        submittedState = try c.decodeIfPresent(DeliveryTimeline.State.self, forKey: .submittedState)
        submittedIDs = try c.decodeIfPresent(Set<String>.self, forKey: .submittedIDs)
        lastUploadedIndex = (try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1) >= 2 ? previousIndex : nil
        lastVerifiedFileIndex = try c.decodeIfPresent(UInt32.self, forKey: .lastVerifiedFileIndex) ?? lastUploadedIndex
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        legacyIDs = try c.decodeIfPresent(Set<String>.self, forKey: .legacyIDs) ?? (version == 1 ? Set(committed.keys).union(pending.keys) : [])
        repairedBasalIndices = try c.decodeIfPresent(Set<UInt32>.self, forKey: .repairedBasalIndices) ?? []
        ingestionCorrections = try c.decodeIfPresent([String: IngestionCorrection].self, forKey: .ingestionCorrections) ?? [:]
        guard version <= 4, nextIndex > (records.last?.index ?? 0) else { throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c, debugDescription: "Unsupported or inconsistent history") }
        captureSubmissionCheckpoint()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(4, forKey: .schemaVersion); try c.encodeIfPresent(ownerID, forKey: .ownerID); try c.encodeIfPresent(sourceID, forKey: .sourceID)
        try c.encodeIfPresent(ownerEmail, forKey: .ownerEmail)
        try c.encodeIfPresent(reportingContextData, forKey: .reportingContextData)
        try c.encode(serial, forKey: .serial); try c.encode(powerUp, forKey: .powerUp); try c.encode(podLot, forKey: .podLot); try c.encode(podSerial, forKey: .podSerial)
        try c.encode(nextIndex, forKey: .nextIndex); try c.encode(records, forKey: .records); try c.encodeIfPresent(committedThrough, forKey: .committedThrough)
        try c.encodeIfPresent(state, forKey: .state); try c.encode(pending, forKey: .pending); try c.encode(committed, forKey: .committed)
        try c.encode(sourceDoses, forKey: .sourceDoses); try c.encode(conflicts, forKey: .conflicts); try c.encode(droppedIDs, forKey: .droppedIDs)
        try c.encode(unclassified, forKey: .unclassified); try c.encode(stagedDeletions, forKey: .stagedDeletions); try c.encode(legacyIDs, forKey: .legacyIDs)
        try c.encode(legacyLateDoses, forKey: .legacyLateDoses); try c.encode(lateDoses, forKey: .lateDoses)
        try c.encodeIfPresent(lastSubmittedIndex, forKey: .lastSubmittedIndex); try c.encodeIfPresent(lastUploadedIndex, forKey: .lastUploadedIndex)
        try c.encodeIfPresent(lastVerifiedFileIndex, forKey: .lastVerifiedFileIndex)
        try c.encodeIfPresent(submittedThrough, forKey: .submittedThrough); try c.encodeIfPresent(submittedState, forKey: .submittedState)
        try c.encodeIfPresent(submittedIDs, forKey: .submittedIDs)
        try c.encodeIfPresent(historyStart, forKey: .historyStart)
        try c.encode(repairedBasalIndices, forKey: .repairedBasalIndices)
        try c.encode(ingestionCorrections, forKey: .ingestionCorrections)
    }
}
