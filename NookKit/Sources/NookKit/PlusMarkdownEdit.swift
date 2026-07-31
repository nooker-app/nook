import Foundation

/// The edits a formatting button makes, worked out without a text view.
///
/// Writing Markdown on a phone means reaching for `*`, `#`, `[`, and backticks on a
/// keyboard where each is two taps deep, in the middle of a sentence. Buttons remove
/// that, but only if they land in the right place: a button that wraps the wrong range
/// or leaves the caret somewhere unexpected is worse than typing the characters.
///
/// Each function returns the smallest replacement that does the job, so the text view
/// records one undo step for one button press and everything else about the document
/// is left alone. Pure, so all of that is testable — the alternative is discovering
/// an off-by-one with the caret in someone's paragraph.
///
/// Ranges are `NSRange` over UTF-16, matching what the text view speaks. This is the
/// one place where that is the right currency rather than `String.Index`.
enum PlusMarkdownEdit {
    /// A replacement to apply, and where the selection goes afterwards.
    struct Edit: Equatable {
        /// The range in the original text to replace.
        var range: NSRange
        var replacement: String
        /// The selection once the replacement is in, in the *new* text.
        var selection: NSRange
    }

    /// Several small edits that belong to one writer action.
    ///
    /// Footnotes are the motivating case: the reference belongs at the caret while
    /// its definition belongs at the end of the document. Replacing everything
    /// between those two places would make TextKit lay the entire document out again
    /// and bring back the bottom-of-document scroll jump. The platform editor applies
    /// these replacements from the end backwards in one undo group instead.
    struct Transaction: Equatable {
        struct Replacement: Equatable {
            var range: NSRange
            var text: String
        }

        var replacements: [Replacement]
        /// Selection in the final document.
        var selection: NSRange

        init(_ edit: Edit) {
            replacements = [.init(range: edit.range, text: edit.replacement)]
            selection = edit.selection
        }

        init(replacements: [Replacement], selection: NSRange) {
            self.replacements = replacements
            self.selection = selection
        }
    }

    enum BreakKind {
        case paragraph
        case line
    }

    /// Wraps the selection in a marker, or unwraps it when it is already wrapped.
    ///
    /// With nothing selected, inserts the pair and puts the caret between them, so
    /// the next thing typed is emphasised. Toggling matters: without it a second tap
    /// on Bold makes `****`, which is not bold at all.
    static func wrap(_ text: String, selection: NSRange, with marker: String) -> Edit {
        let ns = text as NSString
        let marked = marker as NSString

        guard selection.length > 0 else {
            return Edit(
                range: selection,
                replacement: marker + marker,
                selection: NSRange(location: selection.location + marked.length, length: 0))
        }

        let selected = ns.substring(with: selection)
        // Markers inside the selection: the writer selected "**bold**".
        if selected.count >= marked.length * 2, selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = (selected as NSString).substring(
                with: NSRange(
                    location: marked.length,
                    length: (selected as NSString).length - marked.length * 2))
            return Edit(
                range: selection,
                replacement: inner,
                selection: NSRange(location: selection.location, length: (inner as NSString).length))
        }

        // Markers just outside the selection: the writer selected "bold" between them.
        let before = NSRange(location: selection.location - marked.length, length: marked.length)
        let after = NSRange(location: selection.upperBound, length: marked.length)
        if before.location >= 0, after.upperBound <= ns.length,
            ns.substring(with: before) == marker, ns.substring(with: after) == marker
        {
            return Edit(
                range: NSRange(location: before.location, length: marked.length * 2 + selection.length),
                replacement: selected,
                selection: NSRange(location: before.location, length: selection.length))
        }

        return Edit(
            range: selection,
            replacement: marker + selected + marker,
            selection: NSRange(location: selection.location + marked.length, length: selection.length))
    }

    /// Adds a line marker (`# `, `- `, `> `) to the line the selection starts on, or
    /// takes it off when it is already there.
    static func toggleLinePrefix(_ text: String, selection: NSRange, marker: String) -> Edit {
        let ns = text as NSString
        let lineStart = startOfLine(in: ns, at: min(selection.location, ns.length))
        let marked = marker as NSString

        let existing = NSRange(
            location: lineStart, length: min(marked.length, ns.length - lineStart))
        if existing.length == marked.length, ns.substring(with: existing) == marker {
            // The marker can be before the selection, inside it, or straddling its
            // start, and each moves the selection differently. Taking the length as
            // given was wrong for a writer who had selected the whole line: the
            // reported selection ran past the end of the shortened text.
            let cutBefore = max(0, min(existing.upperBound, selection.location) - existing.location)
            let cutInside = max(
                0,
                min(existing.upperBound, selection.upperBound)
                    - max(existing.location, selection.location))
            return Edit(
                range: existing,
                replacement: "",
                selection: NSRange(
                    location: selection.location - cutBefore,
                    length: selection.length - cutInside))
        }

        return Edit(
            range: NSRange(location: lineStart, length: 0),
            replacement: marker,
            selection: NSRange(location: selection.location + marked.length, length: selection.length))
    }

    /// Turns the selection into a link's text, leaving the URL selected so it can be
    /// typed or pasted straight over. With nothing selected, the caret goes where the
    /// text goes, because that is what a writer types first.
    static func link(_ text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let placeholder = "https://"

        guard selection.length > 0 else {
            return Edit(
                range: selection,
                replacement: "[](\(placeholder))",
                selection: NSRange(location: selection.location + 1, length: 0))
        }

        let selected = ns.substring(with: selection)
        let replacement = "[\(selected)](\(placeholder))"
        // Selecting the placeholder rather than placing a caret after it: a pasted URL
        // replaces it, and typing one replaces it too.
        let urlStart = selection.location + (("[\(selected)](" as NSString).length)
        return Edit(
            range: selection,
            replacement: replacement,
            selection: NSRange(location: urlStart, length: (placeholder as NSString).length))
    }

    /// Handles Return without teaching either platform about Markdown structure.
    ///
    /// A paragraph is a blank line in CommonMark. A hard line break is a visible
    /// backslash before the newline, which is safer than two invisible trailing
    /// spaces. Code blocks keep literal newlines, while lists retain the familiar
    /// Return-to-next-item / Return-on-empty-to-exit behaviour.
    static func breakLine(_ text: String, selection: NSRange, kind: BreakKind) -> Edit {
        let ns = text as NSString
        let caret = min(selection.location, ns.length)
        let lineStart = startOfLine(in: ns, at: caret)
        let prefixRange = NSRange(location: lineStart, length: caret - lineStart)
        let beforeCaret = ns.substring(with: prefixRange)

        if isInsideFence(text, atUTF16Offset: caret) {
            return insertion(selection, text: "\n")
        }

        if let list = listPrefix(in: beforeCaret) {
            switch kind {
            case .line:
                let indentation = String(repeating: " ", count: (list.marker as NSString).length)
                return insertion(selection, text: "\\\n\(indentation)")
            case .paragraph:
                let content = String(beforeCaret.dropFirst(list.marker.count))
                if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let range = NSRange(location: lineStart, length: selection.upperBound - lineStart)
                    let replacement = lineStart == 0 ? "" : "\n"
                    return Edit(
                        range: range,
                        replacement: replacement,
                        selection: NSRange(
                            location: lineStart + (replacement as NSString).length,
                            length: 0))
                }
                return insertion(selection, text: "\n\(list.marker)")
            }
        }

        return insertion(selection, text: kind == .line ? "\\\n" : "\n\n")
    }

    struct LinkPaste: Equatable {
        var edit: Edit
        /// The fallback label in the final document. A fetched title may replace only
        /// this range if the document has not changed in the meantime.
        var labelRange: NSRange
    }

    /// Turns one pasted web URL into a Markdown link.
    ///
    /// Selected prose wins over remote metadata and therefore needs no network
    /// request. Without a selection the address is an immediate, useful fallback;
    /// title lookup can replace only its label later.
    static func pasteURL(_ url: URL, into text: String, selection: NSRange) -> LinkPaste {
        let ns = text as NSString
        let rawURL = url.absoluteString
        let destination = escapeDestination(rawURL)
        let selected = selection.length > 0 ? ns.substring(with: selection) : rawURL
        let label = escapeLabel(
            selected.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression))
        let replacement = "[\(label)](\(destination))"
        let edit = Edit(
            range: selection,
            replacement: replacement,
            selection: NSRange(
                location: selection.location + (replacement as NSString).length,
                length: 0))
        return LinkPaste(
            edit: edit,
            labelRange: NSRange(
                location: selection.location + 1,
                length: (label as NSString).length))
    }

    /// Replaces the fallback URL label after metadata arrives.
    static func linkTitle(_ title: String, labelRange: NSRange) -> Edit {
        let label = escapeLabel(
            title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        return Edit(
            range: labelRange,
            replacement: label,
            selection: NSRange(location: labelRange.location + (label as NSString).length, length: 0))
    }

    /// Inserts Nook's deliberately small TOC extension on a block of its own.
    static func tableOfContents(_ text: String, selection: NSRange) -> Edit {
        if let existing = text.range(of: #"(?mi)^[ \t]*\[TOC\][ \t]*$"#, options: .regularExpression) {
            let range = NSRange(existing, in: text)
            return Edit(range: NSRange(location: range.location, length: 0), replacement: "", selection: range)
        }

        let ns = text as NSString
        let before = selection.location > 0
            ? ns.substring(with: NSRange(location: selection.location - 1, length: 1))
            : ""
        let after = selection.upperBound < ns.length
            ? ns.substring(with: NSRange(location: selection.upperBound, length: 1))
            : ""
        let leading = selection.location > 0 && before != "\n" ? "\n\n" : ""
        let trailing = selection.upperBound < ns.length && after != "\n" ? "\n\n" : "\n\n"
        let replacement = "\(leading)[TOC]\(trailing)"
        return Edit(
            range: selection,
            replacement: replacement,
            selection: NSRange(
                location: selection.location + (replacement as NSString).length,
                length: 0))
    }

    /// Adds a reference at the caret and a canonical definition at the end.
    static func footnote(
        _ text: String, selection: NSRange, label: String, content: String
    ) -> Transaction {
        let ns = text as NSString
        let referenceLocation = selection.upperBound
        let reference = "[^\(label)]"
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator: String
        if text.isEmpty || referenceLocation == 0 && ns.length == 0 {
            separator = ""
        } else if text.hasSuffix("\n\n") {
            separator = ""
        } else if text.hasSuffix("\n") {
            separator = "\n"
        } else {
            separator = "\n\n"
        }
        let definition = "\(separator)[^\(label)]: \(cleanContent)\n"

        // Both insertions coincide when the reference is placed at the original end.
        // Combining them gives their order an unambiguous meaning.
        if referenceLocation == ns.length {
            let combined = reference + definition
            return Transaction(
                replacements: [.init(range: NSRange(location: ns.length, length: 0), text: combined)],
                selection: NSRange(location: referenceLocation + (reference as NSString).length, length: 0))
        }

        return Transaction(
            replacements: [
                .init(range: NSRange(location: referenceLocation, length: 0), text: reference),
                .init(range: NSRange(location: ns.length, length: 0), text: definition),
            ],
            selection: NSRange(location: referenceLocation + (reference as NSString).length, length: 0))
    }

    static func updateFootnote(
        _ text: String, label: String, content: String
    ) -> Edit? {
        guard let definition = PlusMarkdownDocumentIndex(text).definition(label: label) else {
            return nil
        }
        let replacement = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return Edit(
            range: definition.contentRange,
            replacement: replacement,
            selection: NSRange(
                location: definition.contentRange.location + (replacement as NSString).length,
                length: 0))
    }

    static func appendFootnoteDefinition(
        _ text: String, label: String, content: String
    ) -> Edit {
        let ns = text as NSString
        let separator: String
        if text.isEmpty || text.hasSuffix("\n\n") {
            separator = ""
        } else if text.hasSuffix("\n") {
            separator = "\n"
        } else {
            separator = "\n\n"
        }
        let replacement = "\(separator)[^\(label)]: \(content.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        return Edit(
            range: NSRange(location: ns.length, length: 0),
            replacement: replacement,
            selection: NSRange(location: ns.length + (replacement as NSString).length, length: 0))
    }

    /// A fenced code block around the selection, on its own lines.
    ///
    /// Separate from `wrap` because a fence has to start a line: `` ``` `` in the
    /// middle of a sentence is an inline code span with three backticks, not a block.
    static func codeBlock(_ text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let selected = selection.length > 0 ? ns.substring(with: selection) : ""
        let needsLeadingBreak = selection.location > 0
            && ns.substring(with: NSRange(location: selection.location - 1, length: 1)) != "\n"
        let lead = needsLeadingBreak ? "\n" : ""

        let replacement = "\(lead)```\n\(selected)\n```\n"
        // The caret goes on the empty line inside the fence when there was nothing to
        // wrap; otherwise it stays on the wrapped code.
        let insideStart = selection.location + (("\(lead)```\n" as NSString).length)
        return Edit(
            range: selection,
            replacement: replacement,
            selection: NSRange(location: insideStart, length: (selected as NSString).length))
    }

    /// Inserts a block example from help without forcing a whole-document rewrite.
    static func insertBlock(_ text: String, selection: NSRange, source: String) -> Edit {
        let ns = text as NSString
        let before = selection.location > 0
            ? ns.substring(with: NSRange(location: selection.location - 1, length: 1))
            : ""
        let after = selection.upperBound < ns.length
            ? ns.substring(with: NSRange(location: selection.upperBound, length: 1))
            : ""
        let leading = selection.location > 0 && before != "\n" ? "\n\n" : ""
        let trailing = selection.upperBound < ns.length && after != "\n" ? "\n\n" : "\n"
        let replacement = "\(leading)\(source)\(trailing)"
        return Edit(
            range: selection,
            replacement: replacement,
            selection: NSRange(
                location: selection.location + (replacement as NSString).length,
                length: 0))
    }

    private static func startOfLine(in text: NSString, at location: Int) -> Int {
        guard location > 0 else { return 0 }
        let search = NSRange(location: 0, length: location)
        let newline = text.rangeOfCharacter(from: .newlines, options: .backwards, range: search)
        return newline.location == NSNotFound ? 0 : newline.upperBound
    }

    private static func insertion(_ selection: NSRange, text: String) -> Edit {
        Edit(
            range: selection,
            replacement: text,
            selection: NSRange(
                location: selection.location + (text as NSString).length,
                length: 0))
    }

    private static func isInsideFence(_ text: String, atUTF16Offset offset: Int) -> Bool {
        let ns = text as NSString
        let prefix = ns.substring(to: min(offset, ns.length))
        var inside = false
        for line in prefix.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inside.toggle()
            }
        }
        return inside
    }

    private static func listPrefix(in line: String) -> (marker: String, indent: String)? {
        guard
            let regex = try? NSRegularExpression(pattern: #"^([ \t]*)([-+*]|\d+[.)]) +"#),
            let match = regex.firstMatch(
                in: line, range: NSRange(location: 0, length: (line as NSString).length)),
            match.range.location != NSNotFound
        else { return nil }
        let marker = (line as NSString).substring(with: match.range)
        let indentRange = match.range(at: 1)
        let indent = indentRange.location == NSNotFound
            ? "" : (line as NSString).substring(with: indentRange)
        return (marker, indent)
    }

    private static func escapeLabel(_ label: String) -> String {
        label
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private static func escapeDestination(_ destination: String) -> String {
        destination
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
    }
}
