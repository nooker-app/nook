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

    private static func startOfLine(in text: NSString, at location: Int) -> Int {
        guard location > 0 else { return 0 }
        let search = NSRange(location: 0, length: location)
        let newline = text.rangeOfCharacter(from: .newlines, options: .backwards, range: search)
        return newline.location == NSNotFound ? 0 : newline.upperBound
    }
}
