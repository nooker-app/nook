#if os(macOS)
import AppKit
import SwiftUI
import Testing

@testable import NookKit

/// Whether a list row's context menu is built before anyone opens it.
///
/// This is a guard on a shape rather than on a number. The article list's rows
/// carried their menu items written out inside the `.contextMenu` closure, and a
/// field log from a session of twenty-one hours counted **905,336** menus built
/// against 1,344 evaluations of a row's own body — 358 of its 1,167 stalled seconds
/// went into menus nobody had opened. Moving the items into a child view fixed it,
/// because SwiftUI does not call a child's `body` until it needs what the child
/// draws.
///
/// The fix is invisible in review — both spellings read the same — so it is pinned
/// here instead: the inline form is measured alongside it, and the test is only
/// meaningful while the two differ.
@Suite("List row menu eagerness", .serialized)
@MainActor
struct ListRowMenuEagernessTests {
    final class Counter { var count = 0; func bump() { count += 1 } }

    /// The same items either spelling would produce.
    struct Items: View {
        let counter: Counter
        var body: some View {
            let _ = counter.bump()
            Button("Mark as Read") {}
            Button("Star") {}
            Button("Save for Offline") {}
            Menu("Categories") { Button("One") {}; Button("Two") {} }
            Divider()
            Link("Open in Browser", destination: URL(string: "https://example.com")!)
        }
    }

    /// Lays a list out the way a window would, twice, so a menu built on either
    /// pass is counted.
    static func layOut<V: View>(_ view: V) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 674, height: 900)
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        host.layoutSubtreeIfNeeded()
    }

    private static let rows = 200

    @Test("a row's menu is not built until it is opened")
    func menuIsDeferred() {
        let child = Counter()
        Self.layOut(
            List {
                ForEach(0..<Self.rows, id: \.self) { index in
                    Text("Row \(index)").contextMenu { Items(counter: child) }
                }
            })
        #expect(child.count == 0, "built \(child.count) menus for \(Self.rows) rows")
    }

    /// The control, and the reason the test above is not vacuous: written inline,
    /// the same items are built once per row.
    @Test("written inline, the same items are built per row")
    func inlineItemsAreEager() {
        let inline = Counter()
        Self.layOut(
            List {
                ForEach(0..<Self.rows, id: \.self) { index in
                    Text("Row \(index)")
                        .contextMenu {
                            let _ = inline.bump()
                            Button("Mark as Read") {}
                            Button("Star") {}
                            Button("Save for Offline") {}
                            Menu("Categories") { Button("One") {}; Button("Two") {} }
                            Divider()
                            Link("Open in Browser", destination: URL(string: "https://example.com")!)
                        }
                }
            })
        #expect(inline.count > 0, "the inline form stopped being eager; this test's premise is gone")
    }
}
#endif
