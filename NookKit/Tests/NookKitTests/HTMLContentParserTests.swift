import Foundation
import Testing
@testable import NookKit

@Suite("Native article HTML blocks")
struct HTMLContentParserTests {
    @Test("Consecutive paragraphs become separate blocks")
    func splitsParagraphRuns() {
        // These used to arrive as one block whose internal paragraph breaks were
        // carried by NSParagraphStyle.paragraphSpacing — an attribute SwiftUI's
        // Text ignores, so the paragraphs ran together at every font size.
        let blocks = HTMLContentParser.parse(
            "<p>First paragraph.</p>\n<p>Second <em>paragraph</em>.</p>  <p>Third.</p>",
            baseURL: nil
        )

        #expect(blocks.count == 3)
        for (index, expected) in ["First", "Second", "Third"].enumerated() {
            guard case .text(let html) = blocks[index] else {
                Issue.record("Block \(index) is not text: \(blocks[index])")
                continue
            }
            #expect(html.contains(expected))
        }
    }

    @Test("Paragraph splitting survives inline markup the source left unclosed")
    func splitsDespiteUnclosedInlineTags() {
        let blocks = HTMLContentParser.parse("<p>One <b>bold</p><p>Two</p>", baseURL: nil)

        #expect(blocks.count == 2)
    }

    @Test("A paragraph run keeps its place among structural blocks")
    func splitParagraphsStayInDocumentOrder() {
        let blocks = HTMLContentParser.parse(
            "<p>Intro one.</p><p>Intro two.</p><h2>Heading</h2><p>Body one.</p><p>Body two.</p>",
            baseURL: nil
        )

        #expect(blocks.count == 5)
        guard case .text = blocks[0], case .text = blocks[1],
              case .heading(let level, _) = blocks[2],
              case .text = blocks[3], case .text = blocks[4] else {
            Issue.record("Unexpected order: \(blocks)")
            return
        }
        #expect(level == 2)
    }

    @Test("Markup outside the paragraph model is left as one block")
    func leavesLooserMarkupIntact() {
        // Each of these is something NativeInlineHTMLRenderer.tokenize also
        // declines to interpret, so the parser must not split them either — the
        // two have to agree on what a paragraph is.
        let cases = [
            "Loose text <p>and a paragraph.</p>",
            "<p>Implied close.<p>Second.",
            "<div>Paragraph-shaped div.</div><div>Another.</div>",
            "<p>Trailing text after.</p> and then more prose",
            "Just one run of prose with no paragraph tags at all",
        ]
        for html in cases {
            let blocks = HTMLContentParser.parse(html, baseURL: nil)
            #expect(blocks.count == 1, "expected a single block for: \(html) — got \(blocks.count)")
        }
    }

    @Test("Empty paragraphs are dropped rather than becoming blank blocks")
    func dropsEmptyParagraphs() {
        let blocks = HTMLContentParser.parse("<p>Real text.</p><p></p><p>   </p><p>More.</p>", baseURL: nil)

        #expect(blocks.count == 2)
    }

    @Test("Preserves CSS-Tricks-style media in article order")
    func preservesRichMedia() throws {
        let html = """
        <p>Before the examples.</p>
        <div><iframe src="//codepen.io/anon/embed/demo" height="450" title="CodePen Demo">Fallback</iframe></div>
        <figure><img width="1200" height="800" src="https://images.example.com/hero.png?a=1&#038;b=2"><figcaption>Image <strong>caption</strong>.</figcaption></figure>
        <figure><video width="1358" height="940" controls src="/media/demo.mp4"></video><figcaption>Video source.</figcaption></figure>
        <p>After the examples.</p>
        """

        let blocks = HTMLContentParser.parse(html, baseURL: URL(string: "https://example.com/article")!)

        #expect(blocks.count == 5)
        guard case .text(let before) = blocks[0],
              case .embed(let embed) = blocks[1],
              case .image(let image) = blocks[2],
              case .video(let video) = blocks[3],
              case .text(let after) = blocks[4] else {
            Issue.record("Unexpected block order: \(blocks)")
            return
        }
        #expect(before.contains("Before the examples"))
        #expect(embed.url.absoluteString == "https://codepen.io/anon/embed/demo")
        #expect(embed.title == "CodePen Demo")
        #expect(image.url.absoluteString == "https://images.example.com/hero.png?a=1&b=2")
        #expect(image.caption == "Image caption.")
        #expect(image.aspectRatio == 1.5)
        #expect(video.url.absoluteString == "https://example.com/media/demo.mp4")
        #expect(video.caption == "Video source.")
        #expect(after.contains("After the examples"))
    }

    @Test("Uses lazy image and nested video source URLs")
    func supportsAlternateMediaSources() {
        let html = """
        <img data-lazy-src="/lazy.png" alt="Lazy image">
        <video poster="/poster.jpg"><source src="/movie.mp4"></video>
        """

        let blocks = HTMLContentParser.parse(html, baseURL: URL(string: "https://example.com/posts/1")!)

        guard case .image(let image) = blocks[0], case .video(let video) = blocks[1] else {
            Issue.record("Expected an image followed by a video")
            return
        }
        #expect(image.url.absoluteString == "https://example.com/lazy.png")
        #expect(image.title == "Lazy image")
        #expect(video.url.absoluteString == "https://example.com/movie.mp4")
        #expect(video.posterURL?.absoluteString == "https://example.com/poster.jpg")
    }

    @Test("Splits structural block tags into native blocks")
    func parsesStructuralBlocks() {
        let html = """
        <h2>Section <em>Title</em></h2>
        <p>Intro paragraph.</p>
        <blockquote><p>Quoted line.</p></blockquote>
        <pre><code class="language-swift">let x = 1\nlet y = 2</code></pre>
        <hr>
        <table>
        <thead><tr><th>Name</th><th>Value</th></tr></thead>
        <tbody><tr><td>Alpha</td><td>1</td></tr></tbody>
        </table>
        <audio src="/clip.mp3" title="Clip"></audio>
        """

        let blocks = HTMLContentParser.parse(html, baseURL: URL(string: "https://example.com/post")!)

        guard case .heading(let level, let headingHTML) = blocks[0] else {
            Issue.record("Expected a heading first: \(blocks)")
            return
        }
        #expect(level == 2)
        #expect(headingHTML.contains("Title"))

        guard case .text(let intro) = blocks[1] else {
            Issue.record("Expected intro text")
            return
        }
        #expect(intro.contains("Intro paragraph"))

        guard case .blockquote(let quoted) = blocks[2], case .text(let quotedText) = quoted[0] else {
            Issue.record("Expected a blockquote with nested text")
            return
        }
        #expect(quotedText.contains("Quoted line"))

        guard case .codeBlock(let code, let language) = blocks[3] else {
            Issue.record("Expected a code block")
            return
        }
        #expect(language == "swift")
        #expect(code == "let x = 1\nlet y = 2")

        guard case .thematicBreak = blocks[4] else {
            Issue.record("Expected a thematic break")
            return
        }

        guard case .table(let table) = blocks[5] else {
            Issue.record("Expected a table")
            return
        }
        let headerRowAllHeaders = table.rows[0].cells.allSatisfy { $0.isHeader }
        let bodyRowHasHeader = table.rows[1].cells.contains { $0.isHeader }
        let bodyRowHasAlpha = table.rows[1].cells.map(\.html).contains("Alpha")
        #expect(table.rows.count == 2)
        #expect(headerRowAllHeaders)
        #expect(table.rows[0].cells.map(\.html) == ["Name", "Value"])
        #expect(!bodyRowHasHeader)
        #expect(bodyRowHasAlpha)

        guard case .audio(let audio) = blocks[6] else {
            Issue.record("Expected an audio block")
            return
        }
        #expect(audio.url.absoluteString == "https://example.com/clip.mp3")
        #expect(audio.title == "Clip")
    }

    @Test("Table cells keep colspan/rowspan and per-cell header flags")
    func parsesTableSpans() {
        let html = """
        <table>
        <tr><th colspan="2">Header</th></tr>
        <tr><td rowspan="2">Left</td><td>A</td></tr>
        <tr><td>B</td></tr>
        </table>
        """
        let blocks = HTMLContentParser.parse(html, baseURL: nil)
        guard case .table(let table) = blocks.first else {
            Issue.record("Expected a table")
            return
        }
        #expect(table.rows.count == 3)
        // Header row: one <th> spanning two columns.
        #expect(table.rows[0].cells.count == 1)
        #expect(table.rows[0].cells[0].isHeader)
        #expect(table.rows[0].cells[0].colSpan == 2)
        // Second row: a rowspan=2 cell followed by a normal cell.
        #expect(table.rows[1].cells[0].html == "Left")
        #expect(table.rows[1].cells[0].rowSpan == 2)
        #expect(table.rows[1].cells[0].colSpan == 1)
        #expect(!table.rows[1].cells[0].isHeader)
        // Third row has just the one remaining cell (the rowspan reserves column 0).
        #expect(table.rows[2].cells.count == 1)
        #expect(table.rows[2].cells[0].html == "B")
    }

    @Test("Lists become native blocks, keeping nested lists and media inside items")
    func parsesListsWithNesting() {
        let html = """
        <p>Intro.</p>
        <ul>
        <li>First item</li>
        <li>Second with <img src="/in-list.png" alt="inline">
        <ol><li>Nested one</li><li>Nested two</li></ol>
        </li>
        </ul>
        <p>Outro.</p>
        """

        let blocks = HTMLContentParser.parse(html, baseURL: URL(string: "https://example.com/post")!)

        // The top-level list must not be split by the nested list or the image.
        guard case .text = blocks[0], case .list(let ordered, let items) = blocks[1], case .text = blocks[2] else {
            Issue.record("Expected text, list, text: \(blocks)")
            return
        }
        #expect(!ordered)
        #expect(items.count == 2)

        // First item is plain text.
        guard case .text(let first) = items[0][0] else {
            Issue.record("Expected text in the first item")
            return
        }
        #expect(first.contains("First item"))

        // Second item keeps its image and its nested ordered list inside it.
        let second = items[1]
        #expect(second.contains { if case .image = $0 { return true } else { return false } })
        guard let nested = second.first(where: { if case .list = $0 { return true } else { return false } }),
              case .list(let nestedOrdered, let nestedItems) = nested else {
            Issue.record("Expected a nested list inside the second item: \(second)")
            return
        }
        #expect(nestedOrdered)
        #expect(nestedItems.count == 2)
    }

    @Test("Decodes entities in code blocks without collapsing whitespace")
    func preservesCodeFormatting() {
        let html = "<pre><code>if (a &lt; b) {\n    return &amp;value;\n}</code></pre>"

        let blocks = HTMLContentParser.parse(html, baseURL: nil)

        guard case .codeBlock(let code, _) = blocks[0] else {
            Issue.record("Expected a code block: \(blocks)")
            return
        }
        #expect(code == "if (a < b) {\n    return &value;\n}")
    }

    @Test("Reader script retains interactive embeds and has a semantic fallback")
    func readerScriptRichContentFallbacks() {
        let script = ArticleWebView(
            url: URL(string: "https://example.com/article")!,
            useReaderMode: true,
            style: ReaderStyle(),
            linkOpensInApp: true
        ).readerScript(style: ReaderStyle())

        #expect(script.contains("codepen"))
        #expect(script.contains("article .article-content"))
        #expect(script.contains("normalizeMedia"))
        #expect(script.contains("attempts < 3"))
    }

    // The markup below is copied from https://nooker.app/@tim/hello-nook, which is
    // where this was found: the table of contents jumped for English headings and
    // did nothing for Korean ones.
    //
    // The reason is visible in the pair — a fragment in an `href` is percent-encoded
    // and an `id` attribute is not, so they are equal as strings only when encoding
    // leaves the text alone. Which is to say, only for ASCII.
    @Test("A table of contents jumps to a heading that is not ASCII")
    func tableOfContentsResolvesAnEncodedFragment() {
        let html = """
        <ul>
        <li><a href="#%EB%A7%8C%EB%93%A4%EA%B2%8C-%EB%90%9C-%EC%9D%B4%EC%9C%A0">만들게 된 이유</a></li>
        <li><a href="#nook-plus">Nook Plus</a></li>
        </ul>
        <h2 id="만들게-된-이유">만들게 된 이유</h2>
        <p>본문</p>
        <h2 id="nook-plus">Nook Plus</h2>
        <p>본문</p>
        """
        let parsed = HTMLContentParser.parseWithAnchors(html, baseURL: nil)

        #expect(anchorIndex(for: "nook-plus", in: parsed.anchors) != nil)
        #expect(
            anchorIndex(
                for: "%EB%A7%8C%EB%93%A4%EA%B2%8C-%EB%90%9C-%EC%9D%B4%EC%9C%A0",
                in: parsed.anchors
            ) != nil,
            "an encoded fragment did not resolve; only ASCII headings would jump"
        )
    }

    // A link written without encoding still has to work, and the raw form wins:
    // an id may contain a percent sign of its own, and decoding one that was never
    // encoded would send the reader somewhere else.
    @Test("Anchor lookup prefers the literal id and tolerates a stray percent")
    func anchorLookupPrefersTheLiteralIdentifier() {
        let anchors = ["100%-done": 1, "100%-done".removingPercentEncoding ?? "x": 2, "한글": 3]
        #expect(anchorIndex(for: "100%-done", in: anchors) == 1)
        #expect(anchorIndex(for: "한글", in: anchors) == 3)
        #expect(anchorIndex(for: "%ED%95%9C%EA%B8%80", in: anchors) == 3)
        #expect(anchorIndex(for: "missing", in: anchors) == nil)
    }


    // Trimmed from the "Nook Plus?" section of https://nooker.app/@tim/hello-nook,
    // where this was found: pressing footnote 6's back-link flashed the paragraph
    // *below* the one holding the marker.
    //
    // A run between two structural blocks becomes one block per paragraph, and the
    // whole run's ids were being attributed to the last of them.
    @Test("A back-link lands on the paragraph holding its marker, not the run's last")
    func footnoteMarkerResolvesToItsOwnParagraph() {
        let html = """
        <h2 id="nook-plus">Nook Plus?</h2>
        <p>첫 문단입니다.</p>
        <p>marker paragraph<sup id="fnref:6"><a href="#fn:6" class="footnote-ref"         role="doc-noteref">6</a></sup></p>
        <p>뒤따르는 문단입니다.</p>
        <h2 id="next">다음</h2>
        """
        let parsed = HTMLContentParser.parseWithAnchors(html, baseURL: nil)

        guard let index = anchorIndex(for: "fnref:6", in: parsed.anchors) else {
            Issue.record("fnref:6 was not recorded at all")
            return
        }
        guard case .text(let landed) = parsed.blocks[index] else {
            Issue.record("landed on \(parsed.blocks[index]), expected a paragraph")
            return
        }
        #expect(
            landed.contains("marker paragraph"),
            "landed on the wrong paragraph: \(landed)"
        )
    }

    // The heading above that run must keep pointing at itself, so fixing the
    // paragraphs does not shift a structural block's own anchor.
    @Test("A heading's id still resolves to the heading")
    func headingAnchorSurvivesPerParagraphRecording() {
        let html = """
        <h2 id="nook-plus">Nook Plus?</h2>
        <p>하나</p>
        <p>둘</p>
        """
        let parsed = HTMLContentParser.parseWithAnchors(html, baseURL: nil)

        guard let index = anchorIndex(for: "nook-plus", in: parsed.anchors) else {
            Issue.record("the heading id was not recorded")
            return
        }
        guard case .heading(_, let landed) = parsed.blocks[index] else {
            Issue.record("landed on \(parsed.blocks[index]), expected the heading")
            return
        }
        #expect(landed.contains("Nook Plus?"), "landed on \(landed)")
    }

}
