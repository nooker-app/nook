import Foundation
import Observation

/// The article the macOS reader pane shows: the list selection, held back only
/// while the selection is moving faster than a reader could be read.
///
/// The list's selection itself stays immediate. Holding ↓ moved it ~30 times a
/// second and the reader rendered every article it passed — measured at 5–15
/// `reader.body` runs inside each stalled second. A change that follows the
/// previous one by at least `settle` (a click, a single key press, the first
/// press of a repeat) passes through in the same transaction, so opening an
/// article is as immediate as before. A change inside that interval is a repeat:
/// it is held, and only the latest one lands once the selection has been still
/// for `settle`. Clearing the selection always passes at once.
@MainActor @Observable
public final class ReaderSelectionSettler {
    public private(set) var settledID: Article.ID?

    @ObservationIgnored private let settle: Duration
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private var lastChange: ContinuousClock.Instant?
    @ObservationIgnored private var pendingID: Article.ID?
    @ObservationIgnored private var pendingTask: Task<Void, Never>?

    public init(settle: Duration = .milliseconds(150),
                now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.settle = settle
        self.now = now
    }

    public func selectionChanged(to id: Article.ID?) {
        let instant = now()
        defer { lastChange = instant }
        let isRepeat = lastChange.map { instant - $0 < settle } ?? false
        guard id != nil, isRepeat else {
            pendingTask?.cancel()
            pendingTask = nil
            pendingID = nil
            if settledID != id { settledID = id }
            return
        }
        pendingID = id
        #if DEBUG && os(macOS)
        MainThreadLog.add("reader.selection.held", ms: 0)
        #endif
        pendingTask?.cancel()
        pendingTask = Task { [weak self, settle] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled, let self else { return }
            self.pendingTask = nil
            if self.settledID != self.pendingID { self.settledID = self.pendingID }
            self.pendingID = nil
        }
    }
}
