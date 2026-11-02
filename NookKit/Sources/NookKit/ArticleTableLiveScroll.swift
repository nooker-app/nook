#if os(macOS)
import AppKit

/// Whether the article list is moving too fast for a row to be worth
/// translating, from the clip view's own bounds changes.
///
/// `NSScrollView` live-scroll notifications cover a trackpad drag and its
/// momentum, but not a classic mouse wheel, keyboard paging, scroller clicks or
/// programmatic scrolls. Every one of those moves the clip view, so the speed of
/// that movement is the signal: above `fastThreshold` the rows on screen are
/// passing through, and a translation started for one is mostly thrown away.
/// Motion counts as fast until `settleDelay` after the last fast sample, so a
/// wheel's discrete ticks read as one gesture.
public struct ScrollMotionGate: Sendable {
    public var fastThreshold: Double
    public var settleDelay: Double
    private var last: (y: Double, at: Double)?
    public private(set) var lastFastAt = -Double.infinity
    public private(set) var lastMoveAt = -Double.infinity

    public init(fastThreshold: Double = 600, settleDelay: Double = 0.15) {
        self.fastThreshold = fastThreshold
        self.settleDelay = settleDelay
    }

    /// Records the clip view's origin at `time` (seconds) and returns whether the
    /// list is moving fast now. Several changes inside one frame are measured
    /// against at least a frame's time, so they never read as an extreme speed.
    @discardableResult
    public mutating func record(y: Double, at time: Double) -> Bool {
        defer { last = (y, time) }
        guard let last, y != last.y else { return isFast(at: time) }
        lastMoveAt = time
        let elapsed = max(time - last.at, 1.0 / 120)
        if abs(y - last.y) / elapsed >= fastThreshold { lastFastAt = time }
        return isFast(at: time)
    }

    public func isFast(at time: Double) -> Bool { time - lastFastAt < settleDelay }

    /// Moved at all within `window` seconds (any speed).
    public func movedRecently(at time: Double, window: Double) -> Bool { time - lastMoveAt < window }
}

/// The ids actually on screen, diffed against the previous pass. AppKit adds
/// row views for rows it prepares around the visible rect as well, so the
/// translator is told about the rows the user can see, not the row views.
public struct VisibleRowSet: Sendable {
    public private(set) var visible: [Article.ID: String] = [:]

    public init() {}

    /// Returns the rows that came into view (id, title) and the ids that left.
    public mutating func update(_ rows: [(id: Article.ID, title: String)])
        -> (appeared: [(id: Article.ID, title: String)], disappeared: [Article.ID]) {
        var next: [Article.ID: String] = [:]
        next.reserveCapacity(rows.count)
        var appeared: [(id: Article.ID, title: String)] = []
        for row in rows where next[row.id] == nil {
            next[row.id] = row.title
            if visible[row.id] == nil { appeared.append(row) }
        }
        let disappeared = visible.keys.filter { next[$0] == nil }.sorted()
        visible = next
        return (appeared, disappeared)
    }

    /// Everything left the screen (the table went away).
    public mutating func removeAll() -> [Article.ID] {
        defer { visible = [:] }
        return visible.keys.sorted()
    }
}

/// Keeps the rows on screen where they are when rows above them change height.
///
/// `noteHeightOfRows` keeps the clip view's origin, so a row above the viewport
/// that grows (a translation landing, a badge's sub-point chip height) pushes
/// every visible row down. The first row whose top is inside the viewport is the
/// anchor: its distance from the top of the viewport is restored afterwards.
@MainActor
public enum ArticleTableScrollAnchor {
    public static func preservingVisibleRows(of tableView: NSTableView, changing rows: IndexSet,
                                             _ body: () -> Void) {
        guard let clip = tableView.enclosingScrollView?.contentView, let first = rows.first else {
            body()
            return
        }
        let visible = clip.documentVisibleRect
        let range = tableView.rows(in: visible)
        // The first row whose top is on screen (the top one is usually cut).
        var anchor = range.location
        if anchor != NSNotFound, anchor < tableView.numberOfRows,
           tableView.rect(ofRow: anchor).minY < visible.minY, anchor + 1 < NSMaxRange(range) {
            anchor += 1
        }
        guard range.length > 0, anchor != NSNotFound, first < anchor else {
            body()
            return
        }
        let before = tableView.rect(ofRow: anchor).minY - clip.bounds.minY
        body()
        let after = tableView.rect(ofRow: anchor).minY - clip.bounds.minY
        let shift = after - before
        guard abs(shift) > 0.01 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + shift))
        tableView.enclosingScrollView?.reflectScrolledClipView(clip)
    }
}
#endif
