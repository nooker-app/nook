import SwiftUI

/// What ⌘Q should do.
///
/// A value rather than a branch inside the event monitor, because the monitor only
/// compiles on macOS and cannot be reached from the package's tests. The rule is the
/// part worth pinning: writing that would be lost turns the shortcut into a
/// press-and-hold, and an app with nothing at stake still quits on the first press.
enum QuitShortcutDecision: Equatable {
    /// Quit now.
    case quit
    /// Swallow it and require the keys to be held.
    case hold

    /// - Parameter hasUnsavedWork: whether quitting would throw something away.
    static func forShortcut(hasUnsavedWork: Bool) -> QuitShortcutDecision {
        hasUnsavedWork ? .hold : .quit
    }

    var quitsImmediately: Bool { self == .quit }
}

/// Who currently has writing that quitting would take with it.
///
/// A registry of claims rather than one flag: two composers can be open at once —
/// the reader window has one and Settings has another — and the first one to close
/// must not clear a guard the other still needs.
@MainActor
final class UnsavedWritingRegistry {
    static let shared = UnsavedWritingRegistry()

    private var claims: Set<UUID> = []

    /// True while anything on screen holds unsaved writing.
    var hasUnsavedWork: Bool { !claims.isEmpty }

    func hold(_ id: UUID) { claims.insert(id) }
    func release(_ id: UUID) { claims.remove(id) }
}

#if os(macOS)
    import AppKit

    extension View {
        /// Makes ⌘Q a press-and-hold for as long as this view holds unsaved writing.
        ///
        /// The claim follows the flag, so a composer that is emptied again — or whose
        /// draft has just been saved — stops guarding the shortcut without closing.
        public func requiresHoldToQuit(when hasUnsavedWork: Bool) -> some View {
            modifier(HoldToQuitClaimModifier(hasUnsavedWork: hasUnsavedWork))
        }
    }

    private struct HoldToQuitClaimModifier: ViewModifier {
        let hasUnsavedWork: Bool
        @State private var claim = UnsavedWritingClaim()

        func body(content: Content) -> some View {
            content
                .onAppear { claim.set(hasUnsavedWork) }
                .onChange(of: hasUnsavedWork) { _, now in claim.set(now) }
                .onDisappear { claim.set(false) }
        }
    }

    /// One view's entry in the registry, tied to the lifetime of that view's state.
    ///
    /// A class with a `deinit` rather than `onDisappear` alone: a sheet torn down with
    /// the window it was in does not reliably get the callback, and a claim left behind
    /// would make ⌘Q need holding for the rest of the session — a guard nobody can see
    /// or clear.
    @MainActor
    private final class UnsavedWritingClaim {
        nonisolated let id = UUID()
        private var held = false

        func set(_ hold: Bool) {
            guard hold != held else { return }
            held = hold
            if hold {
                UnsavedWritingRegistry.shared.hold(id)
            } else {
                UnsavedWritingRegistry.shared.release(id)
            }
        }

        deinit {
            // Isolated state is out of reach here; the id is immutable, which is all
            // the release needs.
            let id = id
            Task { @MainActor in UnsavedWritingRegistry.shared.release(id) }
        }
    }

    /// Turns ⌘Q into a press-and-hold while there is unsaved writing, the way Chrome's
    /// "Warn Before Quitting" does.
    ///
    /// ⌘Q sits next to ⌘W and ⌘A on the keyboard, and in Nook it is the shortcut that
    /// cannot be undone: a composer's text lives on screen until it is published or kept
    /// as a draft, so a mis-hit ends the session and the writing with it. Every other way
    /// out of the composer already asks — the Cancel button and, on iOS, the swipe.
    ///
    /// An alert would be the usual macOS answer, and it is the wrong one here: it steals
    /// focus, has to be dismissed, and trains the reflex of confirming without reading.
    /// Holding the same keys a moment longer costs nothing when it is deliberate and
    /// cannot happen by accident, which is exactly the distinction that matters.
    ///
    /// The shortcut is intercepted, not the quit. `applicationShouldTerminate` would also
    /// catch logging out and the Dock's Quit — neither of which is a slip — and blocking
    /// those risks an app that cannot be shut down.
    ///
    /// Both outcomes are carried out here rather than handed back to the Quit menu item,
    /// and both go through ``quit()``, which closes any sheet first — see there for why ⌘Q
    /// in the composer did nothing at all, in either direction, until it did.
    @MainActor
    public final class QuitHoldController {
        public static let shared = QuitHoldController()

        /// How long the keys have to stay down. Chrome's own interval: past the length of
        /// any mis-hit, short enough that a deliberate quit does not feel refused.
        private static let holdSeconds = 1.5

        private var monitor: Any?
        private var holdTask: Task<Void, Never>?
        private var hud: QuitHoldOverlayPanel?

        private init() {}

        /// Starts watching for the shortcut. Call once, at launch.
        public func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .keyUp, .flagsChanged]
            ) { event in
                // Local monitors run on the main thread, ahead of the main menu's key
                // equivalents — which is what lets the decision be synchronous, and the
                // only way returning nil can keep the Quit item from firing.
                //
                // The stroke crosses into the main actor as a value because an NSEvent
                // is not `Sendable` and cannot; what the decision needs from it is four
                // numbers anyway.
                let stroke = KeyStroke(event)
                let swallow = MainActor.assumeIsolated {
                    QuitHoldController.shared.handle(stroke)
                }
                return swallow ? nil : event
            }
        }

        /// - Returns: true to swallow the event, so the Quit menu item never sees it.
        private func handle(_ stroke: KeyStroke) -> Bool {
            switch stroke.type {
            case .keyDown:
                guard stroke.isQuitShortcut else { return false }
                let decision = QuitShortcutDecision.forShortcut(
                    hasUnsavedWork: UnsavedWritingRegistry.shared.hasUnsavedWork
                )
                if decision.quitsImmediately {
                    quit()
                } else {
                    // Repeats arrive while the key is down; the first press owns the timer.
                    beginHold()
                }
                return true
            case .keyUp:
                if stroke.keyCode == KeyStroke.qKeyCode { endHold() }
                return false
            case .flagsChanged:
                if !stroke.modifiers.contains(.command) { endHold() }
                return false
            default:
                return false
            }
        }

        private func beginHold() {
            guard holdTask == nil else { return }
            let overlay = QuitHoldOverlayPanel(duration: Self.holdSeconds)
            overlay.show()
            hud = overlay
            holdTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.holdSeconds))
                guard let self, !Task.isCancelled else { return }
                // A last look at the hardware state, because a key-up can be missed
                // while ⌘ is down and quitting on a key nobody is holding is the exact
                // accident this exists to prevent.
                let stillHeld = NSEvent.modifierFlags.contains(.command)
                endHold()
                guard stillHeld else { return }
                quit()
            }
        }

        /// Quits, having first closed anything presented as a sheet.
        ///
        /// `NSApp.terminate` on its own does nothing at all while a sheet is attached: it
        /// does not quit and it does not even reach `applicationShouldTerminate`. Measured
        /// in a standalone app — no sheet, the delegate is asked; a sheet attached, it is
        /// not asked at all; the sheet ended first, asked again, and ending it in the same
        /// run-loop turn is enough. Nested sheets need all of them ended, which the
        /// composer has: its own details and footnote editors present on top of it.
        ///
        /// The composer *is* a sheet, so this is why ⌘Q in it did nothing whatsoever —
        /// neither the immediate quit when there was nothing to protect, nor, as it turns
        /// out, the quit at the end of a completed hold. The overlay appeared and holding
        /// it achieved nothing.
        private func quit() {
            for window in NSApp.windows {
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
            }
            NSApp.terminate(nil)
        }

        private func endHold() {
            holdTask?.cancel()
            holdTask = nil
            hud?.dismiss()
            hud = nil
        }
    }

    /// A key event reduced to the parts a quit decision is made from.
    private struct KeyStroke: Sendable {
        let type: NSEvent.EventType
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
        /// The key as typed with the modifiers taken off, which is how a layout that
        /// puts Q elsewhere still reports one.
        let character: String?

        /// `kVK_ANSI_Q`, without pulling in Carbon for one constant.
        static let qKeyCode: UInt16 = 12

        init(_ event: NSEvent) {
            type = event.type
            // Only key events carry these, and `flagsChanged` is read for its flags.
            keyCode = type == .flagsChanged ? 0 : event.keyCode
            modifiers = event.modifierFlags
            character = switch type {
            case .keyDown, .keyUp: event.charactersIgnoringModifiers
            default: nil
            }
        }

        /// ⌘Q and nothing else. Any extra modifier is a different shortcut, and letting
        /// ⇧⌘Q through matters: that one is Log Out.
        var isQuitShortcut: Bool {
            guard modifiers.intersection(.deviceIndependentFlagsMask) == .command else {
                return false
            }
            // The key code covers layouts where ⌘ shortcuts fall back to Roman
            // positions; the character covers the rest, including a Korean input source
            // being active.
            return keyCode == Self.qKeyCode || character?.lowercased() == "q"
        }
    }

    /// The overlay: a floating panel that says what to do, centred on screen.
    ///
    /// A panel of its own rather than something inside the window, because it has to
    /// appear over a sheet — which is where the writing being protected actually is —
    /// and take no focus while doing it.
    @MainActor
    private final class QuitHoldOverlayPanel {
        private let panel: NSPanel

        init(duration: Double) {
            let hosting = NSHostingView(rootView: QuitHoldOverlay(duration: duration))
            hosting.frame.size = hosting.fittingSize
            panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentView = hosting
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            // Nothing to click: swallowing a stray click during the hold would be one
            // more surprise in a moment that already has one.
            panel.ignoresMouseEvents = true
            panel.animationBehavior = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        }

        func show() {
            let screen = NSApp.keyWindow?.screen ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                let size = panel.frame.size
                panel.setFrameOrigin(
                    CGPoint(
                        x: visible.midX - size.width / 2,
                        y: visible.midY - size.height / 2
                    ))
            }
            panel.alphaValue = 0
            // Not `makeKey`: the composer keeps focus, so releasing the keys leaves the
            // caret exactly where it was.
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }

        func dismiss() {
            let panel = panel
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
                panel.close()
            }
        }
    }

    /// What the overlay says.
    private struct QuitHoldOverlay: View {
        let duration: Double
        @State private var filled = false

        var body: some View {
            VStack(spacing: 16) {
                Text("Hold ⌘Q to Quit", bundle: .module)
                    .font(.system(size: 19, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                // A line that fills over exactly the hold interval, so the wait has a
                // visible end. Chrome shows none, which leaves how long to hold as a
                // guess — and a guess is what makes a deliberate quit feel refused.
                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { geometry in
                            Capsule()
                                .fill(.white)
                                .frame(width: filled ? geometry.size.width : 0)
                        }
                    }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 30)
            .padding(.vertical, 26)
            .frame(width: 300)
            .background(
                Color.black.opacity(0.78),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            // Dark in both appearances, like every other transient system overlay.
            .environment(\.colorScheme, .dark)
            .onAppear { withAnimation(.linear(duration: duration)) { filled = true } }
        }
    }
#endif
