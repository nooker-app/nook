import Foundation

public enum MagazineGestureAction: Equatable, Sendable {
    case next, previous, close
}

public enum MagazineGestureEdge: Equatable, Sendable {
    case top, bottom, leading
}

public struct MagazinePullPresentation: Equatable, Sendable {
    public var edge: MagazineGestureEdge?
    public var action: MagazineGestureAction?
    public var distance: CGFloat = 0
    public var progress: CGFloat = 0
    public var isArmed: Bool { progress >= 1 }

    public init() {}
}

/// Input policy separated from AppKit so cancellation, momentum, reversal and
/// axis locking can be exercised without synthesizing a physical trackpad.
struct MagazineGestureState {
    enum Phase { case began, changed, ended, cancelled, momentum, discrete }
    enum Axis { case horizontal, vertical }
    struct Result {
        var consumed = false
        var action: MagazineGestureAction?
        var resistanceTravel: CGFloat = 0
    }

    private(set) var presentation = MagazinePullPresentation()
    private(set) var axis: Axis?
    private var tracking = false
    private var suppressMomentum = false
    private var accumulated = CGPoint.zero
    private var raw: CGFloat = 0

    static let verticalThreshold: CGFloat = 220
    static let horizontalThreshold: CGFloat = 180

    mutating func reset() { self = Self() }

    mutating func update(
        phase: Phase, dx: CGFloat = 0, dy: CGFloat = 0,
        atTop: Bool = false, atBottom: Bool = false,
        hasNext: Bool = true, hasPrevious: Bool = true,
        allowsBack: Bool = true
    ) -> Result {
        if phase == .momentum { return Result(consumed: suppressMomentum || presentation.edge != nil) }
        if phase == .discrete { return Result() }
        if phase == .began { reset(); tracking = true }
        if phase == .cancelled || phase == .ended {
            let consumed = presentation.edge != nil
            let action = phase == .ended && presentation.isArmed ? presentation.action : nil
            reset()
            suppressMomentum = consumed
            return Result(consumed: consumed, action: action)
        }
        // Some devices start with .changed after a view becomes active.
        if !tracking { tracking = true }
        accumulated.x += dx
        accumulated.y += dy
        if axis == nil {
            let x = abs(accumulated.x), y = abs(accumulated.y)
            if x >= 6, x > y * 1.35 { axis = .horizontal }
            else if y >= 6, y > x * 1.35 { axis = .vertical }
            else { return Result() }
        }

        if presentation.edge == nil {
            if axis == .horizontal, allowsBack, dx > 0 {
                presentation.edge = .leading
                presentation.action = .close
            } else if axis == .vertical, atTop, dy > 0 {
                presentation.edge = .top
                presentation.action = hasPrevious ? .previous : .close
            } else if axis == .vertical, atBottom, dy < 0, hasNext {
                presentation.edge = .bottom
                presentation.action = .next
            } else { return Result() }
        }

        let threshold = presentation.edge == .leading ? Self.horizontalThreshold : Self.verticalThreshold
        let delta: CGFloat
        switch presentation.edge {
        case .leading: delta = dx
        case .top: delta = dy
        case .bottom: delta = -dy
        case nil: return Result()
        }
        raw = min(threshold * 2, max(0, raw + delta))
        if raw == 0 {
            presentation = MagazinePullPresentation()
            return Result()
        }
        presentation.progress = min(1, raw / threshold)
        // A bounded, continuously increasing displacement: resistance grows as
        // the finger travels, while the fill measures the actual commit distance.
        presentation.distance = 140 * raw / (raw + 160)
        return Result(consumed: true, resistanceTravel: presentation.isArmed ? max(0, delta) : 0)
    }
}

/// Detents are driven by deliberate movement, never by a repeating timer.
/// AppKit exposes patterns rather than amplitude, so each outward step requests
/// a generic impact, at most twenty times a second. Release/reversal is silent.
struct MagazineResistanceHaptics {
    enum Pulse: Equatable { case threshold, resistance }
    private var armed = false
    private var travel: CGFloat = 0
    private var lastPulse: TimeInterval = -.infinity

    mutating func reset() { self = Self() }

    mutating func update(phase: MagazineGestureState.Phase, isArmed: Bool,
                         outwardTravel: CGFloat, time: TimeInterval) -> Pulse? {
        if phase == .began { reset() }
        if phase == .ended || phase == .cancelled { reset(); return nil }
        guard phase == .began || phase == .changed else { return nil }
        guard isArmed else { armed = false; travel = 0; return nil }
        if !armed {
            armed = true
            travel = 0
            lastPulse = time
            return .threshold
        }
        guard outwardTravel > 0 else { travel = 0; return nil }
        travel += outwardTravel
        guard travel >= 10, time - lastPulse >= 0.05 else { return nil }
        travel = 0
        lastPulse = time
        return .resistance
    }
}
