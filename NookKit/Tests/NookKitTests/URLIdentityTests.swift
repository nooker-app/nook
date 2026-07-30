import Foundation
import Testing

@testable import NookKit

/// `feedIdentityKey` decides when two URLs are the same thing. Getting it wrong
/// splits one feed into duplicates, or merges two that are genuinely different.
/// `ReaderStore.article(atPageURL:)` and `followedFeed(at:)` are one-line lookups
/// over this key, so this is where their behaviour is pinned.
@Suite("URL identity")
struct URLIdentityTests {
    private func key(_ value: String) throws -> String {
        try #require(URL(string: value)).feedIdentityKey
    }

    private func same(_ lhs: String, _ rhs: String) throws -> Bool {
        try key(lhs) == key(rhs)
    }

    @Test("scheme and host are case-insensitive")
    func hostCase() throws {
        #expect(try same("https://Example.com/feed.xml", "https://example.com/feed.xml"))
        #expect(try same("HTTPS://example.com/feed.xml", "https://example.com/feed.xml"))
    }

    /// A path can be case-sensitive on the server, so two spellings are two pages.
    @Test("the path keeps its case")
    func pathCase() throws {
        #expect(try !same("https://example.com/Feed.xml", "https://example.com/feed.xml"))
    }

    @Test("a default port, the fragment, and a trailing slash are dropped")
    func incidentals() throws {
        #expect(try same("https://example.com:443/feed.xml", "https://example.com/feed.xml"))
        #expect(try same("http://example.com:80/feed.xml", "http://example.com/feed.xml"))
        #expect(try same("https://example.com/feed.xml#top", "https://example.com/feed.xml"))
        #expect(try same("https://example.com/@tim/", "https://example.com/@tim"))
    }

    @Test("a non-default port is part of the identity")
    func explicitPort() throws {
        #expect(try !same("https://example.com:8443/feed.xml", "https://example.com/feed.xml"))
    }

    @Test("the query is part of the identity")
    func query() throws {
        #expect(try !same("https://example.com/feed?tag=a", "https://example.com/feed?tag=b"))
        #expect(try !same("https://example.com/feed?tag=a", "https://example.com/feed"))
    }

    // MARK: - Percent-escapes

    /// `%ED` and `%ed` are the same octet. The one Nook post published before the
    /// service validated slugs has a percent-encoded path, and its URL is spelled
    /// both ways by different sources, so a case-sensitive compare would fail to
    /// recognise exactly that post.
    @Test("escape case does not change identity")
    func escapeCase() throws {
        #expect(
            try same(
                "https://example.com/@tim/%ED%95%98%EC%9D%B4",
                "https://example.com/@tim/%ed%95%98%ec%9d%b4"))
        #expect(try same("https://example.com/a%2Fb", "https://example.com/a%2fb"))
    }

    /// Levelling the case must not decode: `%2F` is not a path separator, and
    /// treating it as one would merge two different paths.
    @Test("escapes are levelled, never decoded")
    func escapesAreNotDecoded() throws {
        #expect(try !same("https://example.com/a%2Fb", "https://example.com/a/b"))
        #expect(try key("https://example.com/a%2Fb").contains("%2F"))
    }

    /// A literal percent that is not an escape survives as it is, rather than
    /// swallowing the characters after it.
    @Test("a bare percent is left alone")
    func barePercent() throws {
        // "%zz" is not an escape; nothing may be consumed or upper-cased.
        let value = try key("https://example.com/100%25%20done")
        #expect(value.contains("%25"))
        #expect(value.hasSuffix("%20done"))
    }

    @Test("a URL with no escapes is unchanged")
    func noEscapes() throws {
        #expect(try key("https://example.com/@tim/feed.xml") == "https://example.com/@tim/feed.xml")
    }
}
