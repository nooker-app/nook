import Foundation
import Testing

@testable import NookKit

@Suite("Nook Plus Markdown document index")
struct PlusMarkdownDocumentTests {
    @Test("headings produce stable Korean and duplicate anchors")
    func headings() {
        let index = PlusMarkdownDocumentIndex(
            "# 시작\n\n## 만들게 된 이유\n\n## 만들게 된 이유")
        #expect(index.headings.map(\.level) == [1, 2, 2])
        #expect(index.headings.map(\.anchor) == ["시작", "만들게-된-이유", "만들게-된-이유-2"])
    }

    @Test("TOC and footnotes are indexed outside code fences")
    func extensions() {
        let source = """
            [TOC]

            A reference[^1].

            [^1]: A real definition.

            ```
            [TOC]
            [^2]: code
            ```
            """
        let index = PlusMarkdownDocumentIndex(source)
        #expect(index.tocRanges.count == 1)
        #expect(index.references.map(\.label) == ["1"])
        #expect(index.definitions.map(\.label) == ["1"])
        #expect(index.definition(label: "1")?.content == "A real definition.")
        #expect(index.nextNumericFootnoteLabel == "2")
    }

    @Test("a pasted list-prefixed definition remains source-backed")
    func listPrefixedDefinition() throws {
        let source = "- [^1]: 붙여넣은 각주 내용을 그대로 보여줍니다."
        let definition = try #require(
            PlusMarkdownDocumentIndex(source).definition(label: "1"))
        #expect(definition.content == "붙여넣은 각주 내용을 그대로 보여줍니다.")
        #expect((source as NSString).substring(with: definition.contentRange) == definition.content)
        #expect((source as NSString).substring(with: definition.markerRange) == "- [^1]: ")
    }

    @Test("HTML title metadata prefers Open Graph and decodes entities")
    func titleMetadata() {
        let html = """
            <html><head>
            <title>Fallback</title>
            <meta property="og:title" content="Tom &amp; Jerry">
            </head></html>
            """
        #expect(
            PlusLinkTitleResolver.extractTitle(from: Data(html.utf8))
                == "Tom & Jerry")
    }
}
