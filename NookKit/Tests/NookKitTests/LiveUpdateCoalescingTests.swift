#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import NookKit

/// Live updates landing while the list scrolls: AI category batches, title
/// translations and the row heights they change.
@Suite("Live list updates are coalesced") @MainActor
struct LiveUpdateCoalescingTests {
    private final class ChangeRecorder: ArticleListWindowObserver {
        var changes: [ArticleListWindow.Change] = []
        func articleListWindow(_ window: ArticleListWindow, didChange change: ArticleListWindow.Change) {
            changes.append(change)
        }
    }

    private func makeStore(count: Int) -> (ReaderStore, [ArticleCategory]) {
        let store = ReaderStore._makeForTesting()
        store.feeds = [Fixture.feed("a")]
        store.articles = (0..<count).map { Fixture.article(String(format: "article-%03d", $0), feedID: "a", isRead: $0 % 4 == 0) }
        let first = store.addCategory(name: "One")
        let second = store.addCategory(name: "Two")
        store.selectSmartSource(.all)
        return (store, [first, second])
    }

    @Test("A batch of AI category assignments is one in-place patch: no refilter, exact counts")
    func categoryBatchPatchesInPlace() {
        let (store, categories) = makeStore(count: 60)
        let recorder = ChangeRecorder()
        store.listWindow.observer = recorder
        let filters = store.filterExecutionCount
        var batch: [Article.ID: [String]] = [:]
        for index in 0..<25 {
            batch[String(format: "article-%03d", index)] = index % 3 == 0
                ? [categories[0].id, categories[1].id] : [categories[index % 2].id]
        }
        store._applyCategoryAssignmentsForTesting(batch)

        #expect(store.filterExecutionCount == filters, "a badge batch must not refilter the list")
        #expect(recorder.changes.count == 1)
        if case .patched(let rows)? = recorder.changes.first {
            #expect(rows.count == 25)
        } else {
            Issue.record("expected one batched patch, got \(recorder.changes)")
        }
        for (id, cats) in batch {
            #expect(store.visibleArticles.first { $0.id == id }?.categories == cats)
            #expect(store.article(withID: id)?.categories == cats)
        }
        #expect(store.unreadByCategory == store._recountedUnreadByCategoryForTesting())

        // Re-tagging moves counts between categories exactly as a full pass would.
        store._applyCategoryAssignmentsForTesting(["article-001": [categories[1].id], "article-002": []])
        #expect(store.unreadByCategory == store._recountedUnreadByCategoryForTesting())
        // An unchanged assignment publishes nothing.
        recorder.changes.removeAll()
        store._applyCategoryAssignmentsForTesting(["article-001": [categories[1].id]])
        #expect(recorder.changes.isEmpty)
    }

    @Test("When categories decide membership the batch still refilters")
    func categoryListRefilters() async throws {
        let (store, categories) = makeStore(count: 20)
        store.selectCategory(categories[0].id)
        #expect(store.visibleArticles.isEmpty)
        store._applyCategoryAssignmentsForTesting(["article-003": [categories[0].id]])
        // Wait for the publication, not a timer racing the main actor while
        // other suites run. Keep the wait bounded so a missing refilter fails.
        for _ in 0..<300 where store.visibleArticles.map(\.id) != ["article-003"] {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.visibleArticles.map(\.id) == ["article-003"])

        // A hidden category hides its articles from every list.
        store.selectSmartSource(.all)
        var hidden = categories[1]
        hidden.hidden = true
        store.updateCategory(hidden)
        let before = store.visibleArticles.count
        store._applyCategoryAssignmentsForTesting(["article-005": [hidden.id]])
        for _ in 0..<300 where store.visibleArticles.contains(where: { $0.id == "article-005" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.visibleArticles.count == before - 1)
        #expect(!store.visibleArticles.contains { $0.id == "article-005" })
    }

    @Test("Fast clip-view motion holds translation; slow reading scroll does not; it settles")
    func motionGate() {
        var gate = ScrollMotionGate(fastThreshold: 600, settleDelay: 0.15)
        var time = 0.0
        var y = 0.0
        let still = gate.record(y: y, at: time)
        #expect(!still)
        // 1500 pt/s at 60 Hz.
        for _ in 0..<10 {
            time += 1.0 / 60; y += 25
            let fast = gate.record(y: y, at: time)
            #expect(fast)
        }
        #expect(gate.isFast(at: time + 0.1))
        #expect(!gate.isFast(at: time + 0.2), "stopping settles after the delay")
        // 120 pt/s reading scroll is never fast.
        var slow = ScrollMotionGate(fastThreshold: 600, settleDelay: 0.15)
        time = 10; y = 0
        slow.record(y: y, at: time)
        for _ in 0..<60 {
            time += 1.0 / 60; y += 2
            let fast = slow.record(y: y, at: time)
            #expect(!fast)
        }
        #expect(slow.movedRecently(at: time + 0.5, window: 1))
        // Several bounds changes inside one frame are not an extreme speed.
        var burst = ScrollMotionGate(fastThreshold: 600, settleDelay: 0.15)
        burst.record(y: 0, at: 20)
        let burstFast = burst.record(y: 3, at: 20.0001)
        #expect(!burstFast)
    }

    @Test("Only rows entering or leaving the visible rect reach the translator")
    func visibleRowDiff() {
        var set = VisibleRowSet()
        var diff = set.update([("a", "A"), ("b", "B"), ("c", "C")])
        #expect(diff.appeared.map(\.id) == ["a", "b", "c"])
        #expect(diff.disappeared.isEmpty)
        diff = set.update([("b", "B"), ("c", "C"), ("d", "D")])
        #expect(diff.appeared.map(\.id) == ["d"])
        #expect(diff.disappeared == ["a"])
        diff = set.update([("b", "B"), ("c", "C"), ("d", "D")])
        #expect(diff.appeared.isEmpty && diff.disappeared.isEmpty)
        #expect(set.removeAll() == ["b", "c", "d"])
    }

    @Test("While the list moves, the newest queued row is translated first")
    func newestFirstWhileMoving() {
        let translator = ListTitleTranslator()
        translator.setScrolling(true)
        translator._enableForTesting(targetLanguageCode: "ko")
        translator._markJustEnabledForTesting()
        for id in ["a", "b", "c"] { translator.rowAppeared(id: id, title: "Title \(id) about the weather") }
        for id in ["a", "b", "c"] { #expect(translator._schedulingForTesting(id) == "pending") }
        translator.prefersNewestPending = true
        translator.setScrolling(false)
        #expect(translator._schedulingForTesting("c") == "active")
        #expect(translator._schedulingForTesting("b") == "active")
        #expect(translator._schedulingForTesting("a") == "pending", "the row about to leave waits")
        // Leaving drops the queued row at once; the in-flight ones are cancelled
        // and free their slot when their task ends.
        for id in ["a", "b", "c"] { translator.rowDisappeared(id: id) }
        #expect(translator._schedulingForTesting("a") == "none")
    }

    // MARK: Scroll anchoring against a real NSTableView

    @MainActor
    private final class HeightTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var heights = Array(repeating: CGFloat(20), count: 200)
        let table = NSTableView()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))

        override init() {
            super.init()
            table.addTableColumn(NSTableColumn(identifier: .init("c")))
            table.headerView = nil
            table.intercellSpacing = .zero
            table.style = .plain
            table.dataSource = self
            table.delegate = self
            scroll.documentView = table
            table.reloadData()
            scroll.layoutSubtreeIfNeeded()
        }
        func numberOfRows(in tableView: NSTableView) -> Int { heights.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { heights[row] }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            NSTableCellView()
        }
        func scrollTo(_ y: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        func offset(ofRow row: Int) -> CGFloat { table.rect(ofRow: row).minY - scroll.contentView.bounds.minY }
    }

    @Test("Rows above the viewport growing do not move the rows on screen")
    func anchorKeepsVisibleRows() {
        let harness = HeightTable()
        harness.scrollTo(1_000)            // row 50 at the top
        let before = harness.offset(ofRow: 51)
        for row in 10..<15 { harness.heights[row] = 60 }
        ArticleTableScrollAnchor.preservingVisibleRows(of: harness.table, changing: IndexSet(10..<15)) {
            harness.table.noteHeightOfRows(withIndexesChanged: IndexSet(10..<15))
        }
        #expect(abs(harness.offset(ofRow: 51) - before) < 0.5)
        #expect(abs(harness.scroll.contentView.bounds.minY - 1_200) < 0.5)

        // Without the anchor the same change pushes the screen by 200 pt.
        let plain = HeightTable()
        plain.scrollTo(1_000)
        let plainBefore = plain.offset(ofRow: 51)
        for row in 10..<15 { plain.heights[row] = 60 }
        plain.table.noteHeightOfRows(withIndexesChanged: IndexSet(10..<15))
        #expect(abs(plain.offset(ofRow: 51) - plainBefore - 200) < 0.5)

        // Rows below the viewport changing never scroll.
        harness.scrollTo(0)
        harness.heights[150] = 80
        ArticleTableScrollAnchor.preservingVisibleRows(of: harness.table, changing: IndexSet(integer: 150)) {
            harness.table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: 150))
        }
        #expect(harness.scroll.contentView.bounds.minY == 0)
    }
}
#endif
