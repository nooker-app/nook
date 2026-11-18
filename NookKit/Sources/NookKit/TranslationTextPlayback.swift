import Foundation

/// The reader's approved presentation defaults, independent of provider cadence.
enum ReaderTranslationMotion {
    static let duration = 0.45
    static let strength = 0.3
}

/// Receives cumulative snapshots but exposes one extended grapheme per beat.
/// Revisions replace only the already-visible prefix; appended tokens never reset
/// the beat or replay text. A stalled main thread does not release a whole batch.
struct TranslationRevealBuffer {
    private(set) var target: [Character] = []
    private(set) var visible = ""
    private(set) var shown = 0
    private(set) var nextBeat = 0.0
    private(set) var interval = 0.037
    private var receivedAt: Double?
    private var arrivalRate = 28.0

    var isCaughtUp: Bool { shown == target.count }

    mutating func receive(_ text: String, at now: Double) {
        let next = Array(text)
        let added = next.count - target.count
        if added > 0, let previous = receivedAt, now - previous > 0.015 {
            let sample = min(300, max(5, Double(added) / (now - previous)))
            arrivalRate = arrivalRate * 0.55 + sample * 0.45
        }
        if added > 0 { receivedAt = now }
        if !next.starts(with: target.prefix(shown)) {
            shown = min(shown, next.count)
            visible = String(next.prefix(shown))
        }
        target = next
    }

    @discardableResult
    mutating func step(at now: Double) -> Bool {
        guard !isCaughtUp, now >= nextBeat else { return false }
        let rate = min(56, max(10, arrivalRate * 1.08, Double(target.count - shown) / 1.3))
        interval += (1 / rate - interval) * 0.18
        visible.append(target[shown])
        shown += 1
        nextBeat = now + interval
        return true
    }
}

/// One presentation lifetime. The owner must cancel it on article/run changes.
/// `finish` drains every received character and the last ripple before the
/// caller replaces the streaming view with selectable, structured native HTML.
@MainActor
final class TranslationTextPlayback {
    private var buffer = TranslationRevealBuffer()
    private var receivedFinal = false
    private var cancelled = false
    private var worker: Task<Void, Never>?
    private var lastPublished = ""
    private let isCurrent: () -> Bool
    private let emit: (String, Bool) -> Void
    private let settleDuration: Double

    init(settleDuration: Double = ReaderTranslationMotion.duration,
         isCurrent: @escaping () -> Bool,
         emit: @escaping (String, Bool) -> Void) {
        self.settleDuration = settleDuration
        self.isCurrent = isCurrent
        self.emit = emit
    }

    func receive(_ text: String) {
        guard !cancelled, !receivedFinal, isCurrent() else { return }
        buffer.receive(text, at: ProcessInfo.processInfo.systemUptime)
        startIfNeeded()
    }

    func finish(_ final: String? = nil) async {
        guard !cancelled, isCurrent() else { return }
        if let final { buffer.receive(final, at: ProcessInfo.processInfo.systemUptime) }
        receivedFinal = true
        startIfNeeded()
        await withTaskCancellationHandler {
            await worker?.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        cancelled = true
        worker?.cancel()
        worker = nil
    }

    private func startIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while !cancelled, isCurrent(), !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                buffer.step(at: now)
                if buffer.visible != lastPublished {
                    lastPublished = buffer.visible
                    emit(buffer.visible, false)
                }
                if receivedFinal, buffer.isCaughtUp {
                    emit(buffer.visible, true)
                    if !buffer.visible.isEmpty {
                        try? await Task.sleep(for: .seconds(settleDuration))
                    }
                    return
                }
                let delay = buffer.isCaughtUp ? 0.025 : max(0.008, buffer.nextBeat - ProcessInfo.processInfo.systemUptime)
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
            }
        }
    }
}
