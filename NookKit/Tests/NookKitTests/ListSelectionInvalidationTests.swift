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
    final class Counter { var count = 0; func bump() { count += 1 } }

    @Observable final class Model {
        var selection: Int?
        var rows = Array(0..<300)
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
