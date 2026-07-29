import Foundation
import Testing

@testable import NookKit

@Suite("Nook Plus invitation links")
struct PlusInviteLinkTests {
    static let code = "NVKVNC6C-NTGGAFGX-2CFWQB2M-CQCNNQ38"

    @Test("a built link round-trips back to its code")
    func roundTrip() throws {
        let url = try #require(PlusInviteLink.url(code: Self.code))
        #expect(PlusInviteLink.code(from: url) == Self.code)
    }

    /// The custom scheme is the point: an https URL would put the code in a path
    /// or query that servers and CDNs log, and an invitation code must never
    /// reach a log.
    @Test("links use the custom scheme, not http")
    func usesCustomScheme() throws {
        let url = try #require(PlusInviteLink.url(code: Self.code))
        #expect(url.scheme == "nook")
        #expect(url.absoluteString.hasPrefix("nook://plus/invite"))
    }

    @Test("unrelated links are ignored")
    func ignoresOtherLinks() throws {
        let others = [
            "nook://open",
            "nook://plus/other?code=x",
            "nook://share?url=https://example.com",
            "https://nooker.app/invite?code=\(Self.code)",
            "nook://plus/invite",
            "nook://plus/invite?code=",
        ]
        for raw in others {
            let url = try #require(URL(string: raw))
            #expect(PlusInviteLink.code(from: url) == nil, "\(raw) should not yield a code")
        }
    }

    /// A code typed with stray whitespace by a link generator should still work;
    /// validation belongs to the server, so anything non-empty is passed through
    /// rather than silently discarded.
    @Test("surrounding whitespace is trimmed")
    func trimsWhitespace() throws {
        let url = try #require(URL(string: "nook://plus/invite?code=%20\(Self.code)%20"))
        #expect(PlusInviteLink.code(from: url) == Self.code)
    }

    /// A malformed code is handed on rather than dropped, so it fails at the
    /// server the same way a mistyped one does instead of looking like no link
    /// at all.
    @Test("a malformed code is still delivered")
    func deliversMalformedCode() throws {
        let url = try #require(URL(string: "nook://plus/invite?code=not-a-real-code"))
        #expect(PlusInviteLink.code(from: url) == "not-a-real-code")
    }

    @Test("the scheme and host are matched case-insensitively")
    func caseInsensitive() throws {
        let url = try #require(URL(string: "NOOK://PLUS/invite?code=\(Self.code)"))
        #expect(PlusInviteLink.code(from: url) == Self.code)
    }
}

@MainActor
@Suite("Nook Plus invitation inbox")
struct PlusInviteInboxTests {
    @Test("accepting a link stores the code, and taking it clears it")
    func acceptAndTake() throws {
        let inbox = PlusInviteInbox.shared
        inbox.clear()

        let url = try #require(PlusInviteLink.url(code: PlusInviteLinkTests.code))
        #expect(inbox.accept(url))
        #expect(inbox.pendingCode == PlusInviteLinkTests.code)

        // Taking clears it, so a completed signup cannot be restarted by the
        // same link still sitting in memory.
        #expect(inbox.take() == PlusInviteLinkTests.code)
        #expect(inbox.pendingCode == nil)
        #expect(inbox.take() == nil)
    }

    @Test("a non-invitation link is rejected and leaves the inbox alone")
    func rejectsOtherLinks() throws {
        let inbox = PlusInviteInbox.shared
        inbox.clear()

        let url = try #require(URL(string: "nook://open"))
        #expect(inbox.accept(url) == false)
        #expect(inbox.pendingCode == nil)
    }

    @Test("clearing discards a pending code")
    func clearing() throws {
        let inbox = PlusInviteInbox.shared
        let url = try #require(PlusInviteLink.url(code: PlusInviteLinkTests.code))
        _ = inbox.accept(url)

        inbox.clear()
        #expect(inbox.pendingCode == nil)
    }
}
