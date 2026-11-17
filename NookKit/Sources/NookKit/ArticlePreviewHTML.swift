import Foundation

enum ArticlePreviewHTML {
    /// Prefer a publisher's cover, then real body images. Attribute order, lazy
    /// image URLs and relative URLs are common in both RSS and original pages.
    static func images(in html: String, baseURL: URL) -> [URL] {
        let tags = matches(#"<(?:meta|img)\b[^>]*>"#, in: html)
        var covers: [URL] = []
        var body: [URL] = []
        for tag in tags {
            let values = attributes(tag)
            if tag.lowercased().hasPrefix("<meta") {
                let property = (values["property"] ?? values["name"] ?? "").lowercased()
                if ["og:image", "og:image:secure_url", "twitter:image", "twitter:image:src"].contains(property),
                   let url = resolve(values["content"], baseURL: baseURL) { covers.append(url) }
            } else {
                if ["width", "height"].contains(where: { key in
                    values[key].flatMap(Int.init).map { $0 < 80 } ?? false
                }) { continue }
                let srcset = values["srcset"] ?? values["data-srcset"]
                let largest = srcset?.split(separator: ",").last?.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
                for candidate in [values["data-src"], values["data-lazy-src"], largest, values["src"]] {
                    if let url = resolve(candidate, baseURL: baseURL) {
                        body.append(url)
                        break
                    }
                }
            }
        }
        var seen = Set<URL>()
        return (covers + body).filter { seen.insert($0).inserted }.prefix(3).map { $0 }
    }

    static func resolve(_ value: String?, baseURL: URL) -> URL? {
        guard let value, let url = URL(string: entities(value).trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: baseURL)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func attributes(_ tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#) else { return [:] }
        let ns = tag as NSString
        var result: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            guard let group = (2...4).first(where: { match.range(at: $0).location != NSNotFound }) else { continue }
            result[ns.substring(with: match.range(at: 1)).lowercased()] = ns.substring(with: match.range(at: group))
        }
        return result
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    private static func entities(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-f]+|[0-9]+);"#, options: .caseInsensitive) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let digits = Range(match.range(at: 1), in: text), let range = Range(match.range, in: result) else { continue }
                let value = String(text[digits]).lowercased()
                if let number = UInt32(value.hasPrefix("x") ? String(value.dropFirst()) : value, radix: value.hasPrefix("x") ? 16 : 10),
                   let scalar = UnicodeScalar(number) { result.replaceSubrange(range, with: String(scalar)) }
            }
        }
        return result.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
