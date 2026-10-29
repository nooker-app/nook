import Foundation
import Observation
import SwiftUI

/// Shared reference prevents the full observable result and rendering queue from
/// retaining two Array buffers and forcing a full CoW copy on every flag patch.
@MainActor
final class ArticleListContents {
    var articles: [Article]
    init(_ articles: [Article] = []) { self.articles = articles }
}

/// Exactly what one macOS list row renders, resolved before the row exists.
///
/// A row built from an `Article` looked up its feed, its offline flag and its
/// categories while SwiftUI was creating it, and carried the article's body
/// paragraphs and HTML along as part of its value. The model is built with the
/// display result (off the main actor for large libraries), so creating a row is
/// laying out these fields and nothing else. It is also the equality the display
/// diff uses: a field rows render but this model lacks would be a change the list
/// never shows. Body content and `hasExplicitPublishDate` are deliberately absent;
/// the reader resolves articles by id from the library.
public struct ArticleRowModel: Identifiable, Equatable, Sendable {
    public let id: Article.ID
    public let feedID: Feed.ID
    public let title: String
    public let summary: String
    public let isRead: Bool
    public let isStarred: Bool
    /// A date, never a formatted string: rows render it with `RelativeTimeText`,
    /// which follows the shared ticker.
    public let publishedAt: Date
    /// The feed's display title at publish time; nil renders "Unknown Feed".
    public let feedDisplayTitle: String?
    public let readMinutes: Int
    /// Category ids. Rows resolve names and colors live, so a rename or recolor
    /// shows without a republish.
    public let categories: [String]
    public let isSavedOffline: Bool

    nonisolated public init(_ article: Article, feedDisplayTitle: String?, isSavedOffline: Bool) {
        id = article.id
        feedID = article.feedID
        title = article.title
        summary = article.summary
        isRead = article.isRead
        isStarred = article.isStarred
        publishedAt = article.publishedAt
        self.feedDisplayTitle = feedDisplayTitle
        readMinutes = article.estimatedReadMinutes
        categories = article.categories
        self.isSavedOffline = isSavedOffline
    }
}

/// macOS rendering queue. Membership and navigation always use the complete result.
@MainActor @Observable
public final class ArticleListWindow {
    public private(set) var rows: [ArticleRowModel] = []
    public private(set) var totalCount = 0
    @ObservationIgnored private var full = ArticleListContents()
    @ObservationIgnored private var indexByID: [Article.ID: Int] = [:]
    @ObservationIgnored private var feedTitles: [Feed.ID: String] = [:]
    @ObservationIgnored private var savedIDs: Set<Article.ID> = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var growthTask: Task<Void, Never>?
    /// Runs inside a replacing install, before the replaced List can render again,
    /// so per-row state owned elsewhere (title translation boxes) can be trimmed
    /// while no row view holds it.
    @ObservationIgnored public var onReplacement: (@MainActor () -> Void)?

    public init() {}

    nonisolated static func length(total: Int, previousTotal: Int, previousLength: Int,
                                   replacement: Bool, selectedIndex: Int?) -> Int {
        let minimum = max(200, selectedIndex.map { $0 + 50 } ?? 0)
        let target = replacement ? minimum : max(minimum, previousLength + max(0, total - previousTotal))
        return min(total, target)
    }

    func install(full: [Article], indexByID: [Article.ID: Int], rows: [Article], replacement: Bool = true) {
        install(full: full, indexByID: indexByID,
                rows: rows.map { ArticleRowModel($0, feedDisplayTitle: nil, isSavedOffline: false) },
                replacement: replacement)
    }

    func install(full: [Article], indexByID: [Article.ID: Int], rows: [ArticleRowModel], replacement: Bool = true) {
        install(contents: ArticleListContents(full), indexByID: indexByID, rows: rows,
                feedTitles: [:], savedIDs: [], replacement: replacement)
    }

    /// Only a replacement invalidates pending growth. An incremental install keeps
    /// the prefix it extends, and the sentinel row that requested growth is already
    /// on screen, so its onAppear would not fire again to re-request it.
    func install(contents: ArticleListContents, indexByID: [Article.ID: Int], rows: [ArticleRowModel],
                 feedTitles: [Feed.ID: String], savedIDs: Set<Article.ID>, replacement: Bool) {
        if replacement {
            generation &+= 1
            growthTask?.cancel()
            growthTask = nil
            onReplacement?()
        }
        self.full = contents
        self.indexByID = indexByID
        self.feedTitles = feedTitles
        self.savedIDs = savedIDs
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

    /// The full result's article for a displayed id: an offline stand-in exists
    /// only here, never in the library.
    func article(withID id: Article.ID) -> Article? {
        indexByID[id].flatMap { full.articles.indices.contains($0) ? full.articles[$0] : nil }
    }

    func patch(_ id: Article.ID, _ mutate: (inout Article) -> Void) {
        guard let index = indexByID[id] else { return }
        mutate(&full.articles[index])
        if index < rows.count { rows[index] = model(for: full.articles[index]) }
    }

    /// Reflects one offline save or removal in its row without waiting for the
    /// refilter that follows it (a bulk download refilters only at the end).
    func setSavedOffline(_ id: Article.ID, _ saved: Bool) {
        let changed = saved ? savedIDs.insert(id).inserted : savedIDs.remove(id) != nil
        guard changed, let index = indexByID[id], index < rows.count else { return }
        rows[index] = model(for: full.articles[index])
    }

    private func model(for article: Article) -> ArticleRowModel {
        ArticleRowModel(article, feedDisplayTitle: feedTitles[article.feedID],
                        isSavedOffline: savedIDs.contains(article.id))
    }

    private func publishPrefix(_ count: Int) {
        let appended = full.articles[rows.count..<count].map(model(for:))
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            rows.append(contentsOf: appended)
        }
    }
}
