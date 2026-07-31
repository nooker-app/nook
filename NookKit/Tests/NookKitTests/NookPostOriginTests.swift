import Foundation
import Testing

@testable import NookKit

/// The rules that decide whose cached body may be replaced.
///
/// Pinned hard in both directions. Getting "is this a Nook post" wrong one way
/// leaves a corrected post showing its old text forever; wrong the other way makes
/// Nook re-fetch every article on the open web and overwrite bodies a reader kept.
@Suite("Nook post origin")
struct NookPostOriginTests {
    private func article(
        _ id: String, title: String = "Title", summary: String = "Summary",
        html: String? = "<p>Body.</p>", body: [String] = ["Body."]
    ) -> Article {
        Article(
            id: id, feedID: "f", title: title, summary: summary,
            bodyParagraphs: body,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            url: URL(string: "https://example.com/post")!,
            estimatedReadMinutes: 1, isRead: false, isStarred: false,
            contentHTML: html)
    }

    // MARK: - Recognising a Nook post

    /// The shape a real subscription produces: the feed URL, then the AT URI the
    /// contract puts in the item's guid.
    @Test("an article from a Nook feed is recognised")
    func recognisesNookPost() {
        let id = "https://nooker.app/@tim/feed.xml"
            + "#at://did:plc:caq3ula6ozh5mgqob6cttvby/app.nooker.article/3mrw2j2b4es2x"
        #expect(NookPostOrigin.isNookPost(articleID: id))
    }

    /// A publication on its own domain is still a Nook post. This is why the rule
    /// reads the record type and not the hostname.
    @Test("a custom publication domain is still recognised")
    func recognisesCustomDomain() {
        let id = "https://writing.example.com/feed.xml"
            + "#at://did:plc:abc/app.nooker.article/3kkk"
        #expect(NookPostOrigin.isNookPost(articleID: id))
    }

    @Test("staging is recognised too")
    func recognisesStaging() {
        let id = "https://staging.nooker.app/@tim/feed.xml"
            + "#at://did:plc:abc/app.nooker.article/3kkk"
        #expect(NookPostOrigin.isNookPost(articleID: id))
    }

    /// Everything else keeps the body it fetched, so everything else must be
    /// refused — including things that look close.
    @Test("articles from other sources are not Nook posts")
    func refusesOthers() {
        let ids = [
            "https://example.com/feed.xml#https://example.com/post",
            "https://example.com/feed.xml#tag:example.com,2026:1",
            "https://example.com/feed.xml#12345",
            // Another AT Protocol record type: an AT URI is not enough on its own.
            "https://example.com/feed.xml#at://did:plc:abc/app.bsky.feed.post/3kkk",
            // The collection named, but not as this article's own guid.
            "https://example.com/app.nooker.article/feed.xml#12345",
            // A hostname that merely mentions Nook.
            "https://nooker.app.evil.example.com/feed.xml#https://x/1",
            "",
            "no-separator-at-all",
        ]
        for id in ids {
            #expect(
                !NookPostOrigin.isNookPost(articleID: id),
                "\(id) was treated as a Nook post")
        }
    }

    // MARK: - Detecting a change

    @Test("the fingerprint follows the body")
    func fingerprintFollowsBody() {
        let before = NookPostOrigin.fingerprint(of: article("x", html: "<p>Old.</p>"))
        let after = NookPostOrigin.fingerprint(of: article("x", html: "<p>New.</p>"))
        #expect(before != after)
    }

    @Test("the fingerprint follows the title and the summary")
    func fingerprintFollowsMetadata() {
        let base = NookPostOrigin.fingerprint(of: article("x"))
        #expect(NookPostOrigin.fingerprint(of: article("x", title: "Other")) != base)
        #expect(NookPostOrigin.fingerprint(of: article("x", summary: "Other")) != base)
    }

    /// A refresh that changed nothing must not look like an edit, or every open
    /// re-extracts and the cache stops being one.
    @Test("an unchanged article keeps its fingerprint")
    func fingerprintIsStable() {
        #expect(
            NookPostOrigin.fingerprint(of: article("x"))
                == NookPostOrigin.fingerprint(of: article("x")))
    }

    /// Moving text between fields must not collide.
    @Test("the fingerprint separates the fields it covers")
    func fingerprintIsUnambiguous() {
        let first = NookPostOrigin.fingerprint(of: article("x", title: "ab", summary: "c"))
        let second = NookPostOrigin.fingerprint(of: article("x", title: "a", summary: "bc"))
        #expect(first != second)
    }

    /// A feed that carries no HTML content still has to produce a fingerprint that
    /// moves when the text does; the paragraphs are what it has.
    @Test("an article with no HTML content still fingerprints its body")
    func fingerprintFallsBackToParagraphs() {
        let before = NookPostOrigin.fingerprint(of: article("x", html: nil, body: ["Old."]))
        let after = NookPostOrigin.fingerprint(of: article("x", html: nil, body: ["New."]))
        #expect(before != after)
    }

    // MARK: - The decision

    private var nookID: String {
        "https://nooker.app/@tim/feed.xml#at://did:plc:abc/app.nooker.article/3kkk"
    }

    /// The whole point: an edited Nook post stops being served from cache.
    @Test("an edited Nook post invalidates its cached body")
    func editedNookPostIsStale() {
        let old = article(nookID, html: "<p>Old.</p>")
        let new = article(nookID, html: "<p>New.</p>")
        let recorded = NookPostOrigin.fingerprint(of: old)

        #expect(NookPostOrigin.cachedBodyIsCurrent(recorded, for: old))
        #expect(!NookPostOrigin.cachedBodyIsCurrent(recorded, for: new))
    }

    /// And the other side of it: an unchanged Nook post still comes from cache, so
    /// opening a post twice does not re-extract it.
    @Test("an unchanged Nook post stays cached")
    func unchangedNookPostStaysCached() {
        let post = article(nookID)
        #expect(NookPostOrigin.cachedBodyIsCurrent(NookPostOrigin.fingerprint(of: post), for: post))
    }

    /// Other sources keep what they fetched, whatever their fingerprint says — and
    /// whether or not one was ever recorded.
    @Test("another source's cached body is never invalidated")
    func otherSourcesKeepTheirBody() {
        let id = "https://example.com/feed.xml#https://example.com/post"
        let old = article(id, html: "<p>Old.</p>")
        let new = article(id, html: "<p>Rewritten by the site.</p>")

        #expect(NookPostOrigin.cachedBodyIsCurrent(NookPostOrigin.fingerprint(of: old), for: new))
        #expect(NookPostOrigin.cachedBodyIsCurrent(nil, for: new))
    }

    /// A body cached before fingerprints existed has nothing to compare against.
    /// One re-fetch settles it — and only for Nook posts, so upgrading does not
    /// invalidate every cached article on the device.
    @Test("a Nook post cached before fingerprints existed is refreshed once")
    func missingFingerprintRefreshesNookPostsOnly() {
        #expect(!NookPostOrigin.cachedBodyIsCurrent(nil, for: article(nookID)))
        #expect(
            NookPostOrigin.cachedBodyIsCurrent(
                nil, for: article("https://example.com/feed.xml#1")))
    }
}
