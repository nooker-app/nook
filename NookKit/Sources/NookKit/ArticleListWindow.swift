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

    nonisolated public init(id: Article.ID, feedID: Feed.ID, title: String, summary: String, isRead: Bool,
                            isStarred: Bool, publishedAt: Date, feedDisplayTitle: String?, readMinutes: Int,
                            categories: [String], isSavedOffline: Bool) {
        self.id = id
        self.feedID = feedID
        self.title = title
        self.summary = summary
        self.isRead = isRead
        self.isStarred = isStarred
        self.publishedAt = publishedAt
        self.feedDisplayTitle = feedDisplayTitle
        self.readMinutes = readMinutes
        self.categories = categories
        self.isSavedOffline = isSavedOffline
    }

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

/// Receives every change to `ArticleListWindow.rows`, as it happens.
///
/// The SwiftUI `List` backend observes `rows` and diffs it; the AppKit table
/// backend cannot afford that diff, so the window tells it what kind of change
/// it made: a replacement (reload), an incremental install (the previous rows
/// to diff against), growth (an appended range) or a one-row patch.
@MainActor
public protocol ArticleListWindowObserver: AnyObject {
    func articleListWindow(_ window: ArticleListWindow, didChange change: ArticleListWindow.Change)
}

/// macOS rendering queue. Membership and navigation always use the complete result.
@MainActor @Observable
public final class ArticleListWindow {
    public enum Change {
        /// A new source: nothing of the previous rows carries over.
        case replaced
        /// A data change to the same source, with the rows it replaced.
        case installed(previous: [ArticleRowModel], animated: Bool)
        /// Growth or `ensureVisible`: rows appended at the end, nothing else moved.
        case appended(Range<Int>)
        /// One row's model changed in place.
        case patched(Int)
    }

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
    /// The AppKit table backend, told of each change after `rows` holds it.
    @ObservationIgnored public weak var observer: ArticleListWindowObserver?

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

    func install(full: [Article], indexByID: [Article.ID: Int], rows: [ArticleRowModel], replacement: Bool = true,
                 animated: Bool = false) {
        install(contents: ArticleListContents(full), indexByID: indexByID, rows: rows,
                feedTitles: [:], savedIDs: [], replacement: replacement, animated: animated)
    }

    /// Only a replacement invalidates pending growth. An incremental install keeps
    /// the prefix it extends, and the sentinel row that requested growth is already
    /// on screen, so its onAppear would not fire again to re-request it.
    func install(contents: ArticleListContents, indexByID: [Article.ID: Int], rows: [ArticleRowModel],
                 feedTitles: [Feed.ID: String], savedIDs: Set<Article.ID>, replacement: Bool,
                 animated: Bool = false) {
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
        let previous = self.rows
        self.rows = rows
        observer?.articleListWindow(self, didChange: replacement ? .replaced : .installed(previous: previous, animated: animated))
    }

    /// `rows` read without registering an observation, for the AppKit table: it is
    /// told of every change through `observer`, and a tracked read from inside a
    /// SwiftUI update would re-run that update on every publish for nothing.
    public var rowCount: Int { _rows.count }
    public func row(at index: Int) -> ArticleRowModel { _rows[index] }

    /// The row an id is displayed at, if the window holds it: the window is a
    /// prefix of the full result, so a full-result index below `rows.count` is a row.
    public func rowIndex(of id: Article.ID) -> Int? {
        guard let index = indexByID[id], index < rows.count else { return nil }
        return index
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
        if index < rows.count {
            rows[index] = model(for: full.articles[index])
            observer?.articleListWindow(self, didChange: .patched(index))
        }
    }

    /// Reflects one offline save or removal in its row without waiting for the
    /// refilter that follows it (a bulk download refilters only at the end).
    func setSavedOffline(_ id: Article.ID, _ saved: Bool) {
        let changed = saved ? savedIDs.insert(id).inserted : savedIDs.remove(id) != nil
        guard changed, let index = indexByID[id], index < rows.count else { return }
        rows[index] = model(for: full.articles[index])
        observer?.articleListWindow(self, didChange: .patched(index))
    }

    private func model(for article: Article) -> ArticleRowModel {
        ArticleRowModel(article, feedDisplayTitle: feedTitles[article.feedID],
                        isSavedOffline: savedIDs.contains(article.id))
    }

    private func publishPrefix(_ count: Int) {
        let start = rows.count
        let appended = full.articles[rows.count..<count].map(model(for:))
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            rows.append(contentsOf: appended)
        }
        if !appended.isEmpty { observer?.articleListWindow(self, didChange: .appended(start..<rows.count)) }
    }
}
