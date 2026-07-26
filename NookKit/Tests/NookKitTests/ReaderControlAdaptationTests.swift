import Testing
@testable import NookKit

@Suite("Reader control adaptation")
struct ReaderControlAdaptationTests {
    @Test("Four scrolls from the other side switch the layout")
    func switchesAfterStableEvidence() {
        var policy = ReaderControlAdaptationPolicy()

        for _ in 0..<3 {
            let mirrored = policy.record(.left, primaryHand: .right)
            #expect(!mirrored)
        }
        let mirrored = policy.record(.left, primaryHand: .right)
        #expect(mirrored)
    }

    @Test("Mixed sides break the consecutive run")
    func mixedEvidenceDoesNotSwitch() {
        var policy = ReaderControlAdaptationPolicy()

        for side in [
            ReaderControlSide.left, .left, .right, .left, .left, .left,
        ] {
            let mirrored = policy.record(side, primaryHand: .right)
            #expect(!mirrored)
        }
    }

    @Test("Three scrolls from the primary hand restore the configured layout")
    func primaryHandRestoresLayout() {
        var policy = ReaderControlAdaptationPolicy()
        for _ in 0..<4 {
            _ = policy.record(.left, primaryHand: .right)
        }

        let first = policy.record(.right, primaryHand: .right)
        let second = policy.record(.right, primaryHand: .right)
        let third = policy.record(.right, primaryHand: .right)
        #expect(first)
        #expect(second)
        #expect(!third)
    }

    @Test("Primary hand preserves a default layout on the opposite side")
    func handednessIsIndependentFromDefaultControlSide() {
        var policy = ReaderControlAdaptationPolicy()
        let defaultControlSide = ReaderControlSide.left

        for _ in 0..<6 {
            let mirrored = policy.record(.right, primaryHand: .right)
            #expect(!mirrored)
            #expect((mirrored ? defaultControlSide.opposite : defaultControlSide) == .left)
        }
    }
}
