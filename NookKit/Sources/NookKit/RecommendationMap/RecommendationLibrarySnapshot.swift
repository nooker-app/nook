#if os(macOS)
import Foundation

struct RecommendationLibrarySnapshot: Sendable {
    let scope: String
    var library: ReaderLibrary
    var originalIDs: Set<String> = []

    init(scope: String, library: ReaderLibrary, readerHTML: [String: String]) {
        self.scope = scope
        self.library = library
        for index in self.library.articles.indices {
            let id = self.library.articles[index].id
            guard let html = readerHTML[id] else { continue }
            let paragraphs = Self.paragraphs(html)
            guard !paragraphs.isEmpty else { continue }
            self.library.articles[index].bodyParagraphs = paragraphs
            originalIDs.insert(id)
        }
    }

    static func paragraphs(_ html: String) -> [String] {
        let inert = html.replacingOccurrences(of: #"(?is)<(script|style|template|head|nav|aside|header|footer|form|noscript|svg)\b[^>]*>.*?</\1\s*>"#,
                                              with: " ", options: .regularExpression)
        let blocks = inert.replacingOccurrences(of: #"(?i)</(?:p|div|h[1-6]|li|blockquote|section)>|<br\s*/?>"#,
                                                with: "\n", options: .regularExpression)
        let text = HTMLContentParser.decodeEntities(blocks.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression))
        return text.components(separatedBy: .newlines).map {
            $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }
}
#endif
