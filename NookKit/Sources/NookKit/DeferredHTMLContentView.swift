import SwiftUI

/// Drop-in for `HTMLContentView` on transition-sensitive surfaces (the iOS
/// reader push): `HTMLContentView.init` parses the whole article synchronously
/// on a block-cache miss, which lands on the first frames of the push
/// animation for feed-original bodies. This wrapper instead renders the
/// article's plain paragraphs at the same type scale as the no-HTML fallback,
/// parses the HTML and warms the above-the-fold styled-text imports off the
/// transition, and then swaps in the styled blocks — mirroring what the store
/// already does for reader-mode extractions before flipping them `.ready`.
///
/// A warmed or revisited article is a synchronous cache hit and renders styled
/// on the very first frame, exactly as before.
public struct DeferredHTMLContentView: View {
    private let html: String
    private let baseURL: URL?
    private let placeholderParagraphs: [String]
    private let selectable: Bool
    private var translator: NativeArticleTranslator?
    @State private var blocksReady: Bool

    public init(
        html: String,
        baseURL: URL? = nil,
        placeholderParagraphs: [String],
        selectable: Bool = true,
        translator: NativeArticleTranslator? = nil
    ) {
        self.html = html
        self.baseURL = baseURL
        self.placeholderParagraphs = placeholderParagraphs
        self.selectable = selectable
        self.translator = translator
        // Cheap dictionary probe — no parse. True for warmed/revisited articles.
        _blocksReady = State(initialValue: HTMLBlockCache.shared.blocks(html: html, baseURL: baseURL) != nil)
    }

    public var body: some View {
        // An active translator indexes into the block array it was started
        // against; never swap arrays under it. (It only becomes active from a
        // user action well after the open, when the cache is already warm.)
        if blocksReady || translator?.isActive == true {
            HTMLContentView(html: html, baseURL: baseURL, selectable: selectable, translator: translator)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(placeholderParagraphs, id: \.self) { paragraph in
                    Text(paragraph)
                        .font(.body)
                        .lineSpacing(4)
                }
            }
            .task {
                let html = self.html
                let baseURL = self.baseURL
                // Give the push transition the same settle grace the extraction
                // path uses, running concurrently with the warm work.
                async let grace: Void = { try? await Task.sleep(for: .milliseconds(350)) }()
                await Task.detached(priority: .userInitiated) {
                    if HTMLBlockCache.shared.blocks(html: html, baseURL: baseURL) == nil {
                        HTMLBlockCache.shared.store(
                            HTMLContentParser.parse(html, baseURL: baseURL),
                            html: html, baseURL: baseURL
                        )
                    }
                }.value
                // Import the first screenful's styled text while the placeholder
                // shows, so the swap renders styled without an importer burst.
                await HTMLContentText.warmReaderAttributedCache(html: html, baseURL: baseURL, maxBlocks: 14)
                _ = await grace
                guard !Task.isCancelled else { return }
                blocksReady = true
            }
        }
    }
}
