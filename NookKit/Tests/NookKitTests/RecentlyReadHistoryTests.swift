import Foundation
import Testing
@testable import NookKit

@Suite("Recently opened stories") @MainActor
struct RecentlyReadHistoryTests {
    @Test("Actual opens persist per library, reopening moves a story, reset interests preserves visits")
    func persistence() throws {
        let suite = "RecentReads.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = RecentlyReadHistory(defaults: defaults)
        let now = Date.now
        history.selectLibrary("one")
        history.record("a", now: now)
        history.record("b", now: now.addingTimeInterval(2))
        history.record("a", now: now.addingTimeInterval(4))
        // Co-presented browser/native surfaces don't count as two opens.
        history.record("a", now: now.addingTimeInterval(4.2))
        #expect(history.opened["a"] == now.addingTimeInterval(4))
        history.record("b", now: now.addingTimeInterval(4.5))
        history.record("a", now: now.addingTimeInterval(4.7))
        #expect(history.opened["a"] == now.addingTimeInterval(4.7))
        history.selectLibrary("two")
        #expect(history.opened.isEmpty)
        MagazineRecommendationController.reset(defaults: defaults)
        let restored = RecentlyReadHistory(defaults: defaults)
        restored.selectLibrary("one")
        #expect(restored.opened.count == 2)
        #expect(restored.opened["a"] == now.addingTimeInterval(4.7))
    }

    @Test("Known visits migrate once; history bounds itself by latest opens")
    func migrationAndBound() throws {
        let suite = "RecentMigration.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let feedback = MagazineRecommendationController(defaults: defaults)
        feedback.selectLibrary("one")
        feedback.recordReading(articleID: "known", seconds: 20)
        let history = RecentlyReadHistory(defaults: defaults)
        history.selectLibrary("one")
        #expect(history.opened["known"] != nil)
        MagazineRecommendationController.reset(defaults: defaults)
        let now = Date.now
        for index in 0..<510 { history.record("\(index)", now: now.addingTimeInterval(Double(index + 1))) }
        #expect(history.opened.count == 500)
        #expect(history.opened["known"] == nil)
        #expect(history.opened["9"] == nil)
        #expect(history.opened["10"] != nil)
    }

    @Test("Recent source follows opens, not publication dates or bulk read flags, and excludes deleted stories")
    func storeIntegration() async throws {
        let suite = "RecentStore.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReaderStore._makeForTesting(historyDefaults: defaults)
        store.feeds = [Fixture.feed("feed")]
        var old = Fixture.article("old", feedID: "feed")
        old.publishedAt = .distantPast
        var bulk = Fixture.article("bulk", feedID: "feed")
        bulk.isRead = true
        let fresh = Fixture.article("fresh", feedID: "feed")
        store.articles = [fresh, bulk, old]
        store.selectSmartSource(.recent)
        #expect(store.visibleArticles.isEmpty)
        // Simulate the reader's actual presentation while auto-read stays off.
        store.recordRecentlyOpened(articleID: fresh.id, now: Date(timeIntervalSince1970: 100))
        store.recordRecentlyOpened(articleID: old.id, now: Date(timeIntervalSince1970: 110))
        #expect(store.visibleArticles.map(\.id) == ["old", "fresh"])
        #expect(store.count(for: .recent) == 2)
        #expect(store.article(withID: old.id)?.isRead == false)
        store.recordRecentlyOpened(articleID: fresh.id, now: Date(timeIntervalSince1970: 120))
        #expect(store.visibleArticles.map(\.id) == ["fresh", "old"])
        store.searchText = "does not exist"
        store.debounceSearch()
        try await Task.sleep(for: .milliseconds(450))
        #expect(store.visibleArticles.isEmpty)
        store.searchText = ""
        store.debounceSearch()
        store.articles.removeAll { $0.id == "fresh" }
        store.selectSmartSource(.recent)
        #expect(store.visibleArticles.map(\.id) == ["old"])
        #expect(store.count(for: .recent) == 1)
        store.selectedArticleID = "bulk"
        #expect(store.recentlyRead.opened["bulk"] == nil)
    }
}
