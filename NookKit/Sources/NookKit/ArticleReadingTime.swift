import Foundation

enum ArticleReadingTime {
    static func minutes(in text: String) -> Int? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Article.readingMinutes(for: [text])
    }

    /// Only for a reader's already extracted body, never the original webpage.
    static func minutes(inReaderHTML html: String) -> Int? {
        // Parsers can retain a related-stories aside next to the article. These
        // semantic chrome elements should not inflate the article's reading time.
        let inert = html.replacingOccurrences(of: #"(?is)<(script|style|template|head|nav|aside|header|footer|form|noscript|svg)\b[^>]*>.*?</\1\s*>"#,
                                             with: " ", options: .regularExpression)
        let text = inert.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return minutes(in: HTMLContentParser.decodeEntities(text))
    }
}

#if os(macOS)
import SwiftUI
import Combine

/// Keeps this one metadata label live when the original arrives, without
/// invalidating the magazine's rows or changing the synced RSS baseline.
public struct ArticleReadingTimeLabel: View {
    private let id: Article.ID
    private let article: Article?
    private let fallback: Int
    private let viewportBound: Bool
    private let compact: Bool
    @State private var resolvedID: Article.ID?
    @State private var url: URL?
    @State private var minutes: Int?
    @State private var revision = 0
    @Environment(\.magazinePreviewVisible) private var visible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(article: Article, viewportBound: Bool = false, compact: Bool = false) {
        id = article.id
        self.article = article
        fallback = article.estimatedReadMinutes
        self.viewportBound = viewportBound
        self.compact = compact
    }

    public init(id: Article.ID, fallback: Int) {
        self.id = id
        article = nil
        self.fallback = fallback
        viewportBound = false
        compact = false
    }

    private var active: Bool { !viewportBound || visible }
    private var value: Int { resolvedID == id ? (minutes ?? fallback) : fallback }
    private var taskID: String {
        "\(id)|\(article?.url.absoluteString ?? "")|\(article.flatMap { NookPostOrigin.isNookPost(articleID: $0.id) ? NookPostOrigin.fingerprint(of: $0) : nil } ?? "")|\(active)|\(revision)"
    }

    public var body: some View {
        Group {
            if compact { Text("\(value) min", bundle: .main) }
            else { Text("\(value) min read", bundle: .main) }
        }
        .contentTransition(.numericText())
        .task(id: taskID) {
            guard active, let current = article ?? ReaderStore.shared.listedArticle(withID: id) else { return }
            url = current.url
            let result = await ReaderStore.shared.cachedReadingMinutes(for: current)
            guard !Task.isCancelled else { return }
            withAnimation(viewportBound && !reduceMotion ? .easeOut(duration: 0.2) : nil) {
                resolvedID = id
                minutes = result
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ArticlePreviewCache.didChange).receive(on: RunLoop.main)) { notification in
            guard active, let changed = notification.object as? URL,
                  changed == (article?.url ?? url) else { return }
            revision &+= 1
        }
    }
}
#endif
