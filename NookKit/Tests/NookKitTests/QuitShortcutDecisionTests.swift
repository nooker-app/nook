import Foundation
import Testing

@testable import NookKit

/// ⌘Q is next to ⌘W and ends the session outright, taking a composer's unpublished
/// text with it. These pin the rule that made the shortcut ask first.
@Suite("Quit shortcut")
struct QuitShortcutDecisionTests {
    @Test("unsaved writing turns ⌘Q into a press-and-hold")
    func unsavedWorkHolds() {
        let decision = QuitShortcutDecision.forShortcut(hasUnsavedWork: true)
        #expect(decision == .hold)
        #expect(!decision.quitsImmediately, "a single press must not discard writing")
    }

    /// The other half, and the reason this is a rule rather than a flag left on: an app
    /// that always makes quitting a chore is worse than the accident it prevents.
    ///
    /// "Quits at once" is also carried out by the same monitor rather than handed back to
    /// the Quit menu item. That item does not act while a sheet is presented, and the
    /// composer is a sheet, so a fresh one with nothing typed in it swallowed ⌘Q and did
    /// nothing at all — until a single character turned the guard on and the hold path,
    /// which never involved the menu, started working.
    @Test("with nothing at stake ⌘Q still quits at once")
    func nothingAtStakeQuits() {
        let decision = QuitShortcutDecision.forShortcut(hasUnsavedWork: false)
        #expect(decision == .quit)
        #expect(decision.quitsImmediately)
    }
}

/// The claim, not the key handling: what has to hold is that two composers can guard
/// the shortcut at once and the first to close does not clear the other's guard.
@Suite("Unsaved writing registry")
@MainActor
struct UnsavedWritingRegistryTests {
    @Test("a claim released while another is open leaves the guard in place")
    func overlappingClaims() {
        // An instance of its own, not the shared one: these run in parallel with
        // everything else, and a singleton would make the suites' order matter.
        let registry = UnsavedWritingRegistry()
        let reader = UUID()
        let settings = UUID()

        registry.hold(reader)
        registry.hold(settings)
        registry.release(reader)
        #expect(registry.hasUnsavedWork, "the second composer still has writing at stake")

        registry.release(settings)
        #expect(!registry.hasUnsavedWork)
    }
}
