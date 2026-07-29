import AppKit
import Testing
@testable import NookKit

@Suite("Native article layout")
struct HTMLContentLayoutTests {
    private static let paragraph = HTMLContentBlock.text("Body")
    private static let heading = HTMLContentBlock.heading(level: 2, html: "Heading")
    private static let minorHeading = HTMLContentBlock.heading(level: 3, html: "Heading")
    private static let list = HTMLContentBlock.list(ordered: false, items: [[paragraph]])
    private static let image = HTMLContentBlock.image(HTMLMedia(
        url: URL(string: "https://example.com/a.png")!,
        title: nil, caption: nil, posterURL: nil, aspectRatio: nil
    ))

    /// Every supported body size crossed with the line-height settings the UI
    /// offers, so an invariant has to hold across the whole space rather than at
    /// one convenient point.
    private static let settings: [(size: CGFloat, lineHeight: Double)] = {
        var combinations: [(CGFloat, Double)] = []
        for size in stride(from: CGFloat(10), through: 40, by: 2) {
            for lineHeight in [1.0, 1.2, 1.5, 1.7, 1.9, 2.4, 3.0] {
                combinations.append((size, lineHeight))
            }
        }
        return combinations
    }()

    private func typography(_ size: CGFloat, _ lineHeight: Double) -> ReaderTypography {
        ReaderTypography(font: .system, fontSize: size, lineHeightMultiple: lineHeight, letterSpacingEM: 0)
    }

    @Test("Adjacent block margins collapse according to document structure")
    func semanticBlockSpacing() {
        // Anchored at the reader's default size with no extra leading, which is
        // where the em scale was calibrated against the historical point values.
        let type = typography(18, 1.2)
        #expect(type.lineSpacing == 0)

        func isClose(_ value: CGFloat, _ expected: CGFloat) -> Bool {
            abs(value - expected) < 0.01
        }

        #expect(HTMLBlockSpacing.gap(from: nil, to: Self.paragraph, typography: type) == 0)
        #expect(isClose(HTMLBlockSpacing.gap(from: Self.paragraph, to: Self.paragraph, typography: type), 10.8))
        #expect(isClose(HTMLBlockSpacing.gap(from: Self.paragraph, to: Self.heading, typography: type), 26.1))
        #expect(isClose(HTMLBlockSpacing.gap(from: Self.heading, to: Self.paragraph, typography: type), 8.1))
        #expect(isClose(HTMLBlockSpacing.gap(from: Self.paragraph, to: Self.list, typography: type), 14.4))
        #expect(isClose(
            HTMLBlockSpacing.gap(from: Self.paragraph, to: Self.list, compact: true, typography: type),
            9.36
        ))
    }

    @Test("Paragraphs always separate more than the lines inside them")
    func paragraphNeverInvertsAgainstLineGap() {
        // The defect this guards: every gap used to be a fixed number of points
        // while `lineSpacing` scaled with the body size, so above ~24pt the space
        // between paragraphs fell *below* the space between lines and paragraph
        // boundaries disappeared.
        for (size, lineHeight) in Self.settings {
            let type = typography(size, lineHeight)
            let paragraphGap = HTMLBlockSpacing.gap(
                from: Self.paragraph, to: Self.paragraph, typography: type
            )
            #expect(
                paragraphGap >= type.lineSpacing * 1.5,
                "\(size)pt @ \(lineHeight): paragraph gap \(paragraphGap) vs line gap \(type.lineSpacing)"
            )
        }
    }

    @Test("Structural gaps stay ordered and above the line gap at every setting")
    func spacingHierarchyHolds() {
        for (size, lineHeight) in Self.settings {
            let type = typography(size, lineHeight)
            let afterHeading = HTMLBlockSpacing.gap(from: Self.heading, to: Self.paragraph, typography: type)
            let betweenParagraphs = HTMLBlockSpacing.gap(from: Self.paragraph, to: Self.paragraph, typography: type)
            let beforeList = HTMLBlockSpacing.gap(from: Self.paragraph, to: Self.list, typography: type)
            let beforeMinor = HTMLBlockSpacing.gap(from: Self.paragraph, to: Self.minorHeading, typography: type)
            let beforeMajor = HTMLBlockSpacing.gap(from: Self.paragraph, to: Self.heading, typography: type)
            let beforeImage = HTMLBlockSpacing.gap(from: Self.paragraph, to: Self.image, typography: type)

            let label = "\(size)pt @ \(lineHeight)"
            // A heading introduces the text under it, so it sits closer to that
            // text than paragraphs sit to each other — but still never as close
            // as two lines of one paragraph.
            #expect(afterHeading > type.lineSpacing, "\(label): heading-after collapsed into the line gap")
            #expect(afterHeading < betweenParagraphs, "\(label): heading detached from its body text")
            #expect(betweenParagraphs < beforeList, "\(label): list not set apart from prose")
            #expect(beforeList <= beforeImage, "\(label): media tighter than a list")
            #expect(beforeImage < beforeMinor, "\(label): minor heading tighter than media")
            #expect(beforeMinor < beforeMajor, "\(label): heading levels not distinguished")
        }
    }

    @Test("Every gap grows with the type rather than staying a fixed size")
    func spacingScalesWithTypography() {
        let small = typography(12, 1.7)
        let large = typography(36, 1.7)
        let pairs: [(String, HTMLContentBlock)] = [
            ("paragraph", Self.paragraph), ("heading", Self.heading),
            ("list", Self.list), ("image", Self.image),
        ]
        for (name, block) in pairs {
            let smallGap = HTMLBlockSpacing.gap(from: Self.paragraph, to: block, typography: small)
            let largeGap = HTMLBlockSpacing.gap(from: Self.paragraph, to: block, typography: large)
            #expect(largeGap > smallGap * 2, "\(name) gap did not scale: \(smallGap) -> \(largeGap)")
        }
        // Horizontal metrics have to keep pace too, or a bullet ends up crowding
        // a 36pt glyph it comfortably cleared at 12pt.
        #expect(
            HTMLBlockSpacing.markerColumnWidth(large, ordered: false)
                > HTMLBlockSpacing.markerColumnWidth(small, ordered: false) * 2
        )
        #expect(
            HTMLBlockSpacing.markerColumnWidth(large, ordered: true)
                > HTMLBlockSpacing.markerColumnWidth(large, ordered: false)
        )
        #expect(HTMLBlockSpacing.quoteIndent(large) > HTMLBlockSpacing.quoteIndent(small) * 2)
        #expect(HTMLBlockSpacing.quoteBarWidth(large) > HTMLBlockSpacing.quoteBarWidth(small))
        // The accent bar has a hairline floor so it stays visible at 10pt.
        #expect(HTMLBlockSpacing.quoteBarWidth(typography(10, 1.0)) >= 3)
    }

    @Test("The marker column is wide enough for the largest number it must show")
    func markerColumnFitsEveryOrdinal() {
        // The column is a fixed width, not a minimum — that is what keeps a list
        // body from being measured at one width and drawn at another. So it has to
        // fit the longest marker on its own, or a three-digit ordinal would clip.
        let type = typography(18, 1.7)
        let one = HTMLBlockSpacing.markerColumnWidth(type, ordered: true, itemCount: 9)
        let two = HTMLBlockSpacing.markerColumnWidth(type, ordered: true, itemCount: 42)
        let three = HTMLBlockSpacing.markerColumnWidth(type, ordered: true, itemCount: 100)
        #expect(one < two)
        #expect(two < three)

        // A bullet is one glyph whatever the item count, and never wider than an
        // ordinal's column.
        let bullets = [1, 9, 42, 100].map {
            HTMLBlockSpacing.markerColumnWidth(type, ordered: false, itemCount: $0)
        }
        #expect(Set(bullets).count == 1)
        #expect(bullets[0] < one)

        // Degenerate counts must not produce a zero or negative column.
        for count in [0, 1] {
            #expect(HTMLBlockSpacing.markerColumnWidth(type, ordered: true, itemCount: count) > 0)
        }
    }

    @Test("List items sit between a line break and a paragraph break")
    func listItemGapIsBetweenLineAndParagraph() {
        for (size, lineHeight) in Self.settings {
            let type = typography(size, lineHeight)
            let itemGap = HTMLBlockSpacing.listItemGap(type)
            let paragraphGap = HTMLBlockSpacing.gap(
                from: Self.paragraph, to: Self.paragraph, typography: type
            )
            #expect(itemGap < paragraphGap, "\(size)pt @ \(lineHeight): items as far apart as paragraphs")
            #expect(itemGap > 0)
        }
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
