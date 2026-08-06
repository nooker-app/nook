// Paste into the module under investigation, add the call sites, run the app once,
// read the file. Delete both when the question is answered — the pattern lives in
// the skill, not in the product.
//
// This is the AppKit shape. For UIKit take `UIView`, and read `contentOffset.y`,
// `contentSize.height` and `bounds.height` off the scroll view instead.
#if DEBUG && os(macOS)
    import AppKit

    /// A phase-tagged record of geometry, for a misbehaviour that only happens in the
    /// running app.
    ///
    /// Debug builds only, so nothing here can reach a release. It records offsets,
    /// lengths and classifications — never any of the user's content.
    @MainActor
    enum GeometryLog {
        private static var lines: [String] = []
        /// Small enough that a short session lands on disk, large enough that the write
        /// is not once per event. Writing per event would perturb the timing being
        /// measured.
        private static let flushAt = 200

        /// Inside the sandbox container, which the agent can read directly:
        /// `find ~/Library/Containers -name 'ui-forensics.log'`
        static var url: URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("ui-forensics.log")
        }

        /// One line per phase. Log every number that could take part in the arithmetic
        /// later — the answer came from reconstructing one logged value out of three
        /// others, which is impossible if any of them is missing.
        static func note(_ phase: String, in view: NSView?, extra: String = "") {
            guard let view else { return }
            let scroll = view.enclosingScrollView
            lines.append(
                String(
                    format: "%.3f %-16@ origin %8.2f docH %9.2f docW %7.2f visH %7.2f inset %5.1f %@",
                    ProcessInfo.processInfo.systemUptime,
                    phase as NSString,
                    scroll?.contentView.bounds.origin.y ?? -1,
                    view.frame.height,
                    view.frame.width,
                    scroll?.documentVisibleRect.height ?? -1,
                    scroll?.contentInsets.bottom ?? -1,
                    extra))
            if lines.count >= flushAt { flush() }
        }

        /// Text-view state, when the subject is an editor. Lengths and marked-range
        /// extent, never the text.
        static func note(_ phase: String, in view: NSTextView?, extra: String = "") {
            guard let view else { return }
            let selection = view.selectedRange()
            note(
                phase, in: view as NSView,
                extra: "sel \(selection.location)+\(selection.length) "
                    + "marked \(view.markedRange().length) "
                    + "len \((view.string as NSString).length) \(extra)")
        }

        /// What kind of input this is, without recording what it was.
        static func kind(of replacement: String?) -> String {
            guard let replacement else { return "nil" }
            if replacement.isEmpty { return "delete" }
            if replacement == "\n" { return "newline" }
            if replacement.allSatisfy(\.isWhitespace) { return "space" }
            return replacement.count == 1 ? "char" : "run(\(replacement.count))"
        }

        /// Records every move of a clip view, whoever made it.
        ///
        /// The point of this one: it catches moves nothing in your code asked for. In the
        /// case this skill came from, the framework was clamping and then animating back,
        /// and no call site of ours was involved at all.
        static func observe(_ clip: NSClipView, in view: NSTextView?) {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: nil
            ) { [weak view] _ in
                MainActor.assumeIsolated { GeometryLog.note("bounds", in: view) }
            }
        }

        static func flush() {
            guard !lines.isEmpty, let data = (lines.joined(separator: "\n") + "\n")
                .data(using: .utf8)
            else { return }
            lines.removeAll()
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
