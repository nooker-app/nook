import Foundation

/// Feeds exactly as the service serves them, captured from a live publication.
///
/// Parsed in a test rather than eyeballed, because the subscription this produced
/// was named "timtim" and the XML looked perfectly correct: the fault was in how
/// the feed and the reader met.
enum LiveFeedFixture {
    static let rss = """
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>tim</title>
    <link>https://staging.nooker.app/@tim</link>
    <description></description>
    <language>en</language>
    <lastBuildDate>Thu, 30 Jul 2026 01:23:01 +0000</lastBuildDate>
    <atom:link href="https://staging.nooker.app/@tim/feed.xml" rel="self" type="application/rss+xml"></atom:link>
    <image>
      <url>https://staging.nooker.app/icon.png</url>
      <title>tim</title>
      <link>https://staging.nooker.app/@tim</link>
    </image>
    <item>
      <title>Hello nook</title>
      <link>https://staging.nooker.app/@tim/hellonook</link>
      <guid isPermaLink="false">at://did:plc:z3l3putcqv5wpkbohmft5x32/app.nooker.article/3mrtbovwfnk2z</guid>
      <pubDate>Thu, 30 Jul 2026 01:23:01 +0000</pubDate>
      <dc:creator>tim.staging.nooker.app</dc:creator>
      <content:encoded>&lt;h2&gt;반가워요&lt;/h2&gt;&#xA;&lt;p&gt;&lt;strong&gt;굵기&lt;/strong&gt; 테스트&lt;/p&gt;&#xA;&lt;ul&gt;&#xA;&lt;li&gt;항목&lt;/li&gt;&#xA;&lt;li&gt;테스트&lt;/li&gt;&#xA;&lt;/ul&gt;&#xA;</content:encoded>
    </item>
  </channel>
</rss>

"""

    static let atom = """
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xml:lang="en">
  <id>at://did:plc:z3l3putcqv5wpkbohmft5x32/app.nooker.publication/3mrt7uevdd22z</id>
  <title>tim</title>
  <link href="https://staging.nooker.app/@tim" rel="alternate" type="text/html"></link>
  <link href="https://staging.nooker.app/@tim/atom.xml" rel="self" type="application/atom+xml"></link>
  <updated>2026-07-30T01:23:01Z</updated>
  <icon>https://staging.nooker.app/icon.png</icon>
  <logo>https://staging.nooker.app/icon.png</logo>
  <author>
    <name>tim.staging.nooker.app</name>
  </author>
  <entry>
    <id>at://did:plc:z3l3putcqv5wpkbohmft5x32/app.nooker.article/3mrtbovwfnk2z</id>
    <title>Hello nook</title>
    <link href="https://staging.nooker.app/@tim/hellonook" rel="alternate" type="text/html"></link>
    <published>2026-07-30T01:23:01Z</published>
    <updated>2026-07-30T01:23:01Z</updated>
    <content type="html">&lt;h2&gt;반가워요&lt;/h2&gt;&#xA;&lt;p&gt;&lt;strong&gt;굵기&lt;/strong&gt; 테스트&lt;/p&gt;&#xA;&lt;ul&gt;&#xA;&lt;li&gt;항목&lt;/li&gt;&#xA;&lt;li&gt;테스트&lt;/li&gt;&#xA;&lt;/ul&gt;&#xA;</content>
  </entry>
</feed>

"""
}
