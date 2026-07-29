import Foundation
import NookPlusProtocol
import NookPlusServiceAPI
import Testing

@testable import NookKit

/// Keychain access is not exercised here: it needs an entitled, signed host
/// process, so it is verified by running the app. These cover the parts that
/// are pure logic — and the guarantees that matter if they are wrong.
@Suite("Nook Plus session")
struct PlusSessionTests {
    @Test("session survives a round trip through its stored form")
    func codableRoundTrip() throws {
        let session = PlusSession(
            did: "did:plc:aaaabbbbccccddddeeeeffff",
            handle: "alice.handles.example.com",
            accessJWT: "access-token",
            refreshJWT: "refresh-token"
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(PlusSession.self, from: data)

        #expect(decoded == session)
    }

    /// The password reaches the PDS and is discarded. If it ever appeared in
    /// the stored form it would sit on disk indefinitely.
    @Test("stored form holds no password field")
    func storedFormHasNoPassword() throws {
        let session = PlusSession(
            did: "did:plc:example",
            handle: "alice.handles.example.com",
            accessJWT: "access",
            refreshJWT: "refresh"
        )
        let data = try JSONEncoder().encode(session)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["did", "handle", "accessJWT", "refreshJWT"])
    }

    /// The DID is the identity; the handle is a label that changes.
    @Test("did is immutable, handle is not")
    func didIsImmutable() {
        var session = PlusSession(
            did: "did:plc:example",
            handle: "alice.handles.example.com",
            accessJWT: "access",
            refreshJWT: "refresh"
        )
        session.handle = "ada.handles.example.com"

        #expect(session.did == "did:plc:example")
    }
}

@Suite("Nook Plus problem types")
struct PlusProblemTypeTests {
    /// A build that predates a newly added type must keep working rather than
    /// failing to decode.
    @Test("an unrecognised type is tolerated")
    func unknownTypeIsNil() {
        #expect(ProblemType(unchecked: "https://example.com/problems/invented") == nil)
        #expect(ProblemType(unchecked: nil) == nil)
    }

    @Test("known types decode")
    func knownTypesDecode() {
        #expect(
            ProblemType(unchecked: "https://nooker.app/problems/record-conflict")
                == .recordConflict)
        #expect(
            ProblemType(unchecked: "https://nooker.app/problems/invalid-session")
                == .invalidSession)
    }

    /// Retrying a conflict unchanged either fails again or, worse, succeeds
    /// after the client drops the condition and overwrites someone's edit.
    @Test("a record conflict is not retryable unchanged")
    func conflictIsNotRetryable() {
        #expect(ProblemType.recordConflict.isRetryableUnchanged == false)
        #expect(ProblemType.recordConflict.isUserCorrectable)
        #expect(ProblemType.rateLimited.isRetryableUnchanged)
    }

    /// A suspended member cannot fix their own standing, so the client must
    /// not offer a corrective prompt for it.
    @Test("suspension is not user-correctable")
    func suspensionIsNotUserCorrectable() {
        #expect(ProblemType.memberSuspended.isUserCorrectable == false)
        #expect(ProblemType.memberRevoked.isUserCorrectable == false)
    }

    @Test("every type carries the protocol's fixed prefix")
    func allTypesShareThePrefix() {
        for problemType in ProblemType.allCases {
            #expect(problemType.rawValue.hasPrefix("https://nooker.app/problems/"))
        }
    }
}

@Suite("Nook Plus record envelopes")
struct PlusRecordEnvelopeTests {
    /// Articles and publications are read from the PDS, not from a service
    /// read API, so decoding a real PDS response has to work here.
    @Test("a listRecords page decodes into article records")
    func decodesArticlePage() throws {
        let json = """
            {
              "cursor": "3jt5next",
              "records": [
                {
                  "uri": "at://did:plc:example/app.nooker.article/3jt5artcreate",
                  "cid": "bafyreiexample",
                  "value": {
                    "$type": "app.nooker.article",
                    "publication": "at://did:plc:example/app.nooker.publication/3jt5pub",
                    "title": "An Example Article",
                    "content": "Body text.\\n",
                    "slug": "an-example-article",
                    "publishedAt": "2026-01-15T09:30:00Z"
                  }
                }
              ]
            }
            """.data(using: .utf8)!

        let page = try JSONDecoder().decode(ArticlePage.self, from: json)

        #expect(page.records.count == 1)
        #expect(page.hasMore)
        #expect(page.records[0].value.title == "An Example Article")
        // The record key is what a permanent article URL is built from.
        #expect(page.records[0].recordKey == "3jt5artcreate")
    }
}
