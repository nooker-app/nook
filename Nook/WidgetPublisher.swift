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
    private static let log = Logger(subsystem: "com.tim.nook", category: "widgets")

    func start() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.schedule() }
            }
        Task {
            await ReaderStore.shared.bootstrap()
            observe()
            schedule()
        }
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
        task?.cancel()
        task = Task {
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            let store = ReaderStore.shared
            guard let scope = store.syncFolderURL?.standardizedFileURL.path else {
                await publish(NookWidgetSnapshot())
                return
            }
            let articles = store.widgetArticles
            let feeds = Dictionary(store.feeds.map { ($0.id, $0.displayTitle) }, uniquingKeysWith: { first, _ in first })
            let opened = store.recentlyRead.opened
            // A fresh controller reads the profile saved by either reader layout.
            // Publishing never records a selection, reading time, or read flag.
            let recommendations = MagazineRecommendationController()
            recommendations.selectLibrary(scope)
            let personalized = UserDefaults.standard.object(forKey: MagazineRecommendationController.enabledKey) as? Bool ?? true
            let ranked = await recommendations.rankedRecommendations(candidates: articles,
                library: articles, personalized: personalized)
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
            if try await writer.write(snapshot) { WidgetCenter.shared.reloadAllTimelines() }
        } catch {
            Self.log.error("Widget snapshot could not be saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private actor Writer {
        func write(_ snapshot: NookWidgetSnapshot) throws -> Bool {
            guard let url = NookWidgetStorage.fileURL else { throw CocoaError(.fileNoSuchFile) }
            return try NookWidgetStorage.write(snapshot, to: url)
        }
    }
}
