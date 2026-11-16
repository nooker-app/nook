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
}
