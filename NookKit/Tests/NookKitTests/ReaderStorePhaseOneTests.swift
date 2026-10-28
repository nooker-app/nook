import Foundation
import Testing
@testable import NookKit

@Suite("Phase 1 list replacement and filtering")
@MainActor
struct ReaderStorePhaseOneTests {
    private func makeStore(count: Int = 3) -> ReaderStore {
        let store = ReaderStore._makeForTesting()
        store.feeds = [Fixture.feed("a"), Fixture.feed("b")]
        store.articles = (0..<count).map { Fixture.article("article-\($0)", feedID: $0 == 0 ? "a" : "b") }
        store.selectSmartSource(.all)
        return store
    }

    @Test("Compound navigation executes one filter, including empty folders and direct bindings")
    func navigationCoalesces() {
        let store = makeStore()
        var previous = store.filterExecutionCount
        store.selectCategory("category")
        #expect(store.filterExecutionCount == previous + 1)
        previous = store.filterExecutionCount
        store.selectFeed("a")
        #expect(store.filterExecutionCount == previous + 1)
        previous = store.filterExecutionCount
        store.selectSmartSource(.unread)
        #expect(store.filterExecutionCount == previous + 1)
        previous = store.filterExecutionCount
        store.selectCategory("category")
        store.selectFolder("empty")
        #expect(store.filterExecutionCount == previous + 2)
        #expect(store.categorySelection == nil)
        previous = store.filterExecutionCount
        store.feedSelection = ["b"]
        #expect(store.filterExecutionCount == previous + 1)
        store.feedSelection = ["b"]
        #expect(store.filterExecutionCount == previous + 1)
    }

    @Test("Retention survives read changes, clears before source filtering, and reselection refilters")
    func retainedClearsBeforeFilter() {
        let store = makeStore()
        store.selectSmartSource(.unread)
        store.retainArticle(id: "article-0")
        store.setRead(articleID: "article-0", isRead: true)
        #expect(store.visibleArticles.contains { $0.id == "article-0" })
        store.selectCategory("missing")
        store.selectSmartSource(.unread)
        #expect(!store.visibleArticles.contains { $0.id == "article-0" })
        store.retainArticle(id: "article-1")
        store.setRead(articleID: "article-1", isRead: true)
        store.selectSmartSource(.unread)
        #expect(!store.visibleArticles.contains { $0.id == "article-1" })
    }

    @Test("20 replacements change only the table identity and preserve a still-visible selection")
    func replacementIdentity() {
        let store = makeStore()
        store.selectedArticleID = "article-0"
        for _ in 0..<20 {
            let generation = store.listGeneration
            store.feedSelection = ["a"]
            #if os(macOS)
            #expect(store.listGeneration == generation + 1)
            #endif
            #expect(store.selectedArticleID == "article-0")
            store.selectSmartSource(.all)
            #expect(store.selectedArticleID == "article-0")
        }
        let generation = store.listGeneration
        store.retainArticle(id: "article-0")
        store.setRead(articleID: "article-0", isRead: true)
        store.setStarred(articleID: "article-0", isStarred: true)
        store.selectSmartSource(.all) // same source: refilter, no table replacement
        #expect(store.listGeneration == generation)
        store.feedSelection = ["b"]
        #expect(store.selectedArticleID == nil)
    }

    @Test("Article lookup follows reorder, incremental flags, merge, and deletion")
    func indexTracksLibrary() {
        let store = makeStore()
        store.articles.reverse()
        store.selectedArticleID = "article-0"
        #expect(store.selectedArticle?.id == "article-0")
        store.setRead(articleID: "article-0", isRead: true)
        store.setStarred(articleID: "article-0", isStarred: true)
        #expect(store.article(withID: "article-0")?.isRead == true)
        #expect(store.article(withID: "article-0")?.isStarred == true)
        #expect(store.article(withID: "article-2")?.isRead == false)
        #expect(store.count(for: .all) == 3)
        store._mergeForTesting(ParsedFeed(feed: Fixture.feed("a"), articles: [Fixture.article("new", feedID: "a")]))
        #expect(store.article(withID: "new")?.id == "new")
        #expect(store.count(for: .all) == 4)
        store.deleteArticle(articleID: "article-0")
        #expect(store.article(withID: "article-0") == nil)
        #expect(store.count(for: .all) == 3)
    }

    @Test("Rapid large-library transitions install only the latest source")
    func latestWins() async throws {
        let store = makeStore(count: 1_000)
        for index in store.articles.indices where index.isMultiple(of: 2) {
            store.articles[index].isRead = true
        }
        store.feedSelection = ["a"]
        store.selectSmartSource(.all)
        store.selectSmartSource(.unread)
        for _ in 0..<100 where store.visibleArticles.count != 500 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.visibleArticles.count == 500)
        #expect(store.smartSelection == .unread)
        #expect(store.feedSelection.isEmpty)
        #expect(store.selectedArticleID == nil)
        let generation = store.listGeneration
        try await Task.sleep(for: .milliseconds(350))
        #expect(store.listGeneration == generation)
        #expect(store.visibleArticles.count == 500)
    }

    @Test("Search replacement changes identity, clearing is immediate, and a cleared pending query cannot return")
    func searchReplacement() async throws {
        let store = makeStore()
        let initialGeneration = store.listGeneration
        store.searchText = "article-0"
        store.debounceSearch()
        for _ in 0..<100 where store.activeSearchQuery.isEmpty || store.visibleArticles.count != 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.visibleArticles.map(\.id) == ["article-0"])
        #if os(macOS)
        #expect(store.listGeneration == initialGeneration + 1)
        #endif
        store.searchText = ""
        store.debounceSearch()
        #expect(store.activeSearchQuery.isEmpty)
        #expect(store.visibleArticles.count == 3)
        let generation = store.listGeneration
        store.searchText = "article-2"
        store.debounceSearch()
        store.searchText = ""
        store.debounceSearch()
        try await Task.sleep(for: .milliseconds(350))
        #expect(store.activeSearchQuery.isEmpty)
        #expect(store.listGeneration == generation)
        #expect(store.visibleArticles.count == 3)
    }

    @Test("Deleting selected folders clears retention and installs one replacement filter")
    func removeFoldersSelection() {
        let store = makeStore()
        store.feeds = [Fixture.feed("a", category: "Folder"), Fixture.feed("b", category: "Folder")]
        store.createFolder("Folder")
        store.selectFolder("Folder")
        store.selectedArticleID = "article-0"
        store.retainArticle(id: "article-0")
        let count = store.filterExecutionCount
        store.removeFolders(["Folder"])
        #expect(store.filterExecutionCount == count + 1)
        #expect(store.feedSelection.isEmpty)
        #expect(store.visibleArticles.isEmpty)
        #expect(store.selectedArticleID == nil)
    }

    @Test("Cancelled callers cannot erase a synchronous filter or its selection")
    func cancelledSyncFilter() async {
        let store = makeStore()
        store.selectedArticleID = "article-0"
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            store.selectSmartSource(.all)
            #expect(store.visibleArticles.count == 3)
            #expect(store.selectedArticleID == "article-0")
        }
        await task.value
    }

    @Test("Batch start re-enrols a pending data filter; later data does not move the deadline")
    func batchThrottle() async throws {
        let store = makeStore()
        store.selectSmartSource(.unread)
        store.setRead(articleID: "article-0", isRead: true)
        store._beginBatchFilteringForTesting()
        let executions = store.filterExecutionCount
        try await Task.sleep(for: .milliseconds(800))
        #expect(store.filterExecutionCount == executions)
        store.setStarred(articleID: "article-1", isStarred: true)
        try await Task.sleep(for: .milliseconds(850))
        #expect(store.filterExecutionCount == executions + 1)
        #expect(store.visibleArticles.count == 2)
        store.setStarred(articleID: "article-2", isStarred: true)
        store.selectSmartSource(.all)
        #expect(store.filterExecutionCount == executions + 2)
        #expect(store.visibleArticles.count == 3)
        try await Task.sleep(for: .milliseconds(1600))
        #expect(store.filterExecutionCount == executions + 2)
        store._endBatchFilteringForTesting()
    }

    @Test("Precomputed install replaces the library index and filtered All count atomically")
    func precomputedIndex() {
        let store = makeStore()
        let library = ReaderLibrary(feeds: [Fixture.feed("a")], articles: [
            Fixture.article("replacement", feedID: "a"),
            Fixture.article("hidden", feedID: "a")
        ], lastRefreshedAt: nil, folders: [], filters: [ArticleFilter(pattern: "hidden")])
        store._applyPrecomputedForTesting(library)
        #expect(store.article(withID: "article-0") == nil)
        #expect(store.article(withID: "replacement")?.id == "replacement")
        #expect(store.count(for: .all) == 1)
    }

    @Test("Animation accepts small ordered overlap and rejects replacement, batches, reorder and 41-row deltas")
    func animationPredicate() {
        func animates(_ old: [String], _ new: [String], replacement: Bool = false,
                      batch: Bool = false, bulk: Bool = false, animated: Bool = true) -> Bool {
            ReaderStore.shouldAnimateDisplay(oldIDs: old, newIDs: new, animated: animated,
                replacesList: replacement, isBulkImporting: bulk, isBatchRefreshing: batch)
        }
        #expect(animates(["a", "b"], ["new", "a", "b"]))
        #expect(!animates(["a", "b"], ["b", "a"]))
        #expect(!animates(["a"], ["a", "b"], replacement: true))
        #expect(!animates(["a"], ["a", "b"], batch: true))
        #expect(!animates(["a"], ["a", "b"], bulk: true))
        #expect(!animates(["a"], ["a", "b"], animated: false))
        #expect(!animates([], ["a"]))
        #expect(!animates(["a"], ["b"]))
        #expect(!animates(["a"], ["a"] + (0..<41).map { "new-\($0)" }))
    }

    @Test("Seen writes share one HLC, preserve user flags, and skip background/already-seen/read articles")
    func seenBatch() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nook-seen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReaderStore._makeForTesting(storage: ReaderStorage(directoryURL: directory))
        store.articles = [
            Fixture.article("unread-1", feedID: "a", isStarred: true),
            Fixture.article("unread-2", feedID: "a"),
            Fixture.article("read", feedID: "a", isRead: true),
        ]
        store.selectSmartSource(.all)
        #expect(store._shardForTesting.articleState.isEmpty)
        store.setForegroundActive(true)
        let shard = store._shardForTesting
        let first = shard.articleState["unread-1"]?.seen
        let second = shard.articleState["unread-2"]?.seen
        #expect(first?.value == true)
        #expect(second?.value == true)
        #expect(first?.hlc == second?.hlc)
        #expect(shard.articleState["read"]?.seen == nil)
        #expect(store.article(withID: "unread-1")?.isStarred == true)
        store.selectSmartSource(.all) // identical-result path is also a no-op for already-seen articles
        #expect(store._shardForTesting == shard)
        store.setForegroundActive(false)
        store.articles.append(Fixture.article("background", feedID: "a"))
        store.selectSmartSource(.all)
        #expect(store._shardForTesting.articleState["background"]?.seen == nil)
        await store.prepareForLocalReset()
    }

    @Test("Foreground without a configured storage never writes seen state")
    func seenNeedsStorage() {
        let store = makeStore()
        store.setForegroundActive(true)
        #expect(store._shardForTesting.articleState.isEmpty)
    }

    @Test("Badge guard follows exported value and replays when its consumer changes")
    func badgeExport() {
        let store = makeStore()
        var values: [Int] = []
        store.onUnreadBadgeChange = { values.append($0) }
        store.showsUnreadBadge = false
        store.setRead(articleID: "article-0", isRead: true)
        #expect(values == [3, 0])
        store.showsUnreadBadge = true
        #expect(values == [3, 0, 2])
        store.onUnreadBadgeChange = { values.append($0) }
        #expect(values == [3, 0, 2, 2])
    }
}

@Suite("Refresh merge content projection")
@MainActor
struct MergeProjectionTests {
    @Test("Hydrating an evicted body and transient date provenance are change-free")
    func hydrationIsNotChange() {
        let store = ReaderStore._makeForTesting()
        let feed = Fixture.feed("a")
        var existing = Fixture.article("a#one", feedID: "a")
        existing.bodyParagraphs = []
        existing.contentHTML = nil
        store.feeds = [feed]
        store.articles = [existing]
        var incoming = existing
        incoming.bodyParagraphs = ["fresh body"]
        incoming.hasExplicitPublishDate = false
        incoming.publishedAt = existing.publishedAt.addingTimeInterval(100)
        store._mergeForTesting(ParsedFeed(feed: feed, articles: [incoming]))
        #expect(store.articles == [existing])
        #expect(store._cachedBodyForTesting(existing.id) == incoming.body)
    }

    @Test("Real retained body edits and authoritative date corrections still merge")
    func contentAndDatesChange() {
        let store = ReaderStore._makeForTesting()
        let feed = Fixture.feed("a")
        var existing = Fixture.article("a#one", feedID: "a")
        existing.bodyParagraphs = ["original body"]
        store.feeds = [feed]
        store.articles = [existing]
        var incoming = existing
        incoming.bodyParagraphs = ["edited body"]
        incoming.contentHTML = "<p>edited body</p>"
        store._mergeForTesting(ParsedFeed(feed: feed, articles: [incoming]))
        #expect(store.article(withID: incoming.id)?.body == incoming.body)
        incoming.publishedAt = existing.publishedAt.addingTimeInterval(100)
        incoming.hasExplicitPublishDate = true
        store._mergeForTesting(ParsedFeed(feed: feed, articles: [incoming]))
        #expect(store.article(withID: incoming.id)?.publishedAt == incoming.publishedAt)
    }
}
