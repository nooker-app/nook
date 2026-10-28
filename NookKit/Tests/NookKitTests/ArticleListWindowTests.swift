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
}
