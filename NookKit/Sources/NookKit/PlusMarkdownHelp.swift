import SwiftUI

/// The syntax contract of the composer, close to the place it is used.
///
/// Static examples keep help free from the live editor's parse loop. They also make
/// Nook's two extensions explicit instead of letting `[TOC]` or footnotes look like
/// accidental Markdown that may work differently elsewhere.
struct PlusMarkdownHelpView: View {
    struct Example: Identifiable {
        enum Kind {
            case heading, bold, italic, strikethrough, inlineCode, link
            case list, numberedList, quote, code, table, thematicBreak
            case paragraphBreak, lineBreak, tableOfContents, footnote
        }

        var id: String { title }
        var title: String
        var explanation: String
        var source: String
        var kind: Kind
        var nookExtension = false
    }

    let insert: (Example.Kind) -> Void
    @Environment(\.dismiss) private var dismiss

    private let examples: [Example] = [
        .init(
            title: String(localized: "Heading", bundle: .module),
            explanation: String(localized: "Use one to six # markers followed by a space.", bundle: .module),
            source: "## Section title", kind: .heading),
        .init(
            title: String(localized: "Bold", bundle: .module),
            explanation: String(localized: "Wrap important text in two asterisks.", bundle: .module),
            source: "**important**", kind: .bold),
        .init(
            title: String(localized: "Italic", bundle: .module),
            explanation: String(localized: "Wrap emphasized text in one asterisk.", bundle: .module),
            source: "*emphasis*", kind: .italic),
        .init(
            title: String(localized: "Strikethrough", bundle: .module),
            explanation: String(localized: "Wrap removed text in two tildes.", bundle: .module),
            source: "~~removed~~", kind: .strikethrough),
        .init(
            title: String(localized: "Inline code", bundle: .module),
            explanation: String(localized: "Wrap a short code fragment in backticks.", bundle: .module),
            source: "`value`", kind: .inlineCode),
        .init(
            title: String(localized: "Link", bundle: .module),
            explanation: String(localized: "Paste a URL over selected text, or use the link button.", bundle: .module),
            source: "[Nook](https://example.com)", kind: .link),
        .init(
            title: String(localized: "List", bundle: .module),
            explanation: String(localized: "Start each item with a dash and a space.", bundle: .module),
            source: "- First\n- Second", kind: .list),
        .init(
            title: String(localized: "Numbered list", bundle: .module),
            explanation: String(localized: "Start each item with a number, period, and space.", bundle: .module),
            source: "1. First\n2. Second", kind: .numberedList),
        .init(
            title: String(localized: "Quote", bundle: .module),
            explanation: String(localized: "Start a quoted line with > and a space.", bundle: .module),
            source: "> A careful quotation", kind: .quote),
        .init(
            title: String(localized: "Code block", bundle: .module),
            explanation: String(localized: "Put fenced code on lines of its own.", bundle: .module),
            source: "```swift\nlet value = 1\n```", kind: .code),
        .init(
            title: String(localized: "Table", bundle: .module),
            explanation: String(localized: "Separate columns with pipes and add a delimiter row.", bundle: .module),
            source: "| Name | Value |\n| --- | --- |\n| Nook | Plus |", kind: .table),
        .init(
            title: String(localized: "Thematic break", bundle: .module),
            explanation: String(localized: "Put three dashes on a line of their own.", bundle: .module),
            source: "---", kind: .thematicBreak),
        .init(
            title: String(localized: "New paragraph", bundle: .module),
            explanation: String(localized: "Return inserts the blank line that separates Markdown paragraphs.", bundle: .module),
            source: "First paragraph\n\nSecond paragraph", kind: .paragraphBreak),
        .init(
            title: String(localized: "Line break", bundle: .module),
            explanation: String(localized: "Shift-Return keeps the next line in the same paragraph.", bundle: .module),
            source: "First line\\\nSecond line", kind: .lineBreak),
        .init(
            title: String(localized: "Table of contents", bundle: .module),
            explanation: String(localized: "A line containing [TOC] is replaced by links to the post's headings.", bundle: .module),
            source: "[TOC]", kind: .tableOfContents, nookExtension: true),
        .init(
            title: String(localized: "Footnote", bundle: .module),
            explanation: String(localized: "References use [^1]. Definitions use [^1]: without a list dash.", bundle: .module),
            source: "A claim[^1]\n\n[^1]: Its supporting note.", kind: .footnote),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(examples) { example in
                        exampleCard(example)
                    }
                }
                .padding(20)
            }
            .background(PlusTheme.canvas.ignoresSafeArea())
            .navigationTitle(Text("Markdown help", bundle: .module))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("Done", bundle: .module) }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 620, minHeight: 640)
        #endif
    }

    private func exampleCard(_ example: Example) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(verbatim: example.title)
                    .font(.headline)
                if example.nookExtension {
                    Text("Nook extension", bundle: .module)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PlusTheme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(PlusTheme.accent.opacity(0.12), in: Capsule())
                }
                Spacer()
                Button {
                    insert(example.kind)
                } label: {
                    Text("Insert", bundle: .module)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Text(verbatim: example.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(verbatim: example.source)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(PlusTheme.hairline.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(14)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
