#if DEBUG && os(macOS)
import AppKit

/// A phase-tagged record of the reader's geometry, for the misbehaviour that only
/// happens in the running app.
///
/// Here because two rounds of measurement could reproduce the reader's *lag* and its
/// *top gap* in standalone probes and could not reproduce the third symptom at all —
/// the scroll moving while the reader sits untouched. Four probes parked on real
/// articles for seconds and recorded no bounds change and no movement. So this stops
/// modelling the framework and records what it actually did, in the app, on the
/// machine where it happens.
///
/// Debug builds only. `make build` and ⌘R are both Debug (`SWIFT_ACTIVE_COMPILATION_-`
/// `CONDITIONS = DEBUG`, and the package's compile line carries `-DDEBUG`), and
/// Archive and Profile are not — so nothing here can reach a release.
///
/// It records offsets, heights and counts. Never any of the reader's content.
///
/// **Remove it once it has answered the question.** One file, and every call site is
/// `GeometryLog.` — `grep -rn 'GeometryLog' Nook NookKit` finds all of them. The
/// pattern lives in `.claude/skills/ui-behavior-forensics/`, not in the product.
@MainActor
public enum GeometryLog {
    private static var lines: [String] = []
    /// Small enough that a session lands on disk even though the app keeps running
    /// with its window closed, large enough that the write is not once per event —
    /// writing per event would perturb the timing being measured.
    private static let flushAt = 100

    /// `~/Library/Containers/com.tim.nook/Data/tmp/ui-forensics.log` under the sandbox.
    public static var url: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ui-forensics.log")
    }

    /// One line per phase, carrying every number that could take part in the
    /// arithmetic afterwards.
    ///
    /// Three reconstructions have to check out, or the reading is wrong. A clamp is
    /// `origin == docH - visH + insetT`. The gap above the title is
    /// `titleWinY - clipWinY + origin`. And an uncommanded move is either `origin`
    /// changing — the framework moved the viewport — or `docH` changing with `origin`
    /// still, which is content above the reader growing and sliding the article down
    /// under a stationary scrollbar. Those two look identical to a person and have
    /// opposite causes, which is the single most useful thing this file can settle.
    public static func note(_ phase: String, clip: NSClipView?, extra: String = "") {
        let doc = clip?.documentView
        lines.append(
            String(
                format: "%.3f %-22@ origin %9.2f docH %10.2f visH %8.2f insetT %6.1f %@",
                ProcessInfo.processInfo.systemUptime,
                phase as NSString,
                clip?.bounds.origin.y ?? -1,
                doc?.frame.height ?? -1,
                clip?.bounds.height ?? -1,
                (clip?.superview as? NSScrollView)?.contentInsets.top ?? -1,
                extra))
        if lines.count >= flushAt { flush() }
    }

    /// A record with no clip view to hand — a store event, a task entering.
    public static func note(_ phase: String, extra: String = "") {
        note(phase, clip: reader, extra: extra)
    }

    /// The reader's own clip view, remembered so a store-side record can be read
    /// against the same geometry as a scroll event.
    fileprivate static weak var reader: NSClipView?

    /// Records every move of every large clip view in the app, whoever made it.
    ///
    /// `object: nil` on purpose: it holds no reference, so one registration outlives
    /// every `.id(article.id)` rebuild of the reader. The height filter drops the
    /// sidebar's and the article list's smaller scrollers; `clip=` on each line
    /// separates whatever is left.
    public static func observeAllClips() {
        guard observer == nil else { return }
        let sink = ClipSink()
        observer = sink
        // A target/selector observer rather than a block: the block form is
        // `@Sendable` and would have to carry a `Notification`, which is not, and the
        // point of this file is to add no machinery of its own to what it measures.
        // AppKit posts this on the main thread, which is what makes the isolation
        // sound.
        NotificationCenter.default.addObserver(
            sink, selector: #selector(ClipSink.boundsChanged(_:)),
            name: NSView.boundsDidChangeNotification, object: nil)
    }

    private static var observer: ClipSink?

    @MainActor
    private final class ClipSink: NSObject {
        @objc func boundsChanged(_ notification: Notification) {
            guard let clip = notification.object as? NSClipView, clip.frame.height > 200
            else { return }
            if clip.frame.width > (GeometryLog.reader?.frame.width ?? 0) {
                GeometryLog.reader = clip
            }
            GeometryLog.note(
                "bounds", clip: clip,
                extra: "clip=\(UInt(bitPattern: ObjectIdentifier(clip).hashValue) % 1000) "
                    + "w=\(Int(clip.frame.width))")
        }
    }

    public static func flush() {
        guard !lines.isEmpty,
              let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8)
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
