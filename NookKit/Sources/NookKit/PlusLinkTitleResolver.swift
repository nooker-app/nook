import Foundation

/// Best-effort metadata for a URL pasted into the composer.
///
/// This is deliberately separate from RSS fetching. A feed fetch may reasonably
/// wait and download a complete document; a paste must never hold typing hostage.
/// The address is already useful as the fallback label, so metadata gets one second
/// and a small byte budget.
actor PlusLinkTitleResolver {
    static let shared = PlusLinkTitleResolver()

    private struct Cached {
        var title: String
        var expiresAt: Date
    }

    private var cache: [URL: Cached] = [:]

    func title(for url: URL) async -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        if let cached = cache[url], cached.expiresAt > Date() {
            return cached.title
        }

        let result = await withTaskGroup(of: String?.self) { group in
            group.addTask { await Self.fetch(url) }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let result {
            cache[url] = Cached(title: result, expiresAt: Date().addingTimeInterval(60 * 30))
        }
        return result
    }

    private nonisolated static func fetch(_ url: URL) async -> String? {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 1)
        request.setValue("Nook Writer", forHTTPHeaderField: "User-Agent")
        // Cooperative servers avoid sending an image-heavy page in full. A server
        // may ignore Range, so the one-second task cancellation remains the hard cap.
        request.setValue("bytes=0-262143", forHTTPHeaderField: "Range")

        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            !Task.isCancelled,
            let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode)
        else { return nil }
        if let mime = http.mimeType?.lowercased(),
           !mime.contains("html") && !mime.contains("xhtml")
        {
            return nil
        }
        return extractTitle(from: Data(data.prefix(262_144)))
    }

    nonisolated static func extractTitle(from data: Data) -> String? {
        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        guard !html.isEmpty else { return nil }

        let patterns = [
            #"(?is)<meta[^>]+(?:property|name)\s*=\s*["']og:title["'][^>]+content\s*=\s*["']([^"']+)["'][^>]*>"#,
            #"(?is)<meta[^>]+content\s*=\s*["']([^"']+)["'][^>]+(?:property|name)\s*=\s*["']og:title["'][^>]*>"#,
            #"(?is)<title[^>]*>(.*?)</title>"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(
                    in: html, range: NSRange(location: 0, length: (html as NSString).length)),
                match.numberOfRanges > 1,
                let range = Range(match.range(at: 1), in: html)
            else { continue }
            let title = HTMLContentParser.decodeEntities(String(html[range]))
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return String(title.prefix(240))
            }
        }
        return nil
    }
}
