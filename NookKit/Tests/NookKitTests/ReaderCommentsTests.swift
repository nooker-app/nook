import Foundation
import Testing

@testable import NookKit

/// The comment model, and the engine that fills it.
@Suite("Reader comments")
struct ReaderCommentsTests {
    @Test("a body is rendered as markup when it has any")
    func rendersMarkup() {
        let comment = ReaderComment(id: 0, text: "Plain.", html: "<p>Marked <b>up</b>.</p>")
        #expect(comment.renderableHTML == "<p>Marked <b>up</b>.</p>")
    }

    /// The backstop for markup the page-side flattening could not reach. Drawing a
    /// forum's layout table around a comment is worse than the same words without
    /// their paragraphs.
    @Test("a body still wrapped in a table falls back to its text")
    func tableFallsBackToText() {
        let comment = ReaderComment(
            id: 0, text: "The words.", html: "<table><tr><td>The words.</td></tr></table>")
        #expect(comment.renderableHTML == "<p>The words.</p>")
    }

    /// Text reaching markup has to be escaped, or a comment containing `<script>`
    /// becomes one.
    @Test("the text fallback escapes what it interpolates")
    func textFallbackEscapes() {
        let comment = ReaderComment(
            id: 0, text: "a < b & <script>alert(1)</script>",
            html: "<table><tr><td>x</td></tr></table>")
        let html = try? #require(comment.renderableHTML)
        #expect(html?.contains("<script>") == false)
        #expect(html?.contains("&lt;script&gt;") == true)
        #expect(html?.contains("&amp;") == true)
    }

    @Test("a comment with neither markup nor text has nothing to render")
    func emptyRendersNothing() {
        #expect(ReaderComment(id: 0).renderableHTML == nil)
    }

    // MARK: - Time

    /// legibility has no clock and never parses a timestamp, so the reader does — and
    /// only when the page wrote something a clock can read.
    @Test("an ISO timestamp becomes an instant")
    func parsesISOTimestamps() {
        #expect(ReaderComment(id: 0, timestamp: "2026-08-01T10:00:00Z").postedAt != nil)
        #expect(ReaderComment(id: 0, timestamp: "2026-07-24T00:03:38.142Z").postedAt != nil)
        #expect(ReaderComment(id: 0, timestamp: "2026-08-05T23:36:25+09:00").postedAt != nil)
    }

    /// A page that wrote "3 hours ago" stated a time relative to a moment nobody
    /// recorded. Shown verbatim rather than resolved against this device's clock,
    /// which would be a different answer every time the article is opened.
    @Test("a relative timestamp is not turned into an instant")
    func leavesRelativeTimestampsAlone() {
        #expect(ReaderComment(id: 0, timestamp: "3 hours ago").postedAt == nil)
        #expect(ReaderComment(id: 0, timestamp: "").postedAt == nil)
        #expect(ReaderComment(id: 0).postedAt == nil)
    }

    // MARK: - The thread

    @Test("a thread reports what it is not showing")
    func reportsWhatIsMissing() {
        let items = (0..<3).map { ReaderComment(id: $0, html: "<p>\($0)</p>") }

        // The page said how many it had, and the markup carried fewer.
        let short = ReaderCommentThread(items: items, count: 3, claimedTotal: 40)
        #expect(short.missing == 37)

        // Nothing claimed: `count` is the only number there is.
        let whole = ReaderCommentThread(items: items, count: 3)
        #expect(whole.missing == 0)

        // A page claiming fewer than it carried is not a reason to report a negative.
        let odd = ReaderCommentThread(items: items, count: 3, claimedTotal: 1)
        #expect(odd.missing == 0)
    }

    /// `depth_source: "Flat"` means the page carried no reply structure at all.
    /// Indenting by a made-up number would be a claim about the conversation's shape
    /// that nothing supports.
    @Test("replies are only indented where the page said how deep they are")
    func indentsOnlyRealDepths() {
        let items = [ReaderComment(id: 0), ReaderComment(id: 1, depth: 1)]
        #expect(ReaderCommentThread(items: items, count: 2, depthSource: "CssVariable").showsDepth)
        #expect(ReaderCommentThread(items: items, count: 2, depthSource: "DomNesting").showsDepth)
        #expect(ReaderCommentThread(items: items, count: 2, depthSource: "Flat").showsDepth == false)
        #expect(ReaderCommentThread(items: items, count: 2, depthSource: nil).showsDepth == false)
    }

    @Test("a thread survives a round trip through its stored form")
    func roundTrip() throws {
        let thread = ReaderCommentThread(
            items: [
                ReaderComment(
                    id: 0, author: "ada", timestamp: "2026-08-01T10:00:00Z", depth: 0,
                    permalink: "#c1", text: "First.", html: "<p>First.</p>"),
                ReaderComment(
                    id: 1, author: "grace", depth: 1, parent: 0, isDeleted: true, text: ""),
            ],
            count: 2, claimedTotal: 2, isTruncated: false, depthSource: "CssVariable")
        let decoded = try JSONDecoder().decode(
            ReaderCommentThread.self, from: try JSONEncoder().encode(thread))
        #expect(decoded == thread)
        #expect(decoded.items[1].parent == 0)
        #expect(decoded.items[1].isDeleted)
    }
}

/// The engine reading a real discussion out of real markup.
///
/// Two page shapes, because they fail differently: one marks its thread up
/// semantically and one builds it out of nested tables, and the table one is why the
/// extraction flattens layout markup before the reader ever sees it.
@MainActor
@Suite("Legibility comments")
struct LegibilityCommentsTests {
    /// A body long enough that nothing mistakes the page for an index.
    static let articleBody = "<p>"
        + String(repeating: "The article itself, with enough prose that nothing mistakes it for a list of links. ", count: 8)
        + "</p>"

    static func semanticPage() -> String {
        func comment(_ n: Int, _ depth: Int, _ author: String, _ when: String, _ text: String) -> String {
            """
            <li class="comment-tree-item" id="comment-\(n)">
              <article class="comment" style="--comment-depth:\(depth)">
                <div class="comment-meta">
                  <a class="comment-author" href="/u/\(author)">\(author)</a>
                  <time datetime="\(when)">\(when)</time>
                </div>
                <div class="comment-body"><p>\(text)</p></div>
              </article>
            </li>
            """
        }
        return """
            <!doctype html>
            <html lang="en"><head><meta charset="utf-8"><title>A post — Somebody</title>
            <meta property="og:site_name" content="Somebody"></head>
            <body>
            <article><h1>A post</h1>\(articleBody)</article>
            <section class="comments"><h2>Comments</h2>
            <ol class="comment-tree">
            \(comment(1, 0, "ada", "2026-08-01T10:00:00Z", "First, a top-level remark about the piece."))
            \(comment(2, 1, "grace", "2026-08-01T10:05:00Z", "A reply to Ada, agreeing with the remark."))
            \(comment(3, 2, "linus", "2026-08-01T10:09:00Z", "A reply to the reply, going one deeper."))
            \(comment(4, 0, "edsger", "2026-08-01T10:20:00Z", "A second top-level remark, unrelated."))
            </ol></section>
            </body></html>
            """
    }

    @Test("a semantic thread comes back with its authors, times and shape")
    func semanticThread() async throws {
        guard case .article(let extraction) = await LegibilityEngine().extract(
            document: Self.semanticPage())
        else {
            Issue.record("expected an article")
            return
        }
        let thread = try #require(extraction.comments, "the page's discussion should have come back")

        #expect(thread.items.count == 4)
        #expect(thread.count == 4)
        #expect(thread.items.map(\.author) == ["ada", "grace", "linus", "edsger"])
        #expect(thread.items.map(\.depth) == [0, 1, 2, 0])
        // `parent` is an index into `items`, and always points backwards — which is
        // what makes keeping a prefix of a long thread safe.
        #expect(thread.items.map(\.parent) == [nil, 0, 1, nil])
        #expect(thread.items.allSatisfy { ($0.parent ?? -1) < $0.id })
        #expect(thread.showsDepth, "the page stated its depths in a CSS variable")
        #expect(thread.items[0].postedAt != nil)
        #expect(thread.items[0].renderableHTML?.contains("top-level remark") == true)
        #expect(thread.items[0].permalink == "#comment-1")
    }

    /// The article body must not swallow the thread, or the reader would draw every
    /// comment twice — once as prose and once as a comment.
    @Test("the comments are not in the article body")
    func commentsAreNotInTheArticle() async throws {
        guard case .article(let extraction) = await LegibilityEngine().extract(
            document: Self.semanticPage())
        else {
            Issue.record("expected an article")
            return
        }
        #expect(!extraction.html.contains("A reply to Ada"))
        #expect(extraction.html.contains("The article itself"))
    }

    /// Hacker News builds its thread out of a table per reply. Left alone, the native
    /// renderer drew a one-cell grid around every comment, so the extraction flattens
    /// layout markup on the page — where there is a DOM to do it in — before the
    /// thread crosses into Swift.
    @Test("a table-built thread arrives without its layout tables")
    func tableLayoutIsFlattened() async throws {
        // Reproduced down to the reply link: each row has to carry the same
        // sub-structure as its siblings for the thread to read as one repeated group,
        // and a row stripped of it was picked as the *article* instead.
        func row(_ n: Int, _ indent: Int, _ author: String, _ text: String) -> String {
            """
            <tr class="comtr" id="c\(n)"><td><table><tbody><tr>
               <td class="ind" indent="\(indent)"><img src="s.gif" width="\(indent * 40)" height="1"></td>
               <td class="votelinks"><center><a href="vote?id=\(n)"><div class="votearrow"></div></a></center></td>
               <td class="default"><div><span class="comhead"><a href="user?id=\(author)" class="hnuser">\(author)</a>
               <span class="age" title="2026-08-01T10:0\(n):00"><a href="item?id=\(n)">\(n) minutes ago</a></span></span></div><br>
               <div class="comment"><div class="commtext c00">\(text)</div><div class="reply"><p><a href="reply?id=\(n)">reply</a></p></div></div>
               </td></tr></tbody></table></td></tr>
            """
        }
        let page = """
            <!doctype html>
            <html><head><meta charset="utf-8"><title>A submission | Hacker News</title></head>
            <body><center><table id="hnmain"><tbody>
            <tr><td><table class="fatitem"><tbody><tr><td>
            <span class="titleline"><a href="https://example.com/post">A submission</a></span></td></tr></tbody></table></td></tr>
            <tr><td><table class="comment-tree"><tbody>
            \(row(1, 0, "ada", "A first remark, table-wrapped the way this site does it."))
            \(row(2, 1, "grace", "A reply, one indent step in."))
            \(row(3, 0, "edsger", "A second top-level remark, also in a table."))
            </tbody></table></td></tr>
            </tbody></table></center></body></html>
            """

        guard case .article(let extraction) = await LegibilityEngine().extract(document: page) else {
            Issue.record("expected the submission to extract")
            return
        }
        let thread = try #require(extraction.comments)
        #expect(thread.items.count == 3)
        #expect(thread.items.map(\.depth) == [0, 1, 0], "indentation width is the depth here")

        for comment in thread.items {
            let html = try #require(comment.renderableHTML)
            #expect(
                !html.localizedCaseInsensitiveContains("<table"),
                "layout tables must be flattened on the page, not drawn as a grid")
            #expect(!html.localizedCaseInsensitiveContains("<td"))
        }
        #expect(thread.items[0].renderableHTML?.contains("A first remark") == true)
    }

    /// A page with no discussion must not produce an empty section under the article.
    @Test("an article with no comments has no thread")
    func noCommentsMeansNoThread() async throws {
        let page = """
            <!doctype html>
            <html lang="en"><head><meta charset="utf-8"><title>A post</title></head>
            <body><article><h1>A post</h1>\(Self.articleBody)</article></body></html>
            """
        guard case .article(let extraction) = await LegibilityEngine().extract(document: page) else {
            Issue.record("expected an article")
            return
        }
        #expect(extraction.comments == nil)
        #expect(extraction.commentCount == 0)
    }

    /// A thread longer than the cap comes back as a prefix, and says so.
    ///
    /// A prefix and not a sample, because `parent` is an index into the array: a
    /// parent always precedes its reply, so cutting the tail keeps every kept item's
    /// parent with it. Cutting anywhere else would leave replies pointing at nothing.
    @Test("a thread past the cap is cut from the end, and reports the remainder")
    func longThreadIsCapped() async throws {
        let over = LegibilityEngine.maxComments + 12
        let items = (1...over).map { n in
            """
            <li class="comment-tree-item" id="comment-\(n)">
              <article class="comment" style="--comment-depth:\(n % 3)">
                <div class="comment-meta">
                  <a class="comment-author" href="/u/reader\(n)">reader\(n)</a>
                  <time datetime="2026-08-01T10:00:00Z">2026-08-01T10:00:00Z</time>
                </div>
                <div class="comment-body"><p>Remark number \(n), with enough words to be a remark.</p></div>
              </article>
            </li>
            """
        }.joined(separator: "\n")
        let page = """
            <!doctype html>
            <html lang="en"><head><meta charset="utf-8"><title>A busy post</title></head>
            <body>
            <article><h1>A busy post</h1>\(Self.articleBody)</article>
            <section class="comments"><ol class="comment-tree">\(items)</ol></section>
            </body></html>
            """

        guard case .article(let extraction) = await LegibilityEngine().extract(document: page) else {
            Issue.record("expected an article")
            return
        }
        let thread = try #require(extraction.comments)

        #expect(thread.items.count == LegibilityEngine.maxComments)
        #expect(thread.count == over, "the page's real total is still reported")
        #expect(thread.isTruncated)
        #expect(thread.missing == 12)
        // The invariant the prefix rests on.
        #expect(thread.items.allSatisfy { ($0.parent ?? -1) < $0.id })
        #expect(thread.items.first?.author == "reader1")
        #expect(thread.items.last?.author == "reader\(LegibilityEngine.maxComments)")
    }

    /// Readability reads an article body and nothing else, so an article read with it
    /// has no discussion — which is why the setting's copy says so.
    @Test("only legibility is asked for comments")
    func readabilityCarriesNoComments() {
        // The Readability driver's payload has no comment field at all: the outcome it
        // builds is `.init(html:engine:)`, whose `comments` defaults to nil.
        let extracted = ReaderModeExtractor.Extracted(html: "<p>Body.</p>", engine: .readability)
        #expect(extracted.comments == nil)
    }
}
