import SwiftUI

/// The page's discussion, drawn under the article in the native reader.
///
/// Native views rather than a block of injected markup. legibility hands the thread
/// over as data — author, time, depth, parent, and a sanitized body per item — so
/// there is no reason to flatten it back into HTML and re-parse it: the reply
/// structure survives, the article's own typography applies to the bodies, and none of
/// this reaches the Markdown export or the summarizer, both of which take the article
/// body alone.
///
/// Translation *is* shared. When the reader has the article translated, each comment
/// is translated too — same backend, same glossary, same terminology — and requested
/// only for the comments actually on screen.
public struct ReaderCommentsSection: View {
    private let thread: ReaderCommentThread
    private let baseURL: URL?
    private let typography: ReaderTypography
    /// Matches whatever the article body on this platform does — text selection on the
    /// Mac, and off on iOS, where the reader's own tap and long-press gestures own the
    /// body.
    private let selectable: Bool
    /// The reader's translator, when one is running. Comments follow the article: if it
    /// is translated, they are.
    private var translator: NativeArticleTranslator?
    /// The language the article is being translated into, for the requests this section
    /// makes.
    private let translationLanguage: String

    /// How many to draw before the "show the rest" button.
    ///
    /// Not politeness — measured. Comment rows are drawn eagerly (see
    /// `defersOffscreenBlocks` below), and mounting one costs a few milliseconds, so
    /// thirty of them put a synchronous layout on the frame that presents the
    /// article of which at most one row is on screen.
    ///
    /// Eight long comments cost 47ms now that a row is measured once (see
    /// `ReaderCommentRow.body`), and the rest is deferred rather than dropped —
    /// "Show N more" pays for it when it is actually asked for. Internal so
    /// `ReaderStore` warms exactly the rows that will be drawn.
    static let firstPage = 8

    @State private var showsAll = false

    public init(
        thread: ReaderCommentThread,
        baseURL: URL? = nil,
        typography: ReaderTypography = .platformDefault,
        selectable: Bool = true,
        translator: NativeArticleTranslator? = nil,
        translationLanguage: String = ""
    ) {
        self.thread = thread
        self.baseURL = baseURL
        self.typography = typography
        self.selectable = selectable
        self.translator = translator
        self.translationLanguage = translationLanguage
    }

    private var visible: [ReaderComment] {
        showsAll ? thread.items : Array(thread.items.prefix(Self.firstPage))
    }

    private var hidden: Int { max(0, thread.items.count - visible.count) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ForEach(visible) { comment in
                ReaderCommentRow(
                    comment: comment,
                    depth: thread.showsDepth ? comment.depth : 0,
                    baseURL: baseURL,
                    typography: typography,
                    selectable: selectable,
                    // Deliberately not handed the translator itself: its block
                    // overrides address the *article's* blocks by index, so a comment
                    // asking for "block 0" would be given the article's first
                    // paragraph. The translated body, resolved here, is what it needs.
                    translatedHTML: translator?.translatedComment(id: comment.id))
            }

            if hidden > 0 {
                Button {
                    showsAll = true
                } label: {
                    Text("Show \(hidden) more", bundle: .module)
                }
                .buttonStyle(.bordered)
                .padding(.top, 14)
            }

            if thread.missing > 0 {
                // Said plainly, because the alternative is implying the conversation
                // ends here. A page that loads its replies on scroll, or paginates
                // them, simply does not contain the rest — there is nothing to extract.
                //
                // Two sentences rather than one inflected key: automatic grammar
                // agreement would need plural variations in a catalog whose other three
                // languages have no plural forms at all.
                (thread.missing == 1
                    ? Text("One more comment is on the original page.", bundle: .module)
                    : Text("\(thread.missing) more comments are on the original page.", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Re-runs when a translation run starts or stops, and when the reader reveals
        // more of the thread — so the requests track what is actually being read
        // instead of spending a model call on every reply nobody has looked at.
        .task(id: translationRequestKey) { requestTranslations() }
    }

    private var translationRequestKey: String {
        guard let translator, translator.isActive else { return "off" }
        return "\(translator.run)|\(visible.count)"
    }

    private func requestTranslations() {
        guard let translator, translator.isActive, !translationLanguage.isEmpty else { return }
        for comment in visible {
            translator.requestCommentTranslation(comment, into: translationLanguage)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Comments", bundle: .module)
                .font(.headline)
            Text(thread.claimedTotal ?? thread.count, format: .number)
                .font(.headline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.bottom, 6)
    }
}

/// One comment: who, when, and the body, indented to its place in the thread.
private struct ReaderCommentRow: View {
    let comment: ReaderComment
    let depth: Int
    let baseURL: URL?
    let typography: ReaderTypography
    let selectable: Bool
    /// The translated body, once it has arrived. Until then the original is shown, the
    /// same way the article's paragraphs stay put until theirs land.
    let translatedHTML: String?

    /// Indentation stops after a few levels. A deep chain would otherwise squeeze the
    /// text into a column too narrow to read, and the rule on the left already says
    /// "this is a reply" — the exact number is not what a reader is looking for.
    private static let maxIndentedDepth = 5
    private static let indentStep: CGFloat = 14

    private var indent: CGFloat { CGFloat(min(depth, Self.maxIndentedDepth)) * Self.indentStep }

    var body: some View {
        // The reply rule is an overlay over a padded row, not a sibling in an
        // `HStack`, for the same reason a list marker is: an `HStack` holding a
        // fixed-width child beside a flexible one measures the flexible child's whole
        // subtree several times to resolve its width, and here that subtree is a
        // comment body. Measured, laying out the thread the reader draws:
        //
        //                        HStack   overlay
        //     4 comments          35.0ms   17.6ms
        //     8 comments          68.8ms   33.5ms
        //     8 long comments    127.5ms   47.0ms
        //
        // Less than half, at pixel-identical output. Worth having because this cost
        // lands on the frame that presents the article, where the reader is already
        // scrolling.
        VStack(alignment: .leading, spacing: 4) {
            byline
            body(for: comment)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, depth > 0 ? indent : 0)
        .overlay(alignment: .leading) {
            if depth > 0 {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 2)
                    .padding(.leading, indent - Self.indentStep)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private var byline: some View {
        HStack(spacing: 6) {
            if let author = comment.author, !author.isEmpty {
                Text(author)
                    .font(.caption.weight(.semibold))
            } else {
                Text("Someone", bundle: .module)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let posted = comment.postedAt {
                // A parsed instant gets the same relative wording as the rest of the
                // app, and ticks with it.
                RelativeTimeText(posted)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let stamp = comment.timestamp, !stamp.isEmpty {
                // The page wrote something a clock cannot read — "3 hours ago", or a
                // format nobody standardized. Shown as it was written, because the
                // alternative is inventing a time.
                Text(stamp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func body(for comment: ReaderComment) -> some View {
        if comment.isDeleted, comment.renderableHTML == nil {
            // Kept as a placeholder rather than removed: everything replying to it
            // hangs off this node, and a thread that cannot be reassembled reads worse
            // than one with a gap in it.
            Text("Deleted", bundle: .module)
                .font(.callout.italic())
                .foregroundStyle(.tertiary)
        } else if let html = translatedHTML ?? comment.renderableHTML {
            // The reader's own typography, so a comment reads at the size they chose.
            //
            // `defersOffscreenBlocks: false` because thirty of these share the
            // reader's scroll view. Lazily, each one's height was an estimate until
            // its rows materialized, so the scroll view's content height moved on
            // every scroll and it clamped the offset back — the thread dragged itself
            // upward and its last comments could not be reached.
            HTMLContentView(
                html: html, baseURL: baseURL, selectable: selectable, typography: typography,
                defersOffscreenBlocks: false)
        }
    }
}
