import Foundation
import Testing
@testable import NookKit

@Suite("Feed authors")
struct FeedAuthorTests {
    private func parse(_ xml: String) throws -> [Article] {
        try FeedXMLParser(feedURL: URL(string: "https://example.com/feed")!)
            .parse(data: Data(xml.utf8)).articles
    }

    @Test("RSS creator names take priority over email authors and are deduplicated")
    func rssCreators() throws {
        let articles = try parse("""
        <rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/"><channel><title>Feed</title>
        <item><title>Post</title><link>https://example.com/1</link>
          <author>alice@example.com (Alice)</author>
          <dc:creator><![CDATA[  Alice  ]]></dc:creator><dc:creator>alice</dc:creator>
          <dc:creator>Bob &amp; Carol</dc:creator>
          <source><dc:creator>Not the writer</dc:creator></source>
        </item></channel></rss>
        """)
        #expect(articles[0].authors == ["Alice", "Bob & Carol"])
    }

    @Test("RSS email/name forms, plain names, and missing authors stay distinct")
    func rssAuthorForms() throws {
        let articles = try parse("""
        <rss version="2.0"><channel><title>Feed</title><managingEditor>Editor</managingEditor>
          <item><title>One</title><guid>1</guid><author>writer@example.com (홍 길동)</author></item>
          <item><title>Two</title><guid>2</guid><author>Jane &lt;jane@example.com&gt;</author></item>
          <item><title>Three</title><guid>3</guid><author>writer@example.com</author></item>
          <item><title>Four</title><guid>4</guid><author>  </author></item>
          <item><title>Five</title><guid>5</guid></item>
        </channel></rss>
        """)
        #expect(articles.map(\.authors) == [["홍 길동"], ["Jane"], ["writer@example.com"], [], []])
    }

    @Test("Atom prefers entry authors, then source, then feed regardless of element order")
    func atomInheritance() throws {
        let articles = try parse("""
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Feed</title>
          <entry><title>One</title><id>1</id>
            <author><name>Alice</name><email>alice@example.com</email></author>
            <author><name>Bob</name></author><author><name>Alice</name></author>
            <contributor><name>Not an author</name></contributor>
            <source><author><name>Source writer</name></author></source>
          </entry>
          <entry><title>Two</title><id>2</id><source><author><name>Source writer</name></author></source></entry>
          <entry><title>Three</title><id>3</id></entry>
          <author><name>Feed writer</name></author>
        </feed>
        """)
        #expect(articles.map(\.authors) == [["Alice", "Bob"], ["Source writer"], ["Feed writer"]])
        #expect(articles.map(\.title) == ["One", "Two", "Three"])
    }

    @Test("An Atom feed with no author does not invent one from contributors")
    func atomMissingAuthor() throws {
        let articles = try parse("""
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Feed</title>
          <contributor><name>Editor</name></contributor>
          <entry><id>1</id><title>Post</title><contributor><name>Guest</name></contributor></entry>
        </feed>
        """)
        #expect(articles[0].authors.isEmpty)
    }

    @Test("Captured Nook RSS and Atom feeds expose the same publication author")
    func nookFeeds() throws {
        for xml in [LiveFeedFixture.rss, LiveFeedFixture.atom] {
            let articles = try parse(xml)
            #expect(!articles.isEmpty)
            #expect(articles.allSatisfy { $0.authors == ["tim.staging.nooker.app"] })
        }
    }

    @Test("Authors survive both baseline and content-replica persistence; old documents still decode")
    func persistence() throws {
        var article = Fixture.article("post", feedID: "feed")
        article.authors = ["홍 길동", "Alice"]
        let encoder = JSONEncoder()
        encoder.userInfo[.stripArticleContent] = true
        let decoder = JSONDecoder()
        let round = try decoder.decode(Article.self, from: encoder.encode(article))
        #expect(round.authors == article.authors)
        #expect(round.bodyParagraphs.isEmpty)
        let content = try decoder.decode(ArticleContent.self, from: encoder.encode(ArticleContent(article)))
        #expect(content.makeArticle().authors == article.authors)

        var oldArticle = try #require(JSONSerialization.jsonObject(with: encoder.encode(article)) as? [String: Any])
        oldArticle.removeValue(forKey: "authors")
        let oldData = try JSONSerialization.data(withJSONObject: oldArticle)
        #expect(try decoder.decode(Article.self, from: oldData).authors.isEmpty)
        #expect(try decoder.decode(ArticleContent.self, from: oldData).makeArticle().authors.isEmpty)
    }

    @Test("An author-only refresh reaches the article and displayed row, preserving reader state")
    @MainActor func authorRefresh() async throws {
        let store = ReaderStore._makeForTesting()
        let feed = Fixture.feed("a")
        var original = Fixture.article("a#one", feedID: "a")
        original.isRead = true
        original.isStarred = true
        store.feeds = [feed]
        store.articles = [original]
        store.selectSmartSource(.all)
        var incoming = original
        incoming.authors = ["New writer"]
        incoming.isRead = false
        incoming.isStarred = false
        store._mergeForTesting(ParsedFeed(feed: feed, articles: [incoming]))
        #expect(store.article(withID: original.id)?.authors == ["New writer"])
        #expect(store.article(withID: original.id)?.isRead == true)
        #expect(store.article(withID: original.id)?.isStarred == true)
        #if os(macOS)
        // Refreshes deliberately coalesce list publication. Wait for that path,
        // rather than forcing a selection change that would mask a stale row.
        for _ in 0..<100 where store.listWindow.rows.first?.authors != ["New writer"] {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.listWindow.rows.first?.authors == ["New writer"])
        #endif
    }
}
