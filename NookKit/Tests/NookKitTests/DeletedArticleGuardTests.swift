import Foundation
import Testing
@testable import NookKit

/// Regression guard for deleted-article resurrection: deletion tombstones are
/// applied by the CRDT materialize, but a refresh merge inserts whatever the
/// feed still serves — so a deleted article whose entry was still in the RSS
/// response used to flap back into the list on every refresh, disappearing
/// again at the next materialize. These tests pin the merge-side guard.
@Suite("Deleted-article resurrection guard")
@MainActor
struct DeletedArticleGuardTests {
    @Test("A refresh merge never re-inserts a locally deleted article")
    func mergeSkipsLocallyDeleted() {
        let store = ReaderStore._makeForTesting()
        let feed = Fixture.feed("f1")
        let article = Fixture.article("f1#a1", feedID: "f1")
        store.feeds = [feed]
        store.articles = [article]

        store.deleteArticle(articleID: article.id)
        #expect(store.articles.isEmpty)

        // The feed's next response still carries the deleted entry — it must
        // not come back.
        store._mergeForTesting(ParsedFeed(feed: feed, articles: [article]))
        #expect(!store.articles.contains { $0.id == article.id },
                "deleted article resurrected by a refresh merge")

        // And it stays gone on every later refresh, not just the first.
        store._mergeForTesting(ParsedFeed(feed: feed, articles: [article]))
        #expect(store.articles.isEmpty)
    }

    @Test("Other articles in the same response still merge normally")
    func mergeKeepsOthers() {
        let store = ReaderStore._makeForTesting()
        let feed = Fixture.feed("f1")
        let deleted = Fixture.article("f1#gone", feedID: "f1")
        let kept = Fixture.article("f1#kept", feedID: "f1")
        store.feeds = [feed]
        store.articles = [deleted]
        store.deleteArticle(articleID: deleted.id)

        store._mergeForTesting(ParsedFeed(feed: feed, articles: [deleted, kept]))

        #expect(store.articles.map(\.id) == [kept.id])
    }

    @Test("Tombstones are collected across own and peer shards")
    func tombstoneCollectionSpansShards() {
        var own = DeviceStateDocument(deviceID: "A")
        own.setArticleTombstone("locally-deleted", true, hlc: Fixture.hlc(10, node: "A"))
        var peer = DeviceStateDocument(deviceID: "B")
        peer.setArticleTombstone("peer-deleted", true, hlc: Fixture.hlc(10, node: "B"))

        let ids = ReaderStore.tombstonedArticleIDs(in: [own, peer])
        #expect(ids == Set(["locally-deleted", "peer-deleted"]))
    }

    @Test("Tombstone collection honors last-writer-wins across shards")
    func tombstoneCollectionHonorsLWW() {
        // If a newer register ever cleared a tombstone, the guard must follow
        // the merged (LWW) verdict — the same one materialize applies.
        var older = DeviceStateDocument(deviceID: "A")
        older.setArticleTombstone("x", true, hlc: Fixture.hlc(10, node: "A"))
        var newer = DeviceStateDocument(deviceID: "B")
        newer.setArticleTombstone("x", false, hlc: Fixture.hlc(20, node: "B"))

        #expect(ReaderStore.tombstonedArticleIDs(in: [older, newer]).isEmpty)
        #expect(ReaderStore.tombstonedArticleIDs(in: [newer, older]).isEmpty)
    }
}
