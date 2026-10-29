import XCTest
@testable import GlookoKit

final class AuthenticationTests: XCTestCase {
    private let secret = "synthetic-password-never-log"
    private func client(_ handler: @escaping (URLRequest, Int) throws -> (Int, [String: String], Data)) -> GlookoClient {
        AuthenticationProtocol.configure(handler)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthenticationProtocol.self]
        return GlookoClient(region: .init(signInHosts: ["eu.glooko.test", "global.glooko.test"], dataHost: "eu.glooko.test"), configuration: config)
    }
    func testRequestsIdentifyLoopWithoutClaimingGlookoAppOrBrowserIdentity() async throws {
        let c = client { request, index in
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Loop-GlookoService (+https://github.com/Nutcasey/GlookoService)")
            for header in ["deviceInformation", "Origin", "Referer"] {
                XCTAssertNil(request.value(forHTTPHeaderField: header), "Unexpected identity header: \(header)")
            }
            if index == 0 {
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: AuthenticationProtocol.body(request)) as? [String: Any])
                XCTAssertNil(body["deviceInformation"])
                return (200, ["Set-Cookie": "_logbook-web_session=owned-session; Path=/; Secure; HttpOnly", "Content-Type": "application/json"], Data("{}".utf8))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "_logbook-web_session=owned-session")
            return (200, ["Content-Type": "application/json"], Data("{}".utf8))
        }
        _ = try await c.signIn(email: "offline@example.test", password: secret)
        _ = try await c.get("/api/v2/users")
        _ = try await c.put(resource: "insulins", records: [])
        _ = try await c.put(resource: "foods", records: [])
        _ = try await c.uploadDeviceFile(Data("synthetic legacy file".utf8))
        XCTAssertEqual(AuthenticationProtocol.count, 5)
    }
    func testSignInRotatesHostsAndBodyShapesAndUsesOnlyTheIssuedSessionCookie() async throws {
        let c = client { [secret] request, index in
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: AuthenticationProtocol.body(request)) as? [String: Any])
            let shape = index % 2
            XCTAssertEqual(request.url?.host, index < 2 ? "eu.glooko.test" : "global.glooko.test")
            XCTAssertEqual(request.url?.path, shape == 1 ? "/api/v2/users/sign_in" : "/api/v3/users/sign_in")
            let user = try XCTUnwrap(body[shape == 1 ? "userLogin" : "user"] as? [String: Any])
            XCTAssertEqual(user["email"] as? String, "offline@example.test"); XCTAssertEqual(user["password"] as? String, secret)
            return index < 3 ? (index == 2 ? 404 : 422, [:], Data("rejected shape".utf8)) :
                (200, ["Set-Cookie": "_logbook-web_session=owned-session; Path=/; Secure; HttpOnly", "Content-Type": "application/json"], Data("{}".utf8))
        }
        let route = try await c.signIn(email: "offline@example.test", password: secret)
        XCTAssertEqual(route, "global.glooko.test/api/v2/users/sign_in")
        XCTAssertEqual(AuthenticationProtocol.count, 4)
        XCTAssertEqual(c.sessionCookie, "_logbook-web_session=owned-session")
        XCTAssertFalse(c.lastSignInDiagnostics.contains(secret))
    }
    func testCredentialRejectionAndAccountRestrictionsStopPasswordReplayImmediately() async throws {
        for status in [401, 403, 423, 429] {
            let c = client { [secret] _, _ in (status, [:], Data("server echoed \(secret)".utf8)) }
            do { _ = try await c.signIn(email: "offline@example.test", password: secret); XCTFail("Expected rejection") }
            catch GlookoError.credentialRejected(let actual) { XCTAssertEqual(actual, status) }
            XCTAssertEqual(AuthenticationProtocol.count, 1)
            XCTAssertNil(c.sessionCookie); XCTAssertFalse(c.lastSignInDiagnostics.contains(secret))
        }
    }
    func testMFAHTMLExpiredAndMissingCookiesCannotEstablishAnAuthorisedSessionOrLeakSecrets() async throws {
        for mode in ["mfa", "html", "expired", "missing"] {
            let c = client { [secret] _, _ in
                var headers = ["Content-Type": mode == "html" ? "text/html" : "application/json"]
                if mode != "missing" { headers["Set-Cookie"] = "_logbook-web_session=provisional; Path=/; Secure" + (mode == "expired" ? "; Expires=Thu, 01 Jan 1970 00:00:00 GMT" : "") }
                let body = mode == "mfa" ? "{\"twoFactorRequired\":true}" : "{\"error\":\"\(secret)\"}"
                return (200, headers, Data(body.utf8))
            }
            do { _ = try await c.signIn(email: "offline@example.test", password: secret); XCTFail("Expected unauthorised \(mode)") }
            catch { XCTAssertFalse(String(describing: error).contains(secret)) }
            XCTAssertNil(c.sessionCookie); XCTAssertFalse(c.lastSignInDiagnostics.contains(secret))
            XCTAssertEqual(AuthenticationProtocol.count, mode == "mfa" ? 1 : 4)
        }
    }
    func testTransportFailuresRotateWithoutExposingDescriptionsAndCancellationStopsRotation() async throws {
        let c = client { [secret] _, _ in throw NSError(domain: "offline", code: 999, userInfo: [NSLocalizedDescriptionKey: secret]) }
        do { _ = try await c.signIn(email: "offline@example.test", password: secret); XCTFail("Expected failure") }
        catch { XCTAssertFalse(String(describing: error).contains(secret)) }
        XCTAssertEqual(AuthenticationProtocol.count, 4)
        AuthenticationProtocol.configure { _, _ in throw CancellationError() }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in stream { break }
            return try await c.signIn(email: "offline@example.test", password: self.secret)
        }
        task.cancel(); continuation.finish()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertEqual(AuthenticationProtocol.count, 0)
    }
}

private final class AuthenticationProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest, Int) throws -> (Int, [String: String], Data))?
    private static var requests = 0
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    static func configure(_ next: @escaping (URLRequest, Int) throws -> (Int, [String: String], Data)) { lock.lock(); defer { lock.unlock() }; handler = next; requests = 0 }
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; result.append(buffer, count: n) }
        return result
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix("glooko.test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler!, index = Self.requests; Self.requests += 1; Self.lock.unlock()
        do {
            let (status, headers, data) = try handler(request, index)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
