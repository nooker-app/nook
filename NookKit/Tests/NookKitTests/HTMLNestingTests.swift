import Foundation
import Testing

#if os(macOS)
import AppKit
import SwiftUI
#endif

@testable import NookKit

/// Deeply nested content, which is where the reader's layout used to hang.
///
/// A list item's body is another list, so nesting in the markup is nesting in the
/// view tree. Laying out one nested list cost about 8.7× per level while the
/// marker was an `HStack` sibling of a flexible body — 30 seconds at seven levels,
/// a hundred at eight — and a page nesting a dozen deep, which rendered forum and
/// documentation markup does, pinned the app's main thread at 99% CPU inside
/// `StackLayout.placeChildren` with the article never appearing.
///
/// Two things keep it from coming back, and there is a test for each: the marker
/// is an overlay so no level negotiates a width, and the parse stops nesting at a
/// fixed depth so nothing pathological can be unbounded.
@Suite("HTML nesting")
struct HTMLNestingTests {
    /// `<ul><li>text<ul><li>…` nested `depth` deep, ending in a paragraph.
    static func nestedList(depth: Int) -> String {
        var inner = "<p>leaf paragraph with a few words in it</p>"
        for level in stride(from: depth, to: 0, by: -1) {
            inner = "<ul><li>item at level \(level) with some words\(inner)</li></ul>"
        }
        return inner
    }

    /// How deep a block tree goes, counting lists and quotes.
    static func nesting(of blocks: [HTMLContentBlock]) -> Int {
        blocks.reduce(0) { deepest, block in
            switch block {
            case .list(_, let items):
                max(deepest, 1 + items.reduce(0) { max($0, nesting(of: $1)) })
            case .blockquote(let inner):
                max(deepest, 1 + nesting(of: inner))
            default:
                max(deepest, 1)
            }
        }
    }

    /// Every scrap of text a block tree holds, however deep.
    static func text(in blocks: [HTMLContentBlock]) -> String {
        blocks.map { block in
            switch block {
            case .text(let html): html
            case .heading(_, let html): html
            case .list(_, let items): items.map { text(in: $0) }.joined(separator: " ")
            case .blockquote(let inner): text(in: inner)
            default: ""
            }
        }.joined(separator: " ")
    }

    /// The cap, on the two containers that recurse.
    ///
    /// The recursion had no limit at all, in a parser that recurses on the stack
    /// and feeds a view tree that nests one layout container per level. Past the
    /// cap the rest of the fragment is kept as one text block, so its words and
    /// inline formatting survive — asserted here, because a cap that silently
    /// dropped the content would be worse than the hang.
    @Test("nesting is bounded, and the text past the bound survives")
    func nestingIsBounded() {
        let limit = HTMLContentParser.maxNestingDepth

        let list = HTMLContentParser.parse(Self.nestedList(depth: limit * 3), baseURL: nil)
        #expect(Self.nesting(of: list) <= limit + 1)
        #expect(Self.text(in: list).contains("leaf paragraph"))

        var quoted = "<p>innermost</p>"
        for _ in 0..<(limit * 3) { quoted = "<blockquote>\(quoted)</blockquote>" }
        let quotes = HTMLContentParser.parse(quoted, baseURL: nil)
        #expect(Self.nesting(of: quotes) <= limit + 1)

        // Ordinary nesting is untouched: a cap that changed real documents would
        // show up here rather than in a reader.
        let shallow = HTMLContentParser.parse(Self.nestedList(depth: 3), baseURL: nil)
        #expect(Self.nesting(of: shallow) == 4)
    }

    #if os(macOS)
    /// Layout time against nesting depth, which is the actual defect.
    ///
    /// The bound is loose on purpose. It is not a performance target: the
    /// behaviour it forbids is exponential, so the old code needed hours to reach
    /// the depth this asserts in milliseconds, and any bound at all separates the
    /// two. Measured on the fixed shape: 6ms at depth 8, 9ms at depth 12.
    @Test("a deeply nested list lays out in bounded time")
    @MainActor
    func deepListLaysOutQuickly() {
        func layoutMilliseconds(depth: Int) -> Double {
            let blocks = HTMLContentParser.parse(Self.nestedList(depth: depth), baseURL: nil)
            let view = NSHostingView(
                rootView: HTMLBlockList(blocks: blocks, selectable: false)
                    .frame(width: 700, alignment: .leading))
            let clock = ContinuousClock()
            let start = clock.now
            let fitted = view.fittingSize
            view.frame = NSRect(x: 0, y: 0, width: 700, height: fitted.height)
            view.layoutSubtreeIfNeeded()
            let elapsed = start.duration(to: clock.now)
            return Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1e15
        }

        // Once to let the first view of the process pay for hosting setup, then
        // the measurement.
        _ = layoutMilliseconds(depth: 2)
        let deep = layoutMilliseconds(depth: 12)
        #expect(deep < 4000, "12 levels took \(Int(deep))ms; the old shape needed hours")
    }
    #endif
}
