import Foundation

/// The non-UI half of list-title translation. A run owns provider streaming,
/// validation/fallback, reveal gating, and snapshot coalescing. Its consumer only
/// receives bounded, immutable presentation events and can therefore do a tiny
/// state assignment on the main actor.
actor ListTitleTranslationWorker {
    struct Request: Sendable {
        let source: String
        let languageName: String
        let provider: TranslationProvider
    }

    enum Event: Equatable, Sendable {
        case partial(String, TranslationProvider)
        case completed(String, TranslationProvider)
        case failed
    }

    typealias Backend = @Sendable (
        _ request: Request,
        _ onPartial: @escaping @Sendable (String) async -> Void
    ) async throws -> String?

    static let shared = ListTitleTranslationWorker()

    private let backend: Backend

    init(backend: Backend? = nil) {
        self.backend = backend ?? Self.liveBackend
    }

    /// Starts a self-contained run. The detached producer is deliberate: callers
    /// are MainActor coordinators, but no provider, parsing, validation, or coalescing
    /// work is allowed to inherit their executor.
    func events(
        for request: Request,
        revealDelay: Duration = .milliseconds(340),
        frameInterval: Duration = .milliseconds(100)
    ) -> AsyncStream<Event> {
        let backend = self.backend
        return AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation in
            let emitter = ListTitleProgressEmitter(
                continuation: continuation,
                provider: request.provider,
                revealDelay: revealDelay,
                frameInterval: frameInterval
            )
            let producer = Task.detached(priority: .userInitiated) {
                let terminal: Event?
                do {
                    let final = try await backend(request) { partial in
                        await emitter.emit(partial)
                    }
                    try Task.checkCancellation()
                    let cleaned = final?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    terminal = cleaned.isEmpty ? .failed : .completed(cleaned, request.provider)
                } catch is CancellationError {
                    terminal = nil
                } catch {
                    terminal = .failed
                }
                // Completion wins over any delayed snapshot. A bulk result is
                // ready to read; never manufacture animation frames from it.
                await emitter.finish()
                if let terminal { continuation.yield(terminal) }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.cancel()
                Task { await emitter.finish() }
            }
        }
    }

    private static func liveBackend(
        _ request: Request,
        _ onPartial: @escaping @Sendable (String) async -> Void
    ) async throws -> String? {
        #if DEBUG
        if let delay = TranslationSettings.fakeTranslatorDelay {
            let jitter = TranslationSettings.fakeTranslatorJitter
            // A long fake wraps to more lines than the source, so landing it
            // changes the row's height the way a verbose real translation does.
            let result = TranslationSettings.fakeTranslatorLong
                ? "[\(request.languageName)] \(request.source) — \(request.source)"
                : "[\(request.languageName)] \(request.source)"
            // Deterministic per title (FNV-1a), so runs stay comparable.
            var seed: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in request.source.utf8 { seed = (seed ^ UInt64(byte)) &* 0x100_0000_01b3 }
            var partial = ""
            for character in result {
                var wait = delay
                if jitter > 0 {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    wait += Int((seed >> 33) % UInt64(jitter))
                }
                try await Task.sleep(for: .milliseconds(wait))
                try Task.checkCancellation()
                partial.append(character)
                await onPartial(partial)
            }
            return result
        }
        #endif
        let keepTerms = NaturalTranslator.heuristicKeepTokens(request.source)
        do {
            let result = try await NaturalTranslator.streamTranslateBlockOffMain(
                request.source,
                into: request.languageName,
                keepTerms: keepTerms,
                provider: request.provider,
                onPartial: onPartial
            )
            try Task.checkCancellation()
            let final = result.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            if !final.isEmpty, !isEcho(final, request.source) {
                return final
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
        }

        // The structured model occasionally echoes a short, proper-noun-heavy
        // title. The plain fallback is still executed here, never by the UI actor;
        // its bulk result is delivered immediately when ready.
        guard let plain = await NaturalTranslator.translatePlainFallback(
            request.source,
            into: request.languageName,
            keepTerms: keepTerms,
            provider: request.provider
        ) else {
            return nil
        }
        try Task.checkCancellation()
        let final = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        return final.isEmpty || isEcho(final, request.source) ? nil : final
    }

    private nonisolated static func isEcho(_ output: String, _ source: String) -> Bool {
        func normalized(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping
                .lowercased()
        }
        return normalized(output) == normalized(source)
    }
}

/// Keeps the newest provider snapshot without making the provider wait for UI
/// animation. At most one delayed flush is scheduled, so a burst of tokens costs
/// one row layout, not one layout per token (or per synthetic four-character step).
private actor ListTitleProgressEmitter {
    private let continuation: AsyncStream<ListTitleTranslationWorker.Event>.Continuation
    private let provider: TranslationProvider
    private let revealDelay: Duration
    private let frameInterval: Duration
    private let startedAt = ContinuousClock.now
    private var lastEmission: ContinuousClock.Instant?
    private var displayed = ""
    private var pending: String?
    private var flushTask: Task<Void, Never>?
    private var finished = false

    init(
        continuation: AsyncStream<ListTitleTranslationWorker.Event>.Continuation,
        provider: TranslationProvider,
        revealDelay: Duration,
        frameInterval: Duration
    ) {
        self.continuation = continuation
        self.provider = provider
        self.revealDelay = revealDelay
        self.frameInterval = frameInterval
    }

    func emit(_ raw: String) {
        guard !finished, !Task.isCancelled else { return }
        let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        // A correction back to the displayed value must replace pending text too.
        pending = target
        guard flushTask == nil else { return }
        let deadline = max(startedAt + revealDelay, (lastEmission ?? startedAt) + (lastEmission == nil ? .zero : frameInterval))
        if ContinuousClock.now >= deadline {
            flush()
        } else {
            flushTask = Task { [weak self] in
                do { try await Task.sleep(until: deadline, clock: .continuous) }
                catch { return }
                guard !Task.isCancelled else { return }
                await self?.flush()
            }
        }
    }

    func finish() {
        finished = true
        flushTask?.cancel()
        flushTask = nil
        pending = nil
    }

    private func flush() {
        flushTask = nil
        guard !finished, let target = pending else { return }
        pending = nil
        guard target != displayed else { return }
        displayed = target
        lastEmission = .now
        continuation.yield(.partial(target, provider))
    }
}
