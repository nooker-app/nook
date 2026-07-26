import Foundation

/// A side of the native reader's bottom controls. The raw values intentionally
/// remain `left`/`right` so existing preferences migrate without conversion.
public enum ReaderControlSide: String, CaseIterable, Codable, Identifiable, Sendable {
    case left
    case right

    public var id: Self { self }

    public var opposite: Self {
        self == .left ? .right : .left
    }
}

/// The hand a person normally uses to hold and scroll the device. This is
/// intentionally independent from where they prefer the bottom controls.
public enum ReaderHandedness: String, CaseIterable, Codable, Identifiable, Sendable {
    case left
    case right

    public var id: Self { self }

    var side: ReaderControlSide {
        self == .left ? .left : .right
    }
}

/// Converts a small run of deliberate, same-side reader scrolls into a temporary
/// mirrored-layout state. The configured hand — not the configured control
/// position — is the baseline: evidence from the other hand mirrors the layout,
/// while evidence from the configured hand restores the chosen default.
///
/// This type contains no timers or observation. The iOS reader feeds it one
/// sample only when a real vertical pan ends, keeping work off the per-frame
/// scroll path.
public struct ReaderControlAdaptationPolicy: Sendable {
    public let switchThreshold: Int
    public let restoreThreshold: Int

    private var isMirrored = false
    private var candidate: ReaderControlSide?
    private var consecutiveCount = 0

    public init(switchThreshold: Int = 4, restoreThreshold: Int = 3) {
        self.switchThreshold = max(1, switchThreshold)
        self.restoreThreshold = max(1, restoreThreshold)
    }

    /// Records one qualified scroll and returns whether the configured control
    /// layout should currently be mirrored.
    @discardableResult
    public mutating func record(
        _ observedSide: ReaderControlSide,
        primaryHand: ReaderHandedness
    ) -> Bool {
        let primarySide = primaryHand.side
        let target = isMirrored ? primarySide : primarySide.opposite

        guard observedSide == target else {
            candidate = nil
            consecutiveCount = 0
            return isMirrored
        }

        if candidate == observedSide {
            consecutiveCount += 1
        } else {
            candidate = observedSide
            consecutiveCount = 1
        }

        let threshold = isMirrored ? restoreThreshold : switchThreshold
        guard consecutiveCount >= threshold else { return isMirrored }

        isMirrored.toggle()
        candidate = nil
        consecutiveCount = 0
        return isMirrored
    }

    public mutating func reset() {
        isMirrored = false
        candidate = nil
        consecutiveCount = 0
    }
}
