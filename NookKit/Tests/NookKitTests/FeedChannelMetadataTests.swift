import Foundation
import Testing

@testable import NookKit

/// The feed's own title and link, told apart from the same names nested inside it.
///
/// Written because a feed called "tim" was subscribed to as "timtim". RSS puts a
/// `<title>` and a `<link>` inside `<channel><image>`, which almost every feed
/// with an icon has, and the parser accepted any `title` anywhere under `channel`
/// and appended it. The doubling was visible the moment Nook's own feeds gained an
/// icon, but it was never specific to them.
@Suite("Feed channel metadata")
struct FeedChannelMetadataTests {
    private func parse(_ xml: String) throws -> ParsedFeed {
        let parser = FeedXMLParser(feedURL: URL(string: "https://example.com/feed.xml")!)
        return try parser.parse(data: Data(xml.utf8))
    }

    /// The exact shape Nook publishes.
    @Test("an image's title and link do not become the feed's")
    func rssImageDoesNotLeak() throws {
        let feed = try parse(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0">
              <channel>
                <title>tim</title>
                <link>https://example.com/@tim</link>
                <description>Notes</description>
                <image>
                  <url>https://example.com/icon.png</url>
                  <title>tim</title>
                  <link>https://example.com/@tim</link>
                </image>
                <item>
                  <title>A post</title>
                  <link>https://example.com/@tim/a-post</link>
                </item>
              </channel>
            </rss>
            """)

        #expect(feed.feed.title == "tim", "got \(feed.feed.title)")
        #expect(feed.feed.siteURL.absoluteString == "https://example.com/@tim", "got \(feed.feed.siteURL.absoluteString)")
        #expect(feed.articles.count == 1)
        #expect(feed.articles.first?.title == "A post")
    }

    /// The other elements RSS lets nest the same names. A feed using them is rare
    /// but legal, and it must not rename the subscription either.
    @Test("textInput and cloud titles do not become the feed's")
    func rssTextInputDoesNotLeak() throws {
        let feed = try parse(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0">
              <channel>
                <title>Real Title</title>
                <link>https://example.com/</link>
                <textInput>
                  <title>Search</title>
                  <description>Search this site</description>
                  <name>q</name>
                  <link>https://example.com/search</link>
                </textInput>
              </channel>
            </rss>
            """)

        #expect(feed.feed.title == "Real Title", "got \(feed.feed.title)")
        #expect(feed.feed.siteURL.absoluteString == "https://example.com/", "got \(feed.feed.siteURL.absoluteString)")
    }

    /// Atom nests titles too, inside author and source, and carries a feed-level
    /// logo beside them.
    @Test("an atom entry's source title does not become the feed's")
    func atomSourceDoesNotLeak() throws {
        let feed = try parse(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <title>tim</title>
              <subtitle>Notes</subtitle>
              <icon>https://example.com/icon.png</icon>
              <logo>https://example.com/icon.png</logo>
              <author><name>tim</name></author>
              <entry>
                <title>A post</title>
                <id>at://did:plc:abc/app.nooker.article/1</id>
                <source><title>Somewhere Else</title></source>
              </entry>
            </feed>
            """)

        #expect(feed.feed.title == "tim", "got \(feed.feed.title)")
        #expect(feed.feed.siteDescription == "Notes", "got \(feed.feed.siteDescription)")
        #expect(feed.articles.first?.title == "A post")
    }

    /// The feeds the service actually serves, parsed as the reader parses them.
    /// This is the case that was reported: subscribing named it "timtim".
    @Test("a live Nook feed is named once")
    func liveFeedIsNamedOnce() throws {
        for (format, xml) in [("RSS", LiveFeedFixture.rss), ("Atom", LiveFeedFixture.atom)] {
            let feed = try parse(xml)
            #expect(feed.feed.title == "tim", "\(format) named it \(feed.feed.title)")
            #expect(feed.articles.isEmpty == false, "\(format) parsed no articles")
            for article in feed.articles {
                #expect(article.title.isEmpty == false)
            }
        }
    }

    /// A title arriving in pieces still assembles. The parser appends rather than
    /// assigns because XMLParser hands text over in chunks, and an entity in the
    /// middle splits it — so the fix had to be about scope, not about assignment.
    @Test("a title split by an entity is assembled, not truncated")
    func chunkedTitle() throws {
        let feed = try parse(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0">
              <channel>
                <title>Tom &amp; Jerry</title>
                <link>https://example.com/</link>
              </channel>
            </rss>
            """)

        #expect(feed.feed.title == "Tom & Jerry", "got \(feed.feed.title)")
    }
}
