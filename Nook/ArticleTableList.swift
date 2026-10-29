import AppKit
import NookKit
import SwiftUI

/// Which control draws the macOS article list. Read once at launch.
///
/// `table` (the default) is an AppKit `NSTableView` the app drives directly;
/// `list` is the SwiftUI `List` it replaced, kept so both can be measured and the
/// old one restored without a build: `defaults write com.tim.nook macListBackend list`,
/// or `-macListBackend list` as a launch argument (perf runs).
enum MacListBackend: String {
    case table
    case list

    static let defaultsKey = "macListBackend"
    static let current = MacListBackend(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .table
}

/// The article list column as an AppKit table.
///
/// The SwiftUI `List` rebuilt its whole `NSTableView` on every source switch and
/// let it size each visible row from a full SwiftUI layout of the row, about
/// 2 ms a row, so a switch cost a screenful of row layouts plus the rebuild
/// before the first frame. Here the table lives as long as the column: a switch
/// is `reloadData` into reused cells, heights are known before any row is laid
/// out (`ArticleTableRowHeights`), and `ArticleListWindow` tells the table what
/// changed instead of the table diffing its rows.
///
/// `selectedID` is passed in by the parent so that only a selection change, not
/// a rows change, runs `updateNSView`.
struct ArticleTableRows: NSViewRepresentable {
    let store: ReaderStore
    let titleTranslator: ListTitleTranslator
    let translatesTitles: Bool
    let selectedID: Article.ID?

    func makeCoordinator() -> ArticleTableController {
        ArticleTableController(store: store, translator: titleTranslator)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView(translatesTitles: translatesTitles)
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(translatesTitles: translatesTitles, selectedID: selectedID)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: ArticleTableController) {
        coordinator.dismantle()
    }
}

/// Data source, delegate and window observer of the article table.
@MainActor
final class ArticleTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    ArticleListWindowObserver {
    private let store: ReaderStore
    private let translator: ListTitleTranslator
    private let window: ArticleListWindow
    let tableView = ArticleTableView()
    let scrollView = NSScrollView()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("article"))
    private let heights = ArticleTableRowHeights(metrics: ArticleRowCalibration.measure)
    private var translatesTitles = false
    private var lastSelectedID: Article.ID?
    /// Set while the table's selection is changed to follow the store, so the
    /// change is not written back as if the user had made it.
    private var isFollowingStore = false
    private var columnWidth: CGFloat = 0
    private var pendingHeightIDs: Set<Article.ID> = []
    private var heightFlushTask: Task<Void, Never>?
    private var scrollObservers: [NSObjectProtocol] = []

    init(store: ReaderStore, translator: ListTitleTranslator) {
        self.store = store
        self.translator = translator
        self.window = store.listWindow
        super.init()
    }

    func makeScrollView(translatesTitles: Bool) -> NSScrollView {
        self.translatesTitles = translatesTitles
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.gridStyleMask = .solidHorizontalGridLineMask
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.usesAutomaticRowHeights = false
        tableView.rowSizeStyle = .custom
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.allowsTypeSelect = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onReturn = { [weak self] in self?.openSelectionInBrowser() ?? false }
        tableView.menuProvider = { [weak self] row in self?.menu(forRow: row) }
        tableView.setAccessibilityLabel(String(localized: "Articles"))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true

        // Same contract as iOS and the SwiftUI list: no title translation starts
        // mid-scroll, and the end of a scroll drains the queue.
        let center = NotificationCenter.default
        scrollObservers = [
            center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scrollView,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setScrolling(true) }
            },
            center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scrollView,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setScrolling(false) }
            },
        ]

        window.observer = self
        lastSelectedID = store.selectedArticleID
        reload()
        return scrollView
    }

    func update(translatesTitles: Bool, selectedID: Article.ID?) {
        if translatesTitles != self.translatesTitles {
            self.translatesTitles = translatesTitles
            // Every row swaps between the plain and the translating layout.
            heights.forgetMeasured()
            reload(scrollToTop: false)
        }
        if selectedID != lastSelectedID {
            lastSelectedID = selectedID
            followStoreSelection(scroll: true)
        }
    }

    func dismantle() {
        if window.observer === self { window.observer = nil }
        scrollObservers.forEach(NotificationCenter.default.removeObserver)
        scrollObservers = []
        heightFlushTask?.cancel()
        // A table removed mid-scroll never reports the scroll's end.
        translator.setScrolling(false)
    }

    private func setScrolling(_ scrolling: Bool) {
        #if DEBUG
        MainThreadLog.add("list.scroll.phase", ms: 0)
        #endif
        translator.setScrolling(scrolling)
    }

    // MARK: Window changes

    func articleListWindow(_ window: ArticleListWindow, didChange change: ArticleListWindow.Change) {
        switch change {
        case .installed(let previous, let animated):
            let rows = (0..<window.rowCount).map(window.row(at:))
            apply(ArticleTableUpdate.plan(old: previous, new: rows, animated: animated))
        case .replaced:
            apply(.reload)
        case .appended(let range):
            apply(range.isEmpty ? .none : .insert(IndexSet(integersIn: range)))
        case .patched(let index):
            apply(.reloadRows(IndexSet(integer: index)))
        }
    }

    private func apply(_ update: ArticleTableUpdate) {
        #if DEBUG
        let started = ProcessInfo.processInfo.systemUptime
        defer { MainThreadLog.add("list.table.update", ms: (ProcessInfo.processInfo.systemUptime - started) * 1000) }
        #endif
        switch update {
        case .none:
            return
        case .reload:
            reload()
            return
        case .insert(let rows):
            tableView.insertRows(at: rows, withAnimation: [])
        case .reloadRows(let rows):
            refresh(rows)
        case .apply(let removed, let inserted, let reloaded, let animated):
            // Only an interactive refresh's new rows slide in (`willAnimate`).
            tableView.beginUpdates()
            tableView.removeRows(at: removed, withAnimation: animated ? [.effectFade, .slideUp] : [])
            tableView.insertRows(at: inserted, withAnimation: animated ? [.effectFade, .slideDown] : [])
            tableView.endUpdates()
            refresh(reloaded)
        }
        followStoreSelection(scroll: false)
    }

    /// A new source: every row, from the top. The table and its cells stay.
    private func reload(scrollToTop: Bool = true) {
        #if DEBUG
        let started = ProcessInfo.processInfo.systemUptime
        defer { MainThreadLog.add("list.table.reload", ms: (ProcessInfo.processInfo.systemUptime - started) * 1000) }
        #endif
        pendingHeightIDs.removeAll()
        tableView.reloadData()
        let clip = scrollView.contentView
        let top = NSPoint(x: 0, y: -clip.contentInsets.top)
        // Updating the scrollers costs a few ms; most switches are already at the top.
        if scrollToTop, clip.bounds.origin != top {
            clip.scroll(to: top)
            scrollView.reflectScrolledClipView(clip)
        }
        followStoreSelection(scroll: false)
    }

    /// Content changes in place: the visible cells are reconfigured, the rest are
    /// configured when they are next shown; every changed row is re-measured.
    private func refresh(_ rows: IndexSet) {
        let valid = rows.filteredIndexSet { $0 < window.rowCount }
        guard !valid.isEmpty else { return }
        for row in valid {
            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ArticleTableCellView {
                configure(cell, row: row)
            }
        }
        tableView.noteHeightOfRows(withIndexesChanged: valid)
    }

    // MARK: Selection

    /// Puts the table's selection on the store's, never the other way round: no
    /// path here selects a row the store has not (78f5655).
    private func followStoreSelection(scroll: Bool) {
        let target = ArticleTableSelection.row(following: store.selectedArticleID, in: window)
        guard tableView.selectedRow != (target ?? -1) else { return }
        isFollowingStore = true
        defer { isFollowingStore = false }
        if let target {
            tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
            if scroll { tableView.scrollRowToVisible(target) }
        } else {
            tableView.deselectAll(nil)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isFollowingStore else { return }
        let row = tableView.selectedRow
        let id = row >= 0 && row < window.rowCount ? window.row(at: row).id : nil
        lastSelectedID = id
        if store.selectedArticleID != id { store.selectedArticleID = id }
    }

    private func openSelectionInBrowser() -> Bool {
        guard store.selectedArticle != nil else { return false }
        withAnimation(.easeInOut(duration: 0.3)) {
            store.isBrowserPresented = true
        }
        return true
    }

    // MARK: Rows

    func numberOfRows(in tableView: NSTableView) -> Int { window.rowCount }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        #if DEBUG
        let started = ProcessInfo.processInfo.systemUptime
        defer { MainThreadLog.add("list.table.height", ms: (ProcessInfo.processInfo.systemUptime - started) * 1000) }
        #endif
        guard row < window.rowCount else { return 1 }
        let model = window.row(at: row)
        return heights.height(for: model, width: column.width, translation: translation(for: model))
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < window.rowCount else { return nil }
        let cell: ArticleTableCellView
        if let reused = tableView.makeView(withIdentifier: ArticleTableCellView.reuseIdentifier, owner: nil)
            as? ArticleTableCellView {
            cell = reused
            #if DEBUG
            MainThreadLog.add("list.table.cell.reuse", ms: 0)
            #endif
        } else {
            cell = ArticleTableCellView(translator: translator)
            cell.identifier = ArticleTableCellView.reuseIdentifier
            #if DEBUG
            MainThreadLog.add("list.table.cell.make", ms: 0)
            #endif
        }
        cell.onHeight = { [weak self] cell, height in self?.cell(cell, reportedHeight: height) }
        configure(cell, row: row)
        return cell
    }

    private func configure(_ cell: ArticleTableCellView, row: Int) {
        #if DEBUG
        // The per-row configure, the table's counterpart of the List's per-row closure.
        MainThreadLog.add("list.rowcontent", ms: 0)
        #endif
        let model = window.row(at: row)
        // Handed to the row with its model, before its first body: the row never
        // interns a box itself, and a box released by a replacement is replaced
        // here when the row is next configured (187512d, c493abf).
        let box = translatesTitles ? translator.box(for: model.id, title: model.title) : nil
        cell.configure(model: model, box: box)
    }

    // Visibility, from the row views AppKit actually shows: the translator's
    // dwell, and growth when a row near the end of the window comes into view.
    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard let model = (rowView.view(atColumn: 0) as? ArticleTableCellView)?.model else { return }
        translator.rowAppeared(id: model.id, title: model.title)
        window.rowAppeared(id: model.id)
    }

    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        guard let model = (rowView.view(atColumn: 0) as? ArticleTableCellView)?.model else { return }
        translator.rowDisappeared(id: model.id)
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard abs(column.width - columnWidth) > 0.25 else { return }
        columnWidth = column.width
        // Heights per width are arithmetic over cached text widths, so this is
        // cheap even for a long window.
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<window.rowCount))
    }

    // MARK: Heights

    private func translation(for model: ArticleRowModel) -> String? {
        guard translatesTitles else { return nil }
        switch translator.displayedState(for: model.id, title: model.title) {
        case .translating(let partial, _): return partial
        case .translated(let final, _): return final
        case nil: return nil
        }
    }

    /// A displayed row's laid-out height. When it is not the height the table
    /// was given (a taller fallback font, a translation arriving or streaming),
    /// the row is re-queried — once per run-loop turn for all rows that changed,
    /// with their indexes resolved then, since growth and installs move them.
    private func cell(_ cell: ArticleTableCellView, reportedHeight height: CGFloat) {
        guard let model = cell.model, let row = window.rowIndex(of: model.id),
              tableView.view(atColumn: 0, row: row, makeIfNecessary: false) === cell else { return }
        let translation = translation(for: model)
        #if DEBUG
        let given = heights.height(for: model, width: column.width, translation: translation)
        #endif
        guard heights.record(height, for: model, width: column.width, translation: translation) else {
            return
        }
        #if DEBUG
        MainThreadLog.add("list.row.height", ms: 0)
        MainThreadLog.note("list.table.height.fix", extra: "row=\(row) given=\(given) laidOut=\(height) width=\(column.width) translated=\(translation != nil) titleChars=\(model.title.count) summaryChars=\(model.summary.count)")
        #endif
        pendingHeightIDs.insert(model.id)
        guard heightFlushTask == nil else { return }
        heightFlushTask = Task { @MainActor [weak self] in
            await Task.yield()
            self?.flushHeights()
        }
    }

    private func flushHeights() {
        heightFlushTask = nil
        let rows = IndexSet(pendingHeightIDs.compactMap(window.rowIndex(of:)))
        pendingHeightIDs.removeAll()
        guard !rows.isEmpty else { return }
        #if DEBUG
        MainThreadLog.addOncePerTurn("list.row.height.flush")
        #endif
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: rows)
        }
    }

    // MARK: Menu and swipe

    /// Built when the menu opens, for the row clicked, from the same view the
    /// SwiftUI list used: labels follow the article's current state.
    private func menu(forRow row: Int) -> NSMenu? {
        guard row >= 0, row < window.rowCount else { return nil }
        return NSHostingMenu(rootView: ArticleRowMenu(store: store, id: window.row(at: row).id))
    }

    func tableView(_ tableView: NSTableView, rowActionsForRow row: Int,
                   edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
        guard edge == .leading, row < window.rowCount else { return [] }
        #if DEBUG
        MainThreadLog.add("list.row.swipe", ms: 0)
        #endif
        let id = window.row(at: row).id
        let article = store.listedArticle(withID: id)
        let isRead = article?.isRead ?? false
        let isStarred = article?.isStarred ?? false
        let read = NSTableViewRowAction(
            style: .regular,
            title: isRead ? String(localized: "Mark as Unread") : String(localized: "Mark as Read")
        ) { [weak self] _, _ in
            self?.store.setRead(articleID: id, isRead: !isRead)
            self?.tableView.rowActionsVisible = false
        }
        read.image = NSImage(systemSymbolName: isRead ? "circle" : "checkmark.circle.fill", accessibilityDescription: nil)
        read.backgroundColor = .controlAccentColor
        let star = NSTableViewRowAction(
            style: .regular,
            title: isStarred ? String(localized: "Remove Star") : String(localized: "Star")
        ) { [weak self] _, _ in
            self?.store.toggleStarred(articleID: id)
            self?.tableView.rowActionsVisible = false
        }
        star.image = NSImage(systemSymbolName: isStarred ? "star.slash.fill" : "star.fill", accessibilityDescription: nil)
        star.backgroundColor = .systemYellow
        return [read, star]
    }
}

/// The article table: Return opens the selection in the browser, as the List's
/// `onKeyPress(.return)` did, and the context menu is built per clicked row.
final class ArticleTableView: NSTableView {
    var onReturn: (() -> Bool)?
    var menuProvider: ((Int) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if isReturn, modifiers.isEmpty, onReturn?() == true {
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        menu = row >= 0 ? menuProvider?(row) : nil
        // super records the clicked row, which draws the contextual outline.
        return super.menu(for: event)
    }
}

/// A reusable article cell: one hosting view whose root is replaced per row.
final class ArticleTableCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ArticleTableCell")

    private let translator: ListTitleTranslator
    private let host: NSHostingView<ArticleTableCellContent>
    private(set) var model: ArticleRowModel?
    private var box: ListTitleTranslator.StateBox?
    var onHeight: ((ArticleTableCellView, CGFloat) -> Void)?

    init(translator: ListTitleTranslator) {
        self.translator = translator
        host = NSHostingView(rootView: ArticleTableCellContent(
            model: nil, box: nil, translator: translator, emphasized: false, onHeight: { _ in }))
        super.init(frame: .zero)
        // The table sets the cell's size; the hosting view only fills it. Without
        // this it would publish its fitting size as constraints on every update.
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = bounds
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(model: ArticleRowModel, box: ListTitleTranslator.StateBox?) {
        self.model = model
        self.box = box
        render()
    }

    /// The selected row's text follows the selection highlight, as in the List.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if oldValue != backgroundStyle { render() } }
    }

    private func render() {
        guard let model else { return }
        let id = model.id
        host.rootView = ArticleTableCellContent(
            model: model, box: box, translator: translator, emphasized: backgroundStyle == .emphasized,
            onHeight: { [weak self] height in
                guard let self, self.model?.id == id else { return }
                self.onHeight?(self, height)
            })
    }
}

/// One table row's SwiftUI content: the List's row layout and insets, reporting
/// the height it lays out at so the table can correct an estimate it got wrong.
struct ArticleTableCellContent: View {
    let model: ArticleRowModel?
    let box: ListTitleTranslator.StateBox?
    let translator: ListTitleTranslator
    let emphasized: Bool
    let onHeight: (CGFloat) -> Void

    var body: some View {
        if let model {
            #if DEBUG
            let _ = MainThreadLog.add("list.row", ms: 0)
            #endif
            Group {
                if let box {
                    ArticleRowLayout(model: model) {
                        ListTitleTranslationSlot(title: model.title, box: box, translator: translator)
                    }
                } else {
                    ArticleRowLayout(model: model) { EmptyView() }
                }
            }
            // The List's row insets: 4 pt above and below the row's own padding.
            .padding(.vertical, ArticleRowCalibration.rowInset)
            // Natural height, whatever height the table gave the cell, so the
            // report below cannot feed back into itself.
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.backgroundProminence, emphasized ? .increased : .standard)
        }
    }
}

/// Measures the real row once, for the heights per line count.
@MainActor
enum ArticleRowCalibration {
    static let rowInset: CGFloat = 4

    static func measure() -> ArticleTableRowHeights.Metrics {
        #if DEBUG
        let started = ProcessInfo.processInfo.systemUptime
        defer { MainThreadLog.add("list.table.calibrate", ms: (ProcessInfo.processInfo.systemUptime - started) * 1000) }
        #endif
        let measuring = NSHostingController(rootView: AnyView(EmptyView()))
        func size(_ model: ArticleRowModel, width: CGFloat) -> CGSize {
            measuring.rootView = AnyView(ArticleRowLayout(model: model) { EmptyView() }.padding(.vertical, rowInset))
            return measuring.sizeThatFits(in: CGSize(width: width, height: 10_000))
        }
        func model(title: String, summary: String, starred: Bool = false, offline: Bool = false) -> ArticleRowModel {
            ArticleRowModel(id: "calibration", feedID: "calibration", title: title, summary: summary, isRead: false,
                            isStarred: starred, publishedAt: Date(), feedDisplayTitle: "W", readMinutes: 1,
                            categories: [], isSavedOffline: offline)
        }
        // A hard line break makes a second line at any width.
        let texts = ["W", "W\nW"]
        let rows = texts.map { title in
            ["", "W", "W\nW"].map { summary in size(model(title: title, summary: summary), width: 1_000).height }
        }
        // Widths from the row's own ideal size with one long title line: the
        // part that is not the title's text is the inset; a glyph adds its own.
        let long = String(repeating: "W", count: 60)
        let unbounded: CGFloat = .greatestFiniteMagnitude
        let plain = size(model(title: long, summary: ""), width: unbounded).width
        let starred = size(model(title: long, summary: "", starred: true), width: unbounded).width
        let offline = size(model(title: long, summary: "", offline: true), width: unbounded).width
        let titleWidth = ArticleTableRowHeights.lineWidth(long, font: ArticleRowTextWidths.titleUnread)
        let calloutLine = rows[0][2] - rows[0][1]
        let glyph = NSImage(systemSymbolName: "apple.intelligence", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: ArticleRowTextWidths.calloutSize, weight: .regular))?.size.width ?? 16
        return ArticleTableRowHeights.Metrics(
            rows: rows,
            textInset: plain - titleWidth,
            starGlyph: starred - plain,
            offlineGlyph: offline - plain,
            // ListTitleTranslationBlock: 4 pt above, 4 pt padding each side of
            // the text vertically, 8 pt horizontally, the glyph and 5 pt spacing.
            translationBase: 12,
            translationLine: calloutLine,
            translationInset: 16 + glyph.rounded(.up) + 5)
    }
}
