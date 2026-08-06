import SwiftUI

/// What ⌘Q should do.
///
/// A value rather than a branch inside the event monitor, because the monitor only
/// compiles on macOS and cannot be reached from the package's tests. The rule is the
/// part worth pinning: an open writing surface turns the shortcut into a press-and-hold,
/// and everywhere else ⌘Q quits on the first press.
///
/// The trigger is the composer being open, not whether anything has been typed into it
/// yet. Keying it to unsaved text was tried and reads as broken: whether ⌘Q asked or
/// simply quit depended on invisible state, so the same keypress in what looks like the
/// same screen did two different things. A writer cannot tell those screens apart, and a
/// second and a half is not a cost worth that confusion.
enum QuitShortcutDecision: Equatable {
    /// Quit now.
    case quit
    /// Swallow it and require the keys to be held.
    case hold

    /// - Parameter whileWriting: whether a writing surface is open.
    static func forShortcut(whileWriting: Bool) -> QuitShortcutDecision {
        whileWriting ? .hold : .quit
    }

    var quitsImmediately: Bool { self == .quit }
}

/// Which writing surfaces are open.
///
/// A registry of claims rather than one flag: two composers can be open at once —
/// the reader window has one and Settings has another — and the first one to close
/// must not clear a guard the other still needs.
@MainActor
final class WritingSurfaceRegistry {
    static let shared = WritingSurfaceRegistry()

    /// Each open surface, with the way to close it.
    private var claims: [UUID: () -> Void] = [:]

    /// True while a writing surface is on screen.
    var isWriting: Bool { !claims.isEmpty }

    func hold(_ id: UUID, dismiss: @escaping () -> Void) { claims[id] = dismiss }
    func release(_ id: UUID) { claims.removeValue(forKey: id) }

    /// Asks every open surface to close itself.
    ///
    /// Needed because quitting has to get the composer off the screen first, and closing
    /// its sheet directly is not enough: SwiftUI still holds the state that presented it
    /// and puts it straight back. Only the thing that presented it can take it down.
    ///
    /// A snapshot, because each closure leads to the claim being released.
    func dismissAll() {
        for dismiss in Array(claims.values) { dismiss() }
    }
}

#if os(macOS)
    import AppKit

    extension View {
        /// Makes ⌘Q a press-and-hold for as long as this view is on screen.
        ///
        /// For the whole time, not only while there is text: see ``QuitShortcutDecision``
        /// for why the condition is the screen rather than its contents.
        ///
        /// - Parameter dismiss: how to close this surface. A completed hold uses it, because
        ///   an open sheet refuses termination and only whatever presented it can take it
        ///   down for good. Captured when the surface appears, so it has to stay good for as
        ///   long as the surface is up — a call straight back into whatever presented it,
        ///   like the composer's `onFinished`, does.
        public func requiresHoldToQuit(dismiss: @escaping () -> Void) -> some View {
            modifier(HoldToQuitClaimModifier(dismiss: dismiss))
        }
    }

    private struct HoldToQuitClaimModifier: ViewModifier {
        let dismiss: () -> Void
        @State private var claim = WritingSurfaceClaim()

        func body(content: Content) -> some View {
            content
                .onAppear { claim.set(true, dismiss: dismiss) }
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
    private final class WritingSurfaceClaim {
        nonisolated let id = UUID()

        func set(_ hold: Bool, dismiss: @escaping () -> Void = {}) {
            if hold {
                WritingSurfaceRegistry.shared.hold(id, dismiss: dismiss)
            } else {
                WritingSurfaceRegistry.shared.release(id)
            }
        }

        deinit {
            // Isolated state is out of reach here; the id is immutable, which is all
            // the release needs.
            let id = id
            Task { @MainActor in WritingSurfaceRegistry.shared.release(id) }
        }
    }

    /// Turns ⌘Q into a press-and-hold while there is unsaved writing, the way Chrome's
    /// "Warn Before Quitting" does.
    ///
    /// ⌘Q sits next to ⌘W and ⌘A on the keyboard, and in Nook it is the shortcut that
    /// cannot be undone: a composer's text lives on screen until it is published or kept
    /// as a draft, so a mis-hit ends the session and the writing with it. Every other way
    /// out of the composer already asks — the Cancel button and, on iOS, the swipe. The
    /// hold applies for as long as the composer is open, whether or not anything has been
    /// typed yet; ``QuitShortcutDecision`` says why.
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
                    whileWriting: WritingSurfaceRegistry.shared.isWriting
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

        /// Quits, having first got any open writing surface off the screen.
        ///
        /// `NSApp.terminate` does nothing at all while a sheet is attached: it neither quits
        /// nor reaches `applicationShouldTerminate`. Measured in a standalone app — no
        /// sheet, the delegate is asked; a sheet attached, not asked at all. The composer is
        /// a sheet, which is why ⌘Q in it did nothing whatsoever, in either direction.
        ///
        /// Ending the sheet with `endSheet` is not the answer, and the measurement says why:
        /// the state that presented it is still set, so SwiftUI puts the sheet straight back
        /// — the sheet closed, reopened, and the app stayed. Dismissing through that state
        /// instead detaches it in about 30ms, after which termination goes through.
        ///
        /// So: ask the surfaces to close, then wait for the sheet to actually be gone before
        /// asking to quit. Waiting matters — a quit asked one turn too early is a quit
        /// silently dropped, which is where this started.
        private func quit(attempt: Int = 0) {
            if attempt == 0 { WritingSurfaceRegistry.shared.dismissAll() }
            guard NSApp.windows.contains(where: { $0.attachedSheet != nil }) else {
                NSApp.terminate(nil)
                return
            }
            guard attempt < Self.quitPolls else {
                // A sheet nobody claimed — adding a feed, an import — cannot be closed from
                // here. Take it down directly and go: it may come back the way the composer
                // did, but the alternative is a ⌘Q that does nothing at all.
                for window in NSApp.windows {
                    if let sheet = window.attachedSheet { window.endSheet(sheet) }
                }
                NSApp.terminate(nil)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.quit(attempt: attempt + 1)
            }
        }

        /// About 600ms of waiting for a sheet to detach, which measured at one poll.
        private static let quitPolls = 20

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
