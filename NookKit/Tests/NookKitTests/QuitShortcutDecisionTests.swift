import Foundation
import Testing

@testable import NookKit

/// ⌘Q is next to ⌘W and ends the session outright, taking a composer's unpublished text
/// with it. These pin the rule that made the shortcut ask first.
@Suite("Quit shortcut")
struct QuitShortcutDecisionTests {
    @Test("an open writing surface turns ⌘Q into a press-and-hold")
    func writingHolds() {
        let decision = QuitShortcutDecision.forShortcut(whileWriting: true)
        #expect(decision == .hold)
        #expect(!decision.quitsImmediately, "a single press must not discard writing")
    }

    /// The other half, and the reason this is a rule rather than a flag left on: an app
    /// that always makes quitting a chore is worse than the accident it prevents.
    ///
    /// "Quits at once" is also carried out by the monitor rather than handed to the Quit
    /// menu item, and it closes any sheet on the way — an attached sheet refuses
    /// termination outright, which is why ⌘Q in the composer used to do nothing at all.
    @Test("with no writing open ⌘Q quits at once")
    func nothingOpenQuits() {
        let decision = QuitShortcutDecision.forShortcut(whileWriting: false)
        #expect(decision == .quit)
        #expect(decision.quitsImmediately)
    }

    /// The condition is the screen, not its contents. Keyed to unsaved text instead, the
    /// same keypress in what looks like the same screen did two different things — quit
    /// outright on a composer nothing had been typed into, ask on one that had — and which
    /// of those happened depended on state nobody can see.
    @Test("the hold does not wait for something to be typed")
    func openIsEnough() {
        #expect(QuitShortcutDecision.forShortcut(whileWriting: true) == .hold)
    }
}

/// The claim, not the key handling: what has to hold is that two composers can guard
/// the shortcut at once and the first to close does not clear the other's guard.
@Suite("Writing surface registry")
@MainActor
struct WritingSurfaceRegistryTests {
    @Test("a claim released while another is open leaves the guard in place")
    func overlappingClaims() {
        // An instance of its own, not the shared one: these run in parallel with
        // everything else, and a singleton would make the suites' order matter.
        let registry = WritingSurfaceRegistry()
        let reader = UUID()
        let settings = UUID()

        registry.hold(reader)
        registry.hold(settings)
        registry.release(reader)
        #expect(registry.isWriting, "the second composer is still open")

        registry.release(settings)
        #expect(!registry.isWriting)
    }
}
