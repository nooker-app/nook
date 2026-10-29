#if DEBUG
import NookKit
import os
import QuartzCore
import UIKit

/// Debug-only scenario runner for the iOS side of the perf plan
/// (docs/perf/ios-projection.md). macOS has `PerfDriver` + `MainThreadLog`,
/// both AppKit-only; this is the small iOS counterpart: it drives the shared
/// `ReaderStore` directly and times the main thread with a display link and a
/// run-loop observer.
///
/// Runs only with `-NookPerfLibrary <dir>` (the shared DEBUG library hook, which
/// never touches the bookmark or the folder defaults) and
/// `-NookIOSPerfSteps A1,A2,B2,C1`: A1 feed-small → All, A2 All → Unread,
/// A3 feed-small → Unread, A7 feed-small → first folder, A8 feed-small → first
/// category, B2 Refresh All, C1 fling; `S` runs the smoke pass instead. Each
/// step runs `-NookIOSPerfReps` times (default 5) after one cold rep;
/// `-NookIOSPerfDelay <s>` waits before the first step so a profiler can attach.
/// Results go to `-NookPerfLog <path>` (or the app's tmp directory) as one
/// `scenario.stats` line per rep, and every rep is an `OSSignposter` interval
/// so a trace can line its samples up with the step.
@MainActor
final class IOSPerfDriver {
    static let shared = IOSPerfDriver()

    private let signposter = OSSignposter(subsystem: "com.tim.nook", category: "perf")
    private let monitor = FrameMonitor()
    private var lines: [String] = []
    private var didStart = false

    static func startIfRequested() {
        guard PerfLaunch.isActive, let steps = PerfLaunch.value(for: "-NookIOSPerfSteps") else { return }
        shared.start(steps: steps.split(separator: ",").map(String.init))
    }

    private var logURL: URL {
        if let path = PerfLaunch.value(for: "-NookPerfLog") { return URL(fileURLWithPath: path) }
        return FileManager.default.temporaryDirectory.appendingPathComponent("ios-perf.log")
    }

    private func start(steps: [String]) {
        guard !didStart else { return }
        didStart = true
        let reps = PerfLaunch.value(for: "-NookIOSPerfReps").flatMap(Int.init) ?? 5
        Task { @MainActor in
            let store = ReaderStore.shared
            note("run.begin steps=\(steps.joined(separator: ",")) reps=\(reps) hz=\(UIScreen.main.maximumFramesPerSecond)")
            // Bootstrap, library load and the first fill.
            while !store.isStorageConfigured || store.visibleArticles.isEmpty {
                try? await Task.sleep(for: .milliseconds(100))
            }
            monitor.start()
            await settle(store)
            // Room for `xctrace record --attach` before the first step.
            if let delay = PerfLaunch.value(for: "-NookIOSPerfDelay").flatMap(Double.init) {
                try? await Task.sleep(for: .seconds(delay))
            }
            let unread = store.libraryArticles.filter { !$0.isRead }.count
            note("perf.library articles=\(store.libraryArticles.count) unread=\(unread) feeds=\(store.feeds.count)")
            for step in steps {
                if step == "S" { await smoke(store); continue }
                for rep in 0...reps {
                    await run(step, rep: rep, store: store)
                }
            }
            note("run.end")
            flush()
        }
    }

    private func run(_ step: String, rep: Int, store: ReaderStore) async {
        // Setup outside the measured interval, then a settled start.
        switch step {
        case "A1", "A3", "A7", "A8": store.selectFeed("perf-feed-small")
        case "A2", "B2", "C1": store.selectSmartSource(.all)
        default: note("perf.driver.error step=\(step) reason=unknown"); return
        }
        await settle(store)
        if step == "C1" { scrollView()?.setContentOffset(.zero, animated: false) }
        try? await Task.sleep(for: .milliseconds(300))

        let rowsBefore = store.visibleArticles.count
        let firstBefore = store.visibleArticles.first?.id
        let state = signposter.beginInterval("scenario", "id=\(step, privacy: .public) rep=\(rep)")
        let started = CACurrentMediaTime()
        monitor.begin(started: started) {
            store.visibleArticles.count != rowsBefore || store.visibleArticles.first?.id != firstBefore
        }
        switch step {
        case "A1": store.selectSmartSource(.all)
        case "A2", "A3": store.selectSmartSource(.unread)
        case "A7": store.feedFolders.first.map(store.selectFolder)
        case "A8": store.categories.first.map { store.selectCategory($0.id) }
        case "B2": await store.refreshAllAndWait()
        case "C1": await fling()
        default: break
        }
        let activeEnd = CACurrentMediaTime()
        await settle(store)
        let result = monitor.end()
        signposter.endInterval("scenario", state)
        let ttfr = result.firstChange.map { String(format: "%.1f", ($0 - started) * 1000) } ?? "-"
        note("scenario.stats id=\(step) rep=\(rep) cold=\(rep == 0 ? 1 : 0)"
            + " activeMs=\(ms(activeEnd - started)) worstFrameMs=\(ms(result.worstGap))"
            + " ttfrMs=\(ttfr) stalls50=\(result.gaps50) stalls100=\(result.gaps100) stalls250=\(result.gaps250)"
            + " hitchMs=\(ms(result.hitch)) frames=\(result.frames)"
            + " mainMaxMs=\(ms(result.maxBusy)) mainBusyMs=\(ms(result.busy)) main16=\(result.busy16)"
            + " publishMs=\(result.publishBusy.map(ms) ?? "-")"
            + " rows=\(rowsBefore)->\(store.visibleArticles.count)")
        flush()
    }

    /// The regression smoke pass: the same entry points a user's taps reach
    /// (store navigation, the list's own selection delegate, pull-to-refresh's
    /// control action), with a snapshot of the window after each step written
    /// next to the log as `smoke-<n>-<name>.png`.
    private func smoke(_ store: ReaderStore) async {
        func check(_ name: String) async {
            await settle(store)
            try? await Task.sleep(for: .milliseconds(800))
            snapshot(name)
            note("smoke step=\(name) rows=\(store.visibleArticles.count) selected=\(store.selectedArticleID ?? "nil")"
                + " smart=\(store.smartSelection.map { "\($0)" } ?? "nil") feeds=\(store.feedSelection.count)"
                + " category=\(store.categorySelection ?? "nil") refreshing=\(store.isRefreshing)")
            flush()
        }
        await check("launch")
        store.selectSmartSource(.unread); await check("unread")
        store.selectSmartSource(.today); await check("today")
        store.selectFeed("perf-feed-small"); await check("feed-small")
        if let folder = store.feedFolders.first { store.selectFolder(folder); await check("folder") }
        if let category = store.categories.first { store.selectCategory(category.id); await check("category") }
        store.selectSmartSource(.all); await check("all")
        await fling(); await check("scrolled")
        scrollView()?.setContentOffset(.zero, animated: false); await check("top")
        if let list = scrollView() as? UICollectionView {
            let item = IndexPath(item: 1, section: 0)
            list.delegate?.collectionView?(list, didSelectItemAt: item)
            await check("open-article")
            let navigation = navigationControllers().first { $0.viewControllers.count > 1 }
            navigation?.popViewController(animated: true)
            await check("back")
        } else {
            note("perf.driver.error step=S reason=no_collection_view")
        }
        let before = store.libraryArticles.count
        if let scroll = scrollView(), let refresh = scroll.refreshControl {
            refresh.beginRefreshing()
            refresh.sendActions(for: .valueChanged)
            try? await Task.sleep(for: .milliseconds(500))
            while store.isRefreshing { try? await Task.sleep(for: .milliseconds(100)) }
            await check("refreshed")
            note("smoke refresh articles=\(before)->\(store.libraryArticles.count)")
        } else {
            note("perf.driver.error step=S reason=no_refresh_control")
        }
    }

    private func navigationControllers() -> [UINavigationController] {
        var found: [UINavigationController] = []
        func visit(_ controller: UIViewController) {
            if let navigation = controller as? UINavigationController { found.append(navigation) }
            controller.children.forEach(visit)
            controller.presentedViewController.map(visit)
        }
        keyWindows().compactMap(\.rootViewController).forEach(visit)
        return found
    }

    private func keyWindows() -> [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    }

    private var smokeIndex = 0

    private func snapshot(_ name: String) {
        guard let window = keyWindows().first(where: \.isKeyWindow) else { return }
        smokeIndex += 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = logURL.deletingLastPathComponent()
            .appendingPathComponent(String(format: "smoke-%02d-%@.png", smokeIndex, name))
        try? image.pngData()?.write(to: url)
    }

    /// Eight flings down the list, each a 0.3 s animated offset change of three
    /// screens — the rate of a firm finger flick — then a pause.
    private func fling() async {
        guard let scrollView = scrollView() else {
            note("perf.driver.error step=C1 reason=no_scroll_view")
            return
        }
        for _ in 0..<8 {
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            let target = min(maxY, scrollView.contentOffset.y + scrollView.bounds.height * 3)
            scrollView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
            try? await Task.sleep(for: .milliseconds(450))
        }
    }

    /// The article list's scroll view: the tallest scrollable view on screen.
    private func scrollView() -> UIScrollView? {
        let windows = keyWindows()
        var best: UIScrollView?
        func visit(_ view: UIView) {
            if let scroll = view as? UICollectionView ?? (view as? UITableView),
               !scroll.isHidden, scroll.window != nil,
               scroll.contentSize.height > (best?.contentSize.height ?? 0) {
                best = scroll
            }
            view.subviews.forEach(visit)
        }
        windows.forEach(visit)
        return best
    }

    /// Quiet: the list stopped changing and no frame took longer than 50 ms
    /// for half a second (capped at 15 s).
    private func settle(_ store: ReaderStore) async {
        let deadline = CACurrentMediaTime() + 15
        var lastCount = store.visibleArticles.count
        var stableSince = CACurrentMediaTime()
        while CACurrentMediaTime() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            let now = CACurrentMediaTime()
            if store.visibleArticles.count != lastCount || now - monitor.lastLongFrame < 0.5 {
                lastCount = store.visibleArticles.count
                stableSince = now
            }
            if now - stableSince >= 0.5 { return }
        }
    }

    private func ms(_ seconds: Double) -> String { String(format: "%.1f", seconds * 1000) }

    private func note(_ text: String) {
        lines.append(String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + text)
    }

    private func flush() {
        guard !lines.isEmpty else { return }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        lines.removeAll()
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

/// Frame-to-frame gaps on the main run loop. A display-link callback that comes
/// late is the main thread having been busy (a hang or a hitch) for that long.
@MainActor
private final class FrameMonitor: NSObject {
    struct Result {
        var worstGap: Double = 0
        var gaps50 = 0
        var gaps100 = 0
        var gaps250 = 0
        var hitch: Double = 0
        var frames = 0
        var firstChange: Double?
        /// Main run-loop iterations (wake → sleep): the longest one is the
        /// worst main-thread task, exact rather than rounded to a frame.
        var maxBusy: Double = 0
        var busy: Double = 0
        var busy16 = 0
        /// The iteration that installed the new list plus the one after it
        /// (where a deferred layout/commit lands).
        var publishBusy: Double?
        var publishIterationsLeft = 0
    }

    private var link: CADisplayLink?
    private var previous: CFTimeInterval?
    private var current: Result?
    private var changed: (() -> Bool)?
    private(set) var lastLongFrame: CFTimeInterval = 0
    private var observer: CFRunLoopObserver?
    private var iterationStart: CFTimeInterval?

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.runLoop(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    private func runLoop(_ activity: CFRunLoopActivity) {
        let now = CACurrentMediaTime()
        if activity == .afterWaiting {
            iterationStart = now
            return
        }
        guard let begun = iterationStart, var result = current else { return }
        iterationStart = nil
        let busy = now - begun
        result.maxBusy = max(result.maxBusy, busy)
        result.busy += busy
        if busy >= 0.016 { result.busy16 += 1 }
        if result.publishBusy == nil, changed?() == true {
            result.publishBusy = busy
            result.publishIterationsLeft = 1
        } else if result.publishIterationsLeft > 0, let publish = result.publishBusy {
            result.publishBusy = publish + busy
            result.publishIterationsLeft -= 1
        }
        current = result
    }

    func begin(started: CFTimeInterval, changed: @escaping () -> Bool) {
        previous = started
        current = Result()
        self.changed = changed
    }

    func end() -> Result {
        defer { current = nil; changed = nil }
        return current ?? Result()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        defer { previous = now }
        guard let previous else { return }
        let gap = now - previous
        let budget = link.targetTimestamp - link.timestamp
        if gap > 0.05 { lastLongFrame = now }
        guard var result = current else { return }
        result.frames += 1
        result.worstGap = max(result.worstGap, gap)
        if gap >= 0.05 { result.gaps50 += 1 }
        if gap >= 0.1 { result.gaps100 += 1 }
        if gap >= 0.25 { result.gaps250 += 1 }
        if budget > 0, gap > budget * 1.5 { result.hitch += gap - budget }
        if result.firstChange == nil, changed?() == true { result.firstChange = now }
        current = result
    }
}
#endif
