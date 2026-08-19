import Foundation

/// Which engine turns an article page into reader content.
///
/// Two engines ship, and both are real choices rather than an old one kept for
/// safety. They fail on different pages, which is the whole reason the reader
/// lets you swap them without leaving the article:
///
/// - `legibility` is Nook's own extractor. Every decision it makes is relative
///   to the page, so a twenty-word note and a link post come out as content
///   instead of "no article found" — Readability's absolute length floor rejects
///   both. It also refuses to synthesize a title or a date it did not find.
/// - `readability` is Mozilla's, and keeps the video and CodePen embeds that
///   legibility's sanitizer drops. On an article that *is* a video, it is the
///   one that works.
public enum ReaderParserEngine: String, CaseIterable, Identifiable, Codable, Sendable {
    case legibility
    case readability

    public var id: String { rawValue }

    /// Where the per-device choice lives. Per-device on purpose: the engines
    /// differ by what a person reads, and a phone and a Mac may reasonably
    /// disagree.
    public static let storageKey = "readerParserEngine"

    /// The engine to use when nothing has been chosen.
    public static let fallback = ReaderParserEngine.legibility

    /// The engine this device is set to. Read through `UserDefaults` rather than
    /// `@AppStorage` so non-view code (`ReaderStore`, the extractor) sees the
    /// same value without owning a SwiftUI property wrapper.
    public static var preferred: ReaderParserEngine {
        UserDefaults.standard.string(forKey: storageKey)
            .flatMap(ReaderParserEngine.init(rawValue:)) ?? fallback
    }

    /// The one the reader's switch flips to.
    public var other: ReaderParserEngine {
        self == .legibility ? .readability : .legibility
    }

    /// The engine's name. Deliberately the real name in every language: it is a
    /// proper noun, and a reader who wants to know which extractor produced a
    /// page is not helped by a translated euphemism.
    public var label: String {
        switch self {
        case .legibility: "Legibility"
        case .readability: "Readability"
        }
    }

    /// One line for a picker footer or a menu subtitle — what choosing this
    /// engine gets you, not how it works.
    public var summary: String {
        switch self {
        case .legibility:
            String(localized: "Nook's own extractor. Reads short posts and link posts that Readability skips, and never invents a title or date.", bundle: Bundle.module)
        case .readability:
            String(localized: "Mozilla's extractor. Keeps embedded videos and CodePen examples, which Legibility drops.", bundle: Bundle.module)
        }
    }

    /// The SF Symbol the reader uses for this engine, so the switch reads as a
    /// change of instrument rather than a change of mode.
    public var symbolName: String {
        switch self {
        case .legibility: "text.magnifyingglass"
        case .readability: "doc.text.magnifyingglass"
        }
    }
}
