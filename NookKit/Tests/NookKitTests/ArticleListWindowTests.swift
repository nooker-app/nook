import Foundation
import Observation
import Synchronization
import Testing
@testable import NookKit

@Suite("Article list rendering window") @MainActor
struct ArticleListWindowTests {
    private func articles(_ count: Int) -> [Article] {
        (0..<count).map { Fixture.article("row-\($0)", feedID: "a") }
    }
    private func install(_ articles: [Article], in window: ArticleListWindow, length: Int = 200) {
        window.install(full: articles,
            indexByID: Dictionary(uniqueKeysWithValues: articles.enumerated().map { ($0.element.id, $0.offset) }),
            rows: Array(articles.prefix(length)))
    }

    @Test("Initial window and selected deep rows determine the prefix")
    func initialLength() {
        #expect(ArticleListWindow.length(total: 5_000, previousTotal: 0, previousLength: 0,
            replacement: true, selectedIndex: nil) == 200)
        #expect(ArticleListWindow.length(total: 5_000, previousTotal: 100, previousLength: 100,
            replacement: true, selectedIndex: 900) == 950)
        #expect(ArticleListWindow.length(total: 5_003, previousTotal: 5_000, previousLength: 400,
            replacement: false, selectedIndex: nil) == 403)
        #expect(ArticleListWindow.length(total: 30, previousTotal: 5_000, previousLength: 400,
            replacement: true, selectedIndex: nil) == 30)
    }

    @Test("Growth yields, is single flight and a replacement rejects stale growth")
    func growth() async {
        let window = ArticleListWindow()
        let full = articles(1_000)
        install(full, in: window)
        window.rowAppeared(id: "row-149")
        #expect(window.rows.count == 200)
        window.rowAppeared(id: "row-150")
        window.requestGrowth()
        window.requestGrowth()
        #expect(window.rows.count == 200)
        for _ in 0..<30 where window.rows.count == 200 { await Task.yield() }
        #expect(window.rows.count == 400)
        window.requestGrowth()
        install(Array(full.prefix(10)), in: window)
        for _ in 0..<10 { await Task.yield() }
        #expect(window.rows.count == 10)
        #expect(window.totalCount == 10)
    }

    @Test("Selection expands beyond the window and in-place patches preserve full data")
    func selectionAndPatch() async {
        let window = ArticleListWindow()
        install(articles(1_000), in: window)
        window.patch("row-900") { $0.isRead = true }
        #expect(window.rows.count == 200)
        window.ensureVisible(id: "missing")
        #expect(window.rows.count == 200)
        window.ensureVisible(id: "row-900")
        #expect(window.rows.count == 950)
        #expect(window.rows[900].isRead)
        window.patch("row-5") { $0.isStarred = true }
        #expect(window.rows[5].isStarred)
        window.requestGrowth()
        for _ in 0..<30 where window.rows.count != 1_000 { await Task.yield() }
        #expect(window.rows.count == 1_000)
        #expect(window.rows[5].isStarred)
    }

    @Test("Small updates preserve the grown length plus net growth, and equal-ID source switches preserve identity")
    func incrementalLengthAndEqualSource() async throws {
        let store = ReaderStore._makeForTesting()
        store.feeds = [Fixture.feed("a")]
        store.articles = articles(1_000)
        store.selectSmartSource(.all)
        for _ in 0..<200 where store.visibleArticles.count != 1_000 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #if os(macOS)
        store.listWindow.requestGrowth()
        for _ in 0..<30 where store.listWindow.rows.count != 400 { await Task.yield() }
        #expect(store.listWindow.rows.count == 400)
        #endif
        let generation = store.listGeneration
        store.articles.append(Fixture.article("new-row", feedID: "a"))
        store.selectSmartSource(.all)
        for _ in 0..<200 where store.visibleArticles.count != 1_001 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #if os(macOS)
        #expect(store.listWindow.rows.count == 401)
        #endif
        #expect(store.listGeneration == generation)
        store.selectFeed("a") // every article is in this feed, so the IDs are identical
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.listGeneration == generation)
        #if os(macOS)
        #expect(store.listWindow.rows.count == 401)
        #endif
    }

    @Test("Full result stays observable and an off-window patch does not publish rows")
    func fullObservation() async throws {
        let store = ReaderStore._makeForTesting()
        store.articles = articles(1_000)
        store.selectSmartSource(.all)
        for _ in 0..<200 where store.visibleArticles.count != 1_000 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let fullChanges = Mutex(0)
        let rowChanges = Mutex(0)
        withObservationTracking { _ = store.visibleArticles } onChange: {
            fullChanges.withLock { $0 += 1 }
        }
        withObservationTracking { _ = store.listWindow.rows } onChange: {
            rowChanges.withLock { $0 += 1 }
        }
        let id = store.visibleArticles[900].id
        store.setRead(articleID: id, isRead: true)
        #expect(fullChanges.withLock { $0 } == 1)
        #expect(rowChanges.withLock { $0 } == 0)
        #expect(store.visibleArticles[900].isRead)
    }

    @Test("An in-flight filter cannot overwrite a newer read patch; deep opening expands the installed window")
    func patchDuringFilterAndDeepOpen() async throws {
        let store = ReaderStore._makeForTesting()
        store.articles = articles(1_000)
        store.selectSmartSource(.all)
        for _ in 0..<200 where store.visibleArticles.count != 1_000 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let id = store.visibleArticles[900].id
        store.selectSmartSource(.all)
        store.setRead(articleID: id, isRead: true)
        store.openArticle(id: id)
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.visibleArticles.first { $0.id == id }?.isRead == true)
        #expect(store.selectedArticleID == id)
        #if os(macOS)
        #expect(store.listWindow.rows.contains { $0.id == id })
        #endif
    }

    @Test("Store keeps the full sorted list for navigation, retention, flags and selection pruning")
    func storeFullResult() async throws {
        let store = ReaderStore._makeForTesting()
        store.feeds = [Fixture.feed("a")]
        store.articles = articles(1_000)
        store.selectSmartSource(.all)
        for _ in 0..<200 where store.visibleArticles.count != 1_000 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.visibleArticles.count == 1_000)
        #if os(macOS)
        #expect(store.listWindow.rows.count == 200)
        #expect(store.listWindow.totalCount == 1_000)
        #endif
        let target = store.visibleArticles[900].id
        let previous = store.visibleArticles[899].id
        let next = store.visibleArticles[901].id
        store.selectedArticleID = target
        store.pruneSelectionIfHidden()
        #expect(store.selectedArticleID == target)
        #expect(store.article(before: target)?.id == previous)
        #expect(store.article(after: target)?.id == next)
        #expect(store.article(after: "missing") == nil)
        #if os(macOS)
        #expect(store.listWindow.rows.contains { $0.id == target })
        #endif
        let executions = store.filterExecutionCount
        store.retainArticle(id: target)
        #expect(store.filterExecutionCount == executions)
        store.setRead(articleID: target, isRead: true)
        #expect(store.visibleArticles[900].isRead)
        #if os(macOS)
        #expect(store.listWindow.rows[900].isRead)
        #endif
        store.selectNextArticle()
        #expect(store.selectedArticleID == next)
        store.selectPreviousArticle()
        #expect(store.selectedArticleID == target)
    }

    private func settledStore(_ count: Int) async throws -> ReaderStore {
        let store = ReaderStore._makeForTesting()
        store.feeds = [Fixture.feed("a")]
        store.articles = articles(count)
        store.selectSmartSource(.all)
        for _ in 0..<200 where store.visibleArticles.count != count {
            try await Task.sleep(for: .milliseconds(10))
        }
        return store
    }

    private func dated(_ id: String, _ seconds: TimeInterval) -> Article {
        var article = Fixture.article(id, feedID: "a")
        article.publishedAt = Date(timeIntervalSince1970: seconds)
        return article
    }

    @Test("An incremental install keeps a pending growth request alive")
    func incrementalInstallKeepsGrowth() async {
        let window = ArticleListWindow()
        let full = articles(1_000)
        install(full, in: window)
        window.rowAppeared(id: "row-150")
        window.install(full: full,
            indexByID: Dictionary(uniqueKeysWithValues: full.enumerated().map { ($0.element.id, $0.offset) }),
            rows: Array(full.prefix(200)), replacement: false)
        for _ in 0..<30 where window.rows.count == 200 { await Task.yield() }
        #expect(window.rows.count == 400)
    }

    @Test("A data-driven reorder keeps the grown window and list identity; a sort toggle replaces it")
    func dataReorderVersusSortToggle() async throws {
        let store = try await settledStore(1_000)
        #if os(macOS)
        store.listWindow.requestGrowth()
        for _ in 0..<30 where store.listWindow.rows.count != 400 { await Task.yield() }
        #expect(store.listWindow.rows.count == 400)
        #endif
        let generation = store.listGeneration
        // Date resolution / a corrected feed date moves an off-window article to the top.
        let moved = store.visibleArticles[900].id
        let index = try #require(store.libraryArticles.firstIndex { $0.id == moved })
        store.articles[index].publishedAt = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<200 where store.visibleArticles.first?.id != moved {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.visibleArticles.first?.id == moved)
        #expect(store.listGeneration == generation)
        #if os(macOS)
        #expect(store.listWindow.rows.count == 400)
        #expect(store.listWindow.rows.first?.id == moved)
        #endif

        let first = store.visibleArticles.first?.id
        // The toggle persists a device preference; restore it in the same turn so
        // stores created by concurrently running tests never load the flipped order.
        let savedOrders = UserDefaults.standard.object(forKey: "articleSortOrders")
        store.toggleSortOrder(for: .all)
        UserDefaults.standard.set(savedOrders, forKey: "articleSortOrders")
        for _ in 0..<200 where store.visibleArticles.first?.id == first {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.listGeneration == generation &+ 1)
        #if os(macOS)
        #expect(store.listWindow.rows.count == 200)
        #endif
    }

    @Test("A detached result outlived by window growth is re-cut on main, not refiltered")
    func detachedResultRecutAfterGrowth() async throws {
        let store = try await settledStore(1_000)
        let executions = store.filterExecutionCount
        let deep = store.visibleArticles[700].id
        store.articles.append(dated("new-top", 1_800_000_000))
        store.selectSmartSource(.all) // detached: the library is over the sync threshold
        #if os(macOS)
        store.listWindow.ensureVisible(id: deep) // grows to 750 before the result lands
        #expect(store.listWindow.rows.count == 750)
        #endif
        for _ in 0..<200 where store.visibleArticles.first?.id != "new-top" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.visibleArticles.count == 1_001)
        #expect(store.filterExecutionCount == executions + 1)
        #if os(macOS)
        #expect(store.listWindow.rows.count == 750)
        #expect(store.listWindow.rows.first?.id == "new-top")
        #endif
    }

    @Test("A detached result is discarded and rescheduled when batch state changed meanwhile")
    func detachedResultDiscardedOnBatchChange() async throws {
        let store = try await settledStore(1_000)
        let executions = store.filterExecutionCount
        store.articles.append(dated("new-top", 1_800_000_000))
        store.selectSmartSource(.all)
        store._beginBatchFilteringForTesting()
        for _ in 0..<200 where store.visibleArticles.first?.id != "new-top" {
            try await Task.sleep(for: .milliseconds(10))
        }
        store._endBatchFilteringForTesting()
        #expect(store.visibleArticles.first?.id == "new-top")
        #expect(store.filterExecutionCount == executions + 2)
    }

    @Test("Three new articles slide in end to end through the display diff")
    func threeArticleSlide() {
        let old = (0..<300).map { dated("old-\($0)", 1_700_000_000 - Double($0)) }
        let fresh = (0..<3).map { dated("new-\($0)", 1_800_000_000 - Double($0)) }
        let result = ReaderStore.computeDisplayDiff(old: old, result: fresh + old, feedTitles: [:],
            oldFeedTitles: [:], savedIDs: [], oldSavedIDs: [], replacesList: false,
            previousLength: 200, selectedID: nil, animated: true, bulk: false, batch: false)
        #expect(result.willAnimate)
        #expect(!result.replacesList)
        #expect(result.rows.count == 203)
        #expect(result.rows.prefix(3).map(\.id) == fresh.map(\.id))
    }

    @Test("A data reorder in the diff keeps the length and does not animate")
    func dataReorderDiff() {
        let old = (0..<1_000).map { dated("row-\($0)", 1_700_000_000 - Double($0)) }
        var reordered = old
        let moved = reordered.remove(at: 900)
        reordered.insert(moved, at: 0)
        let result = ReaderStore.computeDisplayDiff(old: old, result: reordered, feedTitles: [:],
            oldFeedTitles: [:], savedIDs: [], oldSavedIDs: [], replacesList: false,
            previousLength: 400, selectedID: nil, animated: true, bulk: false, batch: false)
        #expect(!result.replacesList)
        #expect(!result.willAnimate)
        #expect(result.rows.count == 400)
        let toggled = ReaderStore.computeDisplayDiff(old: old, result: old.reversed(), feedTitles: [:],
            oldFeedTitles: [:], savedIDs: [], oldSavedIDs: [], replacesList: true,
            previousLength: 400, selectedID: nil, animated: true, bulk: false, batch: false)
        #expect(toggled.replacesList)
        #expect(toggled.rows.count == 200)
    }

    @Test("Offline stand-ins are indexed, patched in the window and pruned when removed")
    func offlineStandIns() {
        let inLibrary = Fixture.article("kept", feedID: "a")
        let info = { (id: String, at: TimeInterval) in
            OfflineArticleInfo(id: id, title: id, url: URL(string: "https://example.com/\(id)")!,
                feedTitle: "Gone", savedAt: Date(timeIntervalSince1970: at), byteCount: 1)
        }
        let display = ReaderStore.offlineDisplayArticles(
            infos: [info("orphan", 2), info("kept", 1)], articles: [inLibrary], query: "", filteredIDs: [])
        #expect(display.map(\.id) == ["orphan", "kept"])
        #expect(display[0].feedID == "" && display[0].isRead)
        let result = ReaderStore.computeDisplayDiff(old: [], result: display, feedTitles: [:],
            oldFeedTitles: [:], savedIDs: ["orphan", "kept"], oldSavedIDs: [], replacesList: true,
            previousLength: 0, selectedID: "orphan", animated: false, bulk: false, batch: false)
        #expect(result.indexByID["orphan"] == 0)
        let window = ArticleListWindow()
        window.install(full: result.full, indexByID: result.indexByID, rows: result.rows)
        window.patch("orphan") { $0.isStarred = true }
        #expect(window.rows[0].isStarred)
        let removed = ReaderStore.offlineDisplayArticles(
            infos: [info("kept", 1)], articles: [inLibrary], query: "", filteredIDs: [])
        let after = ReaderStore.computeDisplayDiff(old: display, result: removed, feedTitles: [:],
            oldFeedTitles: [:], savedIDs: ["kept"], oldSavedIDs: ["orphan", "kept"], replacesList: false,
            previousLength: 2, selectedID: "orphan", animated: false, bulk: false, batch: false)
        #expect(after.indexByID["orphan"] == nil) // pruneSelectionIfHidden drops the selection
        #expect(after.rows.map(\.id) == ["kept"])
    }

    @Test("Batch end animates only an interactive refresh that added to a populated library")
    func batchEndAnimationFlag() {
        let existing = [Fixture.article("a1", feedID: "a")]
        let grown = existing + [Fixture.article("a2", feedID: "a")]
        let initial: Set<Article.ID> = ["a1"]
        #expect(ReaderStore.batchEndAnimates(animatesInsertion: true, initialArticleIDs: initial, articles: grown))
        #expect(!ReaderStore.batchEndAnimates(animatesInsertion: true, initialArticleIDs: initial, articles: existing))
        #expect(!ReaderStore.batchEndAnimates(animatesInsertion: false, initialArticleIDs: initial, articles: grown))
        #expect(!ReaderStore.batchEndAnimates(animatesInsertion: true, initialArticleIDs: [], articles: grown))
    }
}
