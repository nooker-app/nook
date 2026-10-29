import Foundation
import SwiftUI
import Testing
@testable import NookKit

/// The macOS reader keeps one `ReaderArticleSession` across articles. These pin that
/// nothing one article leaves in it — translation, summary, detected language — is
/// read for the next one, including work that finishes after the switch.
@Suite("Reader per-article session")
@MainActor
struct ReaderArticleSessionTests {
    /// A translation the test releases by hand, so it can finish after the switch.
    private actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        private(set) var calls = 0

        func wait() async {
            calls += 1
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private func settle(_ session: ReaderArticleSession, until done: () -> Bool) async {
        for _ in 0..<200 where !done() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("A plain-body translation that returns after a switch does not land on the next article")
    func latePlainTranslationIsDropped() async {
        let session = ReaderArticleSession()
        session.begin(articleID: "A")
        let gate = Gate()
        session.translatePlainBody(articleID: "A", title: "Title A", paragraphs: ["Body A"]) { text in
            await gate.wait()
            return "translated \(text)"
        }
        #expect(session.isTranslating(for: "A"))

        session.begin(articleID: "B")
        #expect(!session.isTranslating(for: "B"))
        await gate.open()
        // Give A's task every chance to write.
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))

        #expect(session.plainTranslation(for: "B") == nil)
        #expect(!session.hasPlainTranslation(for: "B"))
        #expect(!session.isTranslating(for: "B"))
        #expect(session.plainTranslation(for: "A") == nil)
    }

    @Test("A plain-body translation for the bound article shows, toggles and keeps its title guard")
    func plainTranslationForCurrentArticle() async {
        let session = ReaderArticleSession()
        session.begin(articleID: "A")
        session.translatePlainBody(articleID: "A", title: "Short", paragraphs: ["one", "two"]) { text in
            text == "Short" ? String(repeating: "x", count: 400) : "uno\n\ndos"
        }
        await settle(session) { session.plainTranslation(for: "A") != nil }

        let translation = session.plainTranslation(for: "A")
        #expect(translation?.title == "Short")
        #expect(translation?.paragraphs == ["uno", "dos"])
        #expect(!session.isTranslating(for: "A"))

        session.setPlainTranslationShown(false, for: "A")
        #expect(session.plainTranslation(for: "A") == nil)
        #expect(session.hasPlainTranslation(for: "A"))
        session.setPlainTranslationShown(true, for: "A")
        #expect(session.plainTranslation(for: "A") != nil)
    }

    @Test("A plain-body translation is not started for an article the session is not bound to")
    func plainTranslationNeedsTheBoundArticle() async {
        let session = ReaderArticleSession()
        session.begin(articleID: "A")
        let gate = Gate()
        session.translatePlainBody(articleID: "B", title: "Title", paragraphs: ["Body"]) { text in
            await gate.wait()
            return text
        }
        #expect(!session.isTranslating(for: "A"))
        #expect(!session.isTranslating(for: "B"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await gate.calls == 0)
    }

    @Test("Before the session is bound to the new article, every read for it is empty")
    func readsAreGatedByArticle() async {
        let session = ReaderArticleSession()
        session.begin(articleID: "A")
        session.setDetectedLanguage("fr", for: "A")
        session.setShowingSystemTranslation(true, for: "A")
        session.translatePlainBody(articleID: "A", title: "T", paragraphs: ["P"]) { "t \($0)" }
        await settle(session) { session.plainTranslation(for: "A") != nil }
        await session.summary.load(ArticleSummaryRequest(
            title: "A", markdown: "", style: .concise, provider: .appleIntelligence, outputLanguage: "English"))
        #expect(session.summary(for: "A")?.issue == .noReliableSummary)

        // The new article's first body, before `begin(articleID: "B")` has run.
        #expect(session.translator(for: "B") == nil)
        #expect(session.summary(for: "B") == nil)
        #expect(session.detectedLanguage(for: "B") == nil)
        #expect(!session.isShowingSystemTranslation(for: "B"))
        #expect(session.plainTranslation(for: "B") == nil)
        #expect(!session.isTranslating(for: "B"))

        // Writes for an article that is not bound are ignored.
        session.setDetectedLanguage("de", for: "B")
        session.setShowingSystemTranslation(true, for: "B")
        #expect(session.detectedLanguage(for: "A") == "fr")

        #expect(session.begin(articleID: "B"))
        #expect(session.translator(for: "B") === session.translator)
        #expect(session.detectedLanguage(for: "B") == nil)
        #expect(!session.isShowingSystemTranslation(for: "B"))
        #expect(session.summary(for: "B")?.issue == nil)
        #expect(session.summary(for: "B")?.summary == nil)
        #expect(!session.hasPlainTranslation(for: "B"))
        #expect(!session.translator.isActive)
        #expect(session.translator.translatedTitle == nil)
    }

    @Test("Binding the article already bound keeps its state")
    func rebindingTheSameArticleIsANoOp() {
        let session = ReaderArticleSession()
        #expect(session.begin(articleID: "A"))
        session.setDetectedLanguage("ja", for: "A")
        #expect(!session.begin(articleID: "A"))
        #expect(session.detectedLanguage(for: "A") == "ja")
    }

    /// The reader resets its scroll with `scrollTo(edge: .top)` on every article
    /// change. That only works if each call is a new value, even when the binding
    /// already reads `.top` (an anchor jump moves the view without changing it).
    @Test("Each scrollTo(edge: .top) is a new ScrollPosition value")
    func scrollToTopIsAlwaysAChange() {
        let top = ScrollPosition(edge: .top)
        var again = top
        again.scrollTo(edge: .top)
        #expect(again != top)
    }
}
