#if os(macOS)
import AppKit
import CoreText

/// How one `ArticleListWindow.Change` reaches the AppKit article table.
///
/// The SwiftUI `List` rebuilt its table on a source switch and diffed the whole
/// window on every other publish. The table is told what changed instead, so a
/// switch is one `reloadData`, growth one `insertRows`, and an incremental
/// install only the rows that actually moved or changed.
public enum ArticleTableUpdate: Equatable {
    /// Everything: a new source.
    case reload
    /// Rows appended at the end (growth, `ensureVisible`).
    case insert(IndexSet)
    /// An incremental install: removals by old index, insertions by new index,
    /// then content reloads by new index. `animated` slides the moved rows.
    case apply(removed: IndexSet, inserted: IndexSet, reloaded: IndexSet, animated: Bool)
    /// Rows whose content changed in place, by index.
    case reloadRows(IndexSet)
    case none

    public static func plan(for change: ArticleListWindow.Change, rows: [ArticleRowModel]) -> ArticleTableUpdate {
        switch change {
        case .replaced:
            return .reload
        case .appended(let range):
            return range.isEmpty ? .none : .insert(IndexSet(integersIn: range))
        case .patched(let index):
            return index < rows.count ? .reloadRows(IndexSet(integer: index)) : .none
        case .installed(let previous, let animated):
            return plan(old: previous, new: rows, animated: animated)
        }
    }

    /// A diff of ids, then a model comparison for the rows both sides keep.
    /// Identical ids skip the diff: that is every flag change and body hydration.
    public static func plan(old: [ArticleRowModel], new: [ArticleRowModel], animated: Bool) -> ArticleTableUpdate {
        if old.count == new.count, zip(old, new).allSatisfy({ $0.id == $1.id }) {
            let changed = IndexSet(new.indices.filter { old[$0] != new[$0] })
            return changed.isEmpty ? .none : .reloadRows(changed)
        }
        let difference = new.map(\.id).difference(from: old.map(\.id))
        var removed = IndexSet()
        var inserted = IndexSet()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var oldByID: [Article.ID: ArticleRowModel] = [:]
        oldByID.reserveCapacity(old.count)
        for row in old { oldByID[row.id] = row }
        var reloaded = IndexSet()
        for (index, row) in new.enumerated() where !inserted.contains(index) {
            if let previous = oldByID[row.id], previous != row { reloaded.insert(index) }
        }
        if removed.isEmpty, inserted.isEmpty {
            return reloaded.isEmpty ? .none : .reloadRows(reloaded)
        }
        return .apply(removed: removed, inserted: inserted, reloaded: reloaded, animated: animated)
    }
}

/// The row the AppKit table selects to follow the store's selection.
public enum ArticleTableSelection {
    /// Only ever the store's own article: with no selection, or one the window
    /// does not hold, the table selects nothing, so no path auto-selects (78f5655).
    @MainActor
    public static func row(following selectedID: Article.ID?, in window: ArticleListWindow) -> Int? {
        selectedID.flatMap(window.rowIndex(of:))
    }
}

/// Row heights for the AppKit article table, known before a row is laid out.
///
/// The SwiftUI `List` let `NSTableView` size every row that came into view from
/// its hosting view's fitting size: a full SwiftUI layout of the row, about 2 ms
/// each, for every row a source switch shows. A row's height depends only on how
/// many lines its title and summary take (each is limited to two) and whether a
/// translated title shows under the title. The line counts come from each text's
/// one-line width, measured once per article and compared with the column width,
/// so a resize re-derives every height without measuring any text again. The
/// heights per line count are calibrated from the real row view (`Metrics`).
///
/// A displayed row reports its laid-out height back (`record`), which wins for
/// that row, width and content from then on: a script whose fallback font is
/// taller, or a streamed translation, corrects itself on the row's next layout.
@MainActor
public final class ArticleTableRowHeights {
    /// Row heights for each line count, measured from the real row.
    public struct Metrics: Equatable, Sendable {
        /// `rows[titleLines - 1][summaryLines]`: summary lines 0 (empty), 1, 2.
        public var rows: [[CGFloat]]
        /// Horizontal space the row takes outside its text column (unread dot and spacing).
        public var textInset: CGFloat
        /// Width taken from the title line by the star and the offline glyph, with spacing.
        public var starGlyph: CGFloat
        public var offlineGlyph: CGFloat
        /// A translated-title block: fixed part and per line.
        public var translationBase: CGFloat
        public var translationLine: CGFloat
        /// Width taken from the translated title's text by the block's padding and glyph.
        public var translationInset: CGFloat

        public init(rows: [[CGFloat]], textInset: CGFloat, starGlyph: CGFloat, offlineGlyph: CGFloat,
                    translationBase: CGFloat, translationLine: CGFloat, translationInset: CGFloat) {
            self.rows = rows
            self.textInset = textInset
            self.starGlyph = starGlyph
            self.offlineGlyph = offlineGlyph
            self.translationBase = translationBase
            self.translationLine = translationLine
            self.translationInset = translationInset
        }
    }

    /// One-line text widths, independent of the column width.
    struct TextWidths {
        let title: String
        let summary: String
        let isRead: Bool
        let titleWidth: CGFloat
        let titleBreaks: Bool
        let summaryWidth: CGFloat
        let summaryBreaks: Bool
    }

    /// Everything a reported height depends on.
    struct HeightKey: Equatable {
        let width: CGFloat
        let title: String
        let summary: String
        let isRead: Bool
        let isStarred: Bool
        let isSavedOffline: Bool
        let translation: String?
    }

    private let metricsProvider: @MainActor () -> Metrics
    private var resolvedMetrics: Metrics?
    private var widths: [Article.ID: TextWidths] = [:]
    private var measured: [Article.ID: (key: HeightKey, height: CGFloat)] = [:]
    private var translationWidths: [String: CGFloat] = [:]
    /// Title/summary fonts the widths were measured with: a different system font
    /// size (never expected on macOS) drops every cached width.
    private let titleRegular: NSFont
    private let titleUnread: NSFont
    private let summaryFont: NSFont
    private let translationFont: NSFont

    public init(metrics: @escaping @MainActor () -> Metrics) {
        metricsProvider = metrics
        let body = NSFont.preferredFont(forTextStyle: .body).pointSize
        let callout = NSFont.preferredFont(forTextStyle: .callout).pointSize
        titleRegular = .systemFont(ofSize: body, weight: .regular)
        titleUnread = .systemFont(ofSize: body, weight: .semibold)
        summaryFont = .systemFont(ofSize: callout, weight: .regular)
        translationFont = .systemFont(ofSize: callout, weight: .medium)
    }

    public var metrics: Metrics {
        if let resolvedMetrics { return resolvedMetrics }
        let metrics = metricsProvider()
        resolvedMetrics = metrics
        return metrics
    }

    /// The row's height in a column `width` wide. `translation` is the title
    /// translation the row shows, if any (`""` for a placeholder still translating).
    public func height(for model: ArticleRowModel, width: CGFloat, translation: String?) -> CGFloat {
        let key = HeightKey(width: width, title: model.title, summary: model.summary, isRead: model.isRead,
                            isStarred: model.isStarred, isSavedOffline: model.isSavedOffline,
                            translation: translation)
        if let entry = measured[model.id], entry.key == key { return entry.height }
        return estimate(for: model, width: width, translation: translation)
    }

    /// Records the height a displayed row laid out at. Returns whether it differs
    /// from what the table was told, so the caller re-queries that row.
    @discardableResult
    public func record(_ height: CGFloat, for model: ArticleRowModel, width: CGFloat, translation: String?) -> Bool {
        let key = HeightKey(width: width, title: model.title, summary: model.summary, isRead: model.isRead,
                            isStarred: model.isStarred, isSavedOffline: model.isSavedOffline,
                            translation: translation)
        let previous = measured[model.id].flatMap { $0.key == key ? $0.height : nil }
            ?? estimate(for: model, width: width, translation: translation)
        measured[model.id] = (key, height)
        return abs(previous - height) > 0.25
    }

    /// The estimate alone, ignoring any reported height.
    func estimate(for model: ArticleRowModel, width: CGFloat, translation: String?) -> CGFloat {
        let metrics = metrics
        let textWidth = max(1, width - metrics.textInset)
        let text = textWidths(for: model)
        var titleWidth = textWidth
        if model.isStarred { titleWidth -= metrics.starGlyph }
        if model.isSavedOffline { titleWidth -= metrics.offlineGlyph }
        let titleLines = text.titleBreaks || text.titleWidth > titleWidth ? 2 : 1
        let summaryLines = model.summary.isEmpty ? 0 : (text.summaryBreaks || text.summaryWidth > textWidth ? 2 : 1)
        var height = metrics.rows[titleLines - 1][summaryLines]
        if let translation {
            let available = textWidth - metrics.translationInset
            let lines = translation.isEmpty ? 1
                : (translation.contains(where: \.isNewline) || translationWidth(translation) > available ? 2 : 1)
            height += metrics.translationBase + CGFloat(lines) * metrics.translationLine
        }
        return height
    }

    /// Forgets every reported height (a toggle that changes what rows draw).
    public func forgetMeasured() { measured.removeAll() }

    var cachedWidthCount: Int { widths.count }

    private func textWidths(for model: ArticleRowModel) -> TextWidths {
        if let cached = widths[model.id], cached.title == model.title, cached.summary == model.summary,
           cached.isRead == model.isRead {
            return cached
        }
        let entry = TextWidths(
            title: model.title, summary: model.summary, isRead: model.isRead,
            titleWidth: Self.lineWidth(model.title, font: model.isRead ? titleRegular : titleUnread),
            titleBreaks: model.title.contains(where: \.isNewline),
            summaryWidth: Self.lineWidth(model.summary, font: summaryFont),
            summaryBreaks: model.summary.contains(where: \.isNewline))
        widths[model.id] = entry
        return entry
    }

    private func translationWidth(_ text: String) -> CGFloat {
        if let cached = translationWidths[text] { return cached }
        let width = Self.lineWidth(text, font: translationFont)
        if translationWidths.count > 4_000 { translationWidths.removeAll() }
        translationWidths[text] = width
        return width
    }

    /// The width the text takes on one unbroken line, rounded up to a whole point
    /// as SwiftUI's `Text` sizes itself: a title that fits by a fraction of a point
    /// still wraps there. (Checked against SwiftUI's own layout of the row over 300
    /// English, Korean and mixed titles at 70 widths: no line count differed.)
    nonisolated public static func lineWidth(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)).rounded(.up)
    }
}
#endif
