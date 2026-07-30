import Foundation
import Testing

@testable import NookKit

/// The rules that let the reader show a writer their own post.
@Suite("Nook Plus own feed")
struct PlusOwnFeedTests {
    @Test("a publication's feed sits beside its page")
    func feedURL() throws {
        let publication = try #require(URL(string: "https://staging.nooker.app/@tim"))
        #expect(
            PlusOwnFeed.feedURL(for: publication).absoluteString
                == "https://staging.nooker.app/@tim/feed.xml")
    }

    /// The stored value comes from the service and may or may not have a trailing
    /// slash, which must not double up in the path.
    @Test("a trailing slash on the publication does not double up")
    func feedURLTrailingSlash() throws {
        let publication = try #require(URL(string: "https://staging.nooker.app/@tim/"))
        #expect(!PlusOwnFeed.feedURL(for: publication).absoluteString.contains("//feed"))
        #expect(PlusOwnFeed.feedURL(for: publication).absoluteString.hasSuffix("/feed.xml"))
    }

    // MARK: - Finding the reader's copy of a post

    private func url(_ value: String) throws -> URL {
        try #require(URL(string: value))
    }

    @Test("the same page matches itself")
    func samePage() throws {
        #expect(
            PlusOwnFeed.isSamePage(
                try url("https://staging.nooker.app/@tim/hello"),
                try url("https://staging.nooker.app/@tim/hello")))
    }

    @Test("different pages do not match")
    func differentPages() throws {
        #expect(
            !PlusOwnFeed.isSamePage(
                try url("https://staging.nooker.app/@tim/hello"),
                try url("https://staging.nooker.app/@tim/goodbye")))
        // A different writer's post with the same address is a different page.
        #expect(
            !PlusOwnFeed.isSamePage(
                try url("https://staging.nooker.app/@tim/hello"),
                try url("https://staging.nooker.app/@sam/hello")))
    }

    /// The reader's own normalisation, relied on rather than repeated.
    @Test("a trailing slash or fragment does not change the page")
    func incidentalDifferences() throws {
        #expect(
            PlusOwnFeed.isSamePage(
                try url("https://staging.nooker.app/@tim/hello"),
                try url("https://staging.nooker.app/@tim/hello/")))
        #expect(
            PlusOwnFeed.isSamePage(
                try url("https://staging.nooker.app/@tim/hello"),
                try url("https://staging.nooker.app/@tim/hello#top")))
        #expect(
            PlusOwnFeed.isSamePage(
                try url("https://staging.nooker.app/@tim/hello"),
                try url("HTTPS://Staging.Nooker.App/@tim/hello")))
    }

    /// The post published before the service validated slugs has a percent-encoded
    /// path, and the two sources of that URL disagree on the case of the escapes.
    /// Failing here means the reader cannot find precisely that post.
    @Test("percent-encoding case does not change the page")
    func escapeCase() throws {
        #expect(
            PlusOwnFeed.isSamePage(
                try url("https://staging.nooker.app/@tim/%ED%95%98%EC%9D%B4"),
                try url("https://staging.nooker.app/@tim/%ed%95%98%ec%9d%b4")))
    }

    /// An escape is not the same as the character it stands for at this level: the
    /// reader keeps paths percent-encoded, so both sides arrive encoded or neither
    /// does. Decoding here would make `%2F` equal to a path separator.
    @Test("case levelling leaves a bare percent alone")
    func malformedEscape() throws {
        #expect(
            PlusOwnFeed.isSamePage(
                try url("https://staging.nooker.app/@tim/100%25-done"),
                try url("https://staging.nooker.app/@tim/100%25-done")))
    }

    // MARK: - Remembering the publication

    /// Mirrored into defaults so the Feeds screen can offer the entry without a
    /// session or a network call.
    @Test("the publication is remembered and forgotten")
    func remembering() {
        let defaults = UserDefaults.standard
        let original = defaults.string(forKey: PlusOwnFeed.publicationURLKey)
        defer { PlusOwnFeed.remember(publicationURL: original) }

        PlusOwnFeed.remember(publicationURL: "https://staging.nooker.app/@tim")
        #expect(PlusOwnFeed.publicationURL?.absoluteString == "https://staging.nooker.app/@tim")
        #expect(PlusOwnFeed.feedURL?.absoluteString == "https://staging.nooker.app/@tim/feed.xml")

        // Signing out has to clear it, or the entry outlives the account.
        PlusOwnFeed.remember(publicationURL: nil)
        #expect(PlusOwnFeed.publicationURL == nil)
        #expect(PlusOwnFeed.feedURL == nil)

        PlusOwnFeed.remember(publicationURL: "")
        #expect(PlusOwnFeed.publicationURL == nil)
    }
}
