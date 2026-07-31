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
@Suite("Nook Plus markdown editor styling")
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
        #expect(heading.pointSize > body.pointSize)
    }

    /// Levels have to be distinguishable from each other, or an outline reads flat.
    @Test("heading levels differ in size")
    func headingLevelsDiffer() throws {
        let first = try #require(font(of: "# One", at: 2))
        let second = try #require(font(of: "## Two", at: 3))
        let third = try #require(font(of: "### Three", at: 4))
        #expect(first.pointSize > second.pointSize)
        #expect(second.pointSize > third.pointSize)
    }

    @Test("bold text is bold and body text is not")
    func boldIsBold() throws {
        let source = "say **this** now"
        let bold = try #require(font(of: source, at: 8))
        let plain = try #require(font(of: source, at: 1))
        #expect(bold.isBold)
        #expect(!plain.isBold)
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
