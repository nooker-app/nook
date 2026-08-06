#if DEBUG && os(macOS)
    import AppKit

    /// A temporary record of what moves the composer's scroll while somebody types.
    ///
    /// Here because movement reported on the last line of a document — on space and
    /// backspace, and only there — could not be reproduced outside the app. Five standalone
    /// probes, each with a real `NSTextView` in a real `NSScrollView` in a real window and
    /// this editor's pipeline replicated (delta-only restyle, no clamp on the typing path, a
    /// simulated input method, spell checking on, the caret at the document end and the view
    /// scrolled to the bottom) measured a viewport that did not move at all. Whatever is
    /// left is something the app has and a probe does not, so the app is where it has to be
    /// measured.
    ///
    /// Debug builds only, so nothing here can reach a release. It records offsets, lengths
    /// and classifications — never any of the writing.
    ///
    /// To read it: type at the end of a post, close the composer, and look for
    /// `nook-editor-scroll.log` under the app's container `tmp`.
    @MainActor
    enum PlusEditorScrollLog {
        private static var lines: [String] = []
        /// Small enough that a short session still lands on disk, large enough that the
        /// writing is not once per keystroke.
        private static let flushAt = 200

        static var url: URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("nook-editor-scroll.log")
        }

        /// One line: where the viewport is, how tall the document is, and where the caret
        /// and any input-method composition are.
        static func note(_ phase: String, in view: NSTextView?, extra: String = "") {
            guard let view else { return }
            let scroll = view.enclosingScrollView
            let selection = view.selectedRange()
            // The width is here to tell a re-wrap from a re-estimate: a height that changed
            // because the text view got narrower is a different bug from a height that
            // changed because TextKit had not finished laying it out.
            lines.append(
                String(
                    format: "%.3f %-16@ origin %8.2f docH %9.2f docW %7.2f visH %7.2f inset %5.1f "
                        + "sel %6d+%d marked %d len %6d %@",
                    ProcessInfo.processInfo.systemUptime,
                    phase as NSString,
                    scroll?.contentView.bounds.origin.y ?? -1,
                    view.frame.height,
                    view.frame.width,
                    scroll?.documentVisibleRect.height ?? -1,
                    scroll?.contentInsets.bottom ?? -1,
                    selection.location,
                    selection.length,
                    view.markedRange().length,
                    (view.string as NSString).length,
                    extra))
            if lines.count >= flushAt { flush() }
        }

        /// What kind of input this is, without recording what was typed.
        static func kind(of replacement: String?) -> String {
            guard let replacement else { return "nil" }
            if replacement.isEmpty { return "delete" }
            if replacement == "\n" { return "newline" }
            if replacement.allSatisfy(\.isWhitespace) { return "space" }
            return replacement.count == 1 ? "char" : "run(\(replacement.count))"
        }

        static func flush() {
            guard !lines.isEmpty else { return }
            let payload = lines.joined(separator: "\n") + "\n"
            lines.removeAll()
            guard let data = payload.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
#endif
