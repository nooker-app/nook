#if DEBUG
@preconcurrency import AppKit
import NookKit
import ObjectiveC

/// JSON schema:
/// ```json
/// {
///   "repetitions": 5,
///   "coldFirst": true,
///   "steps": [{
///     "id": "A1",
///     "setup": [{"type":"selectFeed","target":"feed-small"}],
///     "action": {"type":"selectSmart","target":"all"}
///   }]
/// }
/// ```
/// `type` is one of selectSmart/selectFeed/selectFeeds/selectFolder/
/// selectCategory/search/refreshAll/refreshFeed/refreshActivation/selectIndex/
/// setRead/toggleStar/nextArticle/fling/thumbDrag/constantScroll/keyRepeat/
/// classifyAll/wait/noop. Optional action fields are `target`, `ids`, `value`,
/// `index`, `count`, `rate`, and `duration` (seconds). `coldFirst` adds a rep 0
/// recorded as `cold=1`; set it only on the step that really runs first after
/// launch. The first step that runs (after any `-NookPerfOnly` filter) and does
/// not state `coldFirst` gets a rep 0 marked `cold=1 warmup=1`, which perfreport
/// leaves out of the warm medians; `"coldFirst": false` keeps a one-rep-per-launch
/// script's only rep. An unresolvable target or a missing list logs
/// `perf.driver.error`, which makes the run invalid.
@MainActor
final class PerfDriver {
    static let shared = PerfDriver()
    private var didRun = false

    /// Direct child launches may begin without a foreground activation event.
    /// This acts on this process only, even if the installed app shares its id.
    static func prepareLaunchIfRequested() {
        guard PerfLaunch.isActive else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MainThreadLog.note("perf.activation", extra: "pid=\(ProcessInfo.processInfo.processIdentifier) windows=\(NSApp.windows.count) policy=\(NSApp.activationPolicy().rawValue)")
        MainThreadLog.flush()
        requestInitialWindow(after: 1, retry: true)
    }

    /// With no saved application state, a directly launched child never gets
    /// its initial `Window("main")`. Ask for it the way a Dock click does. The
    /// window comes from SwiftUI's default reopen handling, not app code:
    /// `applicationShouldHandleReopen` returns true, but `WindowReopener` is
    /// still nil because no window has appeared yet. `Window` is single-instance,
    /// so a reopen while the window is still being built (a heavy library's
    /// init) only re-fronts it. Retries once for a slow launch.
    private static func requestInitialWindow(after delay: TimeInterval, retry: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard !NSApp.windows.contains(where: \.isVisible) else { return }
            let windowsBefore = NSApp.windows.count
            let event = NSAppleEventDescriptor(
                eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID))
            _ = try? event.sendEvent(options: .noReply, timeout: 1)
            // The event is handled on a later runloop turn.
            DispatchQueue.main.async {
                MainThreadLog.note("perf.activation", extra: "reopenApplication windowsBefore=\(windowsBefore) windows=\(NSApp.windows.count)")
            }
            if retry { requestInitialWindow(after: 2, retry: false) }
        }
    }

    private struct Script: Decodable {
        var repetitions: Int?
        var coldFirst: Bool?
        let steps: [Step]
    }

    private struct Step: Decodable {
        let id: String
        var repetitions: Int?
        var coldFirst: Bool?
        var setup: [Action]?
        let action: Action
    }

    private struct Action: Decodable {
        let type: String
        var target: String?
        var ids: [String]?
        var value: String?
        var index: Int?
        var count: Int?
        var rate: Double?
        var duration: Double?
    }

    func runIfRequested(store: ReaderStore) async {
        guard !didRun, let path = launchValue("-NookPerfScript") else { return }
        didRun = true
        // Publish perf.library before the first potentially long scenario.
        MainThreadLog.flush()
        do {
            let script = try JSONDecoder().decode(Script.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let only = launchValue("-NookPerfOnly").map {
                Set($0.split(separator: ",").map(String.init))
            }
            let steps = only.map { ids in script.steps.filter { ids.contains($0.id) } } ?? script.steps
            if let only, steps.isEmpty {
                MainThreadLog.note("perf.driver.error", extra: "reason=no_matching_step only=\(only.sorted().joined(separator: ","))")
            }
            try await fixLayout()
            let adapter = PerfStoreAdapter(store: store)
            for (position, step) in steps.enumerated() {
                let repetitions = max(1, step.repetitions ?? script.repetitions ?? 5)
                let stated = step.coldFirst ?? script.coldFirst
                // The first rep after launch is cold whatever the step is.
                let warmup = position == 0 && stated == nil
                if stated == true || warmup {
                    try await run(step: step, rep: 0, cold: true, warmup: warmup, adapter: adapter)
                }
                for rep in 1...repetitions {
                    try await run(step: step, rep: rep, cold: false, adapter: adapter)
                }
            }
        } catch {
            MainThreadLog.note("perf.driver.error", extra: "message=\(String(describing: error).replacingOccurrences(of: " ", with: "_"))")
        }
        MainThreadLog.flush()
        NSApp.terminate(nil)
    }

    private func run(step: Step, rep: Int, cold: Bool, warmup: Bool = false, adapter: PerfStoreAdapter) async throws {
        // Settle after every setup action, not just the last: a selectIndex that
        // follows a source change must see that source's filtered list.
        for action in step.setup ?? [] {
            try await perform(action, adapter: adapter)
            try await settle(adapter: adapter, id: step.id)
        }
        if step.setup?.isEmpty ?? true { try await settle(adapter: adapter, id: step.id) }
        MainThreadLog.scenarioBegin(id: step.id, rep: rep, cold: cold)
        if warmup { MainThreadLog.scenarioValue("warmup", 1) }
        PerfListScrollTarget.setRecording(true)
        try await perform(step.action, adapter: adapter)
        let activeEnd = try await quiesce(adapter: adapter, id: step.id)
        PerfListScrollTarget.setRecording(false)
        MainThreadLog.scenarioEnd(activeEnd: activeEnd)
    }

    private func settle(adapter: PerfStoreAdapter, id: String) async throws {
        var stableSince = ProcessInfo.processInfo.systemUptime
        let deadline = stableSince + 30
        while ProcessInfo.processInfo.systemUptime < deadline {
            let stable = !adapter.isRefreshing && MainThreadLog.secondsSinceLastStall >= 2
            if stable {
                if ProcessInfo.processInfo.systemUptime - stableSince >= 2 { return }
            } else {
                stableSince = ProcessInfo.processInfo.systemUptime
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        MainThreadLog.note("perf.settle.timeout", extra: "id=\(id)")
    }

    /// Waits for 1.5s with no refresh, publish, settle or stall, and returns when
    /// the workload last showed activity — the end of the scenario's active window.
    /// Stability is checked before the deadline, so a stall that outlasts the
    /// deadline but has ended is not reported as a timeout. The cap is generous
    /// because an ambient refresh of 300 feeds, two fetches at a time, runs ~64s.
    private func quiesce(adapter: PerfStoreAdapter, id: String) async throws -> Double {
        var stableSince = ProcessInfo.processInfo.systemUptime
        let deadline = stableSince + 180
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if adapter.isRefreshing {
                stableSince = now
            } else if MainThreadLog.lastActivityAt > stableSince {
                stableSince = MainThreadLog.lastActivityAt
            } else if now - stableSince >= 1.5 {
                return stableSince
            }
            if now >= deadline {
                MainThreadLog.note("perf.quiesce.timeout", extra: "id=\(id)")
                return stableSince
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func perform(_ action: Action, adapter: PerfStoreAdapter) async throws {
        switch action.type {
        case "selectSmart": adapter.selectSmart(action.target ?? "all")
        case "selectFeed": adapter.selectFeeds([action.target ?? "feed-small"])
        case "selectFeeds": adapter.selectFeeds(action.ids ?? [])
        case "selectFolder": adapter.selectFolder(action.target ?? "Folder 01")
        case "selectCategory": adapter.selectCategory(action.target ?? "1")
        case "search": adapter.setSearch(action.value ?? "")
        case "refreshAll": adapter.refreshAll()
        case "refreshFeed": adapter.refreshFeed(action.target ?? "feed-big")
        case "refreshActivation": adapter.refreshActivation()
        case "selectIndex": adapter.selectArticle(index: action.index ?? 0)
        case "setRead":
            MainThreadLog.scenarioValue("toggles", 1)
            adapter.setSelectedRead((action.value ?? "true") != "false")
        case "toggleStar":
            MainThreadLog.scenarioValue("toggles", 1)
            adapter.toggleSelectedStar()
        case "nextArticle":
            MainThreadLog.scenarioValue("toggles", 1)
            adapter.nextArticle()
        case "latestWins":
            adapter.selectSmart("all")
            try await Task.sleep(for: .milliseconds(100))
            adapter.selectSmart("unread")
        case "searchToggle":
            adapter.setSearch(action.value ?? "performance")
            try await Task.sleep(for: .milliseconds(500))
            adapter.setSearch("")
        case "toggleRead":
            MainThreadLog.scenarioValue("toggles", action.count ?? 20)
            for _ in 0..<(action.count ?? 20) {
                adapter.toggleSelectedRead()
                try await Task.sleep(for: .seconds(1 / max(1, action.rate ?? 2)))
            }
        case "toggleStarRepeat":
            MainThreadLog.scenarioValue("toggles", action.count ?? 20)
            for _ in 0..<(action.count ?? 20) {
                adapter.toggleSelectedStar()
                try await Task.sleep(for: .seconds(1 / max(1, action.rate ?? 2)))
            }
        case "nextRepeat":
            MainThreadLog.scenarioValue("toggles", action.count ?? 20)
            for _ in 0..<(action.count ?? 20) { adapter.nextArticle(); try await Task.sleep(for: .milliseconds(100)) }
        case "refreshAndFling": adapter.refreshAll(); try await fling(count: action.count ?? 8)
        case "fling": try await fling(count: action.count ?? 8)
        case "thumbDrag": try await thumbDrag(steps: action.count ?? 30, duration: action.duration ?? 1)
        case "constantScroll": try await constantScroll(rate: action.rate ?? 1500, duration: action.duration ?? 5)
        case "keyRepeat":
            try await keyRepeat(
                command: action.target == "commandDown", rate: action.rate ?? 30,
                duration: action.duration ?? 5, adapter: adapter)
        case "classifyAll": adapter.classifyAll()
        case "wait": try await Task.sleep(for: .seconds(action.duration ?? 1))
        case "noop": break
        default: MainThreadLog.note("perf.action.unknown", extra: "type=\(action.type)")
        }
    }

    private func listScrollView(for action: String) -> NSScrollView? {
        guard let scrollView = PerfListScrollTarget.scrollView else {
            MainThreadLog.note("perf.driver.error", extra: "action=\(action) reason=no_list_scroll_view")
            return nil
        }
        return scrollView
    }

    /// One move per display-link callback, so the per-frame workload is the same
    /// on every run whatever the timer slack.
    private func fling(count: Int) async throws {
        guard let scrollView = listScrollView(for: "fling") else { return }
        for _ in 0..<count {
            var velocity = 6_000.0
            while velocity > 40 {
                move(scrollView, by: velocity / displayHz)
                velocity *= 0.95
                await PerfListScrollTarget.nextFrame()
            }
        }
    }

    private func thumbDrag(steps: Int, duration: Double) async throws {
        guard let scrollView = listScrollView(for: "thumbDrag") else { return }
        let maxY = scrollLimit(scrollView)
        for step in 1...max(1, steps) {
            move(scrollView, to: maxY * Double(step) / Double(max(1, steps)))
            try await Task.sleep(for: .seconds(duration / Double(max(1, steps))))
        }
        scrollView.scrollToEndOfDocument(nil)
    }

    private func constantScroll(rate: Double, duration: Double) async throws {
        guard let scrollView = listScrollView(for: "constantScroll") else { return }
        let frames = Int(duration * displayHz)
        for _ in 0..<max(1, frames) { move(scrollView, by: rate / displayHz); await PerfListScrollTarget.nextFrame() }
    }

    /// Posts ↓ (or ⌘↓) to the article table, which is made first responder first
    /// so the sidebar can never take the keys. Moves are counted on the table's
    /// own selected row, which is where ↓ moves from, and
    /// `missedSelection = posted − moved`.
    private func keyRepeat(command: Bool, rate: Double, duration: Double, adapter: PerfStoreAdapter) async throws {
        guard let tableView = PerfListScrollTarget.tableView, let window = tableView.window else {
            MainThreadLog.note("perf.driver.error", extra: "action=keyRepeat reason=no_article_table")
            return
        }
        window.makeFirstResponder(tableView)
        // Setup's selectIndex moves the store's selection, but the table can keep
        // the row the previous rep ended on, and ↓ moves from the table's row.
        // Put the table on the store's row so every rep starts from the same place.
        if let index = adapter.selectedIndex, index < tableView.numberOfRows {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        }
        let startRow = tableView.selectedRow
        let startIndex = adapter.selectedIndex
        guard startRow >= 0, startRow == startIndex else {
            MainThreadLog.note("perf.driver.error", extra: "action=keyRepeat reason=table_selection_mismatch row=\(startRow) index=\(startIndex ?? -1)")
            return
        }
        let repeats = max(1, Int(rate * duration))
        let posting = await PerfKeyPoster.post(
            count: repeats, rate: rate, command: command, windowNumber: window.windowNumber,
            sink: PerfKeyEventSink(application: NSApp))
        // Let the queued events drain: the selection must hold still for 1s (up
        // to 15s) before it is read.
        var last = tableView.selectedRow
        var stableSince = ProcessInfo.processInfo.systemUptime
        let drainDeadline = stableSince + 15
        while ProcessInfo.processInfo.systemUptime - stableSince < 1, ProcessInfo.processInfo.systemUptime < drainDeadline {
            try await Task.sleep(for: .milliseconds(100))
            if tableView.selectedRow != last { last = tableView.selectedRow; stableSince = ProcessInfo.processInfo.systemUptime }
        }
        let moved = tableView.selectedRow - startRow
        let storeMoved = (adapter.selectedIndex ?? startRow) - startRow
        // Each ↓ moves at most one row, so moving more than was posted means the
        // count started from the wrong row; that rep cannot say what was missed.
        if moved < 0 || moved > repeats {
            MainThreadLog.note("perf.driver.error", extra: "action=keyRepeat reason=moved_out_of_range posted=\(repeats) moved=\(moved)")
        }
        MainThreadLog.scenarioValue("keysPosted", repeats)
        MainThreadLog.scenarioValue("keysMoved", moved)
        MainThreadLog.scenarioValue("missedSelection", repeats - moved)
        MainThreadLog.note(
            "perf.keys",
            extra: "posted=\(posting.count) moved=\(moved) storeMoved=\(storeMoved) startRow=\(startRow) responder=\(window.firstResponder === tableView ? "table" : "other") keysPostedOverMs=\(posting.overMs.rounded()) achievedHz=\(posting.hz.rounded(toPlaces: 2))")
    }

    private var displayHz: Double { Double(NSScreen.main?.maximumFramesPerSecond ?? 60) }
    private func scrollLimit(_ scrollView: NSScrollView) -> Double {
        max(0, Double((scrollView.documentView?.bounds.height ?? 0) - scrollView.contentView.bounds.height))
    }
    private func move(_ scrollView: NSScrollView, by delta: Double) {
        move(scrollView, to: Double(scrollView.contentView.bounds.origin.y) + delta)
    }
    private func move(_ scrollView: NSScrollView, to y: Double) {
        let point = NSPoint(x: scrollView.contentView.bounds.origin.x, y: min(max(0, y), scrollLimit(scrollView)))
        scrollView.contentView.scroll(to: point)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Fixes the window at 1440×900 and the sidebar/list columns at their ideal
    /// widths (270/420), since visible rows = visible height × list width. Frame
    /// and divider autosave are switched off first so none of this is written
    /// into the app's defaults.
    private func fixLayout() async throws {
        guard let window = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first else {
            MainThreadLog.note("perf.driver.error", extra: "action=layout reason=no_window")
            return
        }
        window.setFrameAutosaveName("")
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Let the resize lay out before the dividers are placed against it.
        try await Task.sleep(for: .milliseconds(300))
        guard let splitView = Self.outerSplitView(in: window.contentView), splitView.arrangedSubviews.count >= 3 else {
            MainThreadLog.note("perf.driver.error", extra: "action=layout reason=no_split_view")
            return
        }
        splitView.autosaveName = nil
        splitView.setPosition(270, ofDividerAt: 0)
        splitView.setPosition(270 + splitView.dividerThickness + 420, ofDividerAt: 1)
        splitView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        // The macOS 26 sidebar floats over the content column, whose frame starts
        // at x=0, so the list's visible width is from the sidebar's edge to the
        // detail column.
        let arranged = splitView.arrangedSubviews
        let listWidth = arranged[2].frame.minX - splitView.dividerThickness - arranged[0].frame.maxX
        let widths = arranged.map {
            "\(Int($0.frame.minX))+\(Int($0.frame.width.rounded()))\($0.isHidden ? "h" : "")"
        }
        MainThreadLog.note("perf.layout", extra: "window=\(Int(window.frame.width))x\(Int(window.frame.height)) listWidth=\(Int(listWidth)) columns=\(widths.joined(separator: ","))")
    }

    private static func outerSplitView(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let splitView = view as? NSSplitView, splitView.arrangedSubviews.count >= 3 { return splitView }
        for subview in view.subviews {
            if let found = outerSplitView(in: subview) { return found }
        }
        return nil
    }

    private func launchValue(_ key: String) -> String? { PerfLaunch.value(for: key) }
}

/// Posts key events from a wall-clock dispatch timer. Keeping this outside the
/// main actor prevents the workload from slowing itself down when the UI stalls.
private enum PerfKeyPoster {
    struct Result: Sendable {
        let count: Int
        let overMs: Double
        let hz: Double
    }

    private final class State: @unchecked Sendable {
        var posted = 0
        var firstPostedAt: Double?
    }

    nonisolated static func post(
        count: Int, rate: Double, command: Bool, windowNumber: Int, sink: PerfKeyEventSink
    ) async -> Result {
        let safeRate = max(1, rate)
        let interval = 1 / safeRate
        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "com.tim.nook.perf-key-poster", qos: .userInitiated)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let state = State()
            timer.schedule(
                deadline: .now() + interval,
                repeating: interval,
                leeway: .milliseconds(1))
            timer.setEventHandler {
                let now = ProcessInfo.processInfo.systemUptime
                if state.firstPostedAt == nil { state.firstPostedAt = now - interval }
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(
                        with: type, location: .zero,
                        modifierFlags: command ? [.command] : [], timestamp: now,
                        windowNumber: windowNumber, context: nil,
                        characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                        isARepeat: type == .keyDown && state.posted > 0, keyCode: 125
                    ) {
                        sink.post(event)
                    }
                }
                state.posted += 1
                guard state.posted == count else { return }
                let overMs = (now - (state.firstPostedAt ?? now)) * 1000
                timer.cancel()
                continuation.resume(returning: Result(
                    count: state.posted,
                    overMs: overMs,
                    hz: overMs > 0 ? Double(state.posted) / (overMs / 1000) : 0))
            }
            timer.activate()
        }
    }
}

/// AppKit documents `postEvent` as thread-safe, but its Swift overlay marks all
/// `NSApplication` methods main-actor isolated. Call the same Objective-C entry
/// point through its IMP so the wall-clock timer remains genuinely off-main.
private final class PerfKeyEventSink: @unchecked Sendable {
    private let application: AnyObject

    init(application: NSApplication) {
        self.application = application
    }

    nonisolated func post(_ event: NSEvent) {
        let selector = NSSelectorFromString("postEvent:atStart:")
        typealias PostEvent = @convention(c) (AnyObject, Selector, AnyObject, Bool) -> Void
        let implementation = class_getMethodImplementation(NSApplication.self, selector)
        unsafeBitCast(implementation, to: PostEvent.self)(application, selector, event, false)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}

@MainActor
private struct PerfStoreAdapter {
    let store: ReaderStore
    var isRefreshing: Bool { store.isRefreshing }

    func selectSmart(_ raw: String) {
        if let source = SmartSource(rawValue: raw) { store.selectSmartSource(source) }
    }
    var selectedIndex: Int? {
        store.selectedArticleID.flatMap { id in store.visibleArticles.firstIndex { $0.id == id } }
    }

    func selectFeeds(_ targets: [String]) {
        let ids = targets.flatMap(resolveFeedTarget)
        store.feedSelection = Set(ids)
    }
    func selectFolder(_ target: String) {
        let folder = resolveIndexed(target, prefix: "Folder ", count: 12)
        guard !store.feeds(inFolder: folder).isEmpty else { return invalid("folder", target) }
        store.selectFolder(folder)
    }
    /// `"1"`, `"category-1"` and `"perf-cat-1"` all mean the generator's `perf-cat-1`.
    func selectCategory(_ target: String) {
        let id = target.hasPrefix("perf-cat-")
            ? target : "perf-cat-" + target.replacingOccurrences(of: "category-", with: "")
        guard store.categories.contains(where: { $0.id == id }) else { return invalid("category", target) }
        store.selectCategory(id)
    }
    func setSearch(_ value: String) { store.searchText = value; store.debounceSearch() }
    func refreshAll() { store.refreshAll() }
    func refreshFeed(_ target: String) { resolveFeedTarget(target).first.map(store.perfRefresh(feedID:)) }
    func refreshActivation() { store.refreshOnActivation(honorThrottle: false) }
    func selectArticle(index: Int) {
        guard store.visibleArticles.indices.contains(index) else { return invalid("index", String(index)) }
        MainThreadLog.articleSelectionBegan()
        store.selectedArticleID = store.visibleArticles[index].id
    }
    func setSelectedRead(_ value: Bool) { store.selectedArticleID.map { store.setRead(articleID: $0, isRead: value) } }
    func toggleSelectedRead() {
        guard let id = store.selectedArticleID, let article = store.article(withID: id) else { return }
        store.setRead(articleID: id, isRead: !article.isRead)
    }
    func toggleSelectedStar() { store.selectedArticleID.map(store.toggleStarred(articleID:)) }
    func nextArticle() {
        MainThreadLog.articleSelectionBegan()
        store.selectNextArticle()
    }
    func classifyAll() { store.classifyAllExisting(provider: .appleIntelligence) }

    private func invalid(_ kind: String, _ target: String) {
        MainThreadLog.note("perf.driver.error", extra: "\(kind)=\(target.replacingOccurrences(of: " ", with: "_")) reason=not_found")
    }

    private func resolveFeedTarget(_ target: String) -> [Feed.ID] {
        switch target {
        case "feed-small": return resolved(["perf-feed-small"], target)
        case "feed-big": return resolved(["perf-feed-big"], target)
        case "all": return store.feeds.map(\.id)
        default:
            if target.hasPrefix("first:"), let count = Int(target.dropFirst(6)) { return Array(store.feeds.prefix(count).map(\.id)) }
            return resolved([target], target)
        }
    }
    private func resolved(_ ids: [Feed.ID], _ target: String) -> [Feed.ID] {
        let known = ids.filter { id in store.feeds.contains { $0.id == id } }
        if known.count != ids.count { invalid("feed", target) }
        return known
    }
    private func resolveIndexed(_ target: String, prefix: String, count: Int) -> String {
        if target.hasPrefix(prefix) { return target }
        let index = min(max(Int(target) ?? 1, 1), count)
        return prefix + String(format: "%02d", index)
    }
}
#endif
