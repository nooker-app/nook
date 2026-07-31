import Foundation
import NookPlusProtocol
import Testing

@testable import NookKit

/// Where the service client gets its token from, and when.
///
/// The answer has to be "again, for every request". A store is built when a screen
/// first appears — on macOS that is before anybody has signed in — and the token it
/// sends has to be able to change afterwards: once when a sign-in creates one, and
/// again every time a refresh replaces one.
///
/// This exists because it once did not. A build captured the session at
/// construction, so editing a post answered "your session has expired" at once,
/// signing in again changed nothing, and only relaunching the app helped. No test
/// failed: every test built its store with a session already in hand, which is the
/// single case a frozen credential gets right.
@Suite("Nook Plus store credential", .serialized)
@MainActor
struct PlusStoreCredentialTests {
    /// Records the Authorization header of every request, and answers each one.
    final class Recorder: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var authorizations: [String?] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            Recorder.authorizations.append(request.value(forHTTPHeaderField: "Authorization"))
            // The body does not matter: the header is what is under test, and it has
            // already been recorded by the time the response is written.
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    /// A credential store that can be changed, standing in for the Keychain.
    ///
    /// Deliberately mutable. The point is that the store notices when the stored
    /// credential is replaced, which is what signing in and refreshing both do.
    final class Vault: @unchecked Sendable {
        var session: PlusSession?
        init(_ session: PlusSession?) { self.session = session }
    }

    private static func token(expiring: Int) -> String {
        func segment(_ json: String) -> String {
            Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(segment(#"{"alg":"none"}"#)).\(segment(#"{"exp":\#(expiring)}"#))."
    }

    /// A session whose access token is distinguishable and not near expiry, so
    /// nothing tries to refresh in the middle of the test.
    private static func session(access: Int) -> PlusSession {
        PlusSession(
            did: "did:plc:me", handle: "tim.staging.nooker.app",
            accessJWT: token(expiring: access),
            refreshJWT: token(expiring: 4_000_000_000))
    }

    private func makeStore(_ vault: Vault) -> PlusStore {
        Recorder.authorizations = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Recorder.self]
        return PlusStore(
            environment: .staging,
            urlSession: URLSession(configuration: configuration),
            credential: { vault.session })
    }

    private func article() -> ATRecord<ArticleRecord> {
        ATRecord(
            uri: "at://did:plc:me/app.nooker.article/3mrw2j2b4es2x",
            cid: "bafyreiexamplecid",
            value: ArticleRecord(
                publication: "at://did:plc:me/app.nooker.publication/p",
                title: "Title", content: "Body.", slug: "a-post",
                publishedAt: "2026-07-30T12:00:00Z"))
    }

    /// Editing a post is what the writer reported, so editing is what this drives.
    private func edit(_ store: PlusStore) async {
        await store.update(
            article(), title: "Title", slug: "a-post", markdown: "Body.", summary: "")
    }

    /// The bug, as a test. A store built while signed out has to send the credential
    /// that appears afterwards, because that is the order the macOS screen does it in.
    @Test("a store built before sign-in sends a credential stored afterwards")
    func credentialStoredAfterConstruction() async {
        let vault = Vault(nil)
        let store = makeStore(vault)
        #expect(!store.isSignedIn)

        vault.session = Self.session(access: 4_000_000_000)
        await edit(store)

        let sent = Recorder.authorizations.compactMap { $0 }
        #expect(!sent.isEmpty, "no request carried an Authorization header at all")
        #expect(
            sent.last == "Bearer \(Self.token(expiring: 4_000_000_000))",
            "the request went out without the credential stored after construction")
    }

    /// The other half, and the one that made editing fail hours into a session: a
    /// refresh replaces the access token, and the next request must carry the new one.
    @Test("a replaced credential reaches the next request")
    func replacedCredentialReachesTheWire() async {
        let first = Self.session(access: 4_000_000_000)
        let vault = Vault(first)
        let store = makeStore(vault)

        await edit(store)
        let before = Recorder.authorizations.compactMap { $0 }

        let second = Self.session(access: 4_100_000_000)
        vault.session = second
        await edit(store)
        let after = Recorder.authorizations.compactMap { $0 }

        #expect(!before.isEmpty, "the first request carried no credential")
        #expect(after.count > before.count, "the second edit sent nothing")
        #expect(
            after.last == "Bearer \(second.accessJWT)",
            "the request carried a stale token: \(after.last ?? "none")")
        #expect(
            after.last != "Bearer \(first.accessJWT)",
            "the credential was captured at construction instead of read per request")
    }
}
