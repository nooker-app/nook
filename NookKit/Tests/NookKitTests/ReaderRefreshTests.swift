import Testing

@testable import NookKit

/// The reader's Refresh.
///
/// Most of what this action does — bypassing WebKit's HTTP cache, loading the page in
/// an offscreen web view, keeping the old body on screen while the new one arrives —
/// needs a network and a web view to observe, and the extraction path is covered by
/// `ReaderParserEngineTests`. What is deterministic, and what the reader's only
/// feedback depends on, is that the two kinds of wait can be told apart.
@Suite("Reader refresh")
struct ReaderRefreshTests {
    /// The banner is the whole feedback for either wait, so it has to say which one it
    /// is: a parser switch names the parser it is waiting for, and a refresh must not,
    /// because the parser is exactly what is *not* changing.
    @Test("the two reparse reasons are distinguishable")
    func reparseReasonsAreDistinct() {
        #expect(ReaderStore.ReaderReparse.refresh != .parser(.legibility))
        #expect(ReaderStore.ReaderReparse.parser(.legibility) != .parser(.readability))
        #expect(ReaderStore.ReaderReparse.parser(.legibility) == .parser(.legibility))
    }
}
