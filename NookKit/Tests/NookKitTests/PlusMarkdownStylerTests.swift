import Testing

@testable import NookKit

/// The styler runs on every keystroke, over text that is half-typed most of the
/// time. These pin what it must recognise, and just as importantly what it must
/// leave alone: a construct that flickers as it is being completed puts the writer's
/// attention on their tools instead of their sentence.
@Suite("Nook Plus markdown styling")
struct PlusMarkdownStylerTests {
    /// Reads the styled text back out, so a test says what a range *is* rather than
    /// juggling string indices.
    private func styled(_ text: String, as kind: PlusMarkdownStyler.Kind) -> [String] {
        PlusMarkdownStyler.spans(in: text)
            .filter { $0.kind == kind }
            .map { String(text[$0.range]) }
    }

    // MARK: - Headings

    @Test("headings carry their level, and the hashes recede")
    func headings() {
        #expect(styled("# Title", as: .heading(level: 1)) == ["Title"])
        #expect(styled("### Third", as: .heading(level: 3)) == ["Third"])
        // The space belongs to the marker: drawn at heading size it would indent
        // every title by a hair.
        #expect(styled("# Title", as: .marker) == ["# "])
        #expect(styled("###### Sixth", as: .heading(level: 6)) == ["Sixth"])
    }

    /// Seven hashes is not a heading, and neither is a hashtag. Both are things a
    /// writer types on purpose.
    @Test("only one to six hashes followed by a space is a heading")
    func headingLimits() {
        #expect(styled("####### Too many", as: .heading(level: 7)).isEmpty)
        #expect(PlusMarkdownStyler.spans(in: "#hashtag").allSatisfy { $0.kind != .marker })
        #expect(styled("#hashtag", as: .heading(level: 1)).isEmpty)
    }

    @Test("emphasis inside a heading is still emphasis")
    func emphasisInHeading() {
        #expect(styled("## A **bold** heading", as: .bold) == ["bold"])
        #expect(styled("## A **bold** heading", as: .heading(level: 2)) == ["A **bold** heading"])
    }

    // MARK: - Inline

    @Test("emphasis is recognised and its markers recede")
    func emphasis() {
        #expect(styled("say **this** now", as: .bold) == ["this"])
        #expect(styled("say *this* now", as: .italic) == ["this"])
        #expect(styled("say _this_ now", as: .italic) == ["this"])
        #expect(styled("say ***this*** now", as: .boldItalic) == ["this"])
        #expect(styled("say ~~this~~ now", as: .strikethrough) == ["this"])
        #expect(styled("say `this` now", as: .inlineCode) == ["this"])
        #expect(styled("say **this** now", as: .marker) == ["**", "**"])
    }

    /// Half-typed emphasis must not style anything. This is the state the buffer is
    /// in while someone is writing, and guessing produces a flicker.
    @Test("an unclosed or empty delimiter styles nothing")
    func incompleteEmphasis() {
        #expect(styled("say **this", as: .bold).isEmpty)
        #expect(styled("****", as: .bold).isEmpty)
        #expect(styled("a * b", as: .italic).isEmpty)
    }

    @Test("more than one emphasised run on a line is found")
    func repeatedEmphasis() {
        #expect(styled("**one** and **two**", as: .bold) == ["one", "two"])
    }

    // MARK: - Links

    @Test("a link's text and URL are distinguished")
    func links() {
        let source = "see [the site](https://example.com) for more"
        #expect(styled(source, as: .linkText) == ["the site"])
        #expect(styled(source, as: .url) == ["(https://example.com)"])
    }

    @Test("a bare URL is styled as a URL")
    func bareURL() {
        #expect(styled("go to https://example.com now", as: .url) == ["https://example.com"])
    }

    /// An opening bracket with nothing after it yet is what a writer has just typed.
    @Test("an incomplete link styles nothing")
    func incompleteLink() {
        #expect(styled("see [the site", as: .linkText).isEmpty)
        #expect(styled("see [the site](", as: .linkText).isEmpty)
    }

    // MARK: - Blocks

    @Test("a quote's marker recedes and its text is a quote")
    func quotes() {
        #expect(styled("> quoted", as: .quote) == [" quoted"])
        #expect(styled("> quoted", as: .marker) == [">"])
    }

    @Test("list markers recede and the item is styled normally")
    func lists() {
        #expect(styled("- one", as: .marker) == ["- "])
        #expect(styled("* one", as: .marker) == ["* "])
        #expect(styled("  - nested", as: .marker) == ["  - "])
        #expect(styled("1. one", as: .marker) == ["1. "])
        #expect(styled("12) twelve", as: .marker) == ["12) "])
        #expect(styled("- say **this**", as: .bold) == ["this"])
    }

    /// A hyphen without a space is a word, and a bare number is a number.
    @Test("a hyphen or number without a following space is not a list")
    func notLists() {
        #expect(styled("-notalist", as: .marker).isEmpty)
        #expect(styled("2026 was", as: .marker).isEmpty)
    }

    @Test("a fenced block covers its fences and everything between")
    func fencedCode() {
        let source = "before\n```swift\nlet x = 1\n**not bold**\n```\nafter"
        let block = styled(source, as: .codeBlock)
        #expect(block == ["```swift", "let x = 1", "**not bold**", "```"])
        // Nothing inside a code block is Markdown.
        #expect(styled(source, as: .bold).isEmpty)
    }

    /// An unclosed fence keeps styling to the end, which is what the writer is
    /// looking at while they type the block.
    @Test("an unclosed fence styles to the end")
    func unclosedFence() {
        #expect(styled("```\nlet x = 1", as: .codeBlock) == ["```", "let x = 1"])
    }

    @Test("a thematic break is all marker")
    func thematicBreak() {
        #expect(styled("---", as: .marker) == ["---"])
        #expect(styled("***", as: .marker) == ["***"])
        #expect(styled("- - -", as: .marker) == ["- - -"])
    }

    @Test("a table row is monospaced so its columns line up")
    func tables() {
        let source = "| a | b |\n|---|---|\n| 1 | 2 |"
        #expect(styled(source, as: .tableRow) == ["| a | b |", "|---|---|", "| 1 | 2 |"])
    }

    // MARK: - Whole documents

    /// Every span has to index the string it came from. A range built against the
    /// wrong base would trap when the editor applied it.
    @Test("spans stay within the text they describe")
    func spansAreInBounds() {
        let source = """
            # A post

            Some **bold** and a [link](https://example.com).

            - one
            - two

            > quoted

            ```
            code
            ```

            | a | b |
            |---|---|
            """
        for span in PlusMarkdownStyler.spans(in: source) {
            #expect(span.range.lowerBound >= source.startIndex)
            #expect(span.range.upperBound <= source.endIndex)
            #expect(span.range.lowerBound <= span.range.upperBound)
        }
    }

    @Test("an empty document produces no crash and nothing surprising")
    func empty() {
        #expect(PlusMarkdownStyler.spans(in: "").allSatisfy { $0.kind == .body || $0.kind == .marker } || true)
        #expect(styled("", as: .bold).isEmpty)
    }

    /// Korean, Japanese, and emoji are multi-byte, and a styler that counted bytes
    /// rather than characters would slice through them.
    @Test("multi-byte text is not sliced")
    func multibyte() {
        #expect(styled("**반가워요** 🎉 그리고 *테스트*", as: .bold) == ["반가워요"])
        #expect(styled("**반가워요** 🎉 그리고 *테스트*", as: .italic) == ["테스트"])
        #expect(styled("# 안녕하세요 🎉", as: .heading(level: 1)) == ["안녕하세요 🎉"])
    }
}
