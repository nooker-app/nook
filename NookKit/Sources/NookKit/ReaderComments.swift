import Foundation

/// One comment from an article's page.
///
/// legibility extracts the discussion as data rather than as markup, and this is
/// that data narrowed to what the reader draws. Readability extracts no comments at
/// all, so a thread only ever comes from a legibility read.
public struct ReaderComment: Codable, Sendable, Equatable, Identifiable {
    /// Position in the thread, in document order. This is also what `parent` refers
    /// to, so it is the identity and not a separate one.
    public var id: Int
    /// The author as the page named them, or nil when it named nobody.
    public var author: String?
    /// The posted time, exactly as the document stated it — an ISO 8601 instant on a
    /// page that gave one, "3 hours ago" on a page that gave that, nil on a page
    /// that gave neither.
    ///
    /// Not parsed by the extractor, which has no clock. The reader parses it when it
    /// can and shows it verbatim when it cannot, because inventing a date is worse
    /// than showing an odd one.
    public var timestamp: String?
    /// How deep in the reply tree, 0 for a top-level comment.
    public var depth: Int
    /// The comment this one replies to, as an index into the thread's `items`, or
    /// nil for a top-level comment. Always less than `id`.
    public var parent: Int?
    /// A fragment or URL pointing at this comment on the original page.
    public var permalink: String?
    /// Removed by its author or a moderator. Kept anyway, with whatever text
    /// survived: dropping it would break the reply chain of everything under it,
    /// and a thread that cannot be reassembled is worse than one with a placeholder.
    public var isDeleted: Bool
    /// Prose only, for the case where the body could not be identified.
    public var text: String
    /// The body as sanitized markup. Stricter than an article body — images off,
    /// media dropped, `rel="nofollow noopener noreferrer"` forced on every link —
    /// because a comment is attacker-controlled in a way an article usually is not.
    public var html: String

    public init(
        id: Int, author: String? = nil, timestamp: String? = nil, depth: Int = 0,
        parent: Int? = nil, permalink: String? = nil, isDeleted: Bool = false,
        text: String = "", html: String = ""
    ) {
        self.id = id
        self.author = author
        self.timestamp = timestamp
        self.depth = depth
        self.parent = parent
        self.permalink = permalink
        self.isDeleted = isDeleted
        self.text = text
        self.html = html
    }

    /// The markup to render, or nil when there is nothing to show.
    ///
    /// A body still carrying a `<table>` falls back to plain text. Table markup in a
    /// comment is nearly always the forum's own layout rather than the comment's
    /// content — Hacker News nests one per reply — and the extraction already flattens
    /// it away on the page, where there is a DOM to do it in. This is the backstop for
    /// markup that flattening could not reach: a one-cell grid drawn around a comment
    /// is worse than the same words without their paragraphs.
    public var renderableHTML: String? {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !trimmed.localizedCaseInsensitiveContains("<table") {
            return html
        }
        let prose = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prose.isEmpty else { return nil }
        return "<p>\(Self.escaped(prose))</p>"
    }

    private static func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The timestamp as an instant, when the page stated one that is machine-readable.
    ///
    /// Parsed by the same reader that handles feed dates, which already knows the
    /// shapes the web actually uses — ISO 8601 with and without fractional seconds,
    /// RFC 822, and stamps missing a timezone. A page that wrote "3 hours ago" gets
    /// nil here and is shown verbatim instead.
    public var postedAt: Date? {
        guard let timestamp else { return nil }
        return FeedDateParser.date(from: timestamp)
    }

    enum CodingKeys: String, CodingKey {
        case id = "i"
        case author = "a"
        case timestamp = "t"
        case depth = "d"
        case parent = "p"
        case permalink = "l"
        case isDeleted = "x"
        case text = "s"
        case html = "h"
    }
}

/// An article page's discussion.
public struct ReaderCommentThread: Codable, Sendable, Equatable {
    /// The comments in document order, flat, each carrying its own `depth` and
    /// `parent`.
    ///
    /// Flat and not nested on purpose. Reply depth is attacker-controlled, so a
    /// nested model means a recursive consumer, and a hundred-thousand-deep reply
    /// chain is a stack overflow that cannot be caught. The same information walks
    /// iteratively here.
    public var items: [ReaderComment]
    /// How many the page had, which is not always how many are in `items`.
    public var count: Int
    /// What the page said about itself, when it said anything.
    public var claimedTotal: Int?
    /// The thread on screen is short of the page's. Worth telling the reader: you
    /// cannot extract what the markup does not contain, and Reddit ships a "load
    /// more" stub with the replies absent.
    public var isTruncated: Bool
    /// Whether the reply depths are real or a guess. `"Flat"` means the page carried
    /// no depth information at all, and indenting by a made-up number would be a
    /// claim about the conversation's shape that nothing supports.
    public var depthSource: String?

    public init(
        items: [ReaderComment], count: Int, claimedTotal: Int? = nil,
        isTruncated: Bool = false, depthSource: String? = nil
    ) {
        self.items = items
        self.count = count
        self.claimedTotal = claimedTotal
        self.isTruncated = isTruncated
        self.depthSource = depthSource
    }

    /// Nothing to draw.
    public var isEmpty: Bool { items.isEmpty }

    /// Whether replies should be drawn indented.
    public var showsDepth: Bool { depthSource != nil && depthSource != "Flat" }

    /// How many the reader is not being shown, whether because the page did not
    /// contain them or because the extraction stopped at its cap.
    public var missing: Int {
        max(0, (claimedTotal ?? count) - items.count)
    }

    enum CodingKeys: String, CodingKey {
        case items = "i"
        case count = "c"
        case claimedTotal = "n"
        case isTruncated = "t"
        case depthSource = "d"
    }
}
