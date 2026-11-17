import Foundation
import Testing
@testable import NookKit

/// Same structure as hello-nook: nine TOC targets and six footnote round trips.
/// The fixture is authored here; it does not copy the published article's prose.
enum PublishedPostAnchorFixture {
    static let headings = (1...9).map { "hello-nook-목차-\($0)" }

    static var body: String {
        let toc = headings.map { id in
            let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
            return "<li><a href=\"#\(encoded)\">\(id)</a></li>"
        }.joined()
        let sections = headings.enumerated().map { index, id in
            let note = index < 6
                ? "<sup id=\"hello-nook-fnref:\(index + 1)\"><a href=\"#hello-nook-fn:\(index + 1)\">\(index + 1)</a></sup>"
                : ""
            let prose = String(repeating: "이 문단은 네이티브 리더에서 목차와 각주를 확인하기 위한 본문입니다. ", count: 8)
            return "<h2 id=\"\(id)\">Section \(index + 1)</h2><p>\(prose)\(note)</p>"
        }.joined()
        let notes = (1...6).map { index in
            "<li id=\"hello-nook-fn:\(index)\"><p>Note \(index). <a href=\"#hello-nook-fnref:\(index)\">↩︎</a></p></li>"
        }.joined()
        return "<ul class=\"toc\">\(toc)</ul>\(sections)<div class=\"footnotes\"><ol>\(notes)</ol></div>"
    }

    static var damagedBody: String {
        body.replacingOccurrences(of: #" id="[^"]*""#, with: "", options: .regularExpression)
    }

    static func article(id: String = "feed#at://did:plc:writer/app.nooker.article/post", html: String? = body) -> Article {
        Article(
            id: id, feedID: "feed", title: "Published post", summary: "",
            bodyParagraphs: [], publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            url: URL(string: "https://publication.example/post")!, estimatedReadMinutes: 1,
            isRead: false, isStarred: false, contentHTML: html)
    }
}

@Suite("Published post anchor recovery")
struct NookPostAnchorRepairTests {
    @Test("only a Nook post with lost targets and a complete feed body is repaired")
    func selectsOnlyDamagedNookBodies() {
        let fixture = PublishedPostAnchorFixture.self
        #expect(NookPostAnchorRepair.source(for: fixture.article(), cachedHTML: fixture.damagedBody) != nil)
        #expect(NookPostAnchorRepair.source(for: fixture.article(), cachedHTML: fixture.body) == nil)
        #expect(NookPostAnchorRepair.source(for: fixture.article(id: "feed#ordinary"), cachedHTML: fixture.damagedBody) == nil)
        #expect(NookPostAnchorRepair.source(for: fixture.article(html: nil), cachedHTML: fixture.damagedBody) == nil)
        #expect(NookPostAnchorRepair.source(for: fixture.article(html: fixture.damagedBody), cachedHTML: fixture.damagedBody) == nil)
        #expect(NookPostAnchorRepair.source(for: fixture.article(), cachedHTML: "<p>Saved prose.</p>") == nil)
    }

    @Test("a failed, incomplete, or fallback repair never replaces the saved body")
    @MainActor
    func failedRepairKeepsSavedCopy() async {
        let fixture = PublishedPostAnchorFixture.self
        let outcomes: [ReaderModeExtractor.Outcome?] = [
            nil, .failed, .timedOut,
            .success(.init(html: "<p>All navigation disappeared.</p>", engine: .legibility)),
            .success(.init(html: fixture.damagedBody, engine: .legibility)),
            .success(.init(html: fixture.body, engine: .readability, fellBack: true)),
        ]
        for outcome in outcomes {
            let repaired = await NookPostAnchorRepair.repair(fixture.damagedBody, for: fixture.article()) { _ in outcome }
            #expect(repaired == nil)
        }
    }

    @Test("both bundled parsers restore every target with no page fetch", arguments: ReaderParserEngine.allCases)
    @MainActor
    func bundledParserRepairsSavedPost(engine: ReaderParserEngine) async throws {
        let fixture = PublishedPostAnchorFixture.self
        let article = fixture.article()
        let extractor = ReaderModeExtractor()
        let result = await NookPostAnchorRepair.repair(fixture.damagedBody, for: article) { source in
            await extractor.extractCachedDocument(source, url: article.url, engine: engine)
        }
        let repaired = try #require(result)
        let original = NookPostAnchorRepair.navigation(in: fixture.body)
        let restored = NookPostAnchorRepair.navigation(in: repaired)
        #expect(original.links.count == 21)
        #expect(restored.links.count == 21)
        #expect(restored.anchors.count == 21)
        #expect(restored.isComplete)
        for (old, new) in zip(original.links, restored.links) {
            // Includes the list item, so all six notes cannot silently land on
            // note one; reverse references must return to the right paragraph.
            #expect(anchorTarget(for: old, in: original.anchors) == anchorTarget(for: new, in: restored.anchors))
        }
        #expect(repaired.contains("<sup"))
        var extractedAgain = false
        let second = await NookPostAnchorRepair.repair(repaired, for: article) { _ in
            extractedAgain = true
            return nil
        }
        #expect(second == nil)
        #expect(!extractedAgain, "a repaired body must remain a cache hit on every subsequent open")
    }
}
