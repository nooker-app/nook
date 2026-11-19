import Foundation
import Testing
@testable import NookKit

@Suite("Offline Magazine recommendations")
struct MagazineRecommendationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Explicit skips change ranking immediately without hiding the article from the library")
    func skipRanking() async throws {
        let first = article("first", title: "Swift architecture")
        let second = article("second", title: "A different story", age: 60)
        var history = MagazineReadingHistory()
        history.dismiss(first.id, now: now)
        let ranker = MagazineRecommendationRanker()
        #expect(await ranker.rank(candidates: [first, second], library: [], history: history,
                                 now: now, useSemantics: false)?.articleID == second.id)
        history.dismiss(second.id, now: now)
        #expect(await ranker.rank(candidates: [first, second], library: [], history: history,
                                 now: now, useSemantics: false) == nil)
        #expect(!history.isDismissed(first.id, now: now.addingTimeInterval(31 * 86400)))
        let legacy = try JSONDecoder().decode(MagazineReadingHistory.self, from: Data(#"{"entries":{}}"#.utf8))
        #expect(!legacy.isDismissed(first.id, now: now))
    }

    @Test("Skip persists with personalization off and undo restores the previous ranking within its library")
    @MainActor func skipUndo() async throws {
        let defaults = try #require(UserDefaults(suiteName: "RecommendationUndo.\(UUID())"))
        let controller = MagazineRecommendationController(defaults: defaults)
        defer { MagazineRecommendationController.reset(defaults: defaults) }
        controller.selectLibrary("one")
        let first = article("first", title: "First")
        let second = article("second", title: "Second", age: 60)
        let undo = controller.dismissRecommendation(first.id)
        #expect(await controller.recommend(candidates: [first, second], library: [], personalized: false)?.articleID == second.id)
        let restored = MagazineRecommendationController(defaults: defaults)
        restored.selectLibrary("one")
        #expect(await restored.recommend(candidates: [first, second], library: [], personalized: false)?.articleID == second.id)
        controller.selectLibrary("two")
        #expect(!controller.undoDismissal(undo))
        controller.selectLibrary("one")
        #expect(controller.undoDismissal(undo))
        #expect(await controller.recommend(candidates: [first, second], library: [], personalized: false)?.articleID == first.id)
    }

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

    @Test("All unread ages and pages participate; a year-old match beats 700 newer stories")
    func entireUnreadLibrary() async {
        var reference = article("reference", title: "Swift native macOS architecture", feed: "swift")
        reference.isStarred = true
        reference.isRead = true
        let old = article("old", title: reference.title, feed: "swift", age: 365 * 86400)
        let fresh = (0..<700).map {
            article("fresh-\($0)", title: "Football stadium league results", feed: "sports", age: Double($0))
        }
        let candidates = fresh + [old, reference]
        let ranked = await MagazineRecommendationRanker().ranked(candidates: candidates, library: candidates,
            history: .init(), now: now, useSemantics: false)
        #expect(ranked.count == 701)
        #expect(ranked.first?.articleID == old.id)
        #expect(Set(ranked.map(\.articleID)) == Set((fresh + [old]).map(\.id)))
    }

    @Test("Choosing a recommendation immediately teaches interests without reading time; repeats don't inflate weight")
    func explicitChoices() async throws {
        let reference = article("reference", title: "Swift native macOS architecture", feed: "swift")
        let match = article("match", title: reference.title, feed: "swift", age: 86400)
        let fresh = article("fresh", title: "Football stadium league results", feed: "sports")
        let ranker = MagazineRecommendationRanker()
        var history = try JSONDecoder().decode(MagazineReadingHistory.self, from: Data(#"{"entries":{}}"#.utf8))
        #expect(await ranker.rank(candidates: [match, fresh], library: [reference], history: history,
                                 now: now, useSemantics: false)?.articleID == fresh.id)
        for _ in 0..<20 { history.select(reference.id, now: now) }
        #expect(history.weight(for: reference, now: now) == 0.75)
        #expect(history.entries.isEmpty)
        #expect(await ranker.rank(candidates: [match, fresh], library: [reference], history: history,
                                 now: now, useSemantics: false)?.articleID == match.id)
        let restored = try JSONDecoder().decode(MagazineReadingHistory.self, from: JSONEncoder().encode(history))
        #expect(restored.selections?[reference.id] == now)
    }

    @Test("Recommendation list persists choices and respects personalization, dismissals, and unread membership")
    @MainActor func listController() async throws {
        let suite = "RecommendationList.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var reference = article("reference", title: "Swift native macOS architecture", feed: "swift")
        reference.isRead = true
        let match = article("match", title: reference.title, feed: "swift", age: 100)
        let fresh = article("fresh", title: "Football stadium league results", feed: "sports")
        let candidates = [reference, match, fresh]
        let writer = MagazineRecommendationController(defaults: defaults)
        writer.selectLibrary("one")
        writer.recordSelection(articleID: reference.id)
        let reader = MagazineRecommendationController(defaults: defaults)
        reader.selectLibrary("one")
        #expect(await reader.rankedRecommendations(candidates: candidates, library: candidates,
                                                   personalized: true).first?.articleID == match.id)
        #expect(await reader.rankedRecommendations(candidates: candidates, library: candidates,
                                                   personalized: false).map(\.articleID) == [fresh.id, match.id])
        _ = reader.dismissRecommendation(match.id)
        #expect(await reader.rankedRecommendations(candidates: candidates, library: candidates,
                                                   personalized: true).map(\.articleID) == [fresh.id])
        #expect(await reader.rankedRecommendations(candidates: [reference], library: candidates,
                                                   personalized: true).isEmpty)
    }

    @Test("A large library ranks off the main actor without excluding candidates")
    func largeLibrary() async {
        let articles = (0..<6000).map {
            article("\($0)", title: "Topic \($0 % 40) Swift architecture research update \($0)",
                    feed: "feed-\($0 % 20)", age: Double($0 * 60))
        }
        var history = MagazineReadingHistory()
        for article in articles.suffix(100) { history.record(article.id, seconds: 30, now: now) }
        let start = ContinuousClock.now
        let result = await MagazineRecommendationRanker().ranked(candidates: articles, library: articles,
            history: history, now: now, useSemantics: false)
        print("Magazine rank, 6000 articles: \(start.duration(to: .now))")
        #expect(result.count == 6000)
        let semanticStart = ContinuousClock.now
        let semanticResult = await MagazineRecommendationRanker().rank(candidates: articles, library: articles,
            history: history, now: now)
        print("Magazine rank with available native embeddings, 6000 articles: \(semanticStart.duration(to: .now))")
        #expect(semanticResult != nil)
    }
}
