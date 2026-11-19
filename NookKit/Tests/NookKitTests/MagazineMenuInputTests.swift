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

    @Observable class ToolbarState {
        var visible = false
        var interactive = true
    }

    private struct ToolbarReader: View {
        let state: ToolbarState
        let target: NSView
        let presentation: MagazineMenuPresentation

        var body: some View {
            ZStack {
                ReaderInput(target: target)
                MagazineMorphingMenu("Parser", systemImage: "text.viewfinder", height: 180, iconOnly: true) { _ in
                    Text("Parser options")
                }
                // A nested child must not override its parent's hidden state.
                .magazineMenuContainer(visible: true, interactive: true)
                .magazineMenuContainer(visible: state.visible, interactive: state.interactive)
            }
            .frame(width: 640, height: 480)
            .magazineMorphingMenus(presentation)
        }
    }

    @Test("Lifted menu buttons inherit initial visibility and stop intercepting input when their toolbar hides or disables")
    func toolbarVisibilityIsInherited() async throws {
        _ = NSApplication.shared
        let target = NSView()
        let state = ToolbarState()
        let host = NSHostingView(rootView: ToolbarReader(state: state, target: target, presentation: .init()))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        let center = NSPoint(x: 320, y: 240)
        func settle() async throws {
            host.layoutSubtreeIfNeeded()
            _ = host.fittingSize
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
        }

        try await settle()
        #expect(host.hitTest(center) === target)
        state.visible = true
        try await settle()
        #expect(host.hitTest(center) !== target)
        state.interactive = false
        try await settle()
        #expect(host.hitTest(center) === target)
        state.interactive = true
        try await settle()
        #expect(host.hitTest(center) !== target)
        state.visible = false
        try await settle()
        #expect(host.hitTest(center) === target)
    }

    @Test("Closed menus pass pointer input through to the reader at the top, body and bottom", arguments: [false, true])
    func closedMenusDoNotCoverReader(iconOnly: Bool) async throws {
        _ = NSApplication.shared
        let target = NSView()
        let presentation = MagazineMenuPresentation()
        let host = NSHostingView(rootView:
            ZStack(alignment: .topTrailing) {
                ReaderInput(target: target)
                MagazineMorphingMenu("Menu", systemImage: "ellipsis", height: 180, iconOnly: iconOnly) { _ in
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
