import Foundation
import Testing
@testable import NookKit

/// The macOS reader shows the settled selection: immediate for a lone change,
/// held while the selection key-repeats.
@Suite("Reader selection settler", .serialized) @MainActor
struct ReaderSelectionSettlerTests {
    final class Clock {
        var now = ContinuousClock.now
        func advance(_ duration: Duration) { now = now.advanced(by: duration) }
    }

    @Test("A lone selection reaches the reader at once; a repeat lands only where it stops")
    func readerSettles() async throws {
        let clock = Clock()
        let settler = ReaderSelectionSettler(settle: .milliseconds(40), now: { clock.now })
        settler.selectionChanged(to: "a")
        #expect(settler.settledID == "a")
        clock.advance(.milliseconds(500))
        settler.selectionChanged(to: "b")
        #expect(settler.settledID == "b", "a click after a pause is immediate")
        for id in ["c", "d", "e"] {
            clock.advance(.milliseconds(30))
            settler.selectionChanged(to: id)
            #expect(settler.settledID == "b", "a key repeat is held")
        }
        for _ in 0..<100 where settler.settledID != "e" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(settler.settledID == "e")
        clock.advance(.milliseconds(10))
        settler.selectionChanged(to: "f")
        settler.selectionChanged(to: nil)
        #expect(settler.settledID == nil, "clearing is never held")
        try await Task.sleep(for: .milliseconds(80))
        #expect(settler.settledID == nil, "the cancelled hold does not land afterwards")
    }

    @Test("Reader navigation passes through a hold so it lands in the caller's transaction")
    func navigationPassesThrough() {
        let clock = Clock()
        let settler = ReaderSelectionSettler(settle: .milliseconds(40), now: { clock.now })
        settler.selectionChanged(to: "a")
        clock.advance(.milliseconds(10))
        settler.passingThrough { settler.selectionChanged(to: "b") }
        #expect(settler.settledID == "b", "a quick second next/previous is not held")
        clock.advance(.milliseconds(10))
        settler.selectionChanged(to: "c")
        #expect(settler.settledID == "b", "list repeats are still held afterwards")
    }

    #if os(macOS)
    @Test("The store's reader article follows the selection through the settler")
    func storeReaderArticle() {
        let store = ReaderStore._makeForTesting()
        store.articles = (0..<3).map { Fixture.article("row-\($0)", feedID: "a") }
        store.selectedArticleID = "row-1"
        #expect(store.readerArticle?.id == "row-1")
        store.selectedArticleID = nil
        #expect(store.readerArticle == nil)
    }
    #endif
}
