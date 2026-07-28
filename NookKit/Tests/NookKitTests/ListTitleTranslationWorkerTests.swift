import Foundation
import Testing
@testable import NookKit

@Suite("List title translation worker")
struct ListTitleTranslationWorkerTests {
    private func request(_ provider: TranslationProvider = .gemini) -> ListTitleTranslationWorker.Request {
        ListTitleTranslationWorker.Request(
            source: "A translated title",
            languageName: "Korean",
            provider: provider
        )
    }

    private func drain(
        _ stream: AsyncStream<ListTitleTranslationWorker.Event>
    ) async -> (partials: [String], terminal: ListTitleTranslationWorker.Event?) {
        var partials: [String] = []
        var terminal: ListTitleTranslationWorker.Event?
        for await event in stream {
            switch event {
            case .partial(let text, _): partials.append(text)
            case .completed, .failed: terminal = event
            }
        }
        return (partials, terminal)
    }

    /// The worker's central promise is that a MainActor coordinator can start a
    /// run without any provider work landing on the UI thread. So the test *is* a
    /// MainActor caller — start and consumption both on the UI — and the backend
    /// reports the thread it actually ran on.
    ///
    /// What this pins: the `Backend` contract staying non-isolated. Swift keeps a
    /// nonisolated `async` function off the caller's actor on its own, so the
    /// regression to guard is the contract itself acquiring UI isolation (a
    /// `@MainActor` on the typealias or on a concrete backend) — verified by
    /// mutation: annotating `Backend` with `@MainActor` fails both expectations.
    ///
    /// Sampling the thread replaces an earlier timing proxy (assert a `MainActor`
    /// hop returns within 40 ms). That proxy measured global main-thread
    /// availability rather than this worker: `NativeInlineHTMLRendererTests` and
    /// its AppKit font work, scheduled in parallel, pushed the hop past the bound
    /// and failed the test for an unrelated reason.
    @MainActor
    @Test("Provider work stays off the UI thread even when the caller is the UI")
    func separatesWorkFromUI() async {
        let revealDelay = Duration.milliseconds(40)
        let probe = ThreadProbe()
        let worker = ListTitleTranslationWorker { _, onPartial in
            // Before any suspension: the executor the backend was started on.
            await probe.recordStart(onMainThread: isOnMainThread())
            await onPartial("번역된 제목입니다")
            // After one: a resumption that lands on the UI thread is caught too.
            await probe.recordResume(onMainThread: isOnMainThread())
            return "번역된 제목입니다"
        }

        let clock = ContinuousClock()
        let started = clock.now
        // `Task` here inherits MainActor, so the consumer side is the UI too —
        // the same shape as the real `ListTitleTranslator`.
        let stream = await worker.events(
            for: request(),
            revealDelay: revealDelay,
            frameInterval: .milliseconds(5)
        )
        let collector = Task {
            var firstPartialElapsed: Duration?
            var last: ListTitleTranslationWorker.Event?
            for await event in stream {
                if firstPartialElapsed == nil, case .partial = event {
                    firstPartialElapsed = started.duration(to: clock.now)
                }
                last = event
            }
            return (last, firstPartialElapsed)
        }
        // The stream only finishes after the backend returned, so awaiting it
        // is enough to guarantee the probe was written — no spin-waiting.
        let (lastEvent, firstPartialElapsed) = await collector.value

        #expect(await probe.startedOnMainThread == false)
        #expect(await probe.resumedOnMainThread == false)
        // `Task.sleep` never returns early, so the first partial can only be late.
        // The tolerance absorbs clock granularity between the two start points.
        #expect(firstPartialElapsed ?? .zero >= revealDelay - .milliseconds(5))
        #expect(lastEvent == .completed("번역된 제목입니다", .gemini))
    }

    @Test("Bulk output is paced into bounded cumulative prefixes")
    func pacesBulkOutput() async {
        let final = "abcdefghijklmnop"
        let worker = ListTitleTranslationWorker { _, _ in final }
        let stream = await worker.events(
            for: request(.appleIntelligence),
            revealDelay: .zero,
            frameInterval: .milliseconds(4)
        )

        let (partials, terminal) = await drain(stream)

        #expect(partials.count == 4)
        #expect(partials.map(\.count) == [4, 8, 12, 16])
        #expect(terminal == .completed(final, .appleIntelligence))
    }

    /// A provider may correct itself with a snapshot that is not an extension of
    /// what is already shown. That replaces the line in one frame rather than
    /// synthesizing delete/retype motion — and an identical snapshot is not a
    /// change at all, so it must not cost the row an update.
    @Test("A correction replaces the line and an identical snapshot emits nothing")
    func correctionsReplaceAndRepeatsAreDropped() async {
        let worker = ListTitleTranslationWorker { _, onPartial in
            await onPartial("abcd")
            await onPartial("abcd")
            await onPartial("xyz")
            return "xyz"
        }
        let stream = await worker.events(for: request(), revealDelay: .zero, frameInterval: .zero)

        let (partials, terminal) = await drain(stream)

        #expect(partials == ["abcd", "xyz"])
        #expect(terminal == .completed("xyz", .gemini))
    }

    @Test("A backend with no result terminates without a translated title")
    func reportsFailureWhenBackendHasNoResult() async {
        let worker = ListTitleTranslationWorker { _, _ in nil }
        let stream = await worker.events(for: request(), revealDelay: .zero, frameInterval: .zero)

        let (partials, terminal) = await drain(stream)

        #expect(partials.isEmpty)
        #expect(terminal == .failed)
    }

    /// A blank result must fail rather than complete: `.completed("")` would
    /// leave the row showing an empty translation block it had already grown for.
    @Test("A blank result fails instead of announcing an empty title")
    func reportsFailureForBlankResult() async {
        let worker = ListTitleTranslationWorker { _, _ in "   \n  " }
        let stream = await worker.events(for: request(), revealDelay: .zero, frameInterval: .zero)

        let (partials, terminal) = await drain(stream)

        #expect(partials.isEmpty)
        #expect(terminal == .failed)
    }

    @Test("A throwing backend fails the run instead of hanging the stream")
    func reportsFailureWhenBackendThrows() async {
        struct BackendFailure: Error {}
        let worker = ListTitleTranslationWorker { _, _ in throw BackendFailure() }
        let stream = await worker.events(for: request(), revealDelay: .zero, frameInterval: .zero)

        let (_, terminal) = await drain(stream)

        #expect(terminal == .failed)
    }

    /// Partials already emitted before a failure stay on screen — the run reports
    /// `.failed` without retracting them, and never also reports `.completed`.
    @Test("A backend that fails after streaming keeps its partials and fails once")
    func failureAfterPartialsIsTerminal() async {
        struct BackendFailure: Error {}
        let worker = ListTitleTranslationWorker { _, onPartial in
            await onPartial("abcd")
            throw BackendFailure()
        }
        let stream = await worker.events(for: request(), revealDelay: .zero, frameInterval: .zero)

        var events: [ListTitleTranslationWorker.Event] = []
        for await event in stream { events.append(event) }

        #expect(events == [.partial("abcd", .gemini), .failed])
    }
}

/// `Thread.isMainThread` and `Thread.current` are both banned from async contexts
/// — they invite the wrong mental model of actors. Here the thread genuinely is
/// what we mean to observe: MainActor runs on, and only on, the main thread, so
/// "not the main thread" is exactly "not the UI executor".
private func isOnMainThread() -> Bool {
    pthread_main_np() != 0
}

/// Records the thread the backend ran on. Asserting this directly is what makes
/// the isolation test deterministic: it observes the invariant itself rather
/// than inferring it from how long an unrelated `MainActor` hop took.
private actor ThreadProbe {
    private(set) var startedOnMainThread: Bool?
    private(set) var resumedOnMainThread: Bool?

    func recordStart(onMainThread: Bool) { startedOnMainThread = onMainThread }
    func recordResume(onMainThread: Bool) { resumedOnMainThread = onMainThread }
}
