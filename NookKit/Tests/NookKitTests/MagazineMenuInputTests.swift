#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import NookKit

@Suite("Magazine menu input routing")
@MainActor
struct MagazineMenuInputTests {
    private struct ReaderInput: NSViewRepresentable {
        let target: NSView
        func makeNSView(context: Context) -> NSView { target }
        func updateNSView(_ view: NSView, context: Context) {}
    }

    @Test("Closed menus pass pointer input through to the reader at the top, body and bottom")
    func closedMenusDoNotCoverReader() async throws {
        _ = NSApplication.shared
        let target = NSView()
        let presentation = MagazineMenuPresentation()
        let host = NSHostingView(rootView:
            ZStack(alignment: .topTrailing) {
                ReaderInput(target: target)
                MagazineMorphingMenu("Menu", systemImage: "ellipsis", height: 180) { _ in
                    Text("Menu content")
                }
                .padding(20)
            }
            .frame(width: 640, height: 480)
            .magazineMorphingMenus(presentation)
        )
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        try #require(target.window === window)

        // Use AppKit hit testing, not accessibility actions: AXPress invokes a
        // button directly and would pass even with an invisible view above it.
        for point in [NSPoint(x: 60, y: 40), NSPoint(x: 320, y: 240), NSPoint(x: 60, y: 440)] {
            let hit = try #require(host.hitTest(point))
            #expect(hit === target, "Reader input at \(point) was intercepted by \(type(of: hit))")
        }
    }
}
#endif
