import Testing
@testable import NookKit

@Suite("Magazine gesture intent")
struct MagazineGestureTests {
    @Test("Crossing the threshold arms but only release navigates, once")
    func releaseCommitsOnce() {
        var state = MagazineGestureState()
        let crossing = state.update(phase: .began, dy: -240, atBottom: true)
        #expect(crossing.action == nil)
        #expect(state.presentation.isArmed)
        #expect(state.update(phase: .ended).action == .next)
        #expect(state.update(phase: .ended).action == nil)
        #expect(state.presentation.edge == nil)
    }

    @Test("Retreating below the threshold cancels the armed action")
    func reversalCancels() {
        var state = MagazineGestureState()
        _ = state.update(phase: .began, dy: -250, atBottom: true)
        _ = state.update(phase: .changed, dy: 80, atBottom: true)
        #expect(!state.presentation.isArmed)
        #expect(state.update(phase: .ended).action == nil)
    }

    @Test("System cancellation never commits even when the indicator is full")
    func cancellation() {
        var state = MagazineGestureState()
        _ = state.update(phase: .began, dx: 220)
        #expect(state.presentation.action == .close)
        #expect(state.update(phase: .cancelled).action == nil)
    }

    @Test("Momentum cannot fill or commit; a fresh gesture resets suppression")
    func momentum() {
        var state = MagazineGestureState()
        _ = state.update(phase: .began, dy: -40, atBottom: true)
        _ = state.update(phase: .momentum, dy: -900, atBottom: true)
        #expect(!state.presentation.isArmed)
        #expect(state.update(phase: .ended).action == nil)
        #expect(state.update(phase: .momentum, dy: -900).consumed)
        #expect(!state.update(phase: .began, dy: -30, atBottom: false).consumed)
    }

    @Test("Reaching the edge during one continuous drag starts filling there")
    func continuousScroll() {
        var state = MagazineGestureState()
        #expect(!state.update(phase: .began, dy: -400).consumed)
        #expect(state.presentation.progress == 0)
        _ = state.update(phase: .changed, dy: -40, atBottom: true)
        #expect(state.presentation.progress > 0 && state.presentation.progress < 0.2)
        _ = state.update(phase: .changed, dy: -200, atBottom: true)
        #expect(state.update(phase: .ended).action == .next)
    }

    @Test("Vertical scrolling stays vertical even when a later sample drifts sideways")
    func axisLock() {
        var state = MagazineGestureState()
        _ = state.update(phase: .began, dx: 3, dy: -40)
        _ = state.update(phase: .changed, dx: 250, dy: -2)
        #expect(state.presentation.edge == nil)
        #expect(state.update(phase: .ended).action == nil)
    }

    @Test("The first article closes at the top; later articles go to previous")
    func topBoundary() {
        for previous in [false, true] {
            var state = MagazineGestureState()
            _ = state.update(phase: .began, dy: 240, atTop: true, hasPrevious: previous)
            #expect(state.update(phase: .ended).action == (previous ? .previous : .close))
        }
    }

    @Test("No next article and ordinary mouse wheels never arm navigation")
    func unavailableAndDiscrete() {
        var state = MagazineGestureState()
        _ = state.update(phase: .began, dy: -400, atBottom: true, hasNext: false)
        #expect(state.presentation.edge == nil)
        _ = state.update(phase: .discrete, dy: -900, atBottom: true)
        #expect(state.presentation.edge == nil)
    }

    @Test("Horizontal back respects nested scroll ownership and can be unwound")
    func horizontalOwnership() {
        var state = MagazineGestureState()
        #expect(!state.update(phase: .began, dx: 250, allowsBack: false).consumed)
        #expect(state.presentation.edge == nil)
        _ = state.update(phase: .began, dx: 200)
        #expect(state.presentation.isArmed)
        _ = state.update(phase: .changed, dx: -100)
        #expect(state.update(phase: .ended).action == nil)
    }
}
