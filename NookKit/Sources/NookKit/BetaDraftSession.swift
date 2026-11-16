import Foundation
import Observation

/// One stable edit buffer. All writes run serially on the main actor, including
/// the final synchronous flush used by window close and app termination.
@MainActor @Observable
public final class BetaDraftSession {
    public var draft: PlusDraft {
        didSet {
            guard draft != oldValue else { return }
            isDirty = true
            scheduleSave()
        }
    }
    public private(set) var isDirty = false
    public private(set) var failure: String?
    public private(set) var savedAt: Date?
    public private(set) var isPublishing = false
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private let write: (PlusDraft) throws -> Void
    @ObservationIgnored private let delay: Duration

    public init(draft: PlusDraft = PlusDraft(), delay: Duration = .milliseconds(800),
                write: @escaping (PlusDraft) throws -> Void) {
        self.draft = draft
        self.delay = delay
        self.write = write
    }

    public convenience init(draft: PlusDraft = PlusDraft()) {
        self.init(draft: draft) { value in
            try PlusDraftStore.default().save(value)
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self, delay] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    @discardableResult
    public func flush() -> Bool {
        pendingSave?.cancel()
        pendingSave = nil
        guard !isPublishing else { return false }
        guard isDirty else { return failure == nil }
        do {
            try write(draft)
            isDirty = false
            failure = nil
            savedAt = Date()
            return true
        } catch {
            failure = error.localizedDescription
            return false
        }
    }

    /// Freeze editing and drain the debounce before publishing. A late autosave
    /// must never recreate a draft after a successful publication deletes it.
    public func beginPublishing() -> Bool {
        guard flush() else { return false }
        isPublishing = true
        return true
    }

    public func endPublishing() { isPublishing = false }
}
