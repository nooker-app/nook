import Foundation
import Testing
@testable import NookKit

@Suite("Offline Magazine recommendations")
struct MagazineRecommendationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func article(_ id: String, title: String, feed: String = "feed", age: Double = 0) -> Article {
        var article = Fixture.article(id, feedID: feed)
        article.title = title
        article.summary = title
        article.publishedAt = now.addingTimeInterval(-age)
        return article
    }

    @Test("Cold start uses freshness, prefers unread, and is deterministic")
    func coldStart() async {
        let ranker = MagazineRecommendationRanker()
        let old = article("old", title: "Old", age: 86400)
        let fresh = article("new", title: "New")
        var read = article("read", title: "Already read", age: -60)
        read.isRead = true
        let result = await ranker.rank(candidates: [old, read, fresh], library: [old, read, fresh],
                                       history: .init(), now: now, useSemantics: false)
        #expect(result?.articleID == fresh.id)
        #expect(result?.personalized == false)
        #expect(await ranker.rank(candidates: [], library: [read], history: .init(), now: now) == nil)
    }

    @Test("Reading time promotes a relevant story above the first/newest article")
    func personalInterest() async {
        let ranker = MagazineRecommendationRanker()
        let reference = article("reference", title: "Swift native macOS application development", feed: "swift", age: 86400)
        let unrelated = article("first", title: "Football stadium league results", feed: "sports")
        let match = article("second", title: "Swift native macOS development performance", feed: "swift", age: 3600)
        var history = MagazineReadingHistory()
        for _ in 0..<6 { history.record(reference.id, seconds: 10, now: now) }
        let result = await ranker.rank(candidates: [unrelated, match], library: [reference, unrelated, match],
                                       history: history, now: now, useSemantics: false)
        #expect(result?.articleID == match.id)
        #expect(result?.personalized == true)
    }

    @Test("Stars are evidence, bulk read flags and quick glances are not")
    func deliberateFeedback() async {
        let ranker = MagazineRecommendationRanker()
        var reference = article("reference", title: "한국어 글쓰기 독서 이야기", feed: "books")
        reference.isRead = true
        let unrelated = article("first", title: "축구 경기 결과", feed: "sports")
        let match = article("second", title: "한국어 글쓰기 독서 습관", feed: "books", age: 600)
        var history = MagazineReadingHistory()
        history.record(reference.id, seconds: 3, now: now)
        let initial = await ranker.rank(candidates: [unrelated, match], library: [reference],
                                        history: history, now: now, useSemantics: false)
        #expect(initial?.articleID == unrelated.id)
        #expect(initial?.personalized == false)
        reference.isStarred = true
        let starred = await ranker.rank(candidates: [unrelated, match], library: [reference],
                                        history: history, now: now, useSemantics: false)
        #expect(starred?.articleID == match.id)
    }

    @Test("Ranking respects filter scope even when an excluded article is a perfect match")
    func scope() async {
        var favorite = article("favorite", title: "Swift macOS", feed: "swift")
        favorite.isStarred = true
        let allowed = article("allowed", title: "Garden", feed: "garden")
        let result = await MagazineRecommendationRanker().rank(candidates: [allowed], library: [favorite, allowed],
            history: .init(), now: now, useSemantics: false)
        #expect(result?.articleID == allowed.id)
    }

    @Test("Reading feedback is bounded, decays, expires and round-trips")
    func boundedHistory() throws {
        var history = MagazineReadingHistory()
        history.record("old", seconds: 30, now: now.addingTimeInterval(-91 * 86400))
        for index in 0..<510 { history.record(String(index), seconds: 20, now: now.addingTimeInterval(Double(index))) }
        #expect(history.entries.count == 500)
        #expect(history.entries["old"] == nil)
        let latest = now.addingTimeInterval(1000)
        for _ in 0..<100 { history.record("heavy", seconds: 1000, now: latest) }
        #expect(history.entries["heavy"]?.seconds == 600)
        history.record("invalid", seconds: .nan, now: latest)
        #expect(history.entries["invalid"] == nil)
        let restored = try JSONDecoder().decode(MagazineReadingHistory.self, from: JSONEncoder().encode(history))
        #expect(restored.entries["heavy"]?.seconds == 600)
        let heavy = article("heavy", title: "Reading")
        #expect(restored.weight(for: heavy, now: latest.addingTimeInterval(60 * 86400)) < restored.weight(for: heavy, now: latest))
    }

    @Test("Local profiles persist and remain isolated between libraries; reset keeps other preferences")
    @MainActor func persistence() async throws {
        let suite = "MagazineRecommendationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("keep", forKey: "otherPreference")
        let reference = article("reference", title: "Swift native macOS", feed: "swift")
        let match = article("match", title: "Swift native macOS architecture", feed: "swift", age: 3600)
        let first = article("first", title: "Football results", feed: "sports")
        let writer = MagazineRecommendationController(defaults: defaults)
        writer.selectLibrary("one")
        for _ in 0..<6 { writer.recordReading(articleID: reference.id, seconds: 10) }
        let reader = MagazineRecommendationController(defaults: defaults)
        reader.selectLibrary("one")
        #expect(await reader.recommend(candidates: [first, match], library: [reference], personalized: true)?.personalized == true)
        reader.selectLibrary("two")
        #expect(await reader.recommend(candidates: [first, match], library: [reference], personalized: true)?.personalized == false)
        reader.selectLibrary("one")
        MagazineRecommendationController.reset(defaults: defaults)
        reader.reloadAfterReset()
        #expect(await reader.recommend(candidates: [first, match], library: [reference], personalized: true)?.personalized == false)
        #expect(defaults.string(forKey: "otherPreference") == "keep")
        #expect(defaults.integer(forKey: MagazineRecommendationController.resetKey) == 1)
    }

    @Test("A large library ranks off the main actor with a bounded candidate pool")
    func largeLibrary() async {
        let articles = (0..<6000).map {
            article("\($0)", title: "Topic \($0 % 40) Swift architecture research update \($0)",
                    feed: "feed-\($0 % 20)", age: Double($0 * 60))
        }
        var history = MagazineReadingHistory()
        for article in articles.suffix(100) { history.record(article.id, seconds: 30, now: now) }
        let start = ContinuousClock.now
        let result = await MagazineRecommendationRanker().rank(candidates: articles, library: articles,
            history: history, now: now, useSemantics: false)
        print("Magazine rank, 6000 articles: \(start.duration(to: .now))")
        #expect(result != nil)
        let semanticStart = ContinuousClock.now
        let semanticResult = await MagazineRecommendationRanker().rank(candidates: articles, library: articles,
            history: history, now: now)
        print("Magazine rank with available native embeddings, 6000 articles: \(semanticStart.duration(to: .now))")
        #expect(semanticResult != nil)
    }
}
