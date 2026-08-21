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
    fileprivate static var lines: [String] = []
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
        // Built by interpolation rather than `String(format:)`: mixing `%@` with `%f`
        // in one format string printed every float as `nan` on this ABI, which the
        // verification probe caught before anyone tried to read a log full of them.
        lines.append(
            stamp() + " " + phase.padding(toLength: 22, withPad: " ", startingAt: 0)
                + " origin " + fixed(clip?.bounds.origin.y, 2, 9)
                + " docH " + fixed(doc?.frame.height, 2, 10)
                + " visH " + fixed(clip?.bounds.height, 2, 8)
                + " insetT " + fixed((clip?.superview as? NSScrollView)?.contentInsets.top, 1, 6)
                + " " + extra)
        if lines.count >= flushAt { flush() }
    }

    /// A line with no geometry attached.
    private static func raw(_ text: String) {
        lines.append(stamp() + " " + text)
        if lines.count >= flushAt { flush() }
    }

    private static func stamp() -> String {
        String(ProcessInfo.processInfo.systemUptime.rounded(toPlaces: 3))
    }

    /// A right-aligned fixed-point number, or a dash when there was nothing to read —
    /// which is itself information, because it means no scroll view was found.
    private static func fixed(_ value: CGFloat?, _ places: Int, _ width: Int) -> String {
        let text = value.map { String(Double($0).rounded(toPlaces: places)) } ?? "-"
        return String(repeating: " ", count: max(0, width - text.count)) + text
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

    /// Appends the buffered lines. `summary()` is deliberately not called here — the
    /// periodic writer runs every two seconds and the totals would repeat that often.
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

// MARK: - Where the main thread went

/// Everything the watchdog needs, behind a lock, because it is read from a
/// background thread while the main one is busy — which is the whole point.
private final class MainThreadProbe: @unchecked Sendable {
    static let shared = MainThreadProbe()

    private let lock = NSLock()
    private var heartbeat = ProcessInfo.processInfo.systemUptime
    private var activity = "-"
    /// Accumulated work, keyed by label: call count and total milliseconds. Reported
    /// as a summary rather than a line per call — three hundred blocks would bury
    /// the answer in its own logging.
    private var totals: [String: (calls: Int, ms: Double)] = [:]
    private var stalls: [(started: Double, seconds: Double, during: String)] = []

    func beat(_ now: Double) {
        lock.lock(); heartbeat = now; lock.unlock()
    }

    func setActivity(_ label: String) {
        lock.lock(); activity = label; lock.unlock()
    }

    func add(_ label: String, ms: Double) {
        lock.lock()
        var entry = totals[label] ?? (0, 0)
        entry.calls += 1
        entry.ms += ms
        totals[label] = entry
        lock.unlock()
    }

    /// Called from the watchdog thread. Returns a stall that has just ended.
    func sample(now: Double, threshold: Double) -> (seconds: Double, during: String)? {
        lock.lock()
        let late = now - heartbeat
        let current = activity
        lock.unlock()
        if late > threshold {
            if inStall == nil { inStall = (now - late, current) }
            return nil
        }
        guard let stall = inStall else { return nil }
        inStall = nil
        let seconds = now - stall.0
        lock.lock(); stalls.append((stall.0, seconds, stall.1)); lock.unlock()
        return (seconds, stall.1)
    }

    private var inStall: (Double, String)?

    func drainTotals() -> [(label: String, calls: Int, ms: Double)] {
        lock.lock()
        let snapshot = totals.map { (label: $0.key, calls: $0.value.calls, ms: $0.value.ms) }
        lock.unlock()
        return snapshot.sorted { $0.ms > $1.ms }
    }

    func stallSummary() -> (count: Int, total: Double, worst: Double) {
        lock.lock()
        let all = stalls
        lock.unlock()
        return (all.count, all.reduce(0) { $0 + $1.seconds }, all.map(\.seconds).max() ?? 0)
    }
}

extension GeometryLog {
    /// Starts the heartbeat and the watchdog that reads it.
    ///
    /// A stall is measured rather than inferred: the main thread stamps the clock
    /// every 50ms, and a background thread notices when that stamp goes stale. A
    /// timer cannot fire while the main thread is blocked, which is exactly what
    /// makes its silence the measurement.
    public static func startWatchdog() {
        guard heartbeatTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainThreadProbe.shared.beat(ProcessInfo.processInfo.systemUptime)
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer

        // Written every couple of seconds as well as on the app's own flush points, so
        // a session survives being force-quit rather than living in a buffer.
        let writer = Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { GeometryLog.flush() }
        }
        RunLoop.main.add(writer, forMode: .common)
        flushTimer = writer

        let watchdog = Thread {
            while true {
                let now = ProcessInfo.processInfo.systemUptime
                if let stall = MainThreadProbe.shared.sample(now: now, threshold: 0.25) {
                    // Reported when it ends, so its real duration is known. Queued to
                    // the main actor, which is free by then.
                    let seconds = stall.seconds
                    let during = stall.during
                    Task { @MainActor in
                        GeometryLog.note(
                            "STALL",
                            extra: "for \(seconds.rounded(toPlaces: 2))s during \(during)")
                    }
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        watchdog.name = "nook.ui-forensics.watchdog"
        watchdog.qualityOfService = .utility
        watchdog.start()
    }

    private static var heartbeatTimer: Timer?
    private static var flushTimer: Timer?

    /// Names what the main thread is doing, so a stall can be attributed to it.
    public static func activity(_ label: String) {
        MainThreadProbe.shared.setActivity(label)
    }

    /// Times a piece of synchronous work and accumulates it under `label`.
    ///
    /// Accumulated, not logged per call: the interesting number is "the WebKit
    /// importer ran 412 times for 9.8 seconds", which a line per call would hide.
    @discardableResult
    public static func measure<T>(_ label: String, _ work: () -> T) -> T {
        let start = ProcessInfo.processInfo.systemUptime
        let value = work()
        MainThreadProbe.shared.add(
            label, ms: (ProcessInfo.processInfo.systemUptime - start) * 1000)
        return value
    }

    /// Records work timed by the caller.
    public static func add(_ label: String, ms: Double) {
        MainThreadProbe.shared.add(label, ms: ms)
    }

    /// The totals, written whenever the log is flushed.
    public static func summary() {
        let stalls = MainThreadProbe.shared.stallSummary()
        // Its own line shape: the geometry columns say nothing about a total, and this
        // is the part of the log that gets read first.
        raw("SUMMARY  main thread stalled \(stalls.count) times,"
            + " \(stalls.total.rounded(toPlaces: 2))s in total, worst \(stalls.worst.rounded(toPlaces: 2))s")
        for entry in MainThreadProbe.shared.drainTotals() where entry.ms >= 1 {
            let per = entry.ms / Double(max(1, entry.calls))
            raw("SUMMARY  " + entry.label.padding(toLength: 26, withPad: " ", startingAt: 0)
                + entry.calls.description.padding(toLength: 8, withPad: " ", startingAt: 0)
                + "calls  " + entry.ms.rounded(toPlaces: 1) + "ms total"
                + "  " + per.rounded(toPlaces: 2) + "ms/call")
        }
    }
}

private extension Double {
    /// Fixed decimals without a format string, for the reason given in `note`.
    func rounded(toPlaces places: Int) -> String {
        let scale = pow(10.0, Double(places))
        let value = (self * scale).rounded() / scale
        var text = String(value)
        if let dot = text.firstIndex(of: ".") {
            let decimals = text.distance(from: text.index(after: dot), to: text.endIndex)
            if decimals < places { text += String(repeating: "0", count: places - decimals) }
        } else if places > 0 {
            text += "." + String(repeating: "0", count: places)
        }
        return text
    }
}
#endif
