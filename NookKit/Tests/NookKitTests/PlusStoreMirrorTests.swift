import Foundation
import Testing

@testable import NookKit

/// What the store does to the sync folder, and — mostly — what it must not.
///
/// The mirror deletes files, so the question that matters is what happens when the
/// store cannot see the records. A reader whose network is down, whose session has
/// expired, or who has just launched the app has an empty `articles` list for reasons
/// that have nothing to do with what they published, and a mirror driven off that would
/// empty their folder.
@Suite("Nook Plus store mirror", .serialized)
@MainActor
struct PlusStoreMirrorTests {
    /// Answers every request the way the test asks for.
    ///
    /// Registered rather than injected as a closure because both clients reach the
    /// network through `URLSession`, and this is the seam they share.
    final class Stub: URLProtocol, @unchecked Sendable {
        /// What to do with each request. Set before making one.
        nonisolated(unsafe) static var outcome: Outcome = .fail

        enum Outcome {
            /// Every request fails as if the host could not be reached.
            case fail
            /// Records are returned per collection, keyed by NSID. A collection with
            /// no entry answers with an empty list, which is what a repository with no
            /// records of that type really returns.
            case records([String: String])
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            switch Stub.outcome {
            case .fail:
                client?.urlProtocol(
                    self, didFailWithError: URLError(.notConnectedToInternet))
            case .records(let byCollection):
                let collection =
                    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "collection" }?.value ?? ""
                let json = byCollection[collection] ?? #"{"records":[]}"#
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(json.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    private func makeStore(_ outcome: Stub.Outcome) -> PlusStore {
        Stub.outcome = outcome
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        let credential = PlusSession(
            did: "did:plc:me", handle: "tim.staging.nooker.app",
            // Far-future expiry, so nothing tries to refresh mid-test.
            accessJWT: Self.token(expiring: 4_000_000_000),
            refreshJWT: Self.token(expiring: 4_000_000_000))
        return PlusStore(
            environment: .staging,
            urlSession: URLSession(configuration: configuration),
            credential: { credential })
    }

    /// An unsigned JWT with just the expiry the store reads.
    private static func token(expiring: Int) -> String {
        func segment(_ json: String) -> String {
            Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(segment(#"{"alg":"none"}"#)).\(segment(#"{"exp":\#(expiring)}"#))."
    }

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "nook-store-mirror-\(UUID().uuidString)")
    }

    /// The one that would lose the writer's files.
    ///
    /// `loadContent` leaves `articles` untouched when the fetch fails, which on a fresh
    /// launch means empty. Mirroring that reads every file in the folder as a post that
    /// no longer exists.
    @Test("a failed load does not empty the folder")
    func failedLoadLeavesTheFolderAlone() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // A folder as a previous, successful pass left it.
        let existing = PlusPostMirror.Post(
            slug: "hello", title: "Hello", summary: "", markdown: "Body.",
            publishedAt: "2026-07-30T12:00:00Z", url: nil)
        try PlusPostMirror.write(
            [existing], to: folder, handle: "tim.staging.nooker.app", did: "did:plc:me")
        let file = PlusPostMirror.directory(in: folder, handle: "tim.staging.nooker.app")
            .appending(path: "hello.md")
        #expect(FileManager.default.fileExists(atPath: file.path))

        let store = makeStore(.fail)
        store.syncFolder = { folder }
        await store.loadContent()

        #expect(store.failure != nil, "an unreachable host should have been reported")
        #expect(
            FileManager.default.fileExists(atPath: file.path),
            "a failed load deleted the writer's mirrored post")
    }

    /// The same hazard by a different route: no session at all, which is what the app
    /// looks like before signing in.
    @Test("a store with no session writes nothing")
    func noSessionWritesNothing() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = PlusStore(
            environment: .staging, urlSession: .shared, credential: { nil })
        store.syncFolder = { folder }
        await store.loadContent()

        #expect(store.mirroredDirectory == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "Posts").path))
    }

    /// And the case it is all for: a load that returns writes the files.
    @Test("a successful load mirrors the posts")
    func successfulLoadWritesTheFolder() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let publication = """
            {"records":[{"uri":"at://did:plc:me/app.nooker.publication/p","cid":"bafy1",\
            "value":{"$type":"app.nooker.publication","name":"Tim","slug":"tim",\
            "language":"ko","createdAt":"2026-07-01T00:00:00Z"}}]}
            """
        let article = """
            {"records":[{"uri":"at://did:plc:me/app.nooker.article/abc","cid":"bafy2",\
            "value":{"$type":"app.nooker.article","publication":"at://did:plc:me/app.nooker.publication/p",\
            "title":"안녕","content":"# 본문\\n","slug":"hello","publishedAt":"2026-07-30T12:00:00Z"}}]}
            """
        let store = makeStore(
            .records([
                "app.nooker.publication": publication,
                "app.nooker.article": article,
            ]))
        store.syncFolder = { folder }
        await store.loadContent()

        #expect(store.failure == nil, "unexpected failure: \(store.failure ?? "")")
        let file = PlusPostMirror.directory(in: folder, handle: "tim.staging.nooker.app")
            .appending(path: "hello.md")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("title: \"안녕\""))
        #expect(text.hasSuffix("# 본문\n"))
    }
}
