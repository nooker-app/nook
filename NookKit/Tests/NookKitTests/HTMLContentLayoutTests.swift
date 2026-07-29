import AppKit
import Testing
@testable import NookKit

@Suite("Native article layout")
struct HTMLContentLayoutTests {
    @Test("Adjacent block margins collapse according to document structure")
    func semanticBlockSpacing() {
        let paragraph = HTMLContentBlock.text("Body")
        let heading = HTMLContentBlock.heading(level: 2, html: "Heading")
        let list = HTMLContentBlock.list(ordered: false, items: [[paragraph]])

        #expect(HTMLBlockSpacing.gap(from: nil, to: paragraph) == 0)
        #expect(HTMLBlockSpacing.gap(from: paragraph, to: paragraph) == 10)
        #expect(HTMLBlockSpacing.gap(from: paragraph, to: heading) == 26)
        #expect(HTMLBlockSpacing.gap(from: heading, to: paragraph) == 8)
        #expect(HTMLBlockSpacing.gap(from: paragraph, to: list) == 14)
        #expect(HTMLBlockSpacing.gap(from: paragraph, to: list, compact: true) == 9.1)
    }

    @Test("HTML line breaks remain softer than paragraph breaks")
    func preservesSoftLineBreaks() {
        let prepared = HTMLTextFlow.preparedHTML("First<br class=\"soft\">Second")

        #expect(prepared == "First\u{2028}Second")
    }

    @Test("Imported text drops phantom edges and normalizes paragraph metrics")
    func normalizesImportedParagraphs() {
        let text = NSMutableAttributedString(string: "\nOne\n\nTwo\n")
        let source = NSMutableParagraphStyle()
        source.paragraphSpacingBefore = 18
        source.paragraphSpacing = 24
        source.lineSpacing = 7
        source.minimumLineHeight = 30
        source.maximumLineHeight = 34
        text.addAttribute(.paragraphStyle, value: source, range: NSRange(location: 0, length: text.length))

        HTMLTextFlow.normalize(text, baseSize: 17)

        #expect(text.string == "One\nTwo")
        let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.paragraphSpacingBefore == 0)
        #expect(style?.paragraphSpacing == 10.2)
        #expect(style?.lineSpacing == 0)
        #expect(style?.minimumLineHeight == 0)
        #expect(style?.maximumLineHeight == 0)
        let finalStyle = text.attribute(.paragraphStyle, at: text.length - 1, effectiveRange: nil) as? NSParagraphStyle
        #expect(finalStyle?.paragraphSpacing == 0)
    }

    /// Regression: reader paragraphs must always wrap. Feed CSS surviving the
    /// WebKit importer as a truncating line-break mode made SwiftUI's Text draw
    /// "…" mid-article on macOS — and the same text *wrapped* while a selection
    /// was active (the selection renderer ignores the mode), snapping back to
    /// the ellipsis on deselect.
    @Test("A truncating line-break mode from the importer cannot survive")
    func neutralizesTruncatingLineBreaks() {
        let text = NSMutableAttributedString(string: "A paragraph that must wrap")
        let source = NSMutableParagraphStyle()
        source.lineBreakMode = .byTruncatingTail
        text.addAttribute(.paragraphStyle, value: source, range: NSRange(location: 0, length: text.length))

        HTMLTextFlow.normalize(text, baseSize: 17)

        let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.lineBreakMode == .byWordWrapping)
    }

    /// Regression: imported `text-align: justify`, push-out line breaking, and
    /// stray CSS indents all show up as unexplained horizontal whitespace —
    /// stretched inter-word gaps on awkward-length lines, or a shrunken wrap
    /// width down the right edge.
    @Test("Justified alignment, push-out breaking, and indents are stripped")
    func neutralizesSpacingDistortions() {
        let text = NSMutableAttributedString(string: "Ambiguous-length text that wraps awkwardly")
        let source = NSMutableParagraphStyle()
        source.alignment = .justified
        source.lineBreakStrategy = .pushOut
        source.hyphenationFactor = 1
        source.firstLineHeadIndent = 24
        source.headIndent = 32
        source.tailIndent = -20
        text.addAttribute(.paragraphStyle, value: source, range: NSRange(location: 0, length: text.length))

        HTMLTextFlow.normalize(text, baseSize: 17)

        let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.alignment == .natural)
        #expect(style?.lineBreakStrategy == [])
        #expect(style?.hyphenationFactor == 0)
        #expect(style?.firstLineHeadIndent == 0)
        #expect(style?.headIndent == 0)
        #expect(style?.tailIndent == 0)
    }

    /// Text with no paragraph style at all (the native renderer's runs) still
    /// gains the normalized style, so both import paths emit the same metrics.
    @Test("Style-less runs gain the normalized paragraph style")
    func normalizesStyleFreeRuns() {
        let text = NSMutableAttributedString(string: "Native-renderer run")

        HTMLTextFlow.normalize(text, baseSize: 17)

        let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.lineBreakMode == .byWordWrapping)
        #expect(style?.alignment == .natural)
    }
}
