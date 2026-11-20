#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import NookKit

@Suite("Shared article search")
struct ArticleSearchTests {
    private func article(_ id: String, _ title: String, body: String = "") -> Article {
        var article = Fixture.article(id, feedID: "feed")
        article.title = title; article.summary = ""; article.bodyParagraphs = [body]
        return article
    }

    @Test("Natural phrases drop request words and search bodies without an exact sentence")
    func lexicalMeaning() {
        let rows = [article("voyager", "먼 우주에서 온 신호", body: "탐사선의 전력을 아끼고 통신을 유지한다"),
                    article("bread", "Sourdough", body: "Baking bread in a kitchen")]
        let scores = ArticleSearchRanking.lexical(query: "탐사선 전력 관련 글 찾아줘", articles: rows, feedTitles: [:])
        #expect(scores["voyager"] != nil)
        #expect(scores["bread"] == nil)
        #expect(!ArticleSearchRanking.terms("탐사선에 관한 글 보여주세요").contains("보여주세요"))
    }

    @Test("Cross-language semantic matches join keyword results and exact titles remain first")
    func hybridRanking() {
        let rows = [article("exact", "Voyager 1"), article("meaning", "오래된 탐사선의 통신"), article("unrelated", "Baking bread")]
        let lexical = ArticleSearchRanking.lexical(query: "Voyager", articles: rows, feedTitles: [:])
        let ranked = ArticleSearchRanking.rank(query: "Voyager", articles: rows, lexical: lexical,
                                              semantic: ["exact": 0.75, "meaning": 0.79, "unrelated": 0.21])
        #expect(ranked == ["exact", "meaning"])
        let natural = ArticleSearchRanking.rank(query: "spacecraft communications", articles: rows, lexical: [:],
                                               semantic: ["meaning": 0.78, "unrelated": 0.2])
        #expect(natural == ["meaning"])
    }

    @Test("Stale content, incompatible vectors and invalid numbers never enter semantic search")
    func validVectors() {
        let rows = [article("good", "Good"), article("stale", "Changed"), article("other", "Other"), article("invalid", "Invalid")]
        let model = RecommendationNativeModels.embeddingID
        let vectors: [String: RecommendationVector] = [
            "good": .init(model: model, values: [1, 0], fingerprint: RecommendationGraphEngine.hash(RecommendationContentText.embeddingInput(rows[0]))),
            "stale": .init(model: model, values: [1, 0], fingerprint: "old"),
            "other": .init(model: "different", values: [1, 0]),
            "invalid": .init(model: model, values: [.nan, 0])
        ]
        #expect(ArticleSearchRanking.similarities(query: [1, 0], articles: rows, vectors: vectors) == ["good": 1])
        #expect(ArticleSearchRanking.similarities(query: [.nan, 0], articles: rows, vectors: vectors).isEmpty)
    }

    @Test("Keyboard selection stays on its story across reranking and safely clamps at either end")
    func keyboardSelection() {
        var selection = ArticleSearchSelection()
        selection.reconcile(["a", "b", "c"])
        selection.move(1, in: ["a", "b", "c"])
        #expect(selection.id == "b")
        selection.reconcile(["c", "a", "b"])
        #expect(selection.id == "b")
        selection.move(1, in: ["c", "a", "b"])
        #expect(selection.id == "b")
        selection.move(-1, in: ["c", "a", "b"])
        #expect(selection.id == "a")
        selection.reconcile([])
        selection.move(-1, in: [])
        #expect(selection.id == nil)
    }

    @Test("Search respects the selected source and clearing cancels pending results")
    @MainActor func sourceScopeAndCancellation() async throws {
        let store = ReaderStore._makeForTesting()
        var unread = article("unread", "Battery telemetry")
        unread.isRead = false
        var read = article("read", "Battery telemetry")
        read.isRead = true
        store.articles = [unread, read, article("other", "Baking bread")]
        store.selectSmartSource(.unread)
        store.searchText = "battery telemetry articles"
        store.debounceSearch()
        for _ in 0..<100 where store.activeSearchQuery.isEmpty || store.isSearching || store.visibleArticles.count != 1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.visibleArticles.map(\.id) == ["unread"])
        store.searchText = "different query"
        store.debounceSearch()
        store.searchText = ""
        store.debounceSearch()
        try await Task.sleep(for: .milliseconds(400))
        #expect(store.activeSearchQuery.isEmpty)
        #expect(!store.isSearching)
        #expect(store.visibleArticles.count == 2)
    }

    @Test("Field commands leave marked Korean text to the input method")
    @MainActor func inputMethodCommands() {
        var moved = 0
        let field = ArticleSearchField(text: .constant("한글"), move: { moved += $0; return true }, submit: { true }, escape: { true })
        let delegate = field.makeCoordinator()
        let editor = NSTextView()
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!delegate.control(NSTextField(), textView: editor, doCommandBy: NSSelectorFromString("moveDown:")))
        #expect(moved == 0)
        editor.unmarkText()
        #expect(delegate.control(NSTextField(), textView: editor, doCommandBy: NSSelectorFromString("moveDown:")))
        #expect(moved == 1)
    }
}
#endif
