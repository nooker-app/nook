import Foundation
import Testing
@testable import NookKit

@Suite("Studio publication Markdown")
struct PlusMarkdownRendererTests {
    @Test("published Markdown expands nine TOC entries and six footnote round trips")
    func publishedPost() {
        // hello-nook's structure, with independently authored prose.
        let sections = (1...9).map { index in
            let heading = index == 6 || index == 9 ? "###" : "##"
            let reference = index <= 6 ? "[^\(index)]" : ""
            return "\(heading) 한글 목차 \(index)\n\n본문\(reference)입니다."
        }.joined(separator: "\n\n")
        let definitions = (1...6).map { "[^\($0)]: 각주 \($0)의 설명입니다." }.joined(separator: "\n")
        let html = PlusMarkdownRenderer.html(from: "[TOC]\n\n---\n\n\(sections)\n\n\(definitions)")
        let navigation = NookPostAnchorRepair.navigation(in: html)
        #expect(!html.contains("[TOC]"))
        #expect(!html.contains("[^"))
        #expect(html.contains("<sup"))
        #expect(navigation.links.count == 21)
        #expect(navigation.anchors.count == 21)
        #expect(navigation.isComplete)
        for index in 1...6 {
            #expect(navigation.anchors["fn-\(index)"]?.item == index - 1)
            #expect(navigation.anchors["fnref-\(index)"] != navigation.anchors["fn-\(index)"])
        }
    }

    @Test("repeated references and multi-paragraph notes keep distinct return targets")
    func repeatedFootnotes() {
        let html = PlusMarkdownRenderer.html(from: """
        First[^named].

        ## Second mention

        Second[^named].

        [^named]: First paragraph with **emphasis**.

            Second paragraph.

            - Nested list
            - Another item
        """)
        let navigation = NookPostAnchorRepair.navigation(in: html)
        #expect(navigation.links.count == 4)
        #expect(navigation.isComplete)
        #expect(navigation.anchors["fnref-named"] != navigation.anchors["fnref-named-2"])
        #expect(html.contains("<strong>emphasis</strong>"))
        #expect(html.contains("Second paragraph."))
        #expect(html.contains("<li>Nested list</li>"))
    }

    @Test("code, escaped markers, inline markers, and undefined notes stay literal")
    func literalExamples() {
        let html = PlusMarkdownRenderer.html(from: #"""
        `[TOC]` and `[^note]`

        \[TOC]

        An inline [TOC] marker and missing[^unknown].

        ```md
        [TOC]
        ## Not a heading
        [^note]: Not a definition
        ```

        ## A real heading
        """#)
        let navigation = NookPostAnchorRepair.navigation(in: html)
        #expect(navigation.links.isEmpty)
        #expect(navigation.anchors.keys.sorted() == ["a-real-heading"])
        #expect(html.contains("<code>[TOC]</code>"))
        #expect(html.contains("<p>[TOC]</p>"))
        #expect(html.contains("missing[^unknown]"))
        #expect(html.contains("[^note]: Not a definition"))
    }

    @Test("formatted and duplicate headings produce unique, resolvable anchors")
    func headings() {
        let html = PlusMarkdownRenderer.html(from: """
        [toc]

        ## **한글** & `code`
        ### Nested [link](https://example.com)
        ## Repeat
        ## Repeat
        ## Repeat-2

        Setext heading
        --------------

        ## fn-1

        Body[^1]. [Jump](#repeat).

        [^1]: A note.
        """)
        let navigation = NookPostAnchorRepair.navigation(in: html)
        #expect(navigation.isComplete)
        #expect(navigation.anchors.count == 9)
        #expect(navigation.anchors["repeat"] != navigation.anchors["repeat-2"])
        #expect(navigation.anchors["repeat-2-2"] != nil)
        #expect(navigation.anchors["heading-fn-1"] != navigation.anchors["fn-1"])
        #expect(html.contains("한글 &amp; code</a>"))
        #expect(html.contains("<strong>한글</strong> &amp; <code>code</code>"))
    }

    @Test("GFM, inline formatting and safe links survive the publication renderer")
    func richContent() {
        let html = PlusMarkdownRenderer.html(from: """
        | Heading | Value |
        | --- | --- |
        | One | Two |

        - [x] Done
        - [ ] Pending

        ~~old~~ **bold** <sup>2</sup> ![image](photo.png)

        [external](https://example.com) [unsafe](javascript:alert%281%29)

        ```swift
        let value = 1
        ```
        """)
        #expect(html.contains("<table>"))
        #expect(html.contains("<del>old</del>"))
        #expect(html.contains("<sup>2</sup>"))
        #expect(html.contains("src=\"photo.png\""))
        #expect(html.contains("href=\"https://example.com\""))
        #expect(!html.contains("javascript:"))
        #expect(html.contains("language-swift"))
        let parsed = HTMLContentParser.parseWithAnchors(html, baseURL: URL(string: "https://example.com/post"))
        #expect(parsed.blocks.contains { if case .table = $0 { return true }; return false })
        #expect(parsed.blocks.contains { if case .codeBlock = $0 { return true }; return false })
    }
}
