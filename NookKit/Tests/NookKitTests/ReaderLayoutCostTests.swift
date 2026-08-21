#if os(macOS)
import AppKit
import SwiftUI
import Testing

@testable import NookKit

/// What the reader costs to lay out, and whether it knows how tall it is.
///
/// Both of these were reader complaints before they were tests. The reader's log
/// showed its content height walking 7010 → 7917 → 7184 → 7334 → 8095 during a
/// single scroll, which is a lazy stack revising an estimate as rows come into
/// view — the article sliding under a stationary scrollbar. And it showed 635ms of
/// main thread going into presenting a commented article with only 26ms of that
/// being work this code counted, which was the comment rows being measured several
/// times each.
@Suite("Reader layout cost", .serialized)
@MainActor
struct ReaderLayoutCostTests {
    static func measure<V: View>(_ view: V) -> (ms: Double, height: Double) {
        let host = NSHostingView(rootView: view.frame(width: 614, alignment: .leading))
        let clock = ContinuousClock()
        let start = clock.now
        let fitted = host.fittingSize
        host.frame = NSRect(x: 0, y: 0, width: 614, height: fitted.height)
        host.layoutSubtreeIfNeeded()
        let elapsed = start.duration(to: clock.now)
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        return (ms, fitted.height)
    }

    static let article: String = {
        var out = "<h1>An article title of ordinary length</h1>"
        var index = 0
        while out.utf8.count < 40_000 {
            index += 1
            out += "<p>Paragraph \(index). "
                + String(repeating: "A sentence of ordinary length with a few clauses in it. ", count: 4)
                + "<em>emphasis</em>.</p>"
            if index.isMultiple(of: 7) { out += "<h2>A subheading</h2>" }
        }
        return out
    }()

    /// The reader must know its own height before anything scrolls.
    ///
    /// Asserted as a comparison rather than a number, because the number is the
    /// article's and would have to be rewritten with any typography change. What
    /// matters is the direction: a lazy stack answers with an estimate that is short
    /// of the truth, so if the default ever goes back to lazy, this fails.
    @Test("the article reports its full height, not an estimate")
    func heightIsNotAnEstimate() {
        let eager = Self.measure(HTMLContentView(html: Self.article, baseURL: nil))
        let lazy = Self.measure(
            HTMLContentView(html: Self.article, baseURL: nil, defersOffscreenBlocks: true))
        // A lazy stack under-reports by 22-26%, so these being equal means the default
        // went back to lazy.
        let note = "eager \(Int(eager.height))pt vs lazy \(Int(lazy.height))pt"
        #expect(eager.height > lazy.height * 1.1, Comment(rawValue: note))
    }

    /// The comment thread's own layout, which lands on the frame that presents the
    /// article.
    ///
    /// The bound is loose: eight long comments measured 47ms with the row measured
    /// once and 127ms with it measured several times, so this catches a regression of
    /// that shape without becoming a machine-speed test.
    @Test("a comment thread lays out in bounded time")
    func commentThreadIsBounded() {
        _ = Self.measure(Text("first hosting view in the process"))
        let thread = ReaderCommentThread(
            items: (0..<8).map { index in
                let body = (0..<6).map { paragraph in
                    "<p>Paragraph \(paragraph) of comment \(index). "
                        + String(repeating: "An ordinary sentence with a few clauses. ", count: 3)
                        + "<a href=\"https://example.com\">a link</a>.</p>"
                }.joined()
                return ReaderComment(
                    id: index, author: "commenter\(index)", depth: index % 4,
                    parent: index % 4 == 0 ? nil : index - 1, text: "plain", html: body)
            },
            count: 8, depthSource: "Nested")
        let drawn = Self.measure(ReaderCommentsSection(thread: thread))
        #expect(drawn.ms < 400, "eight comments took \(Int(drawn.ms))ms")
    }
}
#endif
