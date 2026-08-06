import Testing

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

@testable import NookKit

/// What the writer actually sees.
///
/// The styler being right about what a range *is* does not prove the right font
/// reaches the screen, and the gap between the two is where an editor stops looking
/// like an editor. These assert the attributed string the text view is handed.
///
/// These read fonts out of a styled string, and AppKit resolves fonts on the main
/// thread. Asked from a parallel test thread, a lookup can come back as the default
/// Helvetica 12 instead of the system font — which is what made the heading/body size
/// comparison and the restyle-twice comparison fail about once in ten full runs.
@Suite("Nook Plus markdown editor styling")
@MainActor
struct PlusMarkdownEditorTests {
    private let accent = PlatformColor.red

    private func attributed(_ source: String) -> NSAttributedString {
        MarkdownAttributes.attributed(source, accent: accent)
    }

    /// The one property everything else depends on: the text is never rewritten.
    /// Copy has to yield Markdown, and a buffer that differs from what was typed
    /// would mean it does not.
    @Test("the text is exactly what was typed")
    func textIsUnchanged() {
        for source in [
            "# Heading\n\nSome **bold** text.",
            "- one\n- two",
            "```\ncode\n```",
            "반가워요 **굵게** 🎉",
            "",
        ] {
            #expect(attributed(source).string == source, "the buffer changed for \(source.debugDescription)")
        }
    }

    private func font(of source: String, at index: Int) -> PlatformFont? {
        attributed(source).attribute(.font, at: index, effectiveRange: nil) as? PlatformFont
    }

    @Test("a heading is drawn larger than body text")
    func headingIsLarger() throws {
        let source = "# Title\n\nBody."
        let heading = try #require(font(of: source, at: 2))
        let body = try #require(font(of: source, at: source.count - 3))
        // Named, because a bare comparison failing told us nothing when it did: the fonts
        // are what identified it — the heading had come back as Helvetica 12, which is
        // AppKit's fallback when a lookup does not happen on the main thread.
        #expect(
            heading.pointSize > body.pointSize,
            "heading \(heading.fontName)@\(heading.pointSize) vs body \(body.fontName)@\(body.pointSize)")
    }

    /// Levels have to be distinguishable from each other, or an outline reads flat.
    @Test("heading levels differ in size")
    func headingLevelsDiffer() throws {
        let first = try #require(font(of: "# One", at: 2))
        let second = try #require(font(of: "## Two", at: 3))
        let third = try #require(font(of: "### Three", at: 4))
        #expect(
            first.pointSize > second.pointSize,
            "\(first.fontName)@\(first.pointSize) vs \(second.fontName)@\(second.pointSize)")
        #expect(
            second.pointSize > third.pointSize,
            "\(second.fontName)@\(second.pointSize) vs \(third.fontName)@\(third.pointSize)")
    }

    @Test("bold text is bold and body text is not")
    func boldIsBold() throws {
        let source = "say **this** now"
        let bold = try #require(font(of: source, at: 8))
        let plain = try #require(font(of: source, at: 1))
        #expect(bold.isBold)
        #expect(!plain.isBold)
    }

    /// The styler classifying a range as italic does not prove an italic font reaches the
    /// text view — which is this file's whole reason for existing, and was untested for the
    /// one construct that does not come from a plain `systemFont` call. The italic faces are
    /// built from a font descriptor; the route that used to build them went through
    /// `NSFontManager`, a main-thread AppKit class.
    @Test("italic text is italic, and bold italic is both")
    func italicIsItalic() throws {
        let italic = try #require(font(of: "say *this* now", at: 6))
        #expect(italic.isItalic, "\(italic.fontName)")
        #expect(!italic.isBold, "\(italic.fontName)")

        let both = try #require(font(of: "say ***this*** now", at: 8))
        #expect(both.isItalic, "\(both.fontName)")
        #expect(both.isBold, "\(both.fontName)")

        let plain = try #require(font(of: "say *this* now", at: 1))
        #expect(!plain.isItalic, "\(plain.fontName)")
    }

    /// Emphasis nests, and a font that replaced rather than composed dropped whichever
    /// trait was applied first: `**bold *and italic* inside**` rendered its middle as
    /// italic with the bold gone. Spans do not arrive outer-first — the bold inside a link
    /// is reported before the link — so composition cannot lean on their order.
    @Test("nested emphasis keeps both traits")
    func nestedEmphasisComposes() throws {
        let source = "**bold *and italic* inside**"
        let outer = try #require(font(of: source, at: 3))
        #expect(outer.isBold, "\(outer.fontName)")
        #expect(!outer.isItalic, "\(outer.fontName)")

        let inner = try #require(font(of: source, at: 10))
        #expect(inner.isBold, "the outer bold was lost: \(inner.fontName)")
        #expect(inner.isItalic, "\(inner.fontName)")
    }

    /// The same fault in the other direction: emphasis inside a heading used to take the
    /// heading's size down to body size, because the bold span carried an absolute size of
    /// its own. Sizes compose now — a scale relative to body text — so the heading's size
    /// survives whatever is nested in it.
    @Test("emphasis inside a heading keeps the heading's size")
    func headingSizeSurvivesNesting() throws {
        let source = "# Heading with **bold** and `code`"
        let plain = try #require(font(of: source, at: 3))
        let bold = try #require(font(of: source, at: 17))
        let code = try #require(font(of: source, at: 29))

        #expect(bold.pointSize == plain.pointSize, "\(bold.pointSize) vs \(plain.pointSize)")
        #expect(bold.isBold)
        // Code is smaller than the text around it by design, and still far larger than body
        // text: it is a proportion of the heading, not of the body.
        #expect(code.isMonospaced, "\(code.fontName)")
        #expect(code.pointSize < plain.pointSize)
        #expect(code.pointSize > MarkdownAttributes.bodySize)
    }

    /// Stronger than "twice is the same as once" above, and load-bearing in a way that one
    /// is not: restyling settled text must write nothing at all. Every range it writes invalidates
    /// that much TextKit layout, and a keystroke that invalidates the document makes the
    /// reported height wobble — which is what moved the scroll on the last line of a post.
    /// Composing fonts from the intent rather than from whatever font is already there is
    /// what keeps this true.
    @Test("restyling settled text writes nothing")
    func restyleWritesNothingWhenSettled() {
        let source = """
            # 섹션 하나

            본문에 **굵게**, *기울임*, ***둘 다***, `코드`, ~~취소선~~, [링크](https://example.com)

            - 항목 *하나*
            - 항목 **둘**

            > 인용 안의 **굵게**

            | a | **b** |
            |---|---|
            """
        let storage = MarkdownAttributes.attributed(source, accent: accent)
        #expect(MarkdownAttributes.restyleChangedAttributes(storage, accent: accent).isEmpty)
        #expect(MarkdownAttributes.restyleChangedAttributes(storage, accent: accent).isEmpty)
    }

    @Test("code is monospaced")
    func codeIsMonospaced() throws {
        let inline = try #require(font(of: "say `code` now", at: 6))
        #expect(inline.isMonospaced)

        let block = "```\nlet x = 1\n```"
        let inBlock = try #require(font(of: block, at: 6))
        #expect(inBlock.isMonospaced)
    }

    /// A table is the one construct where alignment is the content, so its rows have
    /// to be monospaced or the writer cannot see the columns they are building.
    @Test("table rows are monospaced")
    func tablesAreMonospaced() throws {
        let source = "| a | b |\n|---|---|"
        #expect(try #require(font(of: source, at: 2)).isMonospaced)
    }

    /// Markers stay visible. Hiding them is what forces an editor to fight the
    /// caret, so they are only made faint.
    @Test("markers are dimmed, not removed")
    func markersAreDimmed() throws {
        let source = "# Title"
        let styled = attributed(source)
        #expect(styled.string.hasPrefix("# "), "the marker is still in the text")

        let markerColor = styled.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? PlatformColor
        let textColor = styled.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? PlatformColor
        #expect(markerColor != textColor, "the marker should not be drawn like the text")
    }

    @Test("a strikethrough is struck through")
    func strikethrough() {
        let styled = attributed("say ~~this~~ now")
        let style = styled.attribute(.strikethroughStyle, at: 7, effectiveRange: nil) as? Int
        #expect(style == NSUnderlineStyle.single.rawValue)
    }

    @Test("a link's text is tinted and underlined")
    func links() {
        let styled = attributed("see [the site](https://example.com)")
        let color = styled.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? PlatformColor
        #expect(color == accent)
        let underline = styled.attribute(.underlineStyle, at: 6, effectiveRange: nil) as? Int
        #expect(underline == NSUnderlineStyle.single.rawValue)
    }

    @Test("TOC and footnote references are interactive without rewriting their source")
    func authoringComponents() {
        let source = "[TOC]\n\nA claim[^1].\n\n- [^1]: Pasted note"
        let styled = attributed(source)
        #expect(styled.string == source)
        #expect(styled.attribute(.link, at: 1, effectiveRange: nil) as? URL != nil)
        let reference = (source as NSString).range(of: "[^1]")
        #expect(styled.attribute(.link, at: reference.location, effectiveRange: nil) as? URL != nil)
        let definition = (source as NSString).range(of: "- [^1]:")
        #expect(
            styled.attribute(.foregroundColor, at: definition.location, effectiveRange: nil)
                as? PlatformColor == accent)
    }

    @Test("a hard break removes paragraph spacing only from its own line")
    func hardBreakParagraphSpacing() throws {
        let source = "first\\\nsecond"
        let styled = attributed(source)
        let first = try #require(
            styled.attribute(.paragraphStyle, at: 1, effectiveRange: nil)
                as? NSParagraphStyle)
        let second = try #require(
            styled.attribute(.paragraphStyle, at: (source as NSString).range(of: "second").location,
                effectiveRange: nil) as? NSParagraphStyle)
        #expect(first.paragraphSpacing == 0)
        #expect(second.paragraphSpacing > 0)
    }

    @Test("a single source newline has line spacing while a blank line separates paragraphs")
    func softBreakParagraphSpacing() throws {
        let source = "first\nsecond\n\nthird"
        let styled = attributed(source)
        let first = try #require(
            styled.attribute(.paragraphStyle, at: 1, effectiveRange: nil)
                as? NSParagraphStyle)
        let second = try #require(
            styled.attribute(
                .paragraphStyle,
                at: (source as NSString).range(of: "second").location,
                effectiveRange: nil) as? NSParagraphStyle)
        let trailing = attributed("first\n")
        let trailingFirst = try #require(
            trailing.attribute(.paragraphStyle, at: 1, effectiveRange: nil)
                as? NSParagraphStyle)
        #expect(first.paragraphSpacing == 0)
        #expect(second.paragraphSpacing > 0)
        #expect(trailingFirst.paragraphSpacing == 0)
    }

    /// A whole document has to style without trapping. Every range comes from the
    /// styler, and one built against the wrong string would crash here rather than
    /// in front of a writer.
    @Test("a full document styles without trapping")
    func fullDocument() {
        let source = """
            # A post

            Some **bold**, some *italic*, some `code`, and a [link](https://example.com).

            - one
            - two

            > quoted

            ```swift
            let x = 1
            ```

            | a | b |
            |---|---|
            | 1 | 2 |

            반가워요 🎉
            """
        let styled = attributed(source)
        #expect(styled.string == source)
        #expect(styled.length == (source as NSString).length)
    }

    // MARK: - Restyling in place

    /// The live text view is restyled through its storage rather than by being handed
    /// a new attributed string, because replacing the characters took the undo stack,
    /// the selection, and any in-progress input-method composition with it. These pin
    /// the properties that makes that safe.
    @Test("restyling in place never changes a character")
    func restyleKeepsCharacters() {
        for source in ["# Heading\n\n**bold** text", "반가워요 **굵게** 🎉", "", "no markup here"] {
            let storage = NSMutableAttributedString(string: source)
            MarkdownAttributes.restyle(storage, accent: accent)
            #expect(storage.string == source, "the characters changed for \(source.debugDescription)")
        }
    }

    /// Styling the same text twice must land in the same place. Attributes that
    /// accumulated would drift further from the source with every keystroke.
    @Test("restyling twice is the same as restyling once")
    func restyleIsIdempotent() {
        let source = "# Title\n\nSome **bold** and `code`.\n\n- one\n- two"
        let once = NSMutableAttributedString(string: source)
        MarkdownAttributes.restyle(once, accent: accent)
        let twice = NSMutableAttributedString(string: source)
        MarkdownAttributes.restyle(twice, accent: accent)
        MarkdownAttributes.restyle(twice, accent: accent)
        #expect(once == twice)
    }

    /// The case in-place styling gets wrong if it only adds: text that used to be a
    /// heading and is not any more has to stop being drawn as one. Deleting the `#`
    /// left the line large and bold for the rest of the session.
    @Test("styling that no longer applies is cleared")
    func staleStylingIsCleared() throws {
        let storage = NSMutableAttributedString(string: "# Title")
        MarkdownAttributes.restyle(storage, accent: accent)
        let asHeading = try #require(storage.attribute(.font, at: 2, effectiveRange: nil) as? PlatformFont)

        // The writer deletes the marker, as the text view would report it.
        storage.replaceCharacters(in: NSRange(location: 0, length: 2), with: "")
        MarkdownAttributes.restyle(storage, accent: accent)
        let asBody = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont)

        #expect(asBody.pointSize < asHeading.pointSize)
        #expect(!asBody.isBold)
    }

    /// Multi-byte text is where a byte-counting range conversion would slice a
    /// character in half and trap.
    @Test("multi-byte text styles without trapping")
    func multibyte() {
        for source in [
            "**반가워요** 그리고 *테스트*",
            "# 안녕하세요 🎉",
            "> 인용 🎉 **굵게**",
            "`코드` 그리고 🎉",
        ] {
            let styled = attributed(source)
            #expect(styled.string == source)
        }
    }
}

extension PlatformFont {
    fileprivate var isBold: Bool {
        #if canImport(UIKit)
            fontDescriptor.symbolicTraits.contains(.traitBold)
        #else
            fontDescriptor.symbolicTraits.contains(.bold)
        #endif
    }

    fileprivate var isItalic: Bool {
        #if canImport(UIKit)
            fontDescriptor.symbolicTraits.contains(.traitItalic)
        #else
            fontDescriptor.symbolicTraits.contains(.italic)
        #endif
    }

    fileprivate var isMonospaced: Bool {
        #if canImport(UIKit)
            fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
                || fontName.lowercased().contains("mono")
        #else
            fontDescriptor.symbolicTraits.contains(.monoSpace)
                || fontName.lowercased().contains("mono")
        #endif
    }
}
