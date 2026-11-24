import Foundation
import NookKit
import Observation
import WidgetKit
import os

/// App-lifetime publishing also covers background feed refreshes with no window.
/// Widget extensions only read these few rows; ranking stays in the host app.
@MainActor
final class NookWidgetPublisher {
    private var task: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?
    private let writer = Writer()
    private let recommendations = MagazineRecommendationController()
    private var personalized = UserDefaults.standard.object(forKey: MagazineRecommendationController.enabledKey) as? Bool ?? true
    private static let log = Logger(subsystem: "com.tim.nook", category: "widgets")

    func start() {
        guard defaultsObserver == nil else { return }
        reloadAfterUpdate()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.preferencesChanged() }
            }
        Task {
            await ReaderStore.shared.bootstrap()
            observe()
            schedule()
        }
    }

    private func reloadAfterUpdate() {
        #if DEBUG
        guard !PerfLaunch.isActive else { return }
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        guard !version.isEmpty, !build.isEmpty else { return }
        let identity = version + "/" + build
        let key = "widgetLastReloadedBuild.v1"
        guard NookWidgetRuntime.needsTimelineReload(build: identity,
            lastReloadedBuild: UserDefaults.standard.string(forKey: key)) else { return }
        // Content equality is deliberately irrelevant after an app update.
        // This also wakes an older extension so it can retire its stale code.
        WidgetCenter.shared.reloadAllTimelines()
        UserDefaults.standard.set(identity, forKey: key)
    }

    private func preferencesChanged() {
        let enabled = UserDefaults.standard.object(forKey: MagazineRecommendationController.enabledKey) as? Bool ?? true
        let feedbackChanged = recommendations.reloadStoredHistory()
        guard enabled != personalized || feedbackChanged else { return }
        personalized = enabled
        schedule()
    }

    private func observe() {
        withObservationTracking {
            let store = ReaderStore.shared
            _ = store.magazineContentRevision
            _ = store.syncFolderURL
            _ = store.recentlyRead.opened
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observe()
                self?.schedule()
            }
        }
    }

    private func schedule() {
        #if DEBUG
        MainThreadLog.add("widget.schedule", ms: 0)
        #endif
        task?.cancel()
        task = Task(priority: .utility) {
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            let store = ReaderStore.shared
            guard let scope = store.syncFolderURL?.standardizedFileURL.path else {
                await publish(NookWidgetSnapshot())
                return
            }
            let articles = store.widgetArticles
            let feeds = Dictionary(store.feeds.map { ($0.id, $0.displayTitle) }, uniquingKeysWith: { first, _ in first })
            let opened = store.recentlyRead.opened
            recommendations.selectLibrary(scope)
            recommendations.reloadStoredHistory()
            #if DEBUG
            let started = ProcessInfo.processInfo.systemUptime
            MainThreadLog.note("widget.rank.begin", extra: "articles=\(articles.count)")
            #endif
            let ranked = await recommendations.rankedRecommendations(candidates: articles,
                library: articles, personalized: personalized)
            #if DEBUG
            MainThreadLog.note("widget.rank.end", extra: "ms=\((ProcessInfo.processInfo.systemUptime - started) * 1000) cancelled=\(Task.isCancelled)")
            #endif
            guard !Task.isCancelled, scope == store.syncFolderURL?.standardizedFileURL.path else { return }
            let snapshot = await Task.detached(priority: .utility) {
                let lookup = Dictionary(articles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                func story(_ article: Article) -> NookWidgetStory {
                    NookWidgetStory(id: article.id, title: article.title,
                        source: feeds[article.feedID] ?? article.url.host() ?? "RSS",
                        publishedAt: article.publishedAt, isUnread: !article.isRead)
                }
                let latest = articles.sorted { $0.publishedAt == $1.publishedAt ? $0.id < $1.id : $0.publishedAt > $1.publishedAt }
                let recent = opened.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                    .compactMap { lookup[$0.key] }.prefix(6)
                return NookWidgetSnapshot(libraryID: NookReaderLink.token(scope),
                    unreadCount: articles.filter { !$0.isRead }.count,
                    latest: latest.prefix(6).map(story),
                    recommended: ranked.prefix(6).compactMap { lookup[$0.articleID] }.map(story),
                    recent: recent.map(story))
            }.value
            guard !Task.isCancelled, scope == store.syncFolderURL?.standardizedFileURL.path else { return }
            await publish(snapshot)
        }
    }

    private func publish(_ snapshot: NookWidgetSnapshot) async {
        do {
            if try await writer.write(snapshot) {
                #if DEBUG
                guard !PerfLaunch.isActive else { return }
                #endif
                WidgetCenter.shared.reloadAllTimelines()
            }
        } catch {
            Self.log.error("Widget snapshot could not be saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private actor Writer {
        func write(_ snapshot: NookWidgetSnapshot) throws -> Bool {
            #if DEBUG
            if let path = PerfLaunch.value(for: "-NookPerfLibrary") {
                return try NookWidgetStorage.write(snapshot, to: URL(fileURLWithPath: path)
                    .appendingPathComponent(".nook-perf-widget.json"))
            }
            #endif
            guard let url = NookWidgetStorage.fileURL else { throw CocoaError(.fileNoSuchFile) }
            return try NookWidgetStorage.write(snapshot, to: url)
        }
    }
}
