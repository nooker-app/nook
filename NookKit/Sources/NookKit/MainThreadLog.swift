#if DEBUG && os(macOS)
import AppKit
import os

/// Debug-only timing log used by repeatable performance scenarios. It records
/// counts and durations, never article or library content.
@MainActor
public enum MainThreadLog {
    private static var lines: [String] = []
    private static let flushAt = 100
    nonisolated private static let signposter = OSSignposter(subsystem: "com.tim.nook", category: "perf")

    public static var url: URL {
        if let path = launchValue("-NookPerfLog", in: ProcessInfo.processInfo.arguments)
            ?? ProcessInfo.processInfo.environment["NOOK_PERF_LOG_PATH"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("ui-forensics.log")
    }

    public static func note(_ phase: String, extra: String = "") {
        lines.append(stamp() + " " + phase.padding(toLength: 22, withPad: " ", startingAt: 0) + " " + extra)
        if lines.count >= flushAt { flush() }
    }

    private static func raw(_ text: String) {
        lines.append(stamp() + " " + text)
        if lines.count >= flushAt { flush() }
    }

    private static func stamp() -> String {
        String(ProcessInfo.processInfo.systemUptime.rounded(toPlaces: 3))
    }

    public static func runBegin() {
        guard !didBeginRun else { return }
        didBeginRun = true
        let arguments = ProcessInfo.processInfo.arguments
        let label = launchValue("-NookPerfLabel", in: arguments) ?? "debug"
        let library = launchValue("-NookPerfLibrary", in: arguments)
            .map { URL(fileURLWithPath: $0).lastPathComponent } ?? "default"
        let sha = launchValue("-NookPerfSHA", in: arguments)
            ?? ProcessInfo.processInfo.environment["NOOK_GIT_SHA"] ?? "unknown"
        let binarySha = Bundle.main.object(forInfoDictionaryKey: "NookBuildSHA") as? String ?? "unknown"
        let hz = NSScreen.main?.maximumFramesPerSecond ?? 0
        // Folded at compile time: true only for an unoptimized (-Onone) build, so
        // runs from `make build` and `make perf-build` can never be compared unseen.
        let opt = _isDebugAssertConfiguration() ? "-Onone" : "-O"
        raw("run.begin label=\(token(label)) sha=\(token(sha)) binarySha=\(token(binarySha)) lib=\(token(library)) hz=\(hz) opt=\(opt) log=\(url.path)")
        flush()
    }

    public static func scenarioBegin(id: String, rep: Int, cold: Bool) {
        if scenario != nil { scenarioEnd() }
        previousFrameTimestamp = nil
        // A selection from setup (or an earlier scenario) that never published must
        // not end inside this one and report a TTFR it did not cause.
        selectStartedAt = nil
        pendingSettle = false
        readerSelectStartedAt = nil
        pendingReaderSettle = false
        scenario = Scenario(
            id: id, rep: rep, cold: cold, startedAt: ProcessInfo.processInfo.systemUptime,
            probe: MainThreadProbe.shared.beginScenario())
        scenarioSignpostState = signposter.beginInterval("scenario", "id=\(id, privacy: .public)")
        note("scenario.begin", extra: "id=\(token(id)) rep=\(rep) cold=\(cold ? 1 : 0)")
    }

    /// Ends the open scenario. `activeEnd` is when the workload itself stopped
    /// (action done, refresh finished); a later publish, settle or stall end
    /// extends it. The driver's quiesce tail after it is wall time (`dur`) but not
    /// part of the rates (`activeDur`).
    public static func scenarioEnd(activeEnd: Double? = nil) {
        guard let current = scenario else { return }
        scenario = nil
        if let state = scenarioSignpostState { signposter.endInterval("scenario", state) }
        scenarioSignpostState = nil

        let now = ProcessInfo.processInfo.systemUptime
        var activeUntil = activeEnd ?? now
        if lastActivityAt > current.startedAt { activeUntil = max(activeUntil, lastActivityAt) }
        activeUntil = min(max(activeUntil, current.startedAt), now)
        let durationMs = (now - current.startedAt) * 1000
        let activeMs = (activeUntil - current.startedAt) * 1000
        let diff = MainThreadProbe.shared.endScenario(since: current.probe)
        let stalls = diff.stalls.map { $0 * 1000 }

        // Frame statistics cover frames that started inside the active window.
        // A callback delivered after a long main-thread stall must still retain
        // the in-flight frame that exposes that stall.
        let active = current.frames.filter { $0.at - $0.ms / 1000 <= activeUntil }
        let deltas = active.map(\.ms).sorted()
        var dropped = 0
        var hitchMs = 0.0
        for frame in active where frame.ms > frame.expected * 1.5 {
            dropped += max(1, Int((frame.ms / frame.expected).rounded(.down)) - 1)
            hitchMs += max(0, frame.ms - frame.expected)
        }
        let p99Index = deltas.isEmpty ? 0 : min(deltas.count - 1, Int(Double(deltas.count) * 0.99))
        let droppedPct = deltas.count + dropped > 0 ? Double(dropped) / Double(deltas.count + dropped) * 100 : 0

        let calls: (String) -> Int = { diff.totals[$0]?.calls ?? 0 }
        let total: (String) -> Double = { diff.totals[$0]?.ms ?? 0 }
        let p95: (String) -> Double = { percentile(diff.distributions[$0] ?? [], 0.95) }
        let maximum: (String) -> Double = { diff.distributions[$0]?.max() ?? 0 }
        var fields = [
            "scenario.stats", "id=\(token(current.id))", "rep=\(current.rep)", "cold=\(current.cold ? 1 : 0)",
            "dur=\(number(durationMs))", "activeDur=\(number(activeMs))",
            "stalls50=\(stalls.filter { $0 >= 50 }.count)", "stalls100=\(stalls.filter { $0 >= 100 }.count)",
            "stalls250=\(stalls.filter { $0 >= 250 }.count)", "stalls500=\(stalls.filter { $0 >= 500 }.count)",
            "stalls1000=\(stalls.filter { $0 >= 1000 }.count)", "worstStall=\(number(stalls.max() ?? 0))",
            "stalledMs=\(number(stalls.reduce(0, +)))", "ttfr=\(number(current.ttfr))",
            "readerTTFR=\(number(current.readerTTFR))",
            // `list.publish` and `list.publish.animated` stay exclusive labels; the
            // stat is their sum, and the animated share is reported beside it.
            "publish=\(calls("list.publish") + calls("list.publish.animated"))",
            "publishAnimated=\(calls("list.publish.animated"))",
            "publishRows=\(current.publishRows)", "body=\(calls("list.body"))",
            "rowcontent=\(calls("list.rowcontent"))", "row=\(calls("list.row"))", "rowHeight=\(calls("list.row.height"))",
            "rowHeightFlush=\(calls("list.row.height.flush"))",
            "rowMenu=\(calls("list.row.menu") + calls("list.row.swipe"))", "relTime=\(calls("relativetime.body"))",
            "rootBody=\(calls("root.body"))", "sidebarBody=\(calls("sidebar.body"))", "sidebarRow=\(calls("sidebar.row"))",
            "readerBody=\(calls("reader.body"))", "readerBlocks=\(calls("reader.blocks"))", "titleBox=\(calls("list.title.box"))",
            "titleBoxRelease=\(calls("list.title.box.release"))",
            "frames=\(deltas.count)", "dropped=\(dropped)", "droppedPct=\(number(droppedPct))",
            "hitchMs=\(number(hitchMs))", "hitchRatio=\(number(activeMs > 0 ? hitchMs / (activeMs / 1000) : 0))",
            "p99Frame=\(number(deltas.isEmpty ? 0 : deltas[p99Index]))", "worstFrame=\(number(deltas.last ?? 0))",
            "applyMs=\(number(total("store.applyDisplayed")))", "mergeMs=\(number(total("store.merge")))",
            "mergeP95=\(number(p95("store.merge")))", "mergeCalls=\(calls("store.merge"))",
            "mergeFlush=\(calls("store.merge.flush"))", "mergeChangedNoNew=\(calls("store.merge.changedNoNew"))",
            "mergeFallback=\(calls("store.merge.fallback"))", "didsetMs=\(number(total("store.didset.articles")))",
            "markSeenMs=\(number(total("store.markSeen")))", "hlcTick=\(calls("store.hlc.tick"))",
            "updateInPlaceMs=\(number(total("store.updateInPlace")))",
            "updateInPlaceMaxMs=\(number(maximum("store.updateInPlace")))", "grow=\(calls("list.window.grow"))",
            "growMaxMs=\(number(maximum("list.window.grow")))",
        ]
        fields += current.extras.map { "\($0.key)=\($0.value)" }
        raw(fields.joined(separator: " "))
        flush()
    }

    public static var isScenarioActive: Bool { scenario != nil }

    /// Attaches a scenario-specific value (`toggles`, `missedSelection`, …) to the
    /// open scenario's stats line. Keys appear only on scenarios that set them.
    public static func scenarioValue(_ key: String, _ value: Int) {
        guard var current = scenario else { return }
        current.extras.removeAll { $0.key == key }
        current.extras.append((key, String(value)))
        scenario = current
    }

    public static func recordFrame(timestamp: Double, targetTimestamp: Double) {
        guard var current = scenario else { return }
        defer { scenario = current }
        guard let previous = previousFrameTimestamp else {
            previousFrameTimestamp = timestamp
            return
        }
        previousFrameTimestamp = timestamp
        current.frames.append((
            at: ProcessInfo.processInfo.systemUptime,
            ms: max(0, (timestamp - previous) * 1000),
            expected: max(0.1, (targetTimestamp - timestamp) * 1000)))
    }

    public static func selectionBegan(source: String) {
        selectStartedAt = ProcessInfo.processInfo.systemUptime
        pendingSettle = false
        note("select.begin", extra: "source=\(token(source))")
    }

    public static func recordListPublish(from oldCount: Int, to newCount: Int, animated: Bool) {
        lastPublishAt = ProcessInfo.processInfo.systemUptime
        lastMarkedActivityAt = lastPublishAt
        add(animated ? "list.publish.animated" : "list.publish", ms: 0)
        note("list.publish", extra: "rows=\(oldCount)->\(newCount) animated=\(animated)")
        if var current = scenario {
            if !current.didRecordPublish {
                current.publishRows = newCount
                current.didRecordPublish = true
            }
            scenario = current
        }
        if selectStartedAt != nil { pendingSettle = true }
    }

    /// Starts a reader TTFR: an article selection whose reader has yet to render.
    public static func articleSelectionBegan() {
        readerSelectStartedAt = ProcessInfo.processInfo.systemUptime
        pendingReaderSettle = false
    }

    /// The reader's `body`. Counted as `reader.body`, and the first one after an
    /// article selection ends that selection's reader TTFR on the next heartbeat,
    /// the same approximation `list.settled` uses for the list.
    public static func readerBody() {
        add("reader.body", ms: 0)
        if readerSelectStartedAt != nil { pendingReaderSettle = true }
    }

    /// Counts `label` at most once per main run-loop turn — how many turns did
    /// any of this work, rather than how many times it was asked for.
    public static func addOncePerTurn(_ label: String) {
        guard countedThisTurn.insert(label).inserted else { return }
        add(label, ms: 0)
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { _ = MainThreadLog.countedThisTurn.remove(label) }
        }
    }

    private static var countedThisTurn: Set<String> = []

    private static func heartbeat(_ now: Double) {
        MainThreadProbe.shared.beat(now)
        if pendingSettle, let selectedAt = selectStartedAt {
            pendingSettle = false
            selectStartedAt = nil
            let ms = (now - selectedAt) * 1000
            lastMarkedActivityAt = now
            if var current = scenario { current.ttfr = ms; scenario = current }
            note("list.settled", extra: "sinceSelect=\(number(ms))ms")
        }
        if pendingReaderSettle, let selectedAt = readerSelectStartedAt {
            pendingReaderSettle = false
            readerSelectStartedAt = nil
            let ms = (now - selectedAt) * 1000
            lastMarkedActivityAt = now
            if var current = scenario { current.readerTTFR = max(current.readerTTFR, ms); scenario = current }
            note("reader.settled", extra: "sinceSelect=\(number(ms))ms")
        }
    }

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
        note("import.fallback", extra: "len=\(html.utf8.count) tags=\(tags.sorted().joined(separator: ","))")
    }

    private static var fallbacksLogged = 0

    @discardableResult
    public static func activity(_ label: String) -> String { MainThreadProbe.shared.setActivity(label) }

    @discardableResult
    nonisolated public static func measure<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
        let name = signpostName(label)
        let state = signposter.beginInterval(name)
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            MainThreadProbe.shared.add(label, ms: (ProcessInfo.processInfo.systemUptime - started) * 1000)
            signposter.endInterval(name, state)
        }
        return try work()
    }

    nonisolated public static func add(_ label: String, ms: Double) { MainThreadProbe.shared.add(label, ms: ms) }

    public static func summary() {
        let stalls = MainThreadProbe.shared.stallSummary()
        raw("SUMMARY  main thread stalled \(stalls.count) times, \(stalls.total.rounded(toPlaces: 2))s in total, worst \(stalls.worst.rounded(toPlaces: 2))s")
        for entry in MainThreadProbe.shared.totalsSnapshot() {
            let per = entry.calls > 0 ? entry.ms / Double(entry.calls) : 0
            raw("SUMMARY  " + entry.label.padding(toLength: 26, withPad: " ", startingAt: 0)
                + "\(entry.calls)".padding(toLength: 8, withPad: " ", startingAt: 0)
                + "calls  \(entry.ms.rounded(toPlaces: 1))ms total  \(per.rounded(toPlaces: 2))ms/call")
        }
    }

    public static func startWatchdog() {
        guard heartbeatTimer == nil else { return }
        runBegin()
        let configuredMs = launchValue("-NookStallMs", in: ProcessInfo.processInfo.arguments).flatMap(Double.init)
        let heartbeatInterval = configuredMs == nil ? 0.05 : 0.008
        let threshold = (configuredMs ?? 250) / 1000
        MainThreadProbe.shared.configure(interval: heartbeatInterval, threshold: threshold)
        let timer = Timer(timeInterval: heartbeatInterval, repeats: true) { _ in
            MainActor.assumeIsolated { MainThreadLog.heartbeat(ProcessInfo.processInfo.systemUptime) }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
        let writer = Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { MainThreadLog.flush() }
        }
        RunLoop.main.add(writer, forMode: .common)
        flushTimer = writer

        let names: [(CFRunLoopActivity, String)] = [
            (.entry, "entry"), (.beforeTimers, "beforeTimers"), (.beforeSources, "beforeSources"),
            (.beforeWaiting, "beforeWaiting"), (.afterWaiting, "afterWaiting"), (.exit, "exit"),
        ]
        let phases = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0) { _, activity in
            MainThreadProbe.shared.setPhase(names.first { $0.0 == activity }?.1 ?? "?")
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), phases, .commonModes)
        phaseObserver = phases

        let watchdog = Thread {
            while true {
                let now = ProcessInfo.processInfo.systemUptime
                if let stall = MainThreadProbe.shared.sample(now: now) {
                    Task { @MainActor in
                        MainThreadLog.note("STALL", extra: "for \(stall.seconds.rounded(toPlaces: 3))s during \(stall.during)")
                    }
                }
                Thread.sleep(forTimeInterval: heartbeatInterval)
            }
        }
        watchdog.name = "nook.ui-forensics.watchdog"
        watchdog.qualityOfService = .utility
        watchdog.start()
    }

    public static func flush() {
        guard !lines.isEmpty, let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) else { return }
        lines.removeAll()
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else { try? data.write(to: url) }
    }

    private struct Scenario {
        let id: String
        let rep: Int
        let cold: Bool
        let startedAt: Double
        let probe: MainThreadProbe.Snapshot
        var frames: [(at: Double, ms: Double, expected: Double)] = []
        var publishRows = 0
        var didRecordPublish = false
        /// -1 until a select → `list.settled` completes inside the scenario.
        var ttfr: Double = -1
        /// -1 until an article selection → first reader body settles; the worst one otherwise.
        var readerTTFR: Double = -1
        var extras: [(key: String, value: String)] = []
    }

    private static var didBeginRun = false
    private static var scenario: Scenario?
    private static var scenarioSignpostState: OSSignpostIntervalState?
    private static var previousFrameTimestamp: Double?
    private static var selectStartedAt: Double?
    private static var pendingSettle = false
    private static var readerSelectStartedAt: Double?
    private static var pendingReaderSettle = false
    public private(set) static var lastPublishAt: Double = 0
    private static var lastMarkedActivityAt: Double = 0
    /// The latest publish, list/reader settle, or end of a stall — the last sign
    /// that a scenario's work was still running.
    public static var lastActivityAt: Double { max(lastMarkedActivityAt, MainThreadProbe.shared.lastStallAt()) }
    private static var heartbeatTimer: Timer?
    private static var flushTimer: Timer?
    private static var phaseObserver: CFRunLoopObserver?

    public static var secondsSinceLastStall: Double {
        ProcessInfo.processInfo.systemUptime - MainThreadProbe.shared.lastStallAt()
    }

    private nonisolated static func signpostName(_ label: String) -> StaticString {
        switch label {
        case "store.applyDisplayed": "store.applyDisplayed"
        case "bg.filter": "bg.filter"
        case "store.merge": "store.merge"
        case "store.didset.articles": "store.didset.articles"
        case "store.markSeen": "store.markSeen"
        case "store.updateInPlace": "store.updateInPlace"
        case "root.body": "root.body"
        case "sidebar.body": "sidebar.body"
        case "sidebar.row": "sidebar.row"
        case "reader.body": "reader.body"
        default: "nook.perf"
        }
    }

    private static func launchValue(_ key: String, in arguments: [String]) -> String? {
        PerfLaunch.value(for: key, in: arguments)
    }

    private static func token(_ value: String) -> String { value.replacingOccurrences(of: " ", with: "_") }
    private static func number(_ value: Double) -> String { String(value.rounded(toPlaces: 2)) }
    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count) * fraction).rounded(.up)) - 1))]
    }
}

private final class MainThreadProbe: @unchecked Sendable {
    struct Total: Sendable { var calls = 0; var ms = 0.0 }
    struct Snapshot: Sendable { let totals: [String: Total]; let stallCount: Int }
    static let shared = MainThreadProbe()
    /// Labels whose per-call distribution a scenario reports (p95/max). Everything
    /// else keeps only running totals, so per-row counters cost O(1) memory however
    /// long a Debug session runs.
    private static let distributionLabels: Set<String> = ["store.merge", "store.updateInPlace", "list.window.grow"]

    private let lock = NSLock()
    private var heartbeat = ProcessInfo.processInfo.systemUptime
    private var interval = 0.05
    private var threshold = 0.25
    /// The last heartbeat gap longer than the threshold: the previous beat and the
    /// first fresh one after it, so a stall ends where the main thread came back
    /// rather than where the watchdog next happened to look.
    private var lastGap: (previous: Double, fresh: Double)?
    private var activity = "-"
    private var phase = "-"
    private var totals: [String: Total] = [:]
    private var distributions: [String: [Double]] = [:]
    private var recordsDistributions = false
    private var stalls: [(started: Double, seconds: Double, during: String)] = []
    /// Watchdog thread only.
    private var inStall: (started: Double, activity: String, phase: String, work: [String: Total])?
    private var lastStallEndedAt = -Double.infinity

    func configure(interval: Double, threshold: Double) {
        lock.withLock { self.interval = interval; self.threshold = threshold }
    }
    func beat(_ now: Double) {
        lock.withLock {
            if now - heartbeat > threshold { lastGap = (heartbeat, now) }
            heartbeat = now
        }
    }
    @discardableResult func setActivity(_ label: String) -> String {
        lock.withLock { let previous = activity; activity = label; return previous }
    }
    func setPhase(_ value: String) { lock.withLock { phase = value } }
    func add(_ label: String, ms: Double) {
        lock.withLock {
            totals[label, default: Total()].calls += 1
            totals[label, default: Total()].ms += ms
            if recordsDistributions, Self.distributionLabels.contains(label) {
                distributions[label, default: []].append(ms)
            }
        }
    }

    func beginScenario() -> Snapshot {
        lock.withLock {
            distributions = [:]
            recordsDistributions = true
            return Snapshot(totals: totals, stallCount: stalls.count)
        }
    }

    func endScenario(since snapshot: Snapshot) -> (totals: [String: Total], distributions: [String: [Double]], stalls: [Double]) {
        lock.withLock {
            recordsDistributions = false
            var changed: [String: Total] = [:]
            for (label, entry) in totals {
                let before = snapshot.totals[label] ?? Total()
                guard entry.calls > before.calls else { continue }
                changed[label] = Total(calls: entry.calls - before.calls, ms: entry.ms - before.ms)
            }
            let result = (changed, distributions, Array(stalls.dropFirst(snapshot.stallCount)).map(\.seconds))
            distributions = [:]
            return result
        }
    }

    func sample(now: Double) -> (seconds: Double, during: String)? {
        lock.lock()
        let late = now - heartbeat
        let threshold = threshold
        let interval = interval
        if late > threshold, inStall == nil {
            inStall = (heartbeat, activity, phase, totals)
        }
        let gap = lastGap
        lock.unlock()
        if late > threshold { return nil }
        guard let stall = inStall else { return nil }
        inStall = nil
        // The main thread was certainly blocked from the beat it missed
        // (previous + interval) until the fresh beat — a lower bound, never an
        // overstatement by the watchdog's own sampling period.
        let fresh = gap.flatMap { $0.previous == stall.started ? $0.fresh : nil } ?? now
        let seconds = max(0, fresh - stall.started - interval)
        let after = lock.withLock { totals }
        let ran = after.compactMap { label, entry -> (String, Int, Double)? in
            let before = stall.work[label] ?? Total()
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
        lock.withLock {
            stalls.append((stall.started + interval, seconds, during))
            lastStallEndedAt = fresh
        }
        return (seconds, during)
    }

    func totalsSnapshot() -> [(label: String, calls: Int, ms: Double)] {
        lock.withLock {
            totals.map { (label: $0.key, calls: $0.value.calls, ms: $0.value.ms) }.sorted { $0.ms > $1.ms }
        }
    }
    func stallSummary() -> (count: Int, total: Double, worst: Double) {
        lock.withLock { (stalls.count, stalls.reduce(0) { $0 + $1.seconds }, stalls.map(\.seconds).max() ?? 0) }
    }
    func lastStallAt() -> Double { lock.withLock { lastStallEndedAt } }
}

extension Double {
    fileprivate func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places)); return (self * factor).rounded() / factor
    }
}
#endif
