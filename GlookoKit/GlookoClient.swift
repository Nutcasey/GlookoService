import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Glooko patient-app API, as captured from Glooko iOS 6.17.2 (research/glooko/app-write-protocol.md).
/// Writes are upserts keyed on a client-generated `guid`; a delete is the same record with `softDeleted: 1`.
public final class GlookoClient: @unchecked Sendable {
    public struct Region: Sendable {
        public var signInHosts: [String]
        public var dataHost: String
        public static let eu = Region(signInHosts: ["eu.api.glooko.com", "global.api.glooko.com"],
                                      dataHost: "eu.patient-api.glooko.com")
    }

    public static let sessionCookieName = "_logbook-web_session"

    public let region: Region
    private let lock = NSLock()
    private var cookie: String?
    public var sessionCookie: String? {
        get { lock.lock(); defer { lock.unlock() }; return cookie }
        set { lock.lock(); defer { lock.unlock() }; cookie = newValue }
    }
    private let session: URLSession
    private let deviceInformation: String

    public init(region: Region = .eu, sessionCookie: String? = nil, deviceId: String = UUID().uuidString) {
        self.region = region
        self.cookie = sessionCookie
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
        let info: [String: String] = [
            "applicationType": "logbook", "os": "ios", "osVersion": "27.0.1", "device": "iPhone",
            "deviceModel": "iPhone", "deviceManufacturer": "Apple", "serialNumber": String(deviceId.prefix(12)),
            "deviceId": deviceId, "applicationVersion": "6.17.2", "buildNumber": "37791",
            "gitHash": "ab48de20", "clinicalResearch": "false",
            "extractionInterface": ProcessInfo.processInfo.environment["GLOOKO_EXTRACTION"] ?? "; foreground",
        ]
        deviceInformation = String(decoding: try! JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]), as: UTF8.self)
    }

    /// Cookie names, value lengths and response keys from the last sign-in attempt; never values.
    public private(set) var lastSignInDiagnostics = ""

    public struct HTTPResult: @unchecked Sendable {
        public var status: Int
        public var body: Data
        public var setCookies: [HTTPCookie]
        public var contentType: String? = nil
        public var serverDate: Date? = nil
        public var text: String { String(decoding: body, as: UTF8.self) }
    }

    // MARK: Sign-in

    /// Tries the JSON sign-in on each candidate host and returns the host that issued a session cookie.
    @discardableResult
    public func signIn(email: String, password: String) async throws -> String {
        var failures: [String] = []
        let device = try JSONSerialization.jsonObject(with: Data(deviceInformation.utf8))
        // v2 takes `userLogin` (app shape); v3 takes `user` (nightscout-connect after Glooko's 2025 change).
        let attempts: [(String, [String: Any])] = [
            ("/api/v3/users/sign_in", ["user": ["email": email, "password": password], "deviceInformation": device]),
            ("/api/v3/users/sign_in", ["user": ["email": email, "password": password]]),
            ("/api/v2/users/sign_in", ["userLogin": ["email": email, "password": password], "deviceInformation": device]),
        ]
        for host in region.signInHosts {
            for (path, body) in attempts {
                try Task.checkCancellation()
                let result: HTTPResult
                do {
                    result = try await send("POST", host: host, path: path,
                                            body: try JSONSerialization.data(withJSONObject: body), authenticated: false)
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    failures.append("\(host)\(path): \(error.localizedDescription)"); continue
                }
                lastSignInDiagnostics = "HTTP \(result.status); cookies " +
                    result.setCookies.map { "\($0.name)(\($0.value.count) chars)" }.joined(separator: ", ") +
                    "; body keys " + Self.keys(result.body)
                // Rails may send a cleared cookie before the real one, so take the last non-empty value.
                if (200..<300).contains(result.status),
                   let cookie = result.setCookies.last(where: { $0.name == Self.sessionCookieName && !$0.value.isEmpty }) {
                    sessionCookie = "\(cookie.name)=\(cookie.value)"
                    return "\(host)\(path)"
                }
                if Self.twoFactorRequired(result.body) { throw GlookoError.twoFactorRequired }
                failures.append("\(host)\(path) [\(Self.keys(try JSONSerialization.data(withJSONObject: body)))]: HTTP \(result.status) \(Self.redact(result.text.prefix(200)))")
                // A credential rejection won't improve on another host; stop so the account isn't locked out.
                if result.status == 401 { throw GlookoError.signInFailed(failures) }
            }
        }
        throw GlookoError.signInFailed(failures)
    }

    // MARK: Requests

    public func get(_ path: String, headers: [String: String] = [:]) async throws -> HTTPResult {
        try await send("GET", host: region.dataHost, path: path, body: nil, authenticated: true, headers: headers)
    }

    /// `PUT /api/v2/<resource>` with `{ "<key>": records }`, the app's upsert shape. The key defaults to the
    /// camelCase last path component (`pumps/normal_boluses` → `normalBoluses`), matching the GET pages.
    public func put(resource: String, records: [[String: Any]], key: String? = nil, host: String? = nil) async throws -> HTTPResult {
        let resourceKey = try Self.resourceKey(resource)
        let key = key ?? resourceKey
        let body = try JSONSerialization.data(withJSONObject: [key: records])
        return try await send("PUT", host: host ?? region.dataHost, path: "/api/v2/\(resource)", body: body, authenticated: true)
    }

    public func send(_ method: String, host: String, path: String, body: Data?, authenticated: Bool,
                     headers: [String: String] = [:]) async throws -> HTTPResult {
        guard let url = URL(string: "https://\(host)\(path)") else { throw GlookoError.badURL(path) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(deviceInformation, forHTTPHeaderField: "deviceInformation")
        req.setValue("en-GB", forHTTPHeaderField: "glookoOverrideLocale")
        req.setValue("Glooko/37791 CFNetwork/1.0 Darwin/27.0.0 GlookoiOS/6.17.2", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if authenticated {
            guard let cookie = sessionCookie else { throw GlookoError.notSignedIn }
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: req, delegate: RefuseRedirects.shared)
        guard let http = response as? HTTPURLResponse else { throw GlookoError.invalidResponse }
        let fields = http.allHeaderFields.reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX"); clock.timeZone = TimeZone(secondsFromGMT: 0)
        clock.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return HTTPResult(status: http.statusCode, body: data, setCookies: cookies,
                          contentType: http.value(forHTTPHeaderField: "Content-Type"),
                          serverDate: http.value(forHTTPHeaderField: "Date").flatMap(clock.date(from:)))
    }

    static func resourceKey(_ resource: String) throws -> String {
        guard resource.range(of: #"^[A-Za-z][A-Za-z0-9]*(?:_[A-Za-z0-9]+)*(?:/[A-Za-z][A-Za-z0-9]*(?:_[A-Za-z0-9]+)*)*$"#,
                             options: .regularExpression) != nil,
              let last = resource.split(separator: "/").last else { throw GlookoError.invalidResource }
        let parts = last.split(separator: "_")
        guard let first = parts.first else { throw GlookoError.invalidResource }
        return String(first) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    static func keys(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "(non-JSON)" }
        return obj.map { k, v in (v as? [String: Any]).map { "\(k){\($0.keys.sorted().joined(separator: ","))}" } ?? k }
            .sorted().joined(separator: ", ")
    }

    // MARK: Helpers

    static func twoFactorRequired(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return ["twoFaRequired", "two_fa_required", "twoFactorRequired"].contains { (obj[$0] as? Bool) == true }
    }

    /// Strips anything that looks like a token or e-mail from text shown in diagnostics.
    public static func redact<S: StringProtocol>(_ text: S) -> String {
        var s = String(text)
        for pattern in [#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+"#, #"(?i)(token|cookie|session)[^,}]*"#] {
            s = s.replacingOccurrences(of: pattern, with: "<redacted>", options: .regularExpression)
        }
        return s
    }

    public static func isoTimestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RefuseRedirects()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum GlookoError: Error, CustomStringConvertible {
    case signInFailed([String]), twoFactorRequired, notSignedIn, badURL(String), invalidResource, invalidResponse
    case authenticationRequired(Int), requestRejected(String)
    public var description: String {
        switch self {
        case .signInFailed(let f): return "Sign-in failed:\n  " + f.joined(separator: "\n  ")
        case .twoFactorRequired: return "Account requires two-step verification (not supported yet)"
        case .notSignedIn: return "Sign in to Glooko again"
        case .badURL(let p): return "Bad URL path \(p)"
        case .invalidResource: return "Invalid Glooko resource name"
        case .invalidResponse: return "Glooko returned an unexpected response"
        case .authenticationRequired: return "The Glooko session has expired; sign in again"
        case .requestRejected(let reason): return reason
        }
    }
}
