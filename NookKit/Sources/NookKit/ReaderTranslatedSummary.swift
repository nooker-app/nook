#if os(macOS)
import AppKit
import SwiftUI

/// The standfirst participates in the reader's own translation run. It shares
/// the title/body provider, cancellation and native character-ripple renderer.
public struct ReaderTranslatedSummary: View {
    let original: String
    let translator: NativeArticleTranslator?

    public init(original: String, translator: NativeArticleTranslator?) {
        self.original = original
        self.translator = translator
    }

    public var body: some View {
        Group {
            if let block = translator?.translatedSummaryBlock() {
                translated(block)
            } else {
                prose(original)
            }
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func translated(_ block: HTMLContentBlock) -> some View {
        switch block {
        case .text(let html):
            prose(HTMLContentText.plainText(html))
        case .mixedText(let parts, _):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .html(let html):
                        prose(HTMLContentText.plainText(html))
                    case .streaming(let source, let text, let complete):
                        ReaderStreamingText(original: source, text: text, complete: complete,
                                            baseSize: typography.bodySize, typography: typography)
                    case .streamingMarkdown(let source, let text, let complete):
                        ReaderStreamingText(original: source, text: text, complete: complete,
                                            baseSize: typography.bodySize, typography: typography, markdown: true)
                    }
                }
            }
        default:
            prose(original)
        }
    }

    private func prose(_ text: String) -> some View {
        // RSS previews are plain prose. Importing them as body HTML overrides
        // the header's secondary color and changes its type metrics on completion.
        Text(text).font(.system(size: typography.bodySize)).lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var typography: ReaderTypography {
        let size = NSFont.preferredFont(forTextStyle: .title3).pointSize
        return ReaderTypography(font: .system, fontSize: size, lineHeightMultiple: 1.2 + 3 / size, letterSpacingEM: 0)
    }
}
#endif
