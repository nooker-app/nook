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

/// Content extraction is independent of ranks/read flags. Keep the last parsed
/// original on this worker so a new feed batch does not reparse the whole vault.
actor RecommendationSnapshotBuilder {
    private struct Entry {
        let html: String
        let paragraphs: [String]
        let bytes: Int
    }
    private var scope: String?
    private var cache: [String: Entry] = [:]
    private(set) var parsedDocuments = 0

    func snapshot(scope: String, library: ReaderLibrary,
                  readerHTML: [String: String]) throws -> RecommendationLibrarySnapshot {
        try Task.checkCancellation()
        if self.scope != scope { cache.removeAll(); self.scope = scope }
        var result = RecommendationLibrarySnapshot(scope: scope, library: library, readerHTML: [:])
        var retained: [String: Entry] = [:]
        var bytes = 0
        for index in result.library.articles.indices {
            try Task.checkCancellation()
            let id = result.library.articles[index].id
            guard let html = readerHTML[id] else { continue }
            let entry: Entry
            if let existing = cache[id], existing.html == html {
                entry = existing
            } else {
                let paragraphs = RecommendationLibrarySnapshot.paragraphs(html)
                entry = Entry(html: html, paragraphs: paragraphs,
                    bytes: html.utf8.count + paragraphs.reduce(0) { $0 + $1.utf8.count })
                parsedDocuments += 1
            }
            if !entry.paragraphs.isEmpty {
                result.library.articles[index].bodyParagraphs = entry.paragraphs
                result.originalIDs.insert(id)
            }
            if retained.count < 2048, entry.bytes <= 32 * 1024 * 1024 - bytes {
                retained[id] = entry
                bytes += entry.bytes
            }
        }
        try Task.checkCancellation()
        // Deletions, removed originals and library switches cannot retain stale
        // text. A cancelled partial pass never replaces the completed cache.
        cache = retained
        return result
    }
}
#endif
