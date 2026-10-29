#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import NookKit

@Suite("AppKit article table model") @MainActor
struct ArticleTableModelTests {
    // These tests measure text off the main thread and turn prefill on for
    // every filter running meanwhile; the fonts must exist before that.
    init() { ArticleRowTextWidths.prepareFonts() }

    private func articles(_ count: Int, from start: Int = 0) -> [Article] {
        (start..<(start + count)).map { Fixture.article("row-\($0)", feedID: "a") }
    }

    private func models(_ articles: [Article]) -> [ArticleRowModel] {
        articles.map { ArticleRowModel($0, feedDisplayTitle: nil, isSavedOffline: false) }
    }

    private func install(_ articles: [Article], in window: ArticleListWindow, length: Int = 200,
                         replacement: Bool = true, animated: Bool = false) {
        window.install(full: articles,
            indexByID: Dictionary(uniqueKeysWithValues: articles.enumerated().map { ($0.element.id, $0.offset) }),
            rows: models(Array(articles.prefix(length))), replacement: replacement, animated: animated)
    }

    private final class Recorder: ArticleListWindowObserver {
        var updates: [ArticleTableUpdate] = []
        func articleListWindow(_ window: ArticleListWindow, didChange change: ArticleListWindow.Change) {
            updates.append(ArticleTableUpdate.plan(for: change, rows: (0..<window.rowCount).map(window.row(at:))))
        }
    }

    @Test("A replacement reloads, growth inserts the appended range, a patch reloads one row")
    func windowChangesMapToTableUpdates() async {
        let window = ArticleListWindow()
        let recorder = Recorder()
        window.observer = recorder
        let full = articles(1_000)
        install(full, in: window)
        #expect(recorder.updates == [.reload])

        window.requestGrowth()
        for _ in 0..<30 where window.rowCount == 200 { await Task.yield() }
        #expect(recorder.updates.last == .insert(IndexSet(integersIn: 200..<400)))

        window.ensureVisible(id: "row-700")
        #expect(recorder.updates.last == .insert(IndexSet(integersIn: 400..<750)))

        window.patch("row-3") { $0.isRead = true }
        #expect(recorder.updates.last == .reloadRows(IndexSet(integer: 3)))
        // Off-window patches never reach the table.
        let count = recorder.updates.count
        window.patch("row-900") { $0.isRead = true }
        #expect(recorder.updates.count == count)

        window.setSavedOffline("row-4", true)
        #expect(recorder.updates.last == .reloadRows(IndexSet(integer: 4)))
    }

    @Test("An incremental install inserts and removes only what moved, and reloads changed rows")
    func incrementalInstallDiffs() {
        let window = ArticleListWindow()
        let recorder = Recorder()
        window.observer = recorder
        let old = articles(10)
        install(old, in: window)
        // Three new articles on top, row-5 removed, row-2 read.
        var next = articles(3, from: 100) + old.filter { $0.id != "row-5" }
        next[5].isRead = true // row-2, now at index 5
        install(next, in: window, replacement: false, animated: true)
        #expect(recorder.updates.last == .apply(
            removed: IndexSet(integer: 5), inserted: IndexSet(integersIn: 0..<3),
            reloaded: IndexSet(integer: 5), animated: true))

        // Same ids, one flag: content reload only, nothing inserted or removed.
        var flagged = next
        flagged[0].isStarred = true
        install(flagged, in: window, replacement: false)
        #expect(recorder.updates.last == .reloadRows(IndexSet(integer: 0)))

        // No change at all.
        install(flagged, in: window, replacement: false)
        #expect(recorder.updates.last == ArticleTableUpdate.none)
    }

    @Test("A body-only change plans nothing: the model is what a row draws")
    func bodyHydrationPlansNothing() {
        var old = articles(5)
        var new = old
        new[2].bodyParagraphs = ["hydrated"]
        old[2].bodyParagraphs = []
        #expect(ArticleTableUpdate.plan(old: models(old), new: models(new), animated: false) == .none)
    }

    @Test("The table follows the store's selection and never selects on its own")
    func selectionNeverAutoSelects() async throws {
        let store = ReaderStore._makeForTesting()
        store.feeds = [Fixture.feed("a")]
        store.articles = articles(1_000)
        store.selectSmartSource(.all)
        for _ in 0..<200 where store.visibleArticles.count != 1_000 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let window = store.listWindow
        #expect(store.selectedArticleID == nil)
        #expect(ArticleTableSelection.row(following: store.selectedArticleID, in: window) == nil)

        // A deep selection grows the window to hold it, and the table follows.
        let deep = store.visibleArticles[900].id
        store.selectedArticleID = deep
        #expect(ArticleTableSelection.row(following: store.selectedArticleID, in: window) == 900)

        // A source switch that hides it clears it; nothing is selected instead.
        store.selectSmartSource(.starred)
        for _ in 0..<200 where store.selectedArticleID != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.selectedArticleID == nil)
        #expect(ArticleTableSelection.row(following: store.selectedArticleID, in: window) == nil)
        #expect(ArticleTableSelection.row(following: "missing", in: window) == nil)
    }

    private func metrics() -> ArticleTableRowHeights.Metrics {
        ArticleTableRowHeights.Metrics(rows: [[73, 74, 89], [89, 90, 105]], textInset: 18, starGlyph: 21,
                                       offlineGlyph: 20, translationBase: 12, translationLine: 15,
                                       translationInset: 36)
    }

    private func model(_ id: String, title: String, summary: String = "s", read: Bool = false,
                       starred: Bool = false, categories: [String] = []) -> ArticleRowModel {
        ArticleRowModel(id: id, feedID: "a", title: title, summary: summary, isRead: read, isStarred: starred,
                        publishedAt: Date(timeIntervalSince1970: 0), feedDisplayTitle: nil, readMinutes: 1,
                        categories: categories, isSavedOffline: false)
    }

    @Test("Heights follow line counts per width, from text widths measured once")
    func heightsPerWidth() {
        let widths = ArticleRowTextWidths()
        let heights = ArticleTableRowHeights(metrics: metrics, textWidths: widths)
        let font = ArticleRowTextWidths.titleUnread
        let title = "A title of some length"
        let titleWidth = ArticleTableRowHeights.lineWidth(title, font: font)
        let row = model("a", title: title)
        // Fits on one line exactly at its own width plus the inset, wraps one point narrower.
        #expect(heights.height(for: row, width: titleWidth + 18, translation: nil) == 74)
        #expect(heights.height(for: row, width: titleWidth + 17, translation: nil) == 90)
        // The star takes its glyph from the title line.
        let starred = model("b", title: title, starred: true)
        #expect(heights.height(for: starred, width: titleWidth + 18, translation: nil) == 90)
        #expect(heights.height(for: starred, width: titleWidth + 18 + 21, translation: nil) == 74)
        // Empty summary and hard line breaks.
        #expect(heights.height(for: model("c", title: "x", summary: ""), width: 400, translation: nil) == 73)
        #expect(heights.height(for: model("d", title: "x\ny", summary: "a\nb"), width: 400, translation: nil) == 105)
        // A shown translation adds its block; a placeholder counts one line.
        #expect(heights.height(for: model("e", title: "x"), width: 400, translation: "y") == CGFloat(101))
        #expect(heights.height(for: model("e", title: "x"), width: 400, translation: "") == CGFloat(101))
        #expect(widths.count == 5)
    }

    @Test("Prefilled widths are the ones the table would measure, and a changed title is re-measured")
    func prefillMatchesMeasuring() {
        let widths = ArticleRowTextWidths()
        let rows = (0..<100).map { model("row-\($0)", title: String(repeating: "Wide title ", count: $0 % 7 + 1),
                                         summary: String(repeating: "s", count: $0), read: $0.isMultiple(of: 2)) }
        widths.prefill(rows)
        #expect(widths.count == 100)
        for row in rows {
            let cached = widths.widths(for: row)
            let measured = ArticleRowTextWidths.measure(row)
            #expect(cached.titleWidth == measured.titleWidth && cached.summaryWidth == measured.summaryWidth)
        }
        let renamed = model("row-3", title: "Renamed")
        #expect(widths.widths(for: renamed).title == "Renamed")
        // Prefilling what is cached measures nothing new.
        widths.prefill(rows.prefix(10))
        #expect(widths.count == 100)
    }

    @Test("Growth measures the rows it is about to append before publishing them")
    func growthPrefillsWidths() async {
        ArticleRowTextWidths.prefillEnabled.store(true, ordering: .relaxed)
        defer { ArticleRowTextWidths.prefillEnabled.store(false, ordering: .relaxed) }
        let window = ArticleListWindow()
        let full = (0..<1_000).map { Fixture.article("prefill-\($0)", feedID: "a") }
        install(full, in: window)
        window.requestGrowth()
        for _ in 0..<200 where window.rowCount == 200 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(window.rowCount == 400)
        for index in 200..<400 {
            let row = window.row(at: index)
            #expect(ArticleRowTextWidths.shared.widths(for: row).titleWidth
                    == ArticleRowTextWidths.measure(row).titleWidth)
        }
        #expect(ArticleRowTextWidths.shared.count >= 200)
    }

    @Test("A reported height wins for its row and content, and any change to either drops it")
    func reportedHeightsInvalidate() {
        let heights = ArticleTableRowHeights(metrics: metrics, textWidths: ArticleRowTextWidths())
        let row = model("a", title: "x")
        #expect(heights.record(74, for: row, width: 400, translation: nil) == false)
        #expect(heights.record(80, for: row, width: 400, translation: nil) == true)
        #expect(heights.height(for: row, width: 400, translation: nil) == 80)
        // Same report again: nothing to re-query.
        #expect(heights.record(80, for: row, width: 400, translation: nil) == false)
        // A different width, translation or content falls back to the estimate.
        #expect(heights.height(for: row, width: 300, translation: nil) == 74)
        #expect(heights.height(for: row, width: 400, translation: "t") == CGFloat(101))
        #expect(heights.height(for: model("a", title: "x", read: true), width: 400, translation: nil) == 74)
        #expect(heights.height(for: model("a", title: "x\ny"), width: 400, translation: nil) == 90)
        // The cached text widths follow a title change instead of keeping the old one.
        #expect(heights.height(for: model("a", title: String(repeating: "W", count: 200)), width: 400,
                               translation: nil) == 90)
        heights.forgetMeasured()
        #expect(heights.height(for: row, width: 400, translation: nil) == 74)
    }

    @Test("The first row of a kind teaches every other row of it its sub-point height")
    func categoryChipsLearnTheirHeight() {
        let heights = ArticleTableRowHeights(metrics: metrics, textWidths: ArticleRowTextWidths())
        let first = model("a", title: "x", categories: ["c"])
        let second = model("b", title: "y", categories: ["c"])
        #expect(heights.height(for: second, width: 400, translation: nil) == 74)
        #expect(heights.record(73.5, for: first, width: 400, translation: nil) == true)
        #expect(heights.height(for: second, width: 400, translation: nil) == 73.5)
        // Untagged rows keep the calibrated height, and a wrong line count is not learned.
        #expect(heights.height(for: model("c", title: "z"), width: 400, translation: nil) == 74)
        heights.record(90, for: model("d", title: "w", categories: ["c"]), width: 400, translation: nil)
        #expect(heights.height(for: second, width: 400, translation: nil) == 73.5)
        // A translated row learns separately from an untranslated one.
        #expect(heights.height(for: second, width: 400, translation: "t") == CGFloat(101))
        heights.record(101.5, for: first, width: 400, translation: "t")
        #expect(heights.height(for: second, width: 400, translation: "t") == CGFloat(101.5))
        #expect(heights.height(for: second, width: 400, translation: nil) == 73.5)
        // Losing its chips is a different height: the reported one no longer applies.
        heights.record(73.5, for: first, width: 400, translation: nil)
        #expect(heights.height(for: model("a", title: "x"), width: 400, translation: nil) == 74)
    }
    // MARK: Selection sync against a real NSTableView

    private final class ScrollRecordingTable: NSTableView {
        var scrolledTo: [Int] = []
        override func scrollRowToVisible(_ row: Int) {
            scrolledTo.append(row)
            super.scrollRowToVisible(row)
        }
    }

    /// The controller's part that matters here: rows from the window, every
    /// window change applied through `mutate`, the table's selection changes
    /// handed to the sync.
    private final class TableHarness: NSObject, NSTableViewDataSource, NSTableViewDelegate,
        ArticleListWindowObserver {
        let window = ArticleListWindow()
        let table = ScrollRecordingTable()
        var storeSelection: Article.ID?
        var storeWrites: [Article.ID?] = []
        lazy var sync = ArticleTableSelectionSync(
            tableView: table, window: window,
            storeSelection: { [unowned self] in storeSelection },
            setStoreSelection: { [unowned self] in storeSelection = $0; storeWrites.append($0) })

        override init() {
            super.init()
            table.addTableColumn(NSTableColumn(identifier: .init("c")))
            table.dataSource = self
            table.delegate = self
            window.observer = self
        }

        func numberOfRows(in tableView: NSTableView) -> Int { window.rowCount }
        // View-based, as the app's table: only those insert and remove rows outside an update block.
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            NSTableCellView()
        }
        func tableViewSelectionDidChange(_ notification: Notification) { sync.tableSelectionDidChange() }

        func articleListWindow(_ window: ArticleListWindow, didChange change: ArticleListWindow.Change) {
            let update = ArticleTableUpdate.plan(for: change, rows: (0..<window.rowCount).map(window.row(at:)))
            sync.mutate {
                switch update {
                case .reload, .reloadRows: table.reloadData()
                case .insert(let rows): table.insertRows(at: rows, withAnimation: [])
                case .apply(let removed, let inserted, _, _):
                    table.beginUpdates()
                    table.removeRows(at: removed, withAnimation: [])
                    table.insertRows(at: inserted, withAnimation: [])
                    table.endUpdates()
                case .none: break
                }
            }
        }

        var selectedID: Article.ID? {
            table.selectedRow >= 0 ? window.row(at: table.selectedRow).id : nil
        }
    }

    @Test("A store selection that growth selected first is still scrolled into view")
    func growthSelectionScrolls() {
        let harness = TableHarness()
        install(articles(1_000), in: harness.window)
        // ⌘↓ past the window: the store selects, its didSet grows the window,
        // and growth selects the row before the view hears of the change.
        harness.storeSelection = "row-700"
        harness.window.ensureVisible(id: "row-700")
        #expect(harness.selectedID == "row-700")
        harness.sync.storeSelectionChanged(to: "row-700")
        #expect(harness.table.scrolledTo == [700])
        // Already shown: another pass does not scroll again.
        harness.sync.follow()
        #expect(harness.table.scrolledTo == [700])
        #expect(harness.storeWrites.isEmpty)
    }

    @Test("A deep link selected before its source installs is scrolled to once the row exists")
    func deepLinkSelectionScrollsAfterInstall() {
        let harness = TableHarness()
        install(articles(10, from: 500), in: harness.window)
        harness.storeSelection = "row-40"
        harness.sync.storeSelectionChanged(to: "row-40")
        #expect(harness.selectedID == nil)
        #expect(harness.table.scrolledTo.isEmpty)
        install(articles(1_000), in: harness.window)
        #expect(harness.selectedID == "row-40")
        #expect(harness.table.scrolledTo == [40])
        #expect(harness.storeWrites.isEmpty)
    }

    @Test("Table updates that drop the table's selection never clear the store's")
    func mutationsKeepStoreSelection() {
        let harness = TableHarness()
        let old = articles(300)
        install(old, in: harness.window, length: 300)
        harness.storeSelection = "row-5"
        harness.sync.storeSelectionChanged(to: "row-5")
        #expect(harness.selectedID == "row-5")
        // A refresh re-sorts the selected article to the top: remove + insert.
        let moved = [old[5]] + old.filter { $0.id != "row-5" }
        install(moved, in: harness.window, length: 300, replacement: false)
        #expect(harness.selectedID == "row-5")
        #expect(harness.table.selectedRow == 0)
        // A new source where the selection sits past the reloaded row count.
        harness.storeSelection = "row-250"
        harness.sync.storeSelectionChanged(to: "row-250")
        install(articles(100, from: 1_000) + [old[250]], in: harness.window, length: 101)
        #expect(harness.selectedID == "row-250")
        #expect(harness.storeWrites.isEmpty)
        // The user's own selection still reaches the store, without scrolling.
        let scrolls = harness.table.scrolledTo
        harness.table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        #expect(harness.storeWrites == ["row-1003"])
        harness.sync.storeSelectionChanged(to: "row-1003")
        #expect(harness.table.scrolledTo == scrolls)
    }

    @Test("Caches are bounded: reported heights and text widths keep only the current result past a limit")
    func cachesAreBounded() {
        let heights = ArticleTableRowHeights(metrics: metrics, textWidths: ArticleRowTextWidths())
        for index in 0...ArticleTableRowHeights.measuredLimit {
            heights.record(80, for: model("m-\(index)", title: "x"), width: 400, translation: nil)
        }
        heights.trim(keeping: { $0 == "m-1" })
        #expect(heights.measuredCount == 1)
        #expect(heights.height(for: model("m-1", title: "x"), width: 400, translation: nil) == 80)

        let widths = ArticleRowTextWidths()
        widths.prefill((0..<50).map { model("w-\($0)", title: "t") })
        widths.trim(keeping: ["w-0": 0], limit: 100)
        #expect(widths.count == 50)
        widths.trim(keeping: ["w-0": 0], limit: 10)
        #expect(widths.count == 1)
    }
}
#endif
