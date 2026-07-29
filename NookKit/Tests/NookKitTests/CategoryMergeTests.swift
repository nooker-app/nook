import Foundation
import Testing
@testable import NookKit

@Suite("Article category sync (per-item CRDT + per-article assignment)")
struct CategoryMergeTests {
    private func shard(_ deviceID: String, _ build: (inout DeviceStateDocument) -> Void) -> DeviceStateDocument {
        var doc = DeviceStateDocument(deviceID: deviceID)
        build(&doc)
        return doc
    }

    private func category(_ id: String, _ name: String, order: Int = 0, hidden: Bool = false) -> ArticleCategory {
        ArticleCategory(id: id, name: name, order: order, hidden: hidden)
    }

    @Test("Definitions: concurrent adds of different categories both survive, sorted")
    func concurrentDefinitionsSurvive() {
        let base = Fixture.library(feeds: [], articles: [])
        let a = shard("A") { $0.setCategory("a", category("a", "Apple", order: 0), hlc: Fixture.hlc(1000, node: "A")) }
        let b = shard("B") { $0.setCategory("b", category("b", "AI", order: 1), hlc: Fixture.hlc(1000, node: "B")) }
        let ab = DeviceStateDocument.materialize(base: base, shards: [a, b])
        let ba = DeviceStateDocument.materialize(base: base, shards: [b, a])
        #expect(ab.categories.map(\.name) == ["Apple", "AI"])
        #expect(ba.categories.map(\.name) == ["Apple", "AI"])
    }

    @Test("Definitions: higher-HLC edit wins; tombstone removes")
    func definitionEditAndDelete() {
        let base = Fixture.library(feeds: [], articles: [])
        let early = shard("A") { $0.setCategory("a", category("a", "Old", order: 0), hlc: Fixture.hlc(1000, node: "A")) }
        let renamed = shard("B") { $0.setCategory("a", category("a", "New", order: 0), hlc: Fixture.hlc(2000, node: "B")) }
        #expect(DeviceStateDocument.materialize(base: base, shards: [early, renamed]).categories.map(\.name) == ["New"])

        let deleted = shard("C") { $0.setCategoryTombstone("a", true, hlc: Fixture.hlc(3000, node: "C")) }
        #expect(DeviceStateDocument.materialize(base: base, shards: [early, renamed, deleted]).categories.isEmpty)
    }

    /// Writes an assignment change the way `ReaderStore.recordArticleCategories`
    /// does: the whole-list register plus one membership register per changed id.
    private func assign(
        _ doc: inout DeviceStateDocument,
        article: Article.ID,
        from previous: [String],
        to next: [String],
        at millis: Int64,
        node: String
    ) {
        var tick = millis
        doc.setArticleCategories(article, next, hlc: Fixture.hlc(tick, node: node))
        for added in next where !previous.contains(added) {
            tick += 1
            doc.setArticleCategoryMembership(article, category: added, present: true, hlc: Fixture.hlc(tick, node: node))
        }
        for removed in previous where !next.contains(removed) {
            tick += 1
            doc.setArticleCategoryMembership(article, category: removed, present: false, hlc: Fixture.hlc(tick, node: node))
        }
    }

    /// A library with one article and category definitions x/y/z/w (in that order).
    private func libraryWithDefinitions() -> (ReaderLibrary, DeviceStateDocument) {
        let base = Fixture.library(feeds: [Fixture.feed("f1")], articles: [Fixture.article("a1", feedID: "f1")])
        let defs = shard("defs") {
            $0.setCategory("x", category("x", "X", order: 0), hlc: Fixture.hlc(1, node: "defs"))
            $0.setCategory("y", category("y", "Y", order: 1), hlc: Fixture.hlc(2, node: "defs"))
            $0.setCategory("z", category("z", "Z", order: 2), hlc: Fixture.hlc(3, node: "defs"))
            $0.setCategory("w", category("w", "W", order: 3), hlc: Fixture.hlc(4, node: "defs"))
        }
        return (base, defs)
    }

    @Test("Per-article assignment merges across devices by HLC and materializes onto the article")
    func perArticleAssignment() {
        let (base, defs) = libraryWithDefinitions()
        let early = shard("A") { $0.setArticleCategories("a1", ["x"], hlc: Fixture.hlc(1000, node: "A")) }
        let late = shard("B") { $0.setArticleCategories("a1", ["x", "y"], hlc: Fixture.hlc(2000, node: "B")) }
        let merged = DeviceStateDocument.materialize(base: base, shards: [defs, early, late])
        #expect(merged.articles.first?.categories == ["x", "y"])
        // Order-independent.
        let merged2 = DeviceStateDocument.materialize(base: base, shards: [late, early, defs])
        #expect(merged2.articles.first?.categories == ["x", "y"])
    }

    @Test("Concurrent tagging on two devices unions instead of winner-takes-all")
    func concurrentAssignmentsUnion() {
        // macOS classifies the article "x", iOS classifies it "y" — neither saw
        // the other. The old whole-list register would keep only the later
        // writer; the membership registers keep both.
        let (base, defs) = libraryWithDefinitions()
        var macShard = DeviceStateDocument(deviceID: "mac")
        assign(&macShard, article: "a1", from: [], to: ["x"], at: 1000, node: "mac")
        var phoneShard = DeviceStateDocument(deviceID: "ios")
        assign(&phoneShard, article: "a1", from: [], to: ["y"], at: 1001, node: "ios")

        let merged = DeviceStateDocument.materialize(base: base, shards: [defs, macShard, phoneShard])
        #expect(merged.articles.first?.categories == ["x", "y"])
        let merged2 = DeviceStateDocument.materialize(base: base, shards: [phoneShard, macShard, defs])
        #expect(merged2.articles.first?.categories == ["x", "y"])
    }

    @Test("A removal beats a stale assignment and survives a concurrent add")
    func removalWinsOverStaleAssignment() {
        let (base, defs) = libraryWithDefinitions()
        var macShard = DeviceStateDocument(deviceID: "mac")
        assign(&macShard, article: "a1", from: [], to: ["x", "y"], at: 1000, node: "mac")
        // Later, the user removes y on the Mac…
        assign(&macShard, article: "a1", from: ["x", "y"], to: ["x"], at: 2000, node: "mac")
        // …while the phone (which still saw [x, y]) concurrently adds z. Its
        // whole-list register resurrects y — the membership register must not.
        var phoneShard = DeviceStateDocument(deviceID: "ios")
        assign(&phoneShard, article: "a1", from: ["x", "y"], to: ["x", "y", "z"], at: 2001, node: "ios")

        let merged = DeviceStateDocument.materialize(base: base, shards: [defs, macShard, phoneShard])
        #expect(merged.articles.first?.categories == ["x", "z"])
    }

    @Test("A cross-device union is capped back to three, deterministically")
    func unionCapsAtThree() {
        let (base, defs) = libraryWithDefinitions()
        var macShard = DeviceStateDocument(deviceID: "mac")
        assign(&macShard, article: "a1", from: [], to: ["w", "z"], at: 1000, node: "mac")
        var phoneShard = DeviceStateDocument(deviceID: "ios")
        assign(&phoneShard, article: "a1", from: [], to: ["y", "x"], at: 1001, node: "ios")

        // Union is {x,y,z,w} — capped to the first three in definition order,
        // the same on every device regardless of shard order.
        let merged = DeviceStateDocument.materialize(base: base, shards: [defs, macShard, phoneShard])
        #expect(merged.articles.first?.categories == ["x", "y", "z"])
        let merged2 = DeviceStateDocument.materialize(base: base, shards: [phoneShard, defs, macShard])
        #expect(merged2.articles.first?.categories == ["x", "y", "z"])
    }

    @Test("A pre-membership whole-list shard still merges as the base")
    func legacyWholeListShardMerges() {
        let (base, defs) = libraryWithDefinitions()
        // An old build wrote only the whole-list register.
        let old = shard("old") { $0.setArticleCategories("a1", ["x", "y"], hlc: Fixture.hlc(1000, node: "old")) }
        // An upgraded device adds z via membership.
        var upgraded = DeviceStateDocument(deviceID: "new")
        assign(&upgraded, article: "a1", from: ["x", "y"], to: ["x", "y", "z"], at: 2000, node: "new")

        let merged = DeviceStateDocument.materialize(base: base, shards: [defs, old, upgraded])
        #expect(merged.articles.first?.categories == ["x", "y", "z"])
    }

    @Test("Deleting a category cleans its dangling assignments on every device")
    func tombstonedDefinitionDropsAssignments() {
        let (base, defs) = libraryWithDefinitions()
        var macShard = DeviceStateDocument(deviceID: "mac")
        assign(&macShard, article: "a1", from: [], to: ["x", "y"], at: 1000, node: "mac")
        // Another device deletes category y without touching the article.
        let deleted = shard("ios") { $0.setCategoryTombstone("y", true, hlc: Fixture.hlc(2000, node: "ios")) }

        let merged = DeviceStateDocument.materialize(base: base, shards: [defs, macShard, deleted])
        #expect(merged.articles.first?.categories == ["x"])
    }

    @Test("Category keyword matching is a plain case-optional substring test")
    func keywordMatching() {
        let apple = ArticleCategory(name: "Apple", keywords: ["WWDC", "iPhone"], keywordMatchTarget: .titleAndSummary)
        #expect(apple.matchesKeywords(title: "Everything at WWDC 2026", summary: ""))
        #expect(apple.matchesKeywords(title: "cheap wwdc tickets", summary: ""))       // case-insensitive by default
        #expect(!apple.matchesKeywords(title: "Android news", summary: "Pixel event"))
        let caseSensitive = ArticleCategory(name: "Apple", keywords: ["WWDC"], keywordCaseSensitive: true)
        #expect(!caseSensitive.matchesKeywords(title: "wwdc lowercase", summary: ""))
    }
}
