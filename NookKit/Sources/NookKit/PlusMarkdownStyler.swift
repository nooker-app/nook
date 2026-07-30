import Foundation

/// Works out how Markdown source should look while it is being written.
///
/// The governing decision: **the text is never rewritten, only styled.** What the
/// writer typed stays in the buffer exactly as typed, markers and all, and this
/// only says which ranges should be drawn differently.
///
/// That is what keeps writing undisturbed. An editor that hides or substitutes
/// characters has to fight the cursor at every boundary, and it takes selection,
/// copy, paste, undo, autocorrect, and dictation down with it: copying a paragraph
/// would yield prose with the emphasis silently dropped, and moving the caret
/// through a hidden `**` would stall or jump. Muting a marker rather than removing
/// it costs one faint pair of asterisks and keeps every one of those correct.
///
/// Pure and UI-free so it can be tested directly. It knows nothing about fonts or
/// colours: it reports what a range *is*, and the editor decides how that looks.
enum PlusMarkdownStyler {
    /// What a range of source is.
    enum Kind: Equatable, Sendable {
        /// Body text with no special meaning.
        case body
        /// A heading's text. Level 1 through 6.
        case heading(level: Int)
        case bold
        case italic
        case boldItalic
        case strikethrough
        case inlineCode
        /// A line inside a fenced block, including the fences themselves.
        case codeBlock
        case quote
        /// A table row, monospaced so columns line up while being edited.
        case tableRow
        /// The visible text of a link.
        case linkText
        /// A URL, whether in a link's parentheses or written bare.
        case url
        /// Syntax that has to stay visible but should recede: `#`, `**`, `>`, the
        /// bullet of a list, a fence's backticks.
        case marker
    }

    struct Span: Equatable, Sendable {
        var range: Range<String.Index>
        var kind: Kind
    }

    /// The spans for a whole document, in source order.
    ///
    /// Block kinds come first and inline kinds are layered over them, so a
    /// consumer applying them in order gets emphasis inside a heading. Ranges may
    /// therefore overlap.
    static func spans(in text: String) -> [Span] {
        var spans: [Span] = []
        var insideFence = false

        for line in lines(of: text) {
            let content = text[line]
            let trimmed = content.trimmingCharacters(in: .whitespaces)

            // A fence toggles the block, and both fence lines belong to it. Checked
            // first because nothing inside a code block is Markdown.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                spans.append(Span(range: line, kind: .codeBlock))
                insideFence.toggle()
                continue
            }
            if insideFence {
                spans.append(Span(range: line, kind: .codeBlock))
                continue
            }

            appendBlockSpans(text: text, line: line, content: content, trimmed: trimmed, into: &spans)
        }

        return spans
    }

    // MARK: - Blocks

    private static func appendBlockSpans(
        text: String,
        line: Range<String.Index>,
        content: Substring,
        trimmed: String,
        into spans: inout [Span]
    ) {
        if let heading = headingSpans(text: text, line: line, content: content) {
            spans.append(contentsOf: heading)
            appendInlineSpans(in: heading.last?.range ?? line, of: text, into: &spans)
            return
        }

        if trimmed.hasPrefix(">") {
            let marker = content.range(of: ">")!
            spans.append(Span(range: marker, kind: .marker))
            let rest = marker.upperBound..<line.upperBound
            spans.append(Span(range: rest, kind: .quote))
            appendInlineSpans(in: rest, of: text, into: &spans)
            return
        }

        // Checked before lists, because "- - -" begins exactly like a list item.
        if isThematicBreak(trimmed) {
            spans.append(Span(range: line, kind: .marker))
            return
        }

        if let bullet = listMarker(in: content) {
            spans.append(Span(range: bullet, kind: .marker))
            let rest = bullet.upperBound..<line.upperBound
            appendInlineSpans(in: rest, of: text, into: &spans)
            return
        }

        // A table row: leading pipe, or pipes with content either side. Monospaced
        // so the columns a writer is aligning actually line up.
        if trimmed.contains("|") && trimmed.hasPrefix("|") {
            spans.append(Span(range: line, kind: .tableRow))
            return
        }

        appendInlineSpans(in: line, of: text, into: &spans)
    }

    private static func headingSpans(
        text: String, line: Range<String.Index>, content: Substring
    ) -> [Span]? {
        var hashes = 0
        var index = content.startIndex
        while index < content.endIndex, content[index] == "#", hashes < 7 {
            hashes += 1
            index = content.index(after: index)
        }
        guard (1...6).contains(hashes) else { return nil }
        // ATX requires a space after the hashes; "#tag" is not a heading.
        guard index < content.endIndex, content[index] == " " else { return nil }
        // The space is part of the marker. Left in the heading it would be drawn at
        // heading size, indenting every title by a hair.
        let afterSpace = content.index(after: index)

        return [
            Span(range: content.startIndex..<afterSpace, kind: .marker),
            Span(range: afterSpace..<line.upperBound, kind: .heading(level: hashes)),
        ]
    }

    /// The bullet or number of a list item, including its trailing space.
    private static func listMarker(in content: Substring) -> Range<String.Index>? {
        var index = content.startIndex
        while index < content.endIndex, content[index] == " " || content[index] == "\t" {
            index = content.index(after: index)
        }
        guard index < content.endIndex else { return nil }

        if content[index] == "-" || content[index] == "*" || content[index] == "+" {
            let after = content.index(after: index)
            guard after < content.endIndex, content[after] == " " else { return nil }
            return content.startIndex..<content.index(after: after)
        }

        var digits = index
        while digits < content.endIndex, content[digits].isNumber {
            digits = content.index(after: digits)
        }
        guard digits > index, digits < content.endIndex,
            content[digits] == "." || content[digits] == ")"
        else { return nil }
        let after = content.index(after: digits)
        guard after < content.endIndex, content[after] == " " else { return nil }
        return content.startIndex..<content.index(after: after)
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        for character in ["-", "*", "_"] as [Character] {
            if trimmed.allSatisfy({ $0 == character || $0 == " " }),
                trimmed.filter({ $0 == character }).count >= 3
            {
                return true
            }
        }
        return false
    }

    // MARK: - Inline

    /// Emphasis, code, links, and bare URLs within one range.
    private static func appendInlineSpans(
        in range: Range<String.Index>, of text: String, into spans: inout [Span]
    ) {
        appendDelimited(text, range, "***", .boldItalic, into: &spans)
        appendDelimited(text, range, "**", .bold, into: &spans)
        appendDelimited(text, range, "~~", .strikethrough, into: &spans)
        appendDelimited(text, range, "`", .inlineCode, into: &spans)
        appendDelimited(text, range, "*", .italic, into: &spans)
        appendDelimited(text, range, "_", .italic, into: &spans)
        appendLinks(text, range, into: &spans)
    }

    /// Pairs of the same delimiter, styling the contents and muting the markers.
    ///
    /// Deliberately does not handle nesting or escapes. A live editor is looking at
    /// text that is half-typed most of the time, and a parser strict enough to be
    /// right about the corner cases would flicker as a construct is completed. The
    /// cost of being approximate is a wrong colour for a moment; the cost of
    /// flicker is a writer looking at their tools instead of their sentence.
    private static func appendDelimited(
        _ text: String,
        _ range: Range<String.Index>,
        _ delimiter: String,
        _ kind: Kind,
        into spans: inout [Span]
    ) {
        var search = range
        while let open = text.range(of: delimiter, range: search) {
            let afterOpen = open.upperBound
            guard afterOpen < range.upperBound,
                let close = text.range(of: delimiter, range: afterOpen..<range.upperBound)
            else { return }
            // Empty content is a writer mid-keystroke, not emphasis.
            if afterOpen < close.lowerBound {
                spans.append(Span(range: open, kind: .marker))
                spans.append(Span(range: afterOpen..<close.lowerBound, kind: kind))
                spans.append(Span(range: close, kind: .marker))
            }
            search = close.upperBound..<range.upperBound
            if search.isEmpty { return }
        }
    }

    /// `[text](url)`, plus a bare `http(s)://…`.
    private static func appendLinks(
        _ text: String, _ range: Range<String.Index>, into spans: inout [Span]
    ) {
        var search = range
        while let open = text.range(of: "[", range: search) {
            guard let closeBracket = text.range(of: "]", range: open.upperBound..<range.upperBound),
                closeBracket.upperBound < range.upperBound,
                text[closeBracket.upperBound] == "(",
                let closeParen = text.range(
                    of: ")", range: closeBracket.upperBound..<range.upperBound)
            else {
                search = open.upperBound..<range.upperBound
                if search.isEmpty { return }
                continue
            }

            spans.append(Span(range: open, kind: .marker))
            spans.append(Span(range: open.upperBound..<closeBracket.lowerBound, kind: .linkText))
            spans.append(Span(range: closeBracket.lowerBound..<closeBracket.upperBound, kind: .marker))
            spans.append(
                Span(
                    range: closeBracket.upperBound..<closeParen.upperBound,
                    kind: .url))

            search = closeParen.upperBound..<range.upperBound
            if search.isEmpty { return }
        }

        // A URL already inside a link's parentheses is spoken for. Without this the
        // same address is reported twice, once with the closing paren attached.
        let claimed = spans.filter { $0.kind == .url }.map(\.range)

        for scheme in ["https://", "http://"] {
            var bareSearch = range
            while let start = text.range(of: scheme, range: bareSearch) {
                var end = start.upperBound
                while end < range.upperBound, !text[end].isWhitespace {
                    end = text.index(after: end)
                }
                let alreadyClaimed = claimed.contains { $0.contains(start.lowerBound) }
                if !alreadyClaimed {
                    spans.append(Span(range: start.lowerBound..<end, kind: .url))
                }
                bareSearch = end..<range.upperBound
                if bareSearch.isEmpty { break }
            }
        }
    }

    // MARK: - Lines

    /// Line ranges, excluding the newline. An empty trailing line is included, so a
    /// writer on a fresh last line still gets it styled.
    private static func lines(of text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start = text.startIndex
        var index = text.startIndex

        while index < text.endIndex {
            if text[index] == "\n" {
                result.append(start..<index)
                start = text.index(after: index)
            }
            index = text.index(after: index)
        }
        result.append(start..<text.endIndex)
        return result
    }
}
