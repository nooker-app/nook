import Foundation
import Testing
@testable import NookKit

#if canImport(AppKit)
import AppKit
private typealias PlatformFont = NSFont
#elseif canImport(UIKit)
import UIKit
private typealias PlatformFont = UIFont
#endif

/// The native renderer's whole contract is "byte-identical text, same final
/// attributes, or nil". These tests pin the attribute mapping, the whitelist
/// gate (everything unsupported must return nil, never a wrong render), and —
/// on macOS, where the WebKit importer is available in tests — differential
/// string equality against the classic pipeline for the supported corpus.
@Suite("Native inline HTML renderer")
struct NativeInlineHTMLRendererTests {
    private let bodySize: CGFloat = 16

    private func render(_ html: String, baseSize: CGFloat = 16, bold: Bool = false) -> AttributedString? {
        NativeInlineHTMLRenderer.importPrepared(
            HTMLTextFlow.preparedHTML(html), baseSize: baseSize, bold: bold
        )
    }

    private func plain(_ attributed: AttributedString) -> String {
        String(attributed.characters)
    }

    private func fonts(of attributed: AttributedString) -> [(text: String, font: PlatformFont)] {
        attributed.runs.compactMap { run in
            #if canImport(AppKit)
            guard let font = run.appKit.font else { return nil }
            #else
            guard let font = run.uiKit.font else { return nil }
            #endif
            return (String(attributed.characters[run.range]), font)
        }
    }

    // MARK: - Structure

    @Test("Plain text renders as one run at body size")
    func plainText() throws {
        let result = try #require(render("Hello world"))
        #expect(plain(result) == "Hello world")
        let runFonts = fonts(of: result)
        #expect(runFonts.count == 1)
        #expect(runFonts[0].font.pointSize == bodySize)
    }

    @Test("Paragraphs join with a single newline and no trailing spacing")
    func paragraphs() throws {
        let result = try #require(render("<p>First</p><p>Second</p>"))
        #expect(plain(result) == "First\nSecond")
    }

    @Test("br becomes a soft line break; surrounding spaces stay (WebKit parity)")
    func lineBreak() throws {
        let result = try #require(render("one <br> two"))
        #expect(plain(result) == "one \u{2028} two")
    }

    @Test("Whitespace collapses like CSS white-space normal")
    func whitespaceCollapse() throws {
        let result = try #require(render("  a \n\t b   c  "))
        #expect(plain(result) == "a b c")
    }

    @Test("Whitespace collapses inside code too")
    func whitespaceInCode() throws {
        let result = try #require(render("<code>let  x</code>"))
        #expect(plain(result) == "let x")
    }

    // MARK: - Inline styles

    @Test("Bold and italic map to symbolic traits, nested correctly")
    func boldItalic() throws {
        let result = try #require(render("a <b>b <i>c</i></b>"))
        #expect(plain(result) == "a b c")
        let runFonts = fonts(of: result)
        #expect(runFonts.count == 3)
        #if canImport(AppKit)
        #expect(!runFonts[0].font.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(runFonts[1].font.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(!runFonts[1].font.fontDescriptor.symbolicTraits.contains(.italic))
        #expect(runFonts[2].font.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(runFonts[2].font.fontDescriptor.symbolicTraits.contains(.italic))
        #else
        #expect(!runFonts[0].font.fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(runFonts[1].font.fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(runFonts[2].font.fontDescriptor.symbolicTraits.contains(.traitItalic))
        #endif
    }

    @Test("The bold parameter (headings, table headers) applies everywhere")
    func boldParameter() throws {
        let result = try #require(render("plain", bold: true))
        let font = try #require(fonts(of: result).first?.font)
        #if canImport(AppKit)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
        #else
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
        #endif
    }

    @Test("Inline code uses the shared mono font at 0.92x and the pink tint")
    func inlineCode() throws {
        let result = try #require(render("run <code>swift test</code> now"))
        #expect(plain(result) == "run swift test now")
        let codeRun = try #require(result.runs.first { run in
            #if canImport(AppKit)
            (run.appKit.foregroundColor) == NSColor.systemPink
            #else
            (run.uiKit.foregroundColor) == UIColor.systemPink
            #endif
        })
        #if canImport(AppKit)
        let font = try #require(codeRun.appKit.font)
        #expect(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
        #else
        let font = try #require(codeRun.uiKit.font)
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        #endif
        #expect(font.pointSize == bodySize * 0.92)
    }

    @Test("Bold code keeps semibold weight (no trait round-trip loss)")
    func boldCode() throws {
        let result = try #require(render("<b><code>x</code></b>"))
        let font = try #require(fonts(of: result).first?.font)
        let expected = HTMLContentText.finalCodeFont(baseSize: bodySize, bold: true)
        #expect(font == expected)
    }

    @Test("Links carry the URL, accent color, and the soft underline")
    func links() throws {
        let result = try #require(render(#"<a href="https://example.com/a?b=1&amp;c=2">link</a>"#))
        #expect(plain(result) == "link")
        let run = try #require(result.runs.first)
        #expect(run.link == URL(string: "https://example.com/a?b=1&c=2"))
        #if canImport(AppKit)
        #expect(run.appKit.underlineStyle != nil)
        #expect(run.appKit.foregroundColor == NSColor.controlAccentColor)
        #endif
    }

    @Test("Code inside a link stays pink (tail ordering) but keeps the link")
    func codeInLink() throws {
        let result = try #require(render(#"<a href="https://example.com"><code>x</code></a>"#))
        let run = try #require(result.runs.first)
        #expect(run.link != nil)
        #if canImport(AppKit)
        #expect(run.appKit.foregroundColor == NSColor.systemPink)
        #else
        #expect(run.uiKit.foregroundColor == UIColor.systemPink)
        #endif
    }

    // MARK: - Entities

    @Test("Entities decode: named, numeric, hex, and nbsp as U+00A0")
    func entities() throws {
        #expect(plain(try #require(render("a &amp; b"))) == "a & b")
        #expect(plain(try #require(render("&lt;tag&gt;"))) == "<tag>")
        #expect(plain(try #require(render("&#65;&#x42;"))) == "AB")
        #expect(plain(try #require(render("a&nbsp;b"))) == "a\u{00A0}b")
        #expect(plain(try #require(render("&ldquo;q&rdquo;"))) == "\u{201C}q\u{201D}")
    }

    @Test("Double-encoded entities decode exactly once")
    func doubleEncoded() throws {
        #expect(plain(try #require(render("&amp;lt;"))) == "&lt;")
    }

    @Test("A bare ampersand is literal; ambiguous entity-like text bails")
    func bareAmpersand() throws {
        #expect(plain(try #require(render("fish & chips"))) == "fish & chips")
        // Unknown/legacy entities must fall back, never guess.
        #expect(render("&bogus;") == nil)
        #expect(render("&nbsp") == nil)
    }

    // MARK: - The gate: everything unsupported returns nil

    @Test("Unsupported constructs bail to the WebKit path", arguments: [
        "<div>block</div>",
        "<u>underline</u>",
        "<s>strike</s>",
        "<mark>hi</mark>",
        "<img src=\"x.png\">",
        "<table><tr><td>c</td></tr></table>",
        "<p style=\"color:red\">styled</p>",
        "<span style=\"background:yellow\">styled</span>",
        "<a href=\"https://e.com\" onclick=\"x()\">js</a>",
        "<a>no href</a>",
        "<a href=\"\">empty href</a>",
        "<!-- comment -->text",
        "<b>unclosed",
        "unopened</b>",
        "<b><i>misnested</b></i>",
        "<p><p>nested</p></p>",
        "loose <p>mixed</p>",
        "<p>a</p> trailing loose",
        "<span/>self-closing",
        "&#xD800;",
        "עברית",
        "<b dir=\"rtl\">attr</b>",
        // Windows-1252 numeric range: WebKit remaps these per HTML5; we bail.
        "don&#146;t",
        "&#147;quote&#148;",
        "n&#0;l",
        "tab&#9;entity",
        // Entity-encoded RTL bypassing the raw-scalar gate.
        "&#x5D0;&#x5D1;",
        // Nested anchor: WebKit auto-closes the outer one.
        #"<a href="https://a.com">x<a href="https://b.com">y</a>z</a>"#,
        // Relative / scheme-less hrefs import with NO link under WebKit. A
        // fragment is the one exception and is covered below: it points inside this
        // document rather than at another one.
        #"<a href="/relative/path">rel</a>"#,
    ])
    func unsupportedBails(_ html: String) {
        #expect(render(html) == nil)
    }

    @Test("Ignorable attributes (class/id, anchor cosmetics) are accepted")
    func ignorableAttributes() throws {
        #expect(render(#"<span class="x" id="y">ok</span>"#) != nil)
        #expect(render(#"<a href="https://e.com" title="t" rel="nofollow" target="_blank">ok</a>"#) != nil)
    }

    @Test("Empty and whitespace-only fragments return nil (fallback decides)")
    func emptyFragments() {
        #expect(render("") == nil)
        #expect(render("   \n  ") == nil)
        #expect(render("<p></p>") == nil)
    }

    @Test("CJK, emoji, and combining marks pass through unchanged")
    func unicodeContent() throws {
        let text = "한국어 テスト 中文 🦉 éé"
        #expect(plain(try #require(render(text))) == text)
    }

    // MARK: - Robustness (never crash, nil or valid output)

    @Test("Random mutations never crash the tokenizer")
    func fuzz() {
        let corpus = [
            "a <b>b <i>c</i></b> <a href=\"https://e.com?a=1&amp;b=2\">d</a> <code>e</code>",
            "<p>First &amp; second</p><p>Third&nbsp;fourth</p>",
            "one <br> two &#x1F600; three",
        ]
        var seed: UInt64 = 0x5eed
        func nextRandom(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33) % bound
        }
        for source in corpus {
            for _ in 0..<400 {
                var mutated = Array(source.unicodeScalars)
                let mutations = 1 + nextRandom(4)
                for _ in 0..<mutations where !mutated.isEmpty {
                    switch nextRandom(3) {
                    case 0: mutated.remove(at: nextRandom(mutated.count))
                    case 1: mutated.insert(["<", ">", "&", ";", "\"", "/"][nextRandom(6)], at: nextRandom(mutated.count + 1))
                    default: mutated = Array(mutated.prefix(nextRandom(mutated.count + 1)))
                    }
                }
                var text = ""
                text.unicodeScalars.append(contentsOf: mutated)
                _ = render(text) // must not crash; nil or valid are both fine
            }
        }
    }

    // MARK: - Differential parity against the WebKit importer (macOS)

    #if canImport(AppKit)
    /// The corpus every whitelisted construct must pass before shipping: the
    /// native output's text content must equal the classic pipeline's exactly
    /// (selection/copy and the placeholder height math depend on it).
    @Test("Differential: native text content equals the WebKit pipeline", .serialized, arguments: [
        "Hello world",
        "a <b>bold</b> and <i>italic</i> tail",
        "<strong>s</strong> <em>e</em>",
        "nested <b>bold <i>both</i></b> plain",
        "<p>First paragraph</p><p>Second paragraph</p>",
        "<p>Only one paragraph</p>",
        "line one <br> line two",
        "inline <code>let x = 1</code> code",
        "<b><code>bold code</code></b>",
        #"a <a href="https://example.com/path?a=1&amp;b=2">link</a> b"#,
        #"<a href="https://example.com"><code>linked code</code></a>"#,
        #"<a href="https://example.com">host-only link</a>"#,
        "entities &amp; &lt; &gt; &quot; &#65; &#x42;",
        "nbsp a&nbsp;b end",
        "dashes &mdash; &ndash; &hellip; quotes &lsquo;&rsquo; &ldquo;&rdquo;",
        "&copy; &reg; &trade; &deg; &times; &middot;",
        "  leading and trailing   whitespace  ",
        "multi   internal    spaces",
        "한국어 텍스트와 <b>볼드</b> 혼합",
        "emoji 🦉 and combining e\u{0301}",
        #"<span class="x">span content</span>"#,
        "tab\tand\nnewline collapse",
    ])
    @MainActor
    func differentialParity(_ html: String) throws {
        let prepared = HTMLTextFlow.preparedHTML(html)
        // Canary: the WebKit importer needs a usable environment; skip (not
        // fail) on headless runners where it can't import even trivial HTML.
        guard let webKit = HTMLContentText.webKitImport("<b>x</b>", baseSize: 16, bold: false),
              String(webKit.characters) == "x" else { return }

        let native = try #require(NativeInlineHTMLRenderer.importPrepared(prepared, baseSize: 16, bold: false),
                                  "corpus entry must be native-eligible: \(html)")
        let classic = try #require(HTMLContentText.webKitImport(prepared, baseSize: 16, bold: false))
        let nativeText = String(native.characters)
        let classicText = String(classic.characters)
        #expect(nativeText == classicText, "text mismatch for: \(html)")
        guard nativeText == classicText else { return }

        // Attribute parity, character by character (skipping invisible paragraph
        // separators, whose runs may carry differing but unrendered attributes).
        let nativeNS = NSAttributedString(native)
        let classicNS = NSAttributedString(classic)
        let characters = Array(nativeNS.string.utf16)
        for offset in 0..<min(nativeNS.length, classicNS.length) {
            if characters[offset] == 0x0A { continue }
            let n = nativeNS.attributes(at: offset, effectiveRange: nil)
            let c = classicNS.attributes(at: offset, effectiveRange: nil)
            #expect(n[.font] as? NSFont == c[.font] as? NSFont, "font mismatch at \(offset) for: \(html)")
            #expect(n[.foregroundColor] as? NSColor == c[.foregroundColor] as? NSColor, "color mismatch at \(offset) for: \(html)")
            #expect((n[.link] as? URL) == (c[.link] as? URL), "link mismatch at \(offset) for: \(html)")
            #expect((n[.underlineStyle] as? Int) == (c[.underlineStyle] as? Int), "underline mismatch at \(offset) for: \(html)")
        }
    }
    #endif
}


// MARK: - Footnotes and contents

/// Both features the publishing renderer emits and the reader used to flatten: a
/// footnote marker rendered at body size in the middle of a sentence, and a table
/// of contents whose rows looked like links and did nothing.
@Suite("In-document navigation")
struct NativeInlineHTMLAnchorTests {
    private func render(_ html: String) -> AttributedString? {
        NativeInlineHTMLRenderer.importPrepared(
            HTMLTextFlow.preparedHTML(html), baseSize: 16, bold: false)
    }

    /// Platform attributes, read the way the rest of this file reads them.
    private func baselineOffset(_ run: AttributedString.Runs.Element) -> CGFloat {
        #if canImport(AppKit)
        return run.appKit.baselineOffset ?? 0
        #else
        return run.uiKit.baselineOffset ?? 0
        #endif
    }

    private func pointSize(_ run: AttributedString.Runs.Element) -> CGFloat {
        #if canImport(AppKit)
        return run.appKit.font?.pointSize ?? 0
        #else
        return run.uiKit.font?.pointSize ?? 0
        #endif
    }

    /// The attributed run covering the first occurrence of `text`.
    private func run(
        _ text: String, in attributed: AttributedString
    ) throws -> AttributedString.Runs.Element {
        let range = try #require(attributed.range(of: text))
        return try #require(attributed.runs.first { $0.range.overlaps(range) })
    }

    @Test("A footnote marker renders raised and smaller, not as body text")
    func supIsRaised() throws {
        let rendered = try #require(render("A claim.<sup>1</sup>"))
        let marker = try run("1", in: rendered)
        let body = try run("A claim.", in: rendered)

        #expect(baselineOffset(marker) > 0, "a superscript must sit above the baseline")
        #expect(pointSize(marker) < pointSize(body), "a marker must not be body size")
    }

    @Test("A subscript sits below the baseline")
    func subIsLowered() throws {
        let rendered = try #require(render("H<sub>2</sub>O"))
        #expect(baselineOffset(try run("2", in: rendered)) < 0)
    }

    /// The link a footnote marker and every contents row carries. It is not a place
    /// to go, so it travels under a scheme of ours that the reader resolves and
    /// anything else declines to open.
    @Test("A fragment href becomes an in-document link")
    func fragmentBecomesAnchor() throws {
        let rendered = try #require(render(##"<a href="#my-post-fn:1">1</a>"##))
        let link = try #require(try run("1", in: rendered).link)
        #expect(HTMLContentAnchor.fragment(of: link) == "my-post-fn:1")
    }

    /// The exact markup a published page carries. The footnote link declares its
    /// role for a screen reader, and that attribute alone bailed the whole paragraph
    /// to the WebKit path — so the marker rendered as body text and nothing was
    /// tappable, while the contents list, whose links carry no role, worked.
    @Test("A real footnote marker renders and links")
    func realFootnoteMarkup() throws {
        let html = ##"""
            Nook is a reader.<sup id="fnref:1"><a href="#fn:1" class="footnote-ref" \
            role="doc-noteref">1</a></sup>
            """##.replacingOccurrences(of: "\\\n", with: "")
        let rendered = try #require(render(html), "the paragraph bailed to the WebKit path")

        let marker = try run("1", in: rendered)
        #expect(baselineOffset(marker) > 0, "the marker must be raised")
        let link = try #require(marker.link)
        #expect(HTMLContentAnchor.fragment(of: link) == "fn:1")
    }

    /// And the note's way back, which carries a role too.
    @Test("A footnote back-link renders and links")
    func realBackLinkMarkup() throws {
        let html = ##"""
            <a href="#fnref:1" class="footnote-backref" role="doc-backlink">back</a>
            """##
        let rendered = try #require(render(html))
        let link = try #require(try run("back", in: rendered).link)
        #expect(HTMLContentAnchor.fragment(of: link) == "fnref:1")
    }

    @Test("An ordinary link is still an ordinary link")
    func externalLinkUnchanged() throws {
        let rendered = try #require(render(#"<a href="https://example.com/">x</a>"#))
        let link = try #require(try run("x", in: rendered).link)
        #expect(link.scheme == "https")
        #expect(HTMLContentAnchor.fragment(of: link) == nil, "an external link is not an anchor")
    }

    /// The parse has to say which block an id belongs to, or a resolved link has
    /// nowhere to scroll.
    @Test("The parser records where each id lives")
    func parserRecordsAnchors() {
        let html = """
            <ul class="toc"><li><a href="#p-first">First</a></li></ul>
            <h2 id="p-first">First</h2>
            <p>Body.<sup id="p-fnref:1"><a href="#p-fn:1">1</a></sup></p>
            <ol><li id="p-fn:1"><p>The note.</p></li></ol>
            """
        let parsed = HTMLContentParser.parseWithAnchors(html, baseURL: nil)

        let heading = parsed.anchors["p-first"]
        #expect(heading != nil, "a heading's id must be recorded")
        if let heading {
            #expect(parsed.blocks[heading].isHeading, "the id must point at the heading itself")
        }
        // The marker's own id, so the note can link back to the sentence.
        #expect(parsed.anchors["p-fnref:1"] != nil)
        // And the note, which lives inside the list block.
        #expect(parsed.anchors["p-fn:1"] != nil)
    }
}

extension HTMLContentBlock {
    fileprivate var isHeading: Bool {
        if case .heading = self { return true }
        return false
    }
}

/// The mark that says where a jump landed.
@Suite("Anchor landing")
struct AnchorFlashTests {
    /// Three flashes and back to nothing: an odd number of half-cycles would leave
    /// the highlight on, which is a mark the reader then has to dismiss.
    @Test("it flashes a few times and settles")
    func settles() {
        let flash = AnchorFlash.forReader(reduceMotion: false)
        #expect(flash.animates)
        #expect(flash.halfCycles % 2 == 0, "an autoreversing animation must end where it began")
        #expect(flash.halfCycles / 2 == 3)
        #expect(flash.duration < 3, "a landing mark must not outstay the jump")
    }

    /// Flashing content becomes a hazard at three per second. This is the number
    /// that keeps it well below, and it is worth failing a build over.
    @Test("it stays far below the flash-rate threshold")
    func safeRate() {
        #expect(AnchorFlash.forReader(reduceMotion: false).frequency < 2)
    }

    /// Reduce Motion still gets told where it landed — the point is to locate, and
    /// locating does not require motion.
    @Test("Reduce Motion gets the mark without the blinking")
    func reduceMotion() {
        let flash = AnchorFlash.forReader(reduceMotion: true)
        #expect(!flash.animates)
        #expect(flash.frequency == 0)
        #expect(flash.duration > 0, "it must still appear, just without flashing")
    }
}
