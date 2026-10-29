import Foundation
import Testing
@testable import NookKit

/// Phase 4: what a macOS list row is handed and the title translation box lifetime.
@Suite("Article row cost", .serialized) @MainActor
struct ArticleRowCostTests {
    private func articles(_ count: Int, feedID: String = "a") -> [Article] {
        (0..<count).map { Fixture.article("row-\($0)", feedID: feedID) }
    }

    private func index(_ articles: [Article]) -> [Article.ID: Int] {
        Dictionary(uniqueKeysWithValues: articles.enumerated().map { ($0.element.id, $0.offset) })
    }

    // MARK: Row model

    @Test("The display diff hands rows their feed display title and offline flag")
    func modelsCarryResolvedFields() {
        let full = articles(300)
        let result = ReaderStore.computeDisplayDiff(old: [], result: full, feedTitles: ["a": "Custom A"],
            oldFeedTitles: [:], savedIDs: ["row-1"], oldSavedIDs: [], replacesList: true,
            previousLength: 0, selectedID: nil, animated: false, bulk: false, batch: false)
        #expect(result.rows.count == 200)
        #expect(result.rows[0].feedDisplayTitle == "Custom A")
        #expect(!result.rows[0].isSavedOffline)
        #expect(result.rows[1].isSavedOffline)
        #expect(result.rows[0].publishedAt == full[0].publishedAt)
        #expect(result.rows[0].readMinutes == full[0].estimatedReadMinutes)
    }

    @Test("The row model is the diff's equality: rendered fields republish, body content does not")
    func modelEquality() {
        let old = articles(10)
        func diff(_ new: [Article], titles: [Feed.ID: String] = ["a": "A"], saved: Set<Article.ID> = []) -> Bool {
            ReaderStore.computeDisplayDiff(old: old, result: new, feedTitles: titles, oldFeedTitles: ["a": "A"],
                savedIDs: saved, oldSavedIDs: [], replacesList: false, previousLength: 10, selectedID: nil,
                animated: false, bulk: false, batch: false).identical
        }
        var hydrated = old
        hydrated[3].bodyParagraphs = ["A body that arrived later."]
        hydrated[3].contentHTML = "<p>A body that arrived later.</p>"
        hydrated[3].hasExplicitPublishDate = false
        #expect(diff(hydrated))
        #expect(!diff(old, titles: ["a": "Renamed"]))
        #expect(!diff(old, saved: ["row-4"]))
        var categorized = old
        categorized[2].categories = ["perf-cat-1"]
        #expect(!diff(categorized))
        var minutes = old
        minutes[5].estimatedReadMinutes += 1
        #expect(!diff(minutes))
    }

    @Test("Growth, patches and offline flags rebuild models from the installed titles and saved set")
    func windowBuildsModels() async {
        let window = ArticleListWindow()
        let full = articles(1_000)
        let rows = ReaderStore.rowModels(full.prefix(200), feedTitles: ["a": "A"], savedIDs: ["row-250"])
        window.install(contents: ArticleListContents(full), indexByID: index(full), rows: rows,
                       feedTitles: ["a": "A"], savedIDs: ["row-250"], replacement: true)
        window.requestGrowth()
        for _ in 0..<30 where window.rows.count == 200 { await Task.yield() }
        #expect(window.rows.count == 400)
        #expect(window.rows[399].feedDisplayTitle == "A")
        #expect(window.rows[250].isSavedOffline)

        window.patch("row-5") { $0.isRead = true }
        #expect(window.rows[5].isRead && window.rows[5].feedDisplayTitle == "A")
        window.setSavedOffline("row-7", true)
        #expect(window.rows[7].isSavedOffline)
        window.setSavedOffline("row-7", false)
        #expect(!window.rows[7].isSavedOffline)
        window.setSavedOffline("row-900", true) // off-window: remembered for growth
        window.ensureVisible(id: "row-900")
        #expect(window.rows[900].isSavedOffline)
        #expect(window.article(withID: "row-900")?.id == "row-900")
    }

    #if os(macOS)
    @Test("Copies removed by the expiry purge clear their rows' offline badge at once")
    func purgeClearsOfflineBadge() async throws {
        let store = ReaderStore._makeForTesting()
        store.feeds = [Fixture.feed("a")]
        store.articles = articles(300)
        store.selectSmartSource(.all)
        for _ in 0..<200 where store.listWindow.rows.count != 200 {
            try await Task.sleep(for: .milliseconds(10))
        }
        func saved(_ id: Article.ID) -> Bool? { store.listWindow.rows.first { $0.id == id }?.isSavedOffline }
        store.listWindow.setSavedOffline("row-3", true)
        store.listWindow.setSavedOffline("row-4", true)
        #expect(saved("row-3") == true)
        store.offlineCopiesRemoved(["row-3"])
        #expect(saved("row-3") == false)
        #expect(saved("row-4") == true)
    }
    #endif

    @Test("Only a replacing install runs the replacement hook")
    func replacementHook() {
        let window = ArticleListWindow()
        var calls = 0
        window.onReplacement = { calls += 1 }
        let full = articles(10)
        window.install(full: full, indexByID: index(full), rows: full, replacement: true)
        window.install(full: full, indexByID: index(full), rows: full, replacement: false)
        #expect(calls == 1)
    }

    @Test("A store install publishes models with the feed's custom name")
    func storeInstallUsesDisplayTitle() async throws {
        let store = ReaderStore._makeForTesting()
        var feed = Fixture.feed("a")
        feed.customTitle = "My Name"
        store.feeds = [feed]
        store.articles = articles(20)
        store.selectSmartSource(.all)
        for _ in 0..<200 where store.visibleArticles.count != 20 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #if os(macOS)
        #expect(store.listWindow.rows.first?.feedDisplayTitle == "My Name")
        #endif
        #expect(store.listedArticle(withID: "row-3")?.id == "row-3")
        #expect(store.listedArticle(withID: "missing") == nil)
    }

    // MARK: Title translation boxes

    @Test("Idle boxes are released; boxes with work stay; a re-created box seeds from the cache")
    func boxLifetime() {
        let translator = ListTitleTranslator()
        translator._enableForTesting(targetLanguageCode: "ko", cached: ["Cached title": "캐시된 제목"])
        let cached = translator.box(for: "cached", title: "Cached title")
        #expect(cached.state == .translated("캐시된 제목", provider: .appleIntelligence))
        #expect(cached.layoutRevision == 0, "a seed is the first layout, not a change to re-measure")
        let plain = translator.box(for: "plain", title: "Plain title")
        #expect(plain.state == nil)
        #expect(translator.box(for: "plain", title: "Plain title") === plain)
        translator.rowAppeared(id: "plain", title: "Plain title") // starts a dwell
        #expect(translator.boxCount == 2)

        translator.releaseIdleBoxes()
        #expect(translator.boxCount == 1, "the dwelling row keeps its box")
        #expect(translator.box(for: "plain", title: "Plain title") === plain)
        let recreated = translator.box(for: "cached", title: "Cached title")
        #expect(recreated !== cached)
        #expect(recreated.state == .translated("캐시된 제목", provider: .appleIntelligence))
        translator.rowDisappeared(id: "plain")
    }

    @Test("A result for a released row creates no orphan box")
    func noOrphanBox() {
        let translator = ListTitleTranslator()
        translator._enableForTesting(targetLanguageCode: "ko")
        _ = translator.box(for: "gone", title: "Gone")
        translator.releaseIdleBoxes()
        #expect(translator.boxCount == 0)
        translator._deliverForTesting(.translated("사라짐", provider: .appleIntelligence), for: "gone")
        #expect(translator.boxCount == 0)
        let box = translator.box(for: "kept", title: "Kept")
        translator._deliverForTesting(.translating("부분", provider: .appleIntelligence), for: "kept")
        #expect(box.state == .translating("부분", provider: .appleIntelligence))
        #expect(box.layoutRevision == 1)
    }

    @Test("Rows re-created by the List rebuild that follows enabling translate at once, in either callback order")
    func enableRebuildTranslatesAtOnce() {
        for oldRowGoesFirst in [false, true] {
            let translator = ListTitleTranslator()
            // Hold the queue so no worker starts; `pending` is what is asserted.
            translator.setScrolling(true)
            translator.rowAppeared(id: "a", title: "A title") // the old table's row, shown while off
            translator._enableForTesting(targetLanguageCode: "ko")
            translator._markJustEnabledForTesting()
            if oldRowGoesFirst {
                translator.rowDisappeared(id: "a")
                translator.rowAppeared(id: "a", title: "A title")
            } else {
                translator.rowAppeared(id: "a", title: "A title")
                translator.rowDisappeared(id: "a")
            }
            #expect(translator._schedulingForTesting("a") == "pending", "old row first: \(oldRowGoesFirst)")
            translator.rowDisappeared(id: "a")
            #expect(translator._schedulingForTesting("a") == "none", "the last row view leaving drops the work")
        }
        // Outside the window a row scrolled into view still waits for the dwell.
        let translator = ListTitleTranslator()
        translator.setScrolling(true)
        translator._enableForTesting(targetLanguageCode: "ko")
        translator.rowAppeared(id: "b", title: "B title")
        #expect(translator._schedulingForTesting("b") == "dwell")
        translator.rowDisappeared(id: "b")
    }
}
