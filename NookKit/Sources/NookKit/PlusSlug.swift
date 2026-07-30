import Foundation

/// The web address of a post: derived from the title, validated against what the
/// service accepts, and defaulted when a title yields nothing.
///
/// A word on why an address exists at all. On Bluesky it does not: a post is
/// identified by its record key, a timestamp-ordered identifier the server mints,
/// and nothing in the URL comes from what was written. AT Protocol blogging
/// services do the same, putting the record key in the path. Nook keeps a
/// human-readable address because a link to an essay reads better with words in it,
/// and it serves the record-key form too, so a link never breaks when an address
/// changes.
///
/// The cost of that choice is this file. A title in Korean, Japanese, or Chinese
/// yields no address at all, and the writer should not be asked to invent one in a
/// script they were not writing in. So a date is used instead.
enum PlusSlug {
    static let maximumLength = 60

    /// Why an address cannot be used. The rules mirror the service's, so anything
    /// this accepts the service accepts too.
    enum Problem: Equatable, Sendable {
        case empty
        case tooLong
        /// Anything outside lowercase ASCII letters, digits, and hyphens.
        case unsupportedCharacters
        case hyphenAtEdge

        var message: String {
            switch self {
            case .empty:
                String(localized: "An address is needed. One is suggested from your title.", bundle: .module)
            case .tooLong:
                String(localized: "At most 60 characters.", bundle: .module)
            case .unsupportedCharacters:
                String(
                    localized:
                        "Use lowercase English letters, numbers, and hyphens. This is part of a web address, so it cannot contain Korean, Japanese, Chinese, spaces, or accented letters.",
                    bundle: .module
                )
            case .hyphenAtEdge:
                String(localized: "Cannot start or end with a hyphen.", bundle: .module)
            }
        }
    }

    /// The first thing wrong with an address, or nil when it is usable.
    static func problem(with slug: String) -> Problem? {
        let slug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        if slug.isEmpty { return .empty }
        if slug.utf8.count > maximumLength { return .tooLong }
        for scalar in slug.unicodeScalars {
            switch scalar {
            case "a"..."z", "0"..."9", "-": continue
            default: return .unsupportedCharacters
            }
        }
        if slug.hasPrefix("-") || slug.hasSuffix("-") { return .hyphenAtEdge }
        return nil
    }

    static func isUsable(_ slug: String) -> Bool { problem(with: slug) == nil }

    /// Turns a title into an address, or returns an empty string when it cannot.
    ///
    /// A title with no ASCII yields nothing rather than a transliteration: a
    /// machine's reading of someone's words does not belong in their permanent URL.
    /// Callers pair this with `dated(_:avoiding:)` for that case.
    static func derive(from title: String) -> String {
        var out = ""
        var pendingHyphen = false

        for scalar in title.lowercased().unicodeScalars {
            switch scalar {
            case "a"..."z", "0"..."9":
                let separator = pendingHyphen && !out.isEmpty
                // Checked before appending, not after. Measuring the result of an
                // append can only discover that the limit was already passed.
                if out.utf8.count + (separator ? 2 : 1) > maximumLength { return out }
                if separator { out.append("-") }
                pendingHyphen = false
                out.unicodeScalars.append(scalar)
            default:
                pendingHyphen = true
            }
        }
        return out
    }

    /// A date-based address, avoiding any already in use.
    ///
    /// The default when a title yields nothing. A date is not as good as words, but
    /// it is honest, readable, and sorts — and it is far better than asking someone
    /// writing in Korean to name their post again in English.
    ///
    /// `existing` is the addresses already published, so a second post on the same
    /// day does not collide with the first.
    static func dated(_ date: Date, avoiding existing: Set<String>, calendar: Calendar = .current)
        -> String
    {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            return "post"
        }
        let base = String(format: "%04d-%02d-%02d", year, month, day)
        if !existing.contains(base) { return base }

        // Counts up rather than appending a random suffix: the second post of a day
        // should be "-2", which somebody reading the URL can make sense of.
        var suffix = 2
        while existing.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }
}
