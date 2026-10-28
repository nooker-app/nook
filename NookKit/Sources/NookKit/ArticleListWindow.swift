import Observation
import SwiftUI

/// Shared reference prevents the full observable result and rendering queue from
/// retaining two Array buffers and forcing a full CoW copy on every flag patch.
@MainActor
final class ArticleListContents {
    var articles: [Article]
    init(_ articles: [Article] = []) { self.articles = articles }
}

/// macOS rendering queue. Membership and navigation always use the complete result.
@MainActor @Observable
public final class ArticleListWindow {
    public private(set) var rows: [Article] = []
    public private(set) var totalCount = 0
    @ObservationIgnored private var full = ArticleListContents()
    @ObservationIgnored private var indexByID: [Article.ID: Int] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var growthTask: Task<Void, Never>?

    public init() {}

    nonisolated static func length(total: Int, previousTotal: Int, previousLength: Int,
                                   replacement: Bool, selectedIndex: Int?) -> Int {
        let minimum = max(200, selectedIndex.map { $0 + 50 } ?? 0)
        let target = replacement ? minimum : max(minimum, previousLength + max(0, total - previousTotal))
        return min(total, target)
    }

    func install(full: [Article], indexByID: [Article.ID: Int], rows: [Article], replacement: Bool = true) {
        install(contents: ArticleListContents(full), indexByID: indexByID, rows: rows, replacement: replacement)
    }

    /// Only a replacement invalidates pending growth. An incremental install keeps
    /// the prefix it extends, and the sentinel row that requested growth is already
    /// on screen, so its onAppear would not fire again to re-request it.
    func install(contents: ArticleListContents, indexByID: [Article.ID: Int], rows: [Article],
                 replacement: Bool) {
        if replacement {
            generation &+= 1
            growthTask?.cancel()
            growthTask = nil
        }
        self.full = contents
        self.indexByID = indexByID
        if totalCount != contents.articles.count { totalCount = contents.articles.count }
        self.rows = rows
    }

    /// Not capped: List selection needs the selected row to exist, so a deep jump
    /// (⌘↓ past the window, openArticle, a restored selection) appends the whole gap
    /// in one non-animated publish.
    public func ensureVisible(id: Article.ID) {
        guard let index = indexByID[id], index >= rows.count else { return }
        publishPrefix(min(full.articles.count, max(200, index + 50)))
    }

    /// Called separately from title translator visibility callbacks.
    public func rowAppeared(id: Article.ID) {
        guard let index = indexByID[id], index >= max(0, rows.count - 50) else { return }
        requestGrowth()
    }

    public func requestGrowth() {
        guard growthTask == nil, rows.count < full.articles.count else { return }
        let expectedGeneration = generation
        growthTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.generation == expectedGeneration else { return }
            self.growthTask = nil
            #if DEBUG && os(macOS)
            let started = ProcessInfo.processInfo.systemUptime
            defer { MainThreadLog.add("list.window.grow", ms: (ProcessInfo.processInfo.systemUptime - started) * 1000) }
            #endif
            self.publishPrefix(min(self.full.articles.count, self.rows.count + 200))
        }
    }

    func patch(_ id: Article.ID, _ mutate: (inout Article) -> Void) {
        guard let index = indexByID[id] else { return }
        mutate(&full.articles[index])
        if index < rows.count { mutate(&rows[index]) }
    }

    private func publishPrefix(_ count: Int) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            rows.append(contentsOf: full.articles[rows.count..<count])
        }
    }
}
