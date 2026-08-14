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

    /// uploadBlob takes the image itself, not a JSON envelope around it. Sending
    /// JSON here would store a base64 string as the blob and every derived icon
    /// would fail to decode — invisibly, because the record would still be valid.
    @Test("uploading a blob sends the raw bytes with the image's own type")
    func uploadBlobSendsRawBytes() async throws {
        Recorder.responseJSON = """
            {"blob":{"$type":"blob",
             "ref":{"$link":"bafkreibw6qsz3yg5q7pilv6y3jj3ra5frflo4y42the5me3i7kptibte7m"},
             "mimeType":"image/png","size":4096}}
            """
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let blob = try await client().uploadBlob(
            bytes, mimeType: "image/png", bearer: "access-token")

        let seen = try #require(Recorder.seen)
        #expect(seen.url?.path == "/xrpc/com.atproto.repo.uploadBlob")
        #expect(seen.body == bytes, "the image itself must be the body")
        #expect(seen.headers["Content-Type"] == "image/png")
        #expect(seen.headers["Authorization"] == "Bearer access-token")

        // And the reference comes back in the shape a record stores.
        #expect(blob.ref.link.hasPrefix("bafkrei"))
        #expect(blob.mimeType == "image/png")
        #expect(blob.size == 4096)
    }

    /// Uploading writes to the writer's own repository, so it must be authorized as
    /// them. An unauthenticated upload is refused, and refusing quietly would look
    /// like a network problem.
    @Test("uploading a blob fails loudly when the host refuses it")
    func uploadBlobSurfacesRefusal() async throws {
        Recorder.status = 401
        Recorder.responseJSON = #"{"error":"AuthMissing","message":"not authorized"}"#

        await #expect(throws: (any Error).self) {
            _ = try await client().uploadBlob(
                Data([0x89]), mimeType: "image/png", bearer: "stale")
        }
    }

    // MARK: - Deleting the account

    /// The first half of deletion asks the host to email a code. It takes no input,
    /// so it is the same shape as `refreshSession` and would fail the same way if a
    /// body were sent — but it presents the ACCESS token, not the refresh one.
    @Test("requesting deletion sends no body and presents the access token")
    func requestAccountDeletionShape() async throws {
        Recorder.responseJSON = "{}"
        try await client().requestAccountDeletion(bearer: session().accessJWT)

        let seen = try #require(Recorder.seen)
        #expect(seen.url?.path == "/xrpc/com.atproto.server.requestAccountDelete")
        #expect(seen.body == nil, "a method taking no input must send no body")
        #expect(seen.headers["Content-Type"] == nil)
        #expect(seen.headers["Authorization"] == "Bearer access-token")
    }

    /// The second half carries the DID, the password, and the emailed code — and no
    /// Authorization header. The method is unauthenticated by design: a live session
    /// is not enough to end an account, and sending one would hide that.
    @Test("deleting an account sends the did, password, and code, unauthenticated")
    func deleteAccountShape() async throws {
        Recorder.responseJSON = "{}"
        try await client().deleteAccount(
            did: "did:plc:example", password: "hunter2", token: "  ABC-123  ")

        let seen = try #require(Recorder.seen)
        #expect(seen.url?.path == "/xrpc/com.atproto.server.deleteAccount")
        #expect(seen.headers["Authorization"] == nil, "deletion is authorised by the code")

        let body = try #require(seen.body)
        let sent = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(sent["did"] == "did:plc:example")
        #expect(sent["password"] == "hunter2")
        // Trimmed, because a code arrives by email and is pasted with whatever came
        // with it. An untrimmed one is refused as invalid, which reads as the wrong
        // code rather than as stray whitespace.
        #expect(sent["token"] == "ABC-123")
    }

    /// A wrong code or password must surface, not be swallowed. The host answers 400,
    /// and a deletion that quietly did nothing would be the worst possible outcome
    /// here: the writer believes the account is gone and it is not.
    @Test("a refused deletion throws")
    func deleteAccountSurfacesRefusal() async throws {
        // Built before the status is set, not inside the expectation: `client()`
        // resets the recorder, so a status set first is wiped by it and the refusal
        // never happens. An `Empty` response body decodes from anything, so without
        // this the call succeeds and the test passes while proving nothing.
        let pds = client()
        Recorder.status = 400
        Recorder.responseJSON = #"{"error":"InvalidToken","message":"Token is invalid"}"#

        await #expect(throws: (any Error).self) {
            try await pds.deleteAccount(
                did: "did:plc:example", password: "hunter2", token: "nope")
        }
    }
}
