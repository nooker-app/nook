import Foundation
import Testing
@testable import NookKit

@Suite("Magazine trend text limits")
struct MagazineTrendTests {
    @Test("Only single-line phrases shorter than 20 characters survive")
    func limits() {
        let values = MagazineTrendText.validated(["  AI 브라우저 경쟁  ", "AI 브라우저 경쟁", "a",
            String(repeating: "가", count: 19), String(repeating: "가", count: 20), "두 줄\n제목", "https://example.com"])
        #expect(values == ["AI 브라우저 경쟁", String(repeating: "가", count: 19)])
    }

    @Test("The rotation is capped at 50, and malformed model output is rejected")
    func capsAndParsing() {
        #expect(MagazineTrendText.validated((0..<90).map { "Topic \($0)" }).count == 50)
        #expect(MagazineTrendText.parse("```json\n[\"로컬 AI 확산\",\"개발 도구의 변화\"]\n```").count == 2)
        #expect(MagazineTrendText.parse("Just a sentence").isEmpty)
        #expect(MagazineTrendText.parse("[1,2,3]").isEmpty)
    }

    @Test("A title correction or language change invalidates the cache")
    func cacheIdentity() {
        let original = MagazineTrendText.fingerprint(titles: ["First"], language: "ko")
        #expect(original != MagazineTrendText.fingerprint(titles: ["Corrected"], language: "ko"))
        #expect(original != MagazineTrendText.fingerprint(titles: ["First"], language: "en"))
    }

    @Test("Every clickable trend resolves to a supplied source, never a fabricated ID")
    func sourceMapping() {
        let articles = [Fixture.article("one", feedID: "f"), Fixture.article("two", feedID: "f")]
        let response = """
        [{"text":"개발 도구의 변화","source":2},{"text":"없는 기사","source":3},
         {"text":"잘못된 번호","source":0},{"text":"개발 도구의 변화","source":1},
         {"text":"로컬 AI 확산","source":1},{"text":"너무 작은 번호","source":-9223372036854775808}]
        """
        let items = MagazineTrendItem.parse(response, articles: articles)
        #expect(items.map(\.articleID) == ["two", "one"])
        #expect(items.map(\.text) == ["개발 도구의 변화", "로컬 AI 확산"])
        #expect(MagazineTrendItem.parse("[\"legacy unlinked text\"]", articles: articles).isEmpty)
    }

    @Test("Cached links to removed or filtered-out articles are discarded")
    @MainActor func staleLinks() async throws {
        let suite = "MagazineTrendTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        struct Cache: Encodable {
            let fingerprint = "old"
            let language = "ko"
            let items = [MagazineTrendItem(text: "남아 있는 글", articleID: "kept"),
                         MagazineTrendItem(text: "삭제한 글", articleID: "deleted")]
            let generatedAt = Date.now
        }
        defaults.set(try JSONEncoder().encode(Cache()), forKey: "magazineTrendCache.v2")
        defaults.set(Date.now, forKey: "magazineTrendLastAttempt.v2")
        let controller = MagazineTrendController(defaults: defaults)
        await controller.refresh(articles: [Fixture.article("kept", feedID: "f")], locale: Locale(identifier: "ko"))
        #expect(controller.items.map(\.articleID) == ["kept"])
        await controller.refresh(articles: [], locale: Locale(identifier: "ko"))
        #expect(controller.items.isEmpty)
    }

    @Test("Rotating phrases keep their own article, including identical text with different sources")
    func displayedDestination() {
        let articles = [Fixture.article("one", feedID: "f"), Fixture.article("two", feedID: "f")]
        let items = [MagazineTrendItem(text: "개발 도구의 변화", articleID: "two"),
                     MagazineTrendItem(text: "로컬 AI 확산", articleID: "one"),
                     MagazineTrendItem(text: "로컬 AI 확산", articleID: "two")]
        for index in 0..<9 {
            #expect(MagazineTrendItem.displayed(items: items, index: index, articles: articles, enabled: true)
                == items[index % items.count])
        }
        #expect(Set(items).count == 3)
    }

    @Test("A stale or disabled trend replaces its phrase and destination together")
    func fallbackDestination() {
        var old = Fixture.article("old", feedID: "f")
        old.publishedAt = Date(timeIntervalSince1970: 100)
        var latest = Fixture.article("latest", feedID: "f")
        latest.publishedAt = Date(timeIntervalSince1970: 200)
        let items = [MagazineTrendItem(text: "삭제된 글의 소식", articleID: "removed")]
        let fallback = MagazineTrendItem.displayed(items: items, index: 10, articles: [latest, old], enabled: true)
        #expect(fallback?.articleID == latest.id)
        #expect(fallback?.text != items[0].text)
        #expect(MagazineTrendItem.displayed(items: [.init(text: "이전 글의 소식", articleID: old.id)],
            index: 0, articles: [latest, old], enabled: false) == fallback)
        #expect(MagazineTrendItem.displayed(items: items, index: 0, articles: [], enabled: true) == nil)
    }
}
