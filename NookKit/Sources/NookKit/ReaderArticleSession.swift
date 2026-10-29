import Foundation
import Observation

/// The reader's per-article state — translation, summary, detected language — kept
/// together with the article it belongs to.
///
/// The macOS reader updates in place when the article changes instead of being built
/// again, so its `@State` outlives the article. Reset alone does not cover that: the
/// reset runs in a task or `onChange`, after the new article's first body, and that
/// body read the old article's translated title, translated blocks and summary. Here
/// every read names the article it is for and gets nothing when the state still
/// belongs to another one, so the first frame of the new article is clean before
/// `begin(articleID:)` runs. Work that finishes late — the plain-body translation —
/// is tagged with the run that started it and dropped when it no longer matches.
@MainActor
@Observable
public final class ReaderArticleSession {
    /// The article this state belongs to; nil until the reader binds one.
    public private(set) var articleID: String?

    /// Streams the in-place translation of rich (HTML) articles.
    public let translator = NativeArticleTranslator()
    /// The AI summary card's state.
    public let summary = ArticleSummaryController()

    private var detectedLanguage: String?
    private var isShowingSystemTranslation = false

    // Plain-body articles (no HTML) translate the whole body once.
    private var plainTitle: String?
    private var plainParagraphs: [String]?
    private var isPlainShown = false
    private var isPlainTranslating = false
    private var plainTask: Task<Void, Never>?
    /// Bumped by every plain-body run and every article change, so a run that
    /// returns after either cannot write into the state it no longer owns.
    private var plainRun = 0

    public init() {}

    /// Binds the state to `articleID`, clearing everything that belonged to the
    /// previous article. A no-op for the article already bound.
    ///
    /// - Returns: whether the article changed (and the state was cleared).
    @discardableResult
    public func begin(articleID: String) -> Bool {
        guard articleID != self.articleID else { return false }
        self.articleID = articleID
        translator.stop()
        summary.reset()
        plainTask?.cancel()
        plainTask = nil
        plainRun &+= 1
        // Guarded like `NativeArticleTranslator.stop()`: Observation publishes on
        // every set, and most article changes have nothing to clear.
        if plainTitle != nil { plainTitle = nil }
        if plainParagraphs != nil { plainParagraphs = nil }
        if isPlainShown { isPlainShown = false }
        if isPlainTranslating { isPlainTranslating = false }
        if detectedLanguage != nil { detectedLanguage = nil }
        if isShowingSystemTranslation { isShowingSystemTranslation = false }
        return true
    }

    public func isCurrent(_ articleID: String) -> Bool {
        articleID == self.articleID
    }

    /// The translator, only while it belongs to `articleID`.
    public func translator(for articleID: String) -> NativeArticleTranslator? {
        isCurrent(articleID) ? translator : nil
    }

    /// The summary state, only while it belongs to `articleID`.
    public func summary(for articleID: String) -> ArticleSummaryController? {
        isCurrent(articleID) ? summary : nil
    }

    public func detectedLanguage(for articleID: String) -> String? {
        isCurrent(articleID) ? detectedLanguage : nil
    }

    /// Records the detected language, unless the reader has moved on.
    public func setDetectedLanguage(_ language: String?, for articleID: String) {
        guard isCurrent(articleID) else { return }
        detectedLanguage = language
    }

    /// Whether the system Translation overlay is up for `articleID`.
    public func isShowingSystemTranslation(for articleID: String) -> Bool {
        isCurrent(articleID) && isShowingSystemTranslation
    }

    public func setShowingSystemTranslation(_ showing: Bool, for articleID: String) {
        guard isCurrent(articleID) else { return }
        isShowingSystemTranslation = showing
    }

    /// Whether any translation for `articleID` is in flight.
    public func isTranslating(for articleID: String) -> Bool {
        isCurrent(articleID) && (translator.isTranslating || isPlainTranslating)
    }

    // MARK: - Plain-body translation

    public struct PlainTranslation: Equatable, Sendable {
        public let title: String
        public let paragraphs: [String]
    }

    /// The plain-body translation, when it is for `articleID` and showing.
    public func plainTranslation(for articleID: String) -> PlainTranslation? {
        guard isCurrent(articleID), isPlainShown, let plainTitle, let plainParagraphs else { return nil }
        return PlainTranslation(title: plainTitle, paragraphs: plainParagraphs)
    }

    /// Whether `articleID` already has a plain-body translation, shown or not.
    public func hasPlainTranslation(for articleID: String) -> Bool {
        isCurrent(articleID) && plainParagraphs != nil
    }

    /// Shows or hides the finished plain-body translation.
    public func setPlainTranslationShown(_ shown: Bool, for articleID: String) {
        guard isCurrent(articleID), plainParagraphs != nil else { return }
        isPlainShown = shown
    }

    /// Translates a plain-body article's title, then its body, with `translate`.
    ///
    /// The result lands only if `articleID` is still the bound article and no later
    /// run replaced this one. A length guard keeps an "answered" imperative title
    /// from replacing the real one.
    public func translatePlainBody(
        articleID: String,
        title: String,
        paragraphs: [String],
        translate: @escaping @Sendable (String) async throws -> String
    ) {
        guard isCurrent(articleID) else { return }
        plainTask?.cancel()
        plainRun &+= 1
        let run = plainRun
        isPlainTranslating = true
        let body = paragraphs.joined(separator: "\n\n")
        plainTask = Task { [weak self] in
            let titleText = try? await translate(title)
            let bodyText: String? = titleText == nil ? nil : try? await translate(body)
            guard let self, self.plainRun == run else { return }
            self.plainTask = nil
            self.isPlainTranslating = false
            guard let titleText, let bodyText else { return }
            let cleanedTitle = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
            self.plainTitle = cleanedTitle.count <= max(120, title.count * 4) ? cleanedTitle : title
            self.plainParagraphs = bodyText
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            self.isPlainShown = true
        }
    }
}
