import Foundation

/// Keeps provider receipt ahead of a single, ordered presentation lane. Completed
/// Markdown blocks are committed only after their visible text and ripple drain;
/// an SSE burst or provider retry cannot jump straight to the final document.
@MainActor
final class MarkdownTranslationPlayback {
    private let originals: [HTMLContentBlock]
    private let baseURL: URL?
    private let isCurrent: () -> Bool
    private let emitDocument: ([HTMLContentBlock]) -> Void
    private let titlePlayback: TranslationTextPlayback
    private var active: TranslationTextPlayback?
    private var worker: Task<Void, Never>?
    private var stable: [HTMLContentBlock] = []
    private var latest: [HTMLContentBlock] = []
    private var committed: [HTMLContentBlock] = []
    private var title = ""
    private var titleReady = false
    private var final = false
    private var cancelled = false
    private var activeIndex: Int?
    private let settleDuration: Double

    init(originals: [HTMLContentBlock], baseURL: URL?,
         settleDuration: Double = ReaderTranslationMotion.duration,
         isCurrent: @escaping () -> Bool,
         emitTitle: @escaping (String, Bool) -> Void,
         emitDocument: @escaping ([HTMLContentBlock]) -> Void) {
        self.originals = originals
        self.baseURL = baseURL
        self.settleDuration = settleDuration
        self.isCurrent = isCurrent
        self.emitDocument = emitDocument
        titlePlayback = TranslationTextPlayback(settleDuration: settleDuration, isCurrent: isCurrent, emit: emitTitle)
    }

    func receive(title: String, blocks: [HTMLContentBlock], final: Bool = false) {
        guard !cancelled, isCurrent() else { return }
        let cleaned = MarkdownTranslationStream.plainProjection(title)
        if !cleaned.isEmpty, !titleReady || final {
            self.title = cleaned
            titlePlayback.receive(cleaned)
        }
        if !blocks.isEmpty || final { titleReady = true }
        latest = blocks
        let stableCount = final ? blocks.count : max(0, blocks.count - 1)
        if final {
            // A validated final result is authoritative, including corrections.
            stable = blocks
            self.final = true
        } else if stableCount > stable.count {
            stable.append(contentsOf: blocks[stable.count..<stableCount])
        }
        if let index = activeIndex, let block = target(at: index) {
            active?.receive(ArticleMarkdown.render([block], baseURL: baseURL))
        }
        startIfNeeded()
    }

    func finish(title: String, blocks: [HTMLContentBlock]) async {
        receive(title: title, blocks: blocks, final: true)
        await withTaskCancellationHandler {
            await worker?.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    /// Keep the trustworthy prefix and leave the remainder in its source language.
    func finishPartial() async {
        var accepted = stable
        if latest.count > accepted.count { accepted.append(latest[accepted.count]) }
        await finish(title: title, blocks: accepted)
    }

    func cancel() {
        cancelled = true
        worker?.cancel()
        titlePlayback.cancel()
        active?.cancel()
        worker = nil
    }

    private var current: Bool { !cancelled && !Task.isCancelled && isCurrent() }

    private func target(at index: Int) -> HTMLContentBlock? {
        if stable.indices.contains(index) { return stable[index] }
        return latest.indices.contains(index) ? latest[index] : nil
    }

    private func startIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while current, !titleReady {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
            guard current else { return }
            await titlePlayback.finish(title)
            while current {
                let index = committed.count
                guard let block = target(at: index) else {
                    if final { return }
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                    continue
                }
                // Media and code retain their native, non-translated rendering.
                let streams: Bool
                switch block {
                case .text, .heading, .blockquote, .list, .table: streams = true
                default: streams = false
                }
                if streams {
                    let playback = TranslationTextPlayback(settleDuration: settleDuration, isCurrent: isCurrent) { [weak self] text, complete in
                        self?.publish(text, complete: complete, at: index)
                    }
                    active = playback
                    activeIndex = index
                    playback.receive(ArticleMarkdown.render([block], baseURL: baseURL))
                    while current, !final, !stable.indices.contains(index) {
                        do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                    }
                    guard current, stable.indices.contains(index) else { return }
                    await playback.finish(ArticleMarkdown.render([stable[index]], baseURL: baseURL))
                    activeIndex = nil
                    active = nil
                } else {
                    while current, !final, !stable.indices.contains(index) {
                        do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                    }
                }
                guard current, stable.indices.contains(index) else { return }
                committed.append(stable[index])
                emitDocument(committed + originals.dropFirst(committed.count))
            }
        }
    }

    private func publish(_ text: String, complete: Bool, at index: Int) {
        guard current, let target = target(at: index) else { return }
        let heading: Int?
        if case .heading(let level, _) = target { heading = level } else { heading = nil }
        let original = originals.indices.contains(index) ? MarkdownTranslationStream.plainProjection(ArticleMarkdown.render([originals[index]], baseURL: baseURL)) : ""
        let live = HTMLContentBlock.mixedText(parts: [.streamingMarkdown(original: original, markdown: text, complete: complete)], headingLevel: heading)
        emitDocument(committed + [live] + originals.dropFirst(index + 1))
    }
}
