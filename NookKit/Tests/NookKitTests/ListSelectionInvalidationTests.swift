#if os(macOS)
import AppKit
import Observation
import SwiftUI
import Testing

/// Whether moving the List selection re-runs the per-row closure for the window.
///
/// Field measurement of ↓ at 30 Hz attributed a 1.3 s stall to six list bodies and
/// 7,212 row-closure runs: each selection change re-evaluated the list's body, and
/// with the `ForEach` inline that meant every row of a ~1,200-row window. macOS
/// `ContentView` keeps the `ForEach` in a child view whose inputs compare equal, so
/// the closure re-runs only when the rows themselves change. Pinned here because
/// the two spellings read the same in review.
@Suite("List selection invalidation", .serialized)
@MainActor
struct ListSelectionInvalidationTests {
    final class Counter {
        var count = 0
        /// Row values the closure was handed, so a test can tell the snapshot
        /// child received new data and not merely ran again.
        var seen: Set<Int> = []
        func bump(_ row: Int? = nil) {
            count += 1
            if let row { seen.insert(row) }
        }
    }

    @Observable final class Model {
        var selection: Int?
        var rows = Array(0..<300)
        var generation = 0
    }

    struct Rows: View {
        let model: Model
        let counter: Counter
        var body: some View {
            ForEach(model.rows, id: \.self) { row in
                let _ = counter.bump()
                Text("Row \(row)").tag(row)
            }
        }
    }

    struct SeparateRows: View {
        @Bindable var model: Model
        let counter: Counter
        var body: some View {
            List(selection: $model.selection) { Rows(model: model, counter: counter) }
        }
    }

    struct ObservingOuter: View {
        let model: Model
        let counter: Counter
        let outer: Counter
        var body: some View {
            let _ = outer.bump()
            let _ = model.selection
            SeparateRows(model: model, counter: counter)
        }
    }

    // Regression control: identity and rows have different observation owners.
    struct ReplacedParent: View {
        @Bindable var model: Model
        let counter: Counter
        var body: some View {
            List(selection: $model.selection) { Rows(model: model, counter: counter) }
                .id(model.generation)
        }
    }

    struct SnapshotRows: View {
        let rows: [Int]
        let counter: Counter
        var body: some View {
            ForEach(rows, id: \.self) { row in
                let _ = counter.bump(row)
                Text("Row \(row)").tag(row)
            }
        }
    }

    // Capture rows outside List's binding evaluation. The child does not observe
    // live rows, so the old identity cannot evaluate the new window before removal.
    struct ReplacedLeaf: View {
        @Bindable var model: Model
        let counter: Counter
        var body: some View {
            let rows = model.rows
            List(selection: $model.selection) {
                SnapshotRows(rows: rows, counter: counter)
            }
            .id(model.generation)
        }
    }

    struct InlineRows: View {
        @Bindable var model: Model
        let counter: Counter
        let outer: Counter
        var body: some View {
            let _ = outer.bump()
            // The outer body reads the selection, as the root/list bodies did.
            let _ = model.selection
            List(selection: $model.selection) {
                ForEach(model.rows, id: \.self) { row in
                    let _ = counter.bump()
                    Text("Row \(row)").tag(row)
                }
            }
        }
    }

    private static func host<V: View>(_ view: V) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private static func settle(_ host: NSView) async {
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
    }

    @Test("a selection change does not re-run the separate rows view")
    func separateRowsSurviveSelection() async {
        let model = Model()
        let counter = Counter()
        let host = Self.host(SeparateRows(model: model, counter: counter))
        await Self.settle(host)
        let before = counter.count
        for row in 1...5 {
            model.selection = row
            await Self.settle(host)
        }
        #expect(counter.count == before, "row closure ran \(counter.count - before) times for 5 moves")
        model.rows.append(300)
        await Self.settle(host)
        #expect(counter.count > before, "a rows change must still re-run the closure")
    }

    @Test("an observing outer body reruns while separate rows stay untouched")
    func observingOuterSurvivesSelection() async {
        let model = Model()
        let counter = Counter()
        let outer = Counter()
        let host = Self.host(ObservingOuter(model: model, counter: counter, outer: outer))
        await Self.settle(host)
        let before = counter.count
        let outerBefore = outer.count
        for row in 1...5 {
            model.selection = row
            await Self.settle(host)
        }
        #expect(outer.count >= outerBefore + 5)
        #expect(counter.count == before)
    }

    @Test("one replacement costs one fresh List, and selection does not reevaluate rows")
    func replacementEvaluatesRowsOnce() async {
        let model = Model()
        let counter = Counter()
        let host = Self.host(ReplacedLeaf(model: model, counter: counter))
        await Self.settle(host)
        counter.count = 0
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.generation += 1
            model.rows = Array(300..<500)
        }
        await Self.settle(host)
        // macOS List can call ForEach content more than once per row even on a
        // fresh mount (e.g. native table sizing). Compare to that measured baseline,
        // rather than claiming one closure call per row from a headless host.
        let freshCounter = Counter()
        let freshHost = Self.host(ReplacedLeaf(model: model, counter: freshCounter))
        await Self.settle(freshHost)
        #expect(freshCounter.count > 0)
        #expect(counter.count == freshCounter.count)
        counter.count = 0
        for row in 301...305 {
            model.selection = row
            await Self.settle(host)
        }
        #expect(counter.count == 0)

        // Rows alone (growth, ensureVisible, an incremental install, a patch)
        // change without a generation bump: the snapshot must still be re-cut and
        // reach the ForEach, not stay pinned to the first window.
        counter.count = 0
        counter.seen = []
        model.rows.append(500)
        await Self.settle(host)
        #expect(counter.count > 0, "an appended row did not re-run the snapshot child")
        #expect(counter.seen.contains(500), "the ForEach never received the appended row")
        counter.count = 0
        counter.seen = []
        model.rows[0] = 900
        await Self.settle(host)
        #expect(counter.count > 0, "a patched row did not re-run the snapshot child")
        #expect(counter.seen.contains(900), "the ForEach never received the patched row")
    }

    @Test("a separately observed rows child under a replaced parent costs twice a fresh List")
    func replacementControlEvaluatesTwice() async {
        let model = Model()
        let counter = Counter()
        let host = Self.host(ReplacedParent(model: model, counter: counter))
        await Self.settle(host)
        counter.count = 0
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.generation += 1
            model.rows = Array(300..<500)
        }
        await Self.settle(host)
        let freshCounter = Counter()
        let freshHost = Self.host(ReplacedParent(model: model, counter: freshCounter))
        await Self.settle(freshHost)
        #expect(freshCounter.count > 0)
        #expect(counter.count == freshCounter.count * 2)
    }

    @Test("ContentView keeps selected article resolution outside the root")
    func rootSelectionObservationGuard() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Nook/ContentView.swift"), encoding: .utf8)
        // The root struct and its extensions, up to the first leaf view: computed
        // views in an extension (`browserGrabber`, `browserOverlay`) run inside the
        // root body just the same. Only event handlers may resolve the selection.
        let rootStart = try #require(source.range(of: "struct ContentView: View {"))
        let rootEnd = try #require(source.range(of: "\nprivate struct ", range: rootStart.upperBound..<source.endIndex))
        let rootSource = String(source[rootStart.lowerBound..<rootEnd.lowerBound])
        let eventOnly: Set<String> = ["resolvePresentedBrowserMode"]
        let readers = Self.declarations(in: rootSource).filter { _, text in
            text.components(separatedBy: "store.selectedArticle").dropFirst().contains { !$0.hasPrefix("ID") }
        }.map(\.name)
        #expect(!readers.isEmpty || !rootSource.contains("resolvePresentedBrowserMode"),
                "the guard no longer sees the event handler it allows; its scan is broken")
        #expect(Set(readers).isSubset(of: eventOnly), "selection read in root body path: \(readers)")
        let listOuter = try #require(source.components(separatedBy: "private struct ArticleListView: View").last?
            .components(separatedBy: "private struct ArticleListRows: View").first)
        #expect(!listOuter.contains("generation: store.listGeneration"))
        #expect(!listOuter.contains("ForEach(store.listWindow.rows)"))
        let rowsOwner = try #require(source.components(separatedBy: "private struct ArticleListRows: View").last?
            .components(separatedBy: "private struct ArticleListRowContents: View").first)
        #expect(rowsOwner.contains("let rows = store.listWindow.rows"))
        #expect(rowsOwner.contains("ArticleListRowContents(rows: rows,"))
        #expect(rowsOwner.contains(".id(ArticleListIdentity(generation: store.listGeneration,"))
        let contents = try #require(source.components(separatedBy: "private struct ArticleListRowContents: View").last?
            .components(separatedBy: "private struct ArticleRowMenu: View").first)
        #expect(contents.contains("ForEach(rows)"))
        #expect(!contents.contains("store.listWindow.rows"))
    }

    @Test("Rows are built from their model and the reader follows the settled selection")
    func rowAndReaderSourceGuard() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Nook/ContentView.swift"), encoding: .utf8)
        func section(_ start: String, _ end: String) throws -> String {
            try #require(source.components(separatedBy: start).last?.components(separatedBy: end).first)
        }
        // The per-row closure runs for the whole window on every rows change.
        let contents = try section("private struct ArticleListRowContents: View", "private struct ArticleRowMenu: View")
        for lookup in ["store.feed(for:", "titleTranslator.box(", "OfflineArticleStore", "categories(for"] {
            #expect(!contents.contains(lookup), "per-row closure resolves \(lookup)")
        }
        #expect(contents.contains("ArticleRowMenu(store: store, id: row.id)"))
        #expect(contents.contains("ArticleRowSwipeActions(store: store, id: row.id)"))
        let row = try section("private struct ArticleRow: View, Equatable", "private struct ArticleRowCategoryBadges: View")
        for lookup in ["store.feed(for:", "OfflineArticleStore", "categories(for", "ListTitleTranslationBlock("] {
            #expect(!row.contains(lookup), "row body resolves \(lookup)")
        }
        #expect(row.contains("RelativeTimeText(model.publishedAt)"))
        #expect(row.contains("ListTitleTranslationSlot("))
        let reader = try section("private struct ReaderDetailView: View", "private struct TranslationBanner: View")
        #expect(reader.contains("store.readerArticle"))
        #expect(!reader.contains("store.selectedArticle"))
    }

    @Test("Sidebar sections compare every piece of sidebar state they read")
    func sidebarSectionsCompareReadState() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Nook/ContentView.swift"), encoding: .utf8)
        let sidebar = try #require(source.components(separatedBy: "private struct FeedSidebar: View {").last?
            .components(separatedBy: "\nprivate struct ").first)
        let sections = try #require(source.components(separatedBy: "private struct FeedSidebarSections: View, Equatable {").last?
            .components(separatedBy: "\nprivate struct ").first)
        let state = sidebar.matches(of: /@(?:State|AppStorage)[^\n]*?var ([A-Za-z_][A-Za-z0-9_]*)/).map { String($0.output.1) }
        #expect(state.count >= 10, "the state scan is broken")
        // Only set by actions or read by `body`'s own modifiers (alerts, sheets,
        // the action bar), never while building a section row. A new piece of
        // state must be added here or compared by `FeedSidebarSections`.
        let actionOnly: Set<String> = [
            "isCreatingFolder", "newFolderName", "folderPendingDeletion", "isManagingFolders",
            "folderPendingRename", "renameFolderName", "feedPendingRename", "renameFeedName", "actionFeedback",
        ]
        for name in state where !actionOnly.contains(name) {
            #expect(sections.contains("let \(name):"), "FeedSidebarSections does not hold \(name)")
            #expect(sections.contains("lhs.\(name) == rhs.\(name)"), "FeedSidebarSections == skips \(name)")
        }
    }

    /// Splits a type's source into member declarations (`func`/`var` at member
    /// indentation, any modifiers or attributes before them), each with its text.
    private static func declarations(in source: String) -> [(name: String, text: String)] {
        let pattern = /\n    (?:@[A-Za-z]+(?:\([^)]*\))?\s+)*(?:(?:private|fileprivate|static|nonisolated|mutating)\s+)*(?:func|var)\s+([A-Za-z_][A-Za-z0-9_]*)/
        let matches = source.matches(of: pattern)
        return matches.enumerated().map { index, match in
            let end = index + 1 < matches.count ? matches[index + 1].range.lowerBound : source.endIndex
            return (String(match.output.1), String(source[match.range.lowerBound..<end]))
        }
    }

    /// The control: when the body holding the `ForEach` observes the selection,
    /// every move re-runs the closure for the rows.
    @Test("inline rows in a body that observes selection re-run per move")
    func inlineRowsRerunPerSelection() async {
        let model = Model()
        let counter = Counter()
        let outer = Counter()
        let host = Self.host(InlineRows(model: model, counter: counter, outer: outer))
        await Self.settle(host)
        let before = counter.count
        let outerBefore = outer.count
        for row in 1...5 {
            model.selection = row
            await Self.settle(host)
        }
        #expect(outer.count > outerBefore, "the outer body stopped observing selection; premise gone")
        #expect(counter.count > before, "inline rows stopped re-running; this test's premise is gone")
    }
}
#endif
