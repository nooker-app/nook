import Foundation

/// Old Legibility bodies kept fragment links but discarded every target. A Nook
/// post's complete RSS body is already local, so repair only that known defect,
/// without expiring successes globally or requiring the saved article's website.
enum NookPostAnchorRepair {
    @MainActor
    static func repair(
        _ cachedHTML: String,
        for article: Article,
        extract: (String) async -> ReaderModeExtractor.Outcome?
    ) async -> String? {
        let source = await Task.detached(priority: .userInitiated) {
            Self.source(for: article, cachedHTML: cachedHTML)
        }.value
        guard let source, !Task.isCancelled,
              case .success(let result) = await extract(source),
              !result.fellBack, !Task.isCancelled else { return nil }
        let restored = await Task.detached(priority: .userInitiated) {
            let original = navigation(in: source)
            let replacement = navigation(in: result.html)
            // Losing links altogether must not look like repairing them. Keep the
            // existing body unless every local reference has a real destination.
            return replacement.links.count >= original.links.count
                && replacement.isComplete
        }.value
        return restored && !Task.isCancelled ? result.html : nil
    }

    static func source(for article: Article, cachedHTML: String) -> String? {
        guard NookPostOrigin.isNookPost(articleID: article.id),
              let html = article.contentHTML else { return nil }
        let cached = navigation(in: cachedHTML)
        guard !cached.links.isEmpty, cached.anchors.isEmpty else { return nil }
        let original = navigation(in: html)
        guard !original.links.isEmpty, original.isComplete else { return nil }
        return "<html><body><article>\(html)</article></body></html>"
    }

    struct Navigation {
        let links: [String]
        let anchors: [String: AnchorTarget]

        var isComplete: Bool {
            !links.isEmpty && links.allSatisfy { anchorTarget(for: $0, in: anchors) != nil }
        }
    }

    /// This inspects serialized feed/extractor HTML, not raw Markdown or page
    /// scripts. The native parser supplies the destinations the UI can actually
    /// reach; an ID on an element the renderer drops cannot count as restored.
    static func navigation(in html: String) -> Navigation {
        let pattern = ##"(?is)<a\b[^>]*?\s+href\s*=\s*(?:"#([^"]+)"|'#([^']+)')"##
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(html.startIndex..., in: html)
        let links = regex.matches(in: html, range: range).compactMap { match -> String? in
            let capture = match.range(at: 1).location == NSNotFound ? 2 : 1
            guard let range = Range(match.range(at: capture), in: html) else { return nil }
            return HTMLContentParser.decodeEntities(String(html[range]))
        }
        return Navigation(links: links, anchors: HTMLContentParser.parseWithAnchors(html, baseURL: nil).anchors)
    }
}
