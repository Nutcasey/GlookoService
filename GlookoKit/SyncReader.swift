import Foundation

/// Strict reader for the app's SSV2 paged sync (`lastUpdatedAt` + `lastGuid` cursor), per
/// research/glooko/pump-upload-validation-plan.md stage 1. Never reports "empty" unless every page decoded.
public enum ScanOutcome: Equatable, CustomStringConvertible {
    case requestFailed(status: Int, detail: String)
    case invalidResponse(String)
    case incompleteScan(String)
    case complete(records: Int, pages: Int)

    public var description: String {
        switch self {
        case .requestFailed(let s, let d): return "requestFailed(HTTP \(s): \(d))"
        case .invalidResponse(let d): return "invalidResponse(\(d))"
        case .incompleteScan(let d): return "incompleteScan(\(d))"
        case .complete(let r, let p): return "complete(\(r) records, \(p) pages)"
        }
    }
}

public enum MatchOutcome: String {
    case foundLive, foundDeleted, completeNoMatch, notDetermined
}

public struct SyncScan {
    public var outcome: ScanOutcome
    public var records: [[String: Any]]

    /// Identity-based lookup; never matches by value.
    public func match(guid: String) -> (MatchOutcome, [String: Any]?) {
        guard case .complete = outcome else { return (.notDetermined, nil) }
        guard let r = records.first(where: { ($0["guid"] as? String)?.caseInsensitiveCompare(guid) == .orderedSame }) else {
            return (.completeNoMatch, nil)
        }
        let deleted = (r["softDeleted"] as? Bool) ?? ((r["softDeleted"] as? Int).map { $0 != 0 } ?? false)
        return (deleted ? .foundDeleted : .foundLive, r)
    }
}

public extension GlookoClient {
    /// Drains `/api/v2/<resource>` from the epoch cursor. `key` is the envelope's array name (camelCase of the last path part).
    func scan(_ resource: String, host: String? = nil, pageLimit: Int = 500, maxPages: Int = 200,
              since initialSince: String = "1970-01-01T00:00:00.000Z") async -> SyncScan {
        guard pageLimit > 0, maxPages > 0, !resource.isEmpty else {
            return SyncScan(outcome: .invalidResponse("resource and positive page limits are required"), records: [])
        }
        guard let key = try? Self.resourceKey(resource) else {
            return SyncScan(outcome: .invalidResponse("invalid resource name"), records: [])
        }
        var since = initialSince, lastGuid = "00000000-0000-0000-0000-000000000000"
        var all: [[String: Any]] = []
        var cursors = Set<String>()
        for page in 1...maxPages {
            cursors.insert("\(since)|\(lastGuid)")
            var query = URLComponents()
            query.queryItems = [URLQueryItem(name: "lastUpdatedAt", value: since),
                                URLQueryItem(name: "lastGuid", value: lastGuid),
                                URLQueryItem(name: "limit", value: String(pageLimit)),
                                URLQueryItem(name: "sendSoftDeleted", value: "true")]
            let path = "/api/v2/\(resource)?\(query.percentEncodedQuery!)"
            let r: HTTPResult
            do { r = try await send("GET", host: host ?? region.dataHost, path: path, body: nil, authenticated: true) }
            catch { return SyncScan(outcome: .requestFailed(status: -1, detail: "\(error)"), records: all) }
            guard r.status == 200 else {
                return SyncScan(outcome: .requestFailed(status: r.status, detail: Self.redact(r.text.prefix(200))), records: all)
            }
            guard let obj = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any],
                  let rows = obj[key] as? [[String: Any]],
                  let isLast = obj["lastPage"] as? Bool,
                  let nextSince = obj["lastUpdatedAt"] as? String,
                  let nextGuid = obj["lastGuid"] as? String else {
                return SyncScan(outcome: .invalidResponse("page \(page): missing \(key)/lastPage/lastUpdatedAt/lastGuid"), records: all)
            }
            all += rows
            if isLast { return SyncScan(outcome: .complete(records: all.count, pages: page), records: all) }
            if cursors.contains("\(nextSince)|\(nextGuid)") {
                return SyncScan(outcome: .incompleteScan("cursor repeated on page \(page)"), records: all)
            }
            since = nextSince; lastGuid = nextGuid
        }
        return SyncScan(outcome: .incompleteScan("stopped after \(maxPages) pages"), records: all)
    }
}

/// Destination time encoding: Glooko stores local wall-clock time with a literal `Z` (25 Oct 2026 finding).
public struct WallClock {
    public let timeZone: TimeZone
    public init(timeZone: TimeZone = .current) { self.timeZone = timeZone }
    public init(_ identifier: String) { timeZone = TimeZone(identifier: identifier) ?? .current }

    public func string(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f.string(from: date)
    }

    /// Local clock seconds since midnight (h·3600 + m·60 + s), not elapsed time; differs on DST days.
    public func secondsOfDay(_ date: Date) -> Int {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute, .second], from: date)
        return c.hour! * 3600 + c.minute! * 60 + c.second!
    }

    /// The UTC offset in force at that instant, formatted like the pump records (`+01:00`).
    public func offset(_ date: Date) -> String {
        let s = timeZone.secondsFromGMT(for: date)
        return String(format: "%@%02d:%02d", s < 0 ? "-" : "+", abs(s) / 3600, abs(s) % 3600 / 60)
    }
}
