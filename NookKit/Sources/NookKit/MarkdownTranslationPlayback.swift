import Foundation

/// Keeps provider receipt ahead of a single, ordered presentation lane. Completed
/// Markdown blocks reveal in order, with settling ripples overlapping the next
/// block. An SSE burst or retry cannot jump straight to the final document.
@MainActor
final class MarkdownTranslationPlayback {
    private let originals: [HTMLContentBlock]
    private let originalText: [String]
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
    private var activeBlock: HTMLContentBlock?
    private var settlingBlocks: [Int: HTMLContentBlock] = [:]
    private var settlements: [Int: Task<Void, Never>] = [:]
    private var rendered: [Int: (block: HTMLContentBlock, markdown: String)] = [:]
    private let settleDuration: Double

    init(originals: [HTMLContentBlock], baseURL: URL?,
         settleDuration: Double = ReaderTranslationMotion.duration,
         isCurrent: @escaping () -> Bool,
         emitTitle: @escaping (String, Bool) -> Void,
         emitDocument: @escaping ([HTMLContentBlock]) -> Void) {
        self.originals = originals
        originalText = originals.map {
            MarkdownTranslationStream.plainProjection(ArticleMarkdown.render([$0], baseURL: baseURL))
        }
        self.baseURL = baseURL
        self.settleDuration = settleDuration
        self.isCurrent = isCurrent
        self.emitDocument = emitDocument
        // The title view owns its last ripple; it can settle while the body starts.
        titlePlayback = TranslationTextPlayback(settleDuration: 0, isCurrent: isCurrent, emit: emitTitle)
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
        if let index = activeIndex, let markdown = markdown(at: index) {
            active?.queuedCharacters = self.markdown(at: index + 1)?.count ?? 0
            active?.receive(markdown)
        }
        startIfNeeded()
    }

    func finish(title: String, blocks: [HTMLContentBlock]) async {
        receive(title: title, blocks: blocks, final: true)
        await withTaskCancellationHandler {
            await worker?.value
            // Only the final handoff waits. Earlier paragraph ripples overlap
            // the next paragraph instead of adding 0.45s to every transition.
            while current, let task = settlements.values.first { await task.value }
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
        for task in settlements.values { task.cancel() }
        settlements.removeAll()
        settlingBlocks.removeAll()
        worker = nil
    }

    private var current: Bool { !cancelled && !Task.isCancelled && isCurrent() }

    private func target(at index: Int) -> HTMLContentBlock? {
        if stable.indices.contains(index) { return stable[index] }
        return latest.indices.contains(index) ? latest[index] : nil
    }

    private func markdown(at index: Int) -> String? {
        guard let block = target(at: index) else { return nil }
        if let cached = rendered[index], cached.block == block { return cached.markdown }
        let markdown = ArticleMarkdown.render([block], baseURL: baseURL)
        rendered[index] = (block, markdown)
        return markdown
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
                    let playback = TranslationTextPlayback(settleDuration: 0, isCurrent: isCurrent) { [weak self] text, complete in
                        self?.publish(text, complete: complete, at: index)
                    }
                    active = playback
                    activeIndex = index
                    playback.queuedCharacters = markdown(at: index + 1)?.count ?? 0
                    playback.receive(markdown(at: index) ?? "")
                    while current, !final, !stable.indices.contains(index) {
                        do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                    }
                    guard current, stable.indices.contains(index) else { return }
                    await playback.finish(markdown(at: index) ?? "")
                    active = nil
                } else {
                    while current, !final, !stable.indices.contains(index) {
                        do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                    }
                }
                guard current, stable.indices.contains(index) else { return }
                committed.append(stable[index])
                if let activeBlock, settleDuration > 0 {
                    settlingBlocks[index] = activeBlock
                    settlements[index] = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(self?.settleDuration ?? 0)) }
                        catch { return }
                        guard let self, current else { return }
                        settlingBlocks[index] = nil
                        settlements[index] = nil
                        emitCurrentDocument()
                    }
                }
                activeIndex = nil
                activeBlock = nil
                emitCurrentDocument()
            }
        }
    }

    private func publish(_ text: String, complete: Bool, at index: Int) {
        guard current, let target = target(at: index) else { return }
        let heading: Int?
        if case .heading(let level, _) = target { heading = level } else { heading = nil }
        let original = originalText.indices.contains(index) ? originalText[index] : ""
        activeBlock = .mixedText(parts: [.streamingMarkdown(original: original, markdown: text, complete: complete)], headingLevel: heading)
        emitCurrentDocument()
    }

    private func emitCurrentDocument() {
        guard current else { return }
        var display = committed.enumerated().map { settlingBlocks[$0.offset] ?? $0.element }
        if activeIndex == committed.count, let activeBlock { display.append(activeBlock) }
        display.append(contentsOf: originals.dropFirst(display.count))
        emitDocument(display)
    }
}
