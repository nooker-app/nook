import Foundation

/// Cross-line structure used by authoring features, kept independent of either text
/// system so iOS, macOS, tests, and the eventual publication renderer agree.
struct PlusMarkdownDocumentIndex: Sendable {
    struct Heading: Equatable, Sendable, Identifiable {
        var level: Int
        var title: String
        var range: NSRange
        var anchor: String
        var id: String { "\(range.location)-\(anchor)" }
    }

    struct FootnoteDefinition: Equatable, Sendable {
        var label: String
        var markerRange: NSRange
        var contentRange: NSRange
        var content: String
    }

    struct FootnoteReference: Equatable, Sendable {
        var label: String
        var range: NSRange
    }

    var headings: [Heading] = []
    var definitions: [FootnoteDefinition] = []
    var references: [FootnoteReference] = []
    var tocRanges: [NSRange] = []

    init(_ text: String) {
        let ns = text as NSString
        var insideFence = false
        var anchors: [String: Int] = [:]

        var cursor = 0
        while cursor < ns.length {
            let physicalLine = ns.lineRange(for: NSRange(location: cursor, length: 0))
            var lineRange = physicalLine
            while lineRange.length > 0 {
                let last = ns.character(at: lineRange.upperBound - 1)
                if last == 10 || last == 13 {
                    lineRange.length -= 1
                } else {
                    break
                }
            }
            let line = ns.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
            } else if !insideFence {
                if trimmed.caseInsensitiveCompare("[TOC]") == .orderedSame,
                   let marker = line.range(of: "[TOC]", options: .caseInsensitive)
                {
                    tocRanges.append(NSRange(marker, in: line).offset(by: lineRange.location))
                }

                if let heading = Self.heading(in: line, lineRange: lineRange) {
                    let base = Self.anchor(for: heading.title)
                    let count = anchors[base, default: 0]
                    anchors[base] = count + 1
                    headings.append(
                        Heading(
                            level: heading.level,
                            title: heading.title,
                            range: heading.range,
                            anchor: count == 0 ? base : "\(base)-\(count + 1)"))
                }

                if let definition = Self.definition(in: line, lineRange: lineRange) {
                    definitions.append(definition)
                }

                references.append(contentsOf: Self.references(in: line, lineRange: lineRange))
            }
            cursor = physicalLine.upperBound
        }
    }

    func definition(label: String) -> FootnoteDefinition? {
        definitions.first { $0.label == label }
    }

    var nextNumericFootnoteLabel: String {
        let used = definitions.compactMap { Int($0.label) } + references.compactMap { Int($0.label) }
        return String((used.max() ?? 0) + 1)
    }

    private static func heading(
        in line: String, lineRange: NSRange
    ) -> (level: Int, title: String, range: NSRange)? {
        guard
            let regex = try? NSRegularExpression(pattern: #"^(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*$"#),
            let match = regex.firstMatch(
                in: line, range: NSRange(location: 0, length: (line as NSString).length))
        else { return nil }
        let hashes = match.range(at: 1)
        let titleRange = match.range(at: 2)
        guard hashes.location != NSNotFound, titleRange.location != NSNotFound else { return nil }
        return (
            hashes.length,
            (line as NSString).substring(with: titleRange),
            titleRange.offset(by: lineRange.location))
    }

    private static func definition(
        in line: String, lineRange: NSRange
    ) -> FootnoteDefinition? {
        guard
            let regex = try? NSRegularExpression(
                pattern: #"^[ \t]{0,3}(?:[-+*][ \t]+)?\[\^([^\]\s]+)\]:[ \t]*(.*)$"#),
            let match = regex.firstMatch(
                in: line, range: NSRange(location: 0, length: (line as NSString).length))
        else { return nil }
        let labelRange = match.range(at: 1)
        let contentRange = match.range(at: 2)
        guard labelRange.location != NSNotFound, contentRange.location != NSNotFound else { return nil }
        let markerLength = contentRange.location
        return FootnoteDefinition(
            label: (line as NSString).substring(with: labelRange),
            markerRange: NSRange(location: lineRange.location, length: markerLength),
            contentRange: contentRange.offset(by: lineRange.location),
            content: (line as NSString).substring(with: contentRange))
    }

    private static func references(in line: String, lineRange: NSRange) -> [FootnoteReference] {
        guard let regex = try? NSRegularExpression(pattern: #"\[\^([^\]\s]+)\](?!:)"#) else {
            return []
        }
        let full = NSRange(location: 0, length: (line as NSString).length)
        return regex.matches(in: line, range: full).compactMap { match in
            let labelRange = match.range(at: 1)
            guard labelRange.location != NSNotFound else { return nil }
            return FootnoteReference(
                label: (line as NSString).substring(with: labelRange),
                range: match.range.offset(by: lineRange.location))
        }
    }

    private static func anchor(for title: String) -> String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let allowed = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(String(scalar))
            }
            return "-"
        }
        let collapsed = String(allowed)
            .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "section" : collapsed.lowercased()
    }
}

private extension NSRange {
    func offset(by amount: Int) -> NSRange {
        NSRange(location: location + amount, length: length)
    }
}
