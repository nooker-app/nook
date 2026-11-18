import Foundation
import Observation
import Testing
@testable import NookKit

@Suite("Translation paragraph observation")
@MainActor
struct TranslationObservationTests {
    private final class Changes: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    @Test("A streamed paragraph does not invalidate document structure, header or sibling", arguments: [false, true])
    func isolatedPublication(markdown: Bool) throws {
        let translator = NativeArticleTranslator()
        let summary = HTMLContentBlock.text("<p>Preview</p>")
        let first = HTMLContentBlock.text("<p>First</p>")
        let second = HTMLContentBlock.text("<p>Second</p>")
        translator._installContentForTesting(summary: "Preview", blocks: [summary, first, second], markdown: markdown)
        let originalState = translator.bodyState(at: 0)
        let structure = Changes(), header = Changes(), sibling = Changes(), active = Changes()
        withObservationTracking {
            _ = translator.isActive
            _ = translator.markdownBodyRows
            _ = translator.bodyState(at: 0)
        } onChange: { structure.increment() }
        withObservationTracking { _ = translator.translatedSummaryBlock() } onChange: { header.increment() }
        withObservationTracking { _ = translator.bodyState(at: 1).block } onChange: { sibling.increment() }
        withObservationTracking { _ = originalState.block } onChange: { active.increment() }
        for text in ["번", "번역", "번역 중"] {
            translator._installContentForTesting(summary: "Preview", blocks: [summary, .text(text), second], markdown: markdown)
        }
        #expect(structure.count == 0)
        #expect(header.count == 0)
        #expect(sibling.count == 0)
        #expect(active.count == 1)
        #expect(translator.bodyState(at: 0) === originalState)
        #expect(originalState.block == .text("번역 중"))
    }

    @Test("A shorter final document removes stale rows; stopping clears retained states")
    func shrinkAndRestart() throws {
        let translator = NativeArticleTranslator()
        translator._installContentForTesting(summary: nil, blocks: [.text("one"), .text("two")], markdown: true)
        let first = translator.bodyState(at: 0), removed = translator.bodyState(at: 1)
        let structure = Changes()
        withObservationTracking { _ = translator.markdownBodyRows } onChange: { structure.increment() }
        translator._installContentForTesting(summary: nil, blocks: [.text("final")], markdown: true)
        #expect(structure.count == 1)
        #expect(translator.markdownBodyRows?.count == 1)
        #expect(removed.block == nil)
        #expect(translator.completedMarkdownBlocks() == [.text("final")])
        translator.stop()
        #expect(first.block == nil)
        #expect(translator.markdownBodyRows == nil)
        translator._installContentForTesting(summary: "preview", blocks: [.text("preview"), .text("next article")], markdown: false)
        #expect(translator.translatedSummaryBlock() == .text("preview"))
        #expect(translator.translatedBlock(at: 0) == .text("next article"))
        #expect(translator.completedMarkdownBlocks() == nil)
    }
    @Test("Streaming retains every paragraph while preserving rich block structure")
    func paragraphBoundaries() throws {
        let source = "Preview.\n\nFirst **body** paragraph.\n\nSecond [paragraph](https://example.com).\n\n## Heading\n\nThird paragraph.\n\nFourth paragraph."
        let blocks = try #require(MarkdownNativeParser.blocks(from: source, baseURL: nil,
            protectedBlocks: [:], separateLeadingParagraph: true, coalesceParagraphs: false))
        #expect(blocks.count == 6)
        #expect(blocks[0] == .text("<p>Preview.</p>"))
        #expect(blocks[1] == .text("<p>First <strong>body</strong> paragraph.</p>"))
        #expect(blocks[3] == .heading(level: 2, html: "Heading"))

    }

}
