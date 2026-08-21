#if DEBUG && os(macOS)
import AppKit

/// What the main thread was doing when it stopped answering.
///
/// This replaced a geometry log that had answered its question. That one recorded
/// the reader's scroll offset and content height on every clip-view move, which
/// found and then verified three defects — a nested list whose layout cost 8.7x per
/// level of nesting, comment rows measured several times each, and an article whose
/// `LazyVStack` reported a height 22-26% short of the truth and revised it while the
/// reader scrolled. With the reader's content height now constant across a whole
/// session and no resting offset short of the top, the geometry it recorded had
/// nothing left to say, and the article list does.
///
/// So what remains is the part that generalises: a stall is *measured* rather than
/// inferred, and attributed to whatever ran inside it.
///
/// Debug builds only. `make build` and ⌘R are both Debug; Archive and Profile are
/// not, so nothing here can reach a release. It records counts and durations —
/// never any of the reader's or the library's content.
///
/// **Remove it once it has answered the question.** One file, and every call site is
/// `MainThreadLog.` — `grep -rn 'MainThreadLog' Nook NookKit` finds all of them. The
/// pattern lives in `.claude/skills/ui-behavior-forensics/`, not in the product.
@MainActor
public enum MainThreadLog {
    private static var lines: [String] = []
    /// Small enough that a session lands on disk even though the app keeps running
    /// with its window closed, large enough that the write is not once per event —
    /// writing per event would perturb the timing being measured.
    private static let flushAt = 100

    /// `~/Library/Containers/com.tim.nook/Data/tmp/ui-forensics.log` under the sandbox.
    public static var url: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ui-forensics.log")
    }

    /// One line, for an event worth seeing in sequence rather than in a total.
    public static func note(_ phase: String, extra: String = "") {
        lines.append(
            stamp() + " " + phase.padding(toLength: 22, withPad: " ", startingAt: 0) + " " + extra)
        if lines.count >= flushAt { flush() }
    }

    private static func raw(_ text: String) {
        lines.append(stamp() + " " + text)
        if lines.count >= flushAt { flush() }
    }

    private static func stamp() -> String {
        String(ProcessInfo.processInfo.systemUptime.rounded(toPlaces: 3))
    }

    /// Records which elements sent an HTML fragment down the WebKit importer, so the
    /// native path can be taught them. Element names and a length — never text.
    ///
    /// Kept after the cleanup because it is how the last 284ms freeze was found: one
    /// unknown element name sends a whole fragment down a path costing a thousand
    /// times more per call, and the fragment itself never says which one.
    ///
    /// Capped, because one article can fall back on every paragraph and the answer is
    /// in the first handful either way.
    public static func noteFallbackTags(in html: String) {
        guard fallbacksLogged < 24 else { return }
        fallbacksLogged += 1
        var tags: Set<String> = []
        var index = html.startIndex
        while let open = html[index...].firstIndex(of: "<") {
            let rest = html[html.index(after: open)...]
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "/" || $0 == "!" }
            if !name.isEmpty { tags.insert(name.lowercased()) }
            guard let next = html[html.index(after: open)...].firstIndex(of: "<") else { break }
            index = next
        }
        note(
            "import.fallback",
            extra: "len=\(html.utf8.count) tags=\(tags.sorted().joined(separator: ","))")
    }

    private static var fallbacksLogged = 0

    /// Names what the main thread is doing, so a stall can be attributed to it.
    /// Returns the label it replaced, so a nested scope can put it back instead of
    /// clearing its caller's — two labels that reset each other to "-" is how an
    /// attribution goes missing.
    @discardableResult
    public static func activity(_ label: String) -> String {
        MainThreadProbe.shared.setActivity(label)
    }

    /// Times a synchronous piece of work into the totals.
    @discardableResult
    public static func measure<T>(_ label: String, _ work: () -> T) -> T {
        let started = ProcessInfo.processInfo.systemUptime
        let result = work()
        MainThreadProbe.shared.add(
            label, ms: (ProcessInfo.processInfo.systemUptime - started) * 1000)
        return result
    }

    /// Counts an occurrence (`ms: 0`) or adds a duration already measured.
    public static func add(_ label: String, ms: Double) {
        MainThreadProbe.shared.add(label, ms: ms)
    }

    /// The totals, written at the app's own flush points and every couple of seconds.
    public static func summary() {
        let stalls = MainThreadProbe.shared.stallSummary()
        raw(
            "SUMMARY  main thread stalled \(stalls.count) times, "
                + "\(stalls.total.rounded(toPlaces: 2))s in total, "
                + "worst \(stalls.worst.rounded(toPlaces: 2))s")
        for entry in MainThreadProbe.shared.drainTotals() {
            let per = entry.calls > 0 ? entry.ms / Double(entry.calls) : 0
            raw(
                "SUMMARY  " + entry.label.padding(toLength: 26, withPad: " ", startingAt: 0)
                    + "\(entry.calls)".padding(toLength: 8, withPad: " ", startingAt: 0)
                    + "calls  \(entry.ms.rounded(toPlaces: 1))ms total  "
                    + "\(per.rounded(toPlaces: 2))ms/call")
        }
    }

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
            MainActor.assumeIsolated { MainThreadLog.flush() }
        }
        RunLoop.main.add(writer, forMode: .common)
        flushTimer = writer

        // Names the run loop's own phases, which is what gives an unlabelled stall an
        // attribution. All activities, one lock write each, no allocation.
        let names: [(CFRunLoopActivity, String)] = [
            (.entry, "entry"), (.beforeTimers, "beforeTimers"),
            (.beforeSources, "beforeSources"), (.beforeWaiting, "beforeWaiting"),
            (.afterWaiting, "afterWaiting"), (.exit, "exit"),
        ]
        let phases = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.allActivities.rawValue, true, 0
        ) { _, activity in
            let name = names.first { $0.0 == activity }?.1 ?? "?"
            MainThreadProbe.shared.setPhase(name)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), phases, .commonModes)
        phaseObserver = phases

        let watchdog = Thread {
            while true {
                let now = ProcessInfo.processInfo.systemUptime
                if let stall = MainThreadProbe.shared.sample(now: now, threshold: 0.25) {
                    // Reported when it ends, so its real duration is known. Queued to
                    // the main actor, which is free by then.
                    let seconds = stall.seconds
                    let during = stall.during
                    Task { @MainActor in
                        MainThreadLog.note(
                            "STALL", extra: "for \(seconds.rounded(toPlaces: 2))s during \(during)")
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
    private static var phaseObserver: CFRunLoopObserver?

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

/// The heartbeat, the work totals, and the stalls — reachable from the watchdog
/// thread, so lock-protected rather than main-actor.
private final class MainThreadProbe: @unchecked Sendable {
    static let shared = MainThreadProbe()

    private let lock = NSLock()
    private var heartbeat = ProcessInfo.processInfo.systemUptime
    private var activity = "-"
    private var phase = "-"
    /// Accumulated work, keyed by label: call count and total milliseconds. Reported
    /// as a summary rather than a line per call — a thousand list rows would bury the
    /// answer in its own logging.
    private var totals: [String: (calls: Int, ms: Double)] = [:]
    private var stalls: [(started: Double, seconds: Double, during: String)] = []

    func beat(_ now: Double) {
        lock.lock(); heartbeat = now; lock.unlock()
    }

    @discardableResult
    func setActivity(_ label: String) -> String {
        lock.lock()
        let previous = activity
        activity = label
        lock.unlock()
        return previous
    }

    /// Which part of the main run loop last ran, so a stall outside any labelled
    /// activity still says something. `beforeWaiting` is where AppKit commits a
    /// CoreAnimation transaction, which is where SwiftUI lays out; `afterWaiting`
    /// and `beforeSources` are handling an input event; `beforeTimers` is a timer.
    func setPhase(_ phase: String) {
        lock.lock(); self.phase = phase; lock.unlock()
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
        let currentPhase = phase
        let snapshot = totals
        lock.unlock()
        if late > threshold {
            if inStall == nil { inStall = (now - late, current, currentPhase, snapshot) }
            return nil
        }
        guard let stall = inStall else { return nil }
        inStall = nil
        let seconds = now - stall.started

        // What actually ran while the main thread was gone. This exists because the
        // first log this watchdog produced attributed 6.5 of 7.9 stalled seconds to
        // nothing at all: the labelled activities covered one cache warm and no other
        // main-thread work, so the majority of the freeze had no name. Diffing the
        // work counters across the stall names it without needing a new call site.
        lock.lock()
        let after = totals
        lock.unlock()
        let ran = after.compactMap { label, entry -> (String, Int, Double)? in
            let before = stall.work[label] ?? (calls: 0, ms: 0)
            let calls = entry.calls - before.calls
            guard calls > 0 else { return nil }
            return (label, calls, entry.ms - before.ms)
        }
        .sorted { $0.2 > $1.2 }
        .prefix(4)
        .map { $0.2 >= 1 ? "\($0.0)x\($0.1) \($0.2.rounded(toPlaces: 0))ms" : "\($0.0)x\($0.1)" }
        .joined(separator: ", ")

        let during = (stall.activity == "-" ? "runloop:\(stall.phase)" : stall.activity)
            + (ran.isEmpty ? "  ran nothing counted" : "  ran \(ran)")
        lock.lock(); stalls.append((stall.started, seconds, during)); lock.unlock()
        return (seconds, during)
    }

    private var inStall:
        (started: Double, activity: String, phase: String,
         work: [String: (calls: Int, ms: Double)])?

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

extension Double {
    fileprivate func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
#endif
