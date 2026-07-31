import Foundation
import Testing

@testable import NookKit

/// What a formatting button does to the text and to the caret.
///
/// Pinned closely because these run with the caret in the middle of someone's
/// sentence: an off-by-one puts the marker in the wrong place, or drops the caret
/// somewhere the writer did not ask for and has to hunt for.
@Suite("Nook Plus markdown edits")
struct PlusMarkdownEditTests {
    /// Applies an edit the way a text view would, so the assertions are about the
    /// document the writer ends up with rather than about the edit's parts.
    private func apply(_ edit: PlusMarkdownEdit.Edit, to text: String) -> String {
        let ns = NSMutableString(string: text)
        ns.replaceCharacters(in: edit.range, with: edit.replacement)
        return ns as String
    }

    private func selected(_ edit: PlusMarkdownEdit.Edit, in result: String) -> String {
        (result as NSString).substring(with: edit.selection)
    }

    private func apply(_ transaction: PlusMarkdownEdit.Transaction, to text: String) -> String {
        let ns = NSMutableString(string: text)
        for replacement in transaction.replacements.sorted(
            by: { $0.range.location > $1.range.location })
        {
            ns.replaceCharacters(in: replacement.range, with: replacement.text)
        }
        return ns as String
    }

    // MARK: - Wrapping

    @Test("wrapping a selection puts the markers around it")
    func wrapSelection() {
        let text = "say this now"
        let edit = PlusMarkdownEdit.wrap(text, selection: NSRange(location: 4, length: 4), with: "**")
        #expect(apply(edit, to: text) == "say **this** now")
        // The selection follows the words, not the markers, so typing replaces the
        // words and tapping Bold again unwraps them.
        #expect(selected(edit, in: apply(edit, to: text)) == "this")
    }

    /// With nothing selected the pair is inserted and the caret goes between them, so
    /// the next thing typed comes out emphasised.
    @Test("wrapping nothing leaves the caret between the markers")
    func wrapCaret() {
        let text = "say  now"
        let edit = PlusMarkdownEdit.wrap(text, selection: NSRange(location: 4, length: 0), with: "**")
        let result = apply(edit, to: text)
        #expect(result == "say **** now")
        #expect(edit.selection == NSRange(location: 6, length: 0))
        #expect(edit.selection.length == 0)
    }

    /// Without this a second tap on Bold produces `****`, which is not bold at all.
    @Test("wrapping again unwraps, whether the markers are inside the selection or outside it")
    func wrapToggles() {
        let inside = "say **this** now"
        let editInside = PlusMarkdownEdit.wrap(
            inside, selection: NSRange(location: 4, length: 8), with: "**")
        #expect(apply(editInside, to: inside) == "say this now")
        #expect(selected(editInside, in: apply(editInside, to: inside)) == "this")

        let outside = "say **this** now"
        let editOutside = PlusMarkdownEdit.wrap(
            outside, selection: NSRange(location: 6, length: 4), with: "**")
        #expect(apply(editOutside, to: outside) == "say this now")
        #expect(selected(editOutside, in: apply(editOutside, to: outside)) == "this")
    }

    /// A marker at the very start or end of the document is where an unwrap that
    /// looks outside the selection would read past the ends and trap.
    @Test("wrapping at the edges of the document is safe")
    func wrapAtEdges() {
        let start = PlusMarkdownEdit.wrap("this now", selection: NSRange(location: 0, length: 4), with: "**")
        #expect(apply(start, to: "this now") == "**this** now")

        let end = PlusMarkdownEdit.wrap("say this", selection: NSRange(location: 4, length: 4), with: "**")
        #expect(apply(end, to: "say this") == "say **this**")

        let whole = PlusMarkdownEdit.wrap("**hi**", selection: NSRange(location: 0, length: 6), with: "**")
        #expect(apply(whole, to: "**hi**") == "hi")

        let empty = PlusMarkdownEdit.wrap("", selection: NSRange(location: 0, length: 0), with: "**")
        #expect(apply(empty, to: "") == "****")
    }

    /// Korean and emoji are where a range counted in characters rather than UTF-16
    /// would land mid-character.
    @Test("wrapping multi-byte text lands where it should")
    func wrapMultibyte() {
        let text = "이건 굵게 나와야 해"
        // "굵게" — three UTF-16 units in ("이", "건", the space), two long.
        let edit = PlusMarkdownEdit.wrap(text, selection: NSRange(location: 3, length: 2), with: "**")
        #expect(apply(edit, to: text) == "이건 **굵게** 나와야 해")
        #expect(selected(edit, in: apply(edit, to: text)) == "굵게")

        let withEmoji = "a 🎉 b"
        let after = PlusMarkdownEdit.wrap(withEmoji, selection: NSRange(location: 2, length: 2), with: "*")
        #expect(apply(after, to: withEmoji) == "a *🎉* b")
    }

    // MARK: - Line prefixes

    @Test("a line marker goes at the start of the line, not at the caret")
    func linePrefix() {
        let text = "first\nsecond line\nthird"
        // Caret in the middle of "second line".
        let edit = PlusMarkdownEdit.toggleLinePrefix(text, selection: NSRange(location: 10, length: 0), marker: "> ")
        #expect(apply(edit, to: text) == "first\n> second line\nthird")
        // The caret keeps its place in the words, having moved along with them.
        #expect(edit.selection.location == 12)
    }

    @Test("a line marker already there is taken off")
    func linePrefixToggles() {
        let text = "# Title\n\nBody"
        let edit = PlusMarkdownEdit.toggleLinePrefix(text, selection: NSRange(location: 4, length: 0), marker: "# ")
        #expect(apply(edit, to: text) == "Title\n\nBody")
        #expect(edit.selection.location == 2)
    }

    @Test("a line marker on the first line has no newline to find")
    func linePrefixFirstLine() {
        let edit = PlusMarkdownEdit.toggleLinePrefix("Title", selection: NSRange(location: 3, length: 0), marker: "# ")
        #expect(apply(edit, to: "Title") == "# Title")

        let empty = PlusMarkdownEdit.toggleLinePrefix("", selection: NSRange(location: 0, length: 0), marker: "- ")
        #expect(apply(empty, to: "") == "- ")
    }

    /// Removing a marker must not pull the caret back before the line starts.
    @Test("removing a marker keeps the caret on its own line")
    func linePrefixRemovalClamps() {
        let text = "- item"
        let edit = PlusMarkdownEdit.toggleLinePrefix(text, selection: NSRange(location: 0, length: 0), marker: "- ")
        #expect(apply(edit, to: text) == "item")
        #expect(edit.selection.location == 0)
    }

    /// The reported bug: with the whole line selected, the marker being removed is
    /// *inside* the selection, so the selection has to shrink as well as move. Taking
    /// its length as given described a selection running past the end of the text.
    @Test("removing a marker inside the selection shrinks the selection")
    func linePrefixRemovalInsideSelection() {
        let text = "# Title"
        let whole = PlusMarkdownEdit.toggleLinePrefix(
            text, selection: NSRange(location: 0, length: 7), marker: "# ")
        let result = apply(whole, to: text)
        #expect(result == "Title")
        #expect(whole.selection == NSRange(location: 0, length: 5))
        #expect(selected(whole, in: result) == "Title")

        // Straddling the marker: from inside it to the end of the line.
        let straddle = PlusMarkdownEdit.toggleLinePrefix(
            text, selection: NSRange(location: 1, length: 6), marker: "# ")
        #expect(selected(straddle, in: apply(straddle, to: text)) == "Title")
    }

    // MARK: - Links

    /// The URL is selected rather than left to a caret, so a pasted or typed address
    /// replaces the placeholder instead of joining it.
    @Test("a link leaves the URL selected")
    func link() {
        let text = "see the site now"
        let edit = PlusMarkdownEdit.link(text, selection: NSRange(location: 4, length: 8))
        let result = apply(edit, to: text)
        #expect(result == "see [the site](https://) now")
        #expect(selected(edit, in: result) == "https://")
    }

    @Test("a link with nothing selected puts the caret where the words go")
    func linkEmpty() {
        let edit = PlusMarkdownEdit.link("", selection: NSRange(location: 0, length: 0))
        #expect(apply(edit, to: "") == "[](https://)")
        #expect(edit.selection == NSRange(location: 1, length: 0))
    }

    // MARK: - Code blocks

    /// A fence has to start a line: three backticks mid-sentence is an inline span,
    /// not a block.
    @Test("a code block breaks the line before its fence")
    func codeBlockBreaksLine() {
        let text = "before"
        let edit = PlusMarkdownEdit.codeBlock(text, selection: NSRange(location: 6, length: 0))
        #expect(apply(edit, to: text) == "before\n```\n\n```\n")

        let atLineStart = "before\n"
        let noExtra = PlusMarkdownEdit.codeBlock(atLineStart, selection: NSRange(location: 7, length: 0))
        #expect(apply(noExtra, to: atLineStart) == "before\n```\n\n```\n")

        let atStart = PlusMarkdownEdit.codeBlock("", selection: NSRange(location: 0, length: 0))
        #expect(apply(atStart, to: "") == "```\n\n```\n")
    }

    @Test("a code block wraps the selection and keeps it selected")
    func codeBlockWrapsSelection() {
        let text = "let x = 1"
        let edit = PlusMarkdownEdit.codeBlock(text, selection: NSRange(location: 0, length: 9))
        let result = apply(edit, to: text)
        #expect(result == "```\nlet x = 1\n```\n")
        #expect(selected(edit, in: result) == "let x = 1")
    }

    // MARK: - Semantic breaks

    @Test("Return creates paragraphs and Shift-Return creates a visible hard break")
    func semanticBreaks() {
        let paragraph = PlusMarkdownEdit.breakLine(
            "first", selection: NSRange(location: 5, length: 0), kind: .paragraph)
        #expect(apply(paragraph, to: "first") == "first\n\n")

        let line = PlusMarkdownEdit.breakLine(
            "first", selection: NSRange(location: 5, length: 0), kind: .line)
        #expect(apply(line, to: "first") == "first\\\n")
    }

    @Test("Return continues a list and exits an empty item")
    func listBreaks() {
        let next = PlusMarkdownEdit.breakLine(
            "- one", selection: NSRange(location: 5, length: 0), kind: .paragraph)
        #expect(apply(next, to: "- one") == "- one\n- ")

        let source = "- one\n- "
        let exit = PlusMarkdownEdit.breakLine(
            source, selection: NSRange(location: 8, length: 0), kind: .paragraph)
        #expect(apply(exit, to: source) == "- one\n\n")
    }

    @Test("code fences retain literal newlines")
    func codeBreaks() {
        let source = "```\ncode\n```"
        let edit = PlusMarkdownEdit.breakLine(
            source, selection: NSRange(location: 8, length: 0), kind: .paragraph)
        #expect(apply(edit, to: source) == "```\ncode\n\n```")
    }

    // MARK: - Paste and authoring components

    @Test("a pasted URL uses selected prose without waiting for metadata")
    func pasteURLOverSelection() throws {
        let url = try #require(URL(string: "https://example.com/a(b)"))
        let source = "Read this today"
        let paste = PlusMarkdownEdit.pasteURL(
            url, into: source, selection: NSRange(location: 5, length: 4))
        #expect(apply(paste.edit, to: source) == "Read [this](https://example.com/a\\(b\\)) today")
    }

    @Test("a pasted URL is its own immediate fallback label")
    func pasteURLFallback() throws {
        let url = try #require(URL(string: "https://example.com/post"))
        let paste = PlusMarkdownEdit.pasteURL(
            url, into: "", selection: NSRange(location: 0, length: 0))
        let result = apply(paste.edit, to: "")
        #expect(result == "[https://example.com/post](https://example.com/post)")
        #expect((result as NSString).substring(with: paste.labelRange) == url.absoluteString)
    }

    @Test("TOC is inserted as one block and a second insertion selects the existing marker")
    func tableOfContents() {
        let first = PlusMarkdownEdit.tableOfContents(
            "Intro", selection: NSRange(location: 5, length: 0))
        #expect(apply(first, to: "Intro") == "Intro\n\n[TOC]\n\n")

        let source = "[TOC]\n\n# One"
        let duplicate = PlusMarkdownEdit.tableOfContents(
            source, selection: NSRange(location: (source as NSString).length, length: 0))
        #expect(apply(duplicate, to: source) == source)
        #expect((source as NSString).substring(with: duplicate.selection).contains("[TOC]"))
    }

    @Test("a footnote transaction changes only its reference and definition")
    func footnote() {
        let source = "A claim"
        let transaction = PlusMarkdownEdit.footnote(
            source,
            selection: NSRange(location: (source as NSString).length, length: 0),
            label: "1",
            content: "Supporting note")
        #expect(apply(transaction, to: source) == "A claim[^1]\n\n[^1]: Supporting note\n")
        #expect(transaction.replacements.count == 1)

        let middle = PlusMarkdownEdit.footnote(
            "Claim and more",
            selection: NSRange(location: 5, length: 0),
            label: "2",
            content: "Second")
        #expect(apply(middle, to: "Claim and more") == "Claim[^2] and more\n\n[^2]: Second\n")
        #expect(middle.replacements.count == 2)
    }

    // MARK: - Everything lands inside the document

    /// A selection the edit describes has to exist in the text it produced. This is
    /// the assertion that catches an off-by-one before a text view does, by trapping.
    @Test("every edit reports a selection inside the resulting text")
    func selectionsAreValid() {
        let documents = ["", "hello", "# Title\n\nBody text", "반가워요 🎉", "a\n\nb"]
        for text in documents {
            let length = (text as NSString).length
            for location in 0...length {
                for size in 0...(length - location) {
                    let selection = NSRange(location: location, length: size)
                    let edits = [
                        PlusMarkdownEdit.wrap(text, selection: selection, with: "**"),
                        PlusMarkdownEdit.wrap(text, selection: selection, with: "`"),
                        PlusMarkdownEdit.toggleLinePrefix(text, selection: selection, marker: "# "),
                        PlusMarkdownEdit.link(text, selection: selection),
                        PlusMarkdownEdit.codeBlock(text, selection: selection),
                    ]
                    for edit in edits {
                        let result = apply(edit, to: text) as NSString
                        #expect(
                            edit.selection.upperBound <= result.length,
                            "\(text.debugDescription) at \(selection) produced a selection past the end")
                        #expect(edit.selection.location >= 0)
                    }
                }
            }
        }
    }
}
