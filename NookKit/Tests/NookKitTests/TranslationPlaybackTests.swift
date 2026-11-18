import Foundation
import Testing
@testable import NookKit

@Suite("Reader translation playback")
@MainActor
struct TranslationPlaybackTests {
    @Test("Bursts and delayed frames still reveal one complete grapheme per beat")
    func graphemeBeats() {
        var buffer = TranslationRevealBuffer()
        let text = "한글👨‍👩‍👧‍👦e\u{301}" + String(repeating: "물결", count: 150)
        buffer.receive(text, at: 0)
        var previous = 0
        for tick in 0..<10_000 {
            if buffer.step(at: Double(tick) * 0.01) {
                #expect(buffer.visible.count == previous + 1)
                previous = buffer.visible.count
            }
            if buffer.isCaughtUp { break }
        }
        #expect(buffer.visible == text)
        buffer.receive(text + "끝", at: 500)
        let advanced = buffer.step(at: 1_000)
        #expect(advanced)
        #expect(buffer.visible == text + "끝")
    }

    @Test("Revisions and shorter snapshots never index beyond the new text")
    func revisions() {
        var buffer = TranslationRevealBuffer()
        buffer.receive("조용히 읽기", at: 0)
        for tick in 0..<30 { buffer.step(at: Double(tick)) }
        buffer.receive("편하게 읽기", at: 31)
        #expect(buffer.visible == "편하게 읽기")
        buffer.receive("짧게", at: 32)
        #expect(buffer.visible == "짧게")
        #expect(buffer.isCaughtUp)
        buffer.receive("", at: 33)
        #expect(buffer.visible.isEmpty)
        #expect(buffer.isCaughtUp)
    }

    @Test("Finishing drains pending text before the completion callback")
    func drainsBeforeCompletion() async {
        var received: [(String, Bool)] = []
        let playback = TranslationTextPlayback(settleDuration: 0, isCurrent: { true }) {
            received.append(($0, $1))
        }
        playback.receive("처음")
        await playback.finish("처음부터 끝까지")
        #expect(received.last?.0 == "처음부터 끝까지")
        #expect(received.last?.1 == true)
        #expect(received.filter(\.1).count == 1)
        let steps = received.filter { !$0.1 }.map { $0.0.count }
        #expect(steps == Array(1..."처음부터 끝까지".count))
        playback.cancel()
    }

    @Test("A cancelled or superseded run cannot publish or block finish")
    func cancellation() async throws {
        var isCurrent = true
        var received: [String] = []
        let playback = TranslationTextPlayback(settleDuration: 0, isCurrent: { isCurrent }) { text, _ in received.append(text) }
        playback.receive(String(repeating: "가", count: 200))
        try await Task.sleep(for: .milliseconds(60))
        isCurrent = false
        playback.cancel()
        let count = received.count
        await playback.finish("stale")
        playback.receive("late")
        try await Task.sleep(for: .milliseconds(40))
        #expect(received.count == count)
        #expect(!received.contains("stale"))
    }

    @Test("Document bursts keep title, body, and protected blocks in order")
    func documentOrder() async {
        let originals: [HTMLContentBlock] = [.text("<p>Original</p>"), .codeBlock(code: "let n = 1", language: "swift")]
        let final: [HTMLContentBlock] = [.text("<p><strong>번역</strong> 글</p>"), originals[1]]
        var titleComplete = false
        var title = ""
        var frames: [[HTMLContentBlock]] = []
        let playback = MarkdownTranslationPlayback(originals: originals, baseURL: nil, settleDuration: 0,
            isCurrent: { true },
            emitTitle: { text, complete in title = text; titleComplete = complete },
            emitDocument: { blocks in
                #expect(titleComplete)
                frames.append(blocks)
            })
        playback.receive(title: "제목", blocks: [.text("<p>번</p>")])
        await playback.finish(title: "제목", blocks: final)
        #expect(title == "제목")
        #expect(frames.last == final)
        #expect(frames.contains { blocks in
            if case .mixedText(let parts, _) = blocks.first,
               case .streamingMarkdown(_, let markdown, let complete) = parts.first {
                return !markdown.isEmpty && !complete
            }
            return false
        })
        #expect(frames.contains { blocks in
            if case .mixedText(let parts, _) = blocks.first,
               case .streamingMarkdown(_, _, let complete) = parts.first { return complete }
            return false
        })
        #expect(frames.allSatisfy { $0.last == originals[1] })
        playback.cancel()
    }

    @Test("A shorter retry preserves stable paragraphs; failure leaves source suffix")
    func retryAndFailure() async {
        let source: [HTMLContentBlock] = [.text("First"), .text("Second"), .text("Third")]
        let first = HTMLContentBlock.text("<p>하나</p>")
        let playbackResult = ResultBox()
        let playback = MarkdownTranslationPlayback(originals: source, baseURL: nil, settleDuration: 0,
            isCurrent: { true }, emitTitle: { _, _ in }, emitDocument: { playbackResult.blocks = $0 })
        playback.receive(title: "제목", blocks: [first, .text("<p>둘</p>")])
        playback.receive(title: "제", blocks: [.text("retry")])
        await playback.finishPartial()
        #expect(playbackResult.blocks.first == first)
        #expect(playbackResult.blocks.dropFirst() == source.dropFirst())
        playback.cancel()
    }

    @Test("An authoritative shorter document cannot leave a removed block waiting")
    func shorterFinalDocument() async throws {
        let result = ResultBox()
        let playback = MarkdownTranslationPlayback(originals: [.text("original")], baseURL: nil, settleDuration: 0,
            isCurrent: { true }, emitTitle: { _, _ in }, emitDocument: { result.blocks = $0 })
        playback.receive(title: "제목", blocks: [.text("<p>길게 도착 중인 본문</p>")])
        try await Task.sleep(for: .milliseconds(180))
        await playback.finish(title: "제목", blocks: [])
        playback.cancel()
    }

    @Test("Title guards and plain feed conversion preserve the original contract")
    func inputContracts() {
        #expect(NaturalTranslator.acceptsTitle("한국어 제목", source: "An English title"))
        #expect(!NaturalTranslator.acceptsTitle(" ", source: "Title"))
        #expect(!NaturalTranslator.acceptsTitle(String(repeating: "가", count: 121), source: "Title"))
        #expect(NativeArticleTranslator.plainBodyHTML([]) == nil)
        #expect(NativeArticleTranslator.plainBodyHTML(["a < b & c\nnext"]) == "<p>a &lt; b &amp; c<br>next</p>")
    }

    #if os(macOS)
    @Test("Every partial link prefix reveals only its label, never the destination syntax")
    func streamingLinkPrefixes() {
        let markdown = "[문서](<https://example.com/path>)"
        var previous = ""
        for length in 1...markdown.count {
            let rendered = StreamingMarkdownFormatter.attributed(String(markdown.prefix(length)), baseSize: 17)
            let visible = String(rendered.characters)
            #expect("문서".hasPrefix(visible))
            #expect(visible.count >= previous.count)
            #expect(visible.count <= previous.count + 1)
            previous = visible
        }
        #expect(previous == "문서")
        let complete = StreamingMarkdownFormatter.attributed("[문서](https://example.com) 다음", baseSize: 17)
        #expect(String(complete.characters) == "문서 다음")
        let code = StreamingMarkdownFormatter.attributed("`[array](value)`", baseSize: 17)
        #expect(String(code.characters) == "[array](value)")
    }

    @Test("Appending and correcting glyphs preserve the settled prefix and suffix")
    func arrivalHistory() {
        var history = TranslationArrivalHistory()
        history.update("차분하게 읽는 시간", at: 1)
        let before = history.starts
        history.update("편안하게 읽는 시간", at: 4)
        #expect(Array(history.starts.suffix(7)) == Array(before.suffix(7)))
        let revised = history.starts
        history.update("편안하게 읽는 시간입니다", at: 5)
        #expect(Array(history.starts.prefix(revised.count)) == revised)
        #expect(ReaderTranslationMotion.duration == 0.45)
        #expect(ReaderTranslationMotion.strength == 0.3)
    }
    #endif

    private final class ResultBox { var blocks: [HTMLContentBlock] = [] }
}
