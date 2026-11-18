import Foundation
import Testing
@testable import NookKit

@Suite("Reader standfirst translation")
@MainActor
struct ReaderSummaryTranslationTests {
    @Test("The header and first body paragraph remain distinct on both native paths", arguments: [false, true])
    func summaryRouting(markdown: Bool) {
        let translator = NativeArticleTranslator()
        let preview = HTMLContentBlock.text("<p>번역된 미리보기</p>")
        let body = [HTMLContentBlock.heading(level: 2, html: "본문 제목"), .text("<p>첫 본문 문단</p>")]
        translator._installContentForTesting(summary: "Original preview", blocks: [preview] + body, markdown: markdown)
        #expect(translator.translatedSummaryBlock() == preview)
        if markdown { #expect(translator.completedMarkdownBlocks() == body) }
        else {
            #expect(translator.translatedBlock(at: 0) == body[0])
            #expect(translator.translatedBlock(at: 1) == body[1])
        }
        translator.stop()
        #expect(translator.translatedSummaryBlock() == nil)
        #expect(translator.completedMarkdownBlocks() == nil)
        #expect(translator.translatedBlock(at: 0) == nil)
    }

    @Test("An absent preview never consumes the first body block", arguments: [false, true])
    func noSummary(markdown: Bool) {
        let translator = NativeArticleTranslator()
        let first = HTMLContentBlock.text("<p>첫 문단</p>")
        translator._installContentForTesting(summary: " \n", blocks: [first], markdown: markdown)
        #expect(translator.translatedSummaryBlock() == nil)
        if markdown { #expect(translator.completedMarkdownBlocks() == [first]) }
        else { #expect(translator.translatedBlock(at: 0) == first) }
        translator.stop()
    }

    @Test("Preview input stays plain prose and changes the article cache identity")
    func inputAndCache() throws {
        #expect(NativeArticleTranslator.summaryBlock(nil) == nil)
        #expect(NativeArticleTranslator.summaryBlock(" \n") == nil)
        let summary = try #require(NativeArticleTranslator.summaryBlock("A < B & C"))
        #expect(summary == .text("<p>A &lt; B &amp; C</p>"))
        let body = [HTMLContentBlock.text("<p>Body</p>")]
        let withSummary = MarkdownTranslationTemplate(title: "Title", blocks: [summary] + body, baseURL: nil)
        let without = MarkdownTranslationTemplate(title: "Title", blocks: body, baseURL: nil)
        #expect(withSummary.sourceIdentity != without.sourceIdentity)
        #expect(withSummary.markerlessDocumentMarkdown.contains("A < B & C"))
    }

    @Test("Validation rejects a translation that merges the preview into the body")
    func mergedPreviewIsRejected() {
        let source = "# Reading\n\nA short preview.\n\nThe full article begins here."
        let separate = "# 읽기\n\n짧은 미리보기입니다.\n\n전체 글은 여기서 시작합니다."
        let merged = "# 읽기\n\n짧은 미리보기입니다. 전체 글은 여기서 시작합니다."
        #expect(MarkdownTranslationValidator.accepts(source: source, output: separate, language: "Korean"))
        #expect(!MarkdownTranslationValidator.accepts(source: source, output: merged, language: "Korean"))
    }

    @Test("Native Markdown keeps the standfirst separate while coalescing body prose")
    func nativeParagraphBoundary() throws {
        let markdown = "짧은 미리보기입니다.\n\n작성자 안내입니다.\n\n첫 본문 문단입니다.\n\n## 소제목"
        let blocks = try #require(MarkdownNativeParser.blocks(from: markdown, baseURL: nil,
            protectedBlocks: [:], separateLeadingParagraph: true))
        #expect(blocks.count == 3)
        #expect(blocks[0] == .text("<p>짧은 미리보기입니다.</p>"))
        #expect(blocks[1] == .text("<p>작성자 안내입니다.</p><p>첫 본문 문단입니다.</p>"))
        let translator = NativeArticleTranslator()
        translator._installContentForTesting(summary: "Original preview", blocks: blocks, markdown: true)
        #expect(translator.translatedSummaryBlock() == blocks[0])
        #expect(translator.completedMarkdownBlocks() == Array(blocks.dropFirst()))
        let ordinary = try #require(MarkdownNativeParser.blocks(from: markdown, baseURL: nil, protectedBlocks: [:]))
        #expect(ordinary.count == 2)
    }
}
