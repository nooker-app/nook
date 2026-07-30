import Foundation
import Testing

@testable import NookKit

/// What actually goes on the wire.
///
/// These exist because of a bug no amount of reading the call site would have found:
/// the request helper sent `{}` with `Content-Type: application/json` for every
/// method, including the one that takes no input. The host refuses that —
/// "A request body was provided when none was expected", 400 — so every attempt to
/// renew a session failed, and the app told the writer to sign in again every two
/// hours with a refresh token valid for ninety days in the Keychain.
///
/// Nothing about the Swift signature was wrong. Only the bytes were.
@Suite("Nook Plus PDS requests", .serialized)
struct PlusPDSRequestTests {
    /// Captures the request and answers with canned JSON.
    final class Recorder: URLProtocol, @unchecked Sendable {
        /// The last request seen, with its body. `URLProtocol` strips `httpBody`
        /// from the request it is handed, so the stream is read back here.
        nonisolated(unsafe) static var seen: (url: URL?, headers: [String: String], body: Data?)?
        nonisolated(unsafe) static var responseJSON = "{}"
        nonisolated(unsafe) static var status = 200

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open()
                var collected = Data()
                let size = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: size)
                    if read <= 0 { break }
                    collected.append(buffer, count: read)
                }
                stream.close()
                body = collected.isEmpty ? nil : collected
            }
            Self.seen = (request.url, request.allHTTPHeaderFields ?? [:], body)

            let response = HTTPURLResponse(
                url: request.url!, statusCode: Self.status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(Self.responseJSON.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func client() -> PlusPDSClient {
        Recorder.seen = nil
        Recorder.status = 200
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Recorder.self]
        return PlusPDSClient(
            host: "pds.example.com",
            issuedDomains: ["example.com"],
            session: URLSession(configuration: configuration))
    }

    private func session() -> PlusSession {
        PlusSession(
            did: "did:plc:example", handle: "tim.example.com",
            accessJWT: "access-token", refreshJWT: "refresh-token")
    }

    /// The bug, pinned. `refreshSession` takes no input, and a body makes the host
    /// refuse the request outright.
    @Test("refreshing a session sends no body and no content type")
    func refreshSendsNoBody() async throws {
        Recorder.responseJSON = """
            {"did":"did:plc:example","handle":"tim.example.com",
             "accessJwt":"new-access","refreshJwt":"new-refresh"}
            """
        _ = try await client().refresh(session())

        let seen = try #require(Recorder.seen)
        #expect(seen.body == nil, "a method taking no input must send no body")
        #expect(
            seen.headers["Content-Type"] == nil,
            "no body means no content type either")
    }

    /// And it must present the *refresh* token, not the access token: the access
    /// token is what has just expired.
    @Test("refreshing presents the refresh token")
    func refreshUsesTheRefreshToken() async throws {
        Recorder.responseJSON = """
            {"did":"did:plc:example","handle":"tim.example.com",
             "accessJwt":"new-access","refreshJwt":"new-refresh"}
            """
        _ = try await client().refresh(session())

        let seen = try #require(Recorder.seen)
        #expect(seen.headers["Authorization"] == "Bearer refresh-token")
        #expect(seen.url?.path == "/xrpc/com.atproto.server.refreshSession")
    }

    @Test("refreshing returns the renewed pair")
    func refreshReturnsTheNewTokens() async throws {
        Recorder.responseJSON = """
            {"did":"did:plc:example","handle":"tim.example.com",
             "accessJwt":"new-access","refreshJwt":"new-refresh"}
            """
        let renewed = try await client().refresh(session())

        // Both, because the host rotates the refresh token and storing only the
        // access token would leave the next renewal reaching for a stale one.
        #expect(renewed.accessJWT == "new-access")
        #expect(renewed.refreshJWT == "new-refresh")
        #expect(renewed.did == "did:plc:example")
    }

    /// A method that does take input still sends it, so the fix did not empty every
    /// request.
    @Test("a method with input still sends its body")
    func requestsWithInputStillSendOne() async throws {
        Recorder.responseJSON = "{}"
        try await client().requestPasswordReset(email: "someone@example.com")

        let seen = try #require(Recorder.seen)
        let body = try #require(seen.body)
        #expect(seen.headers["Content-Type"] == "application/json")

        let decoded = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(decoded["email"] == "someone@example.com")
    }

    /// Sign-in sends credentials, and the password must be in the body rather than
    /// anywhere it could be logged — a query string, or a header.
    @Test("signing in sends its credentials in the body")
    func signInSendsABody() async throws {
        Recorder.responseJSON = """
            {"did":"did:plc:example","handle":"tim.example.com",
             "accessJwt":"a","refreshJwt":"r"}
            """
        _ = try await client().signIn(identifier: "tim.example.com", password: "hunter2")

        let seen = try #require(Recorder.seen)
        let body = try #require(seen.body)
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(decoded["password"] == "hunter2")
        #expect(seen.url?.query == nil, "credentials must never travel in a query string")
    }
}
