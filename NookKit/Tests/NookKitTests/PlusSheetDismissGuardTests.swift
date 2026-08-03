import Testing

@testable import NookKit

/// A swipe used to close the composer outright, taking unsaved writing with it —
/// while the Cancel button two centimetres away asked what to do with it. These
/// pin the rule that closed that gap.
@Suite("Sheet dismissal")
struct PlusSheetDismissGuardTests {
    @Test("unsaved work turns a swipe into a question")
    func unsavedWorkAsks() {
        let decision = SheetDismissDecision.forSwipe(hasUnsavedWork: true)
        #expect(decision == .ask)
        #expect(!decision.allowsDismissal, "a swipe must not discard unsaved writing")
    }

    /// The other half, and the reason this is a rule rather than a flag left on: a
    /// sheet that always refuses the gesture is a sheet a reader cannot put down.
    @Test("a sheet with nothing at stake still closes on a swipe")
    func nothingAtStakeCloses() {
        let decision = SheetDismissDecision.forSwipe(hasUnsavedWork: false)
        #expect(decision == .dismiss)
        #expect(decision.allowsDismissal)
    }
}
