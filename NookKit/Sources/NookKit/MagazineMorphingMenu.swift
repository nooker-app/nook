#if os(macOS)
import AppKit
import SwiftUI

/// One presentation per reader. Delayed receipts belong to the menu that opened
/// them; closing, navigating or opening another menu cancels that work.
@MainActor @Observable
public final class MagazineMenuPresentation {
    fileprivate var activeID: UUID?
    fileprivate var revealedID: UUID?
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var reduceMotion = false

    public init() {}
    public var isPresented: Bool { activeID != nil }

    fileprivate func open(_ id: UUID, reduceMotion: Bool) {
        revealTask?.cancel()
        dismissTask?.cancel()
        self.reduceMotion = reduceMotion
        revealedID = nil
        withAnimation(animation) { activeID = id }
        revealTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 40)) } catch { return }
            guard activeID == id else { return }
            withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.13)) { revealedID = id }
        }
    }

    public func dismiss() {
        revealTask?.cancel()
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.07)) { revealedID = nil }
        withAnimation(animation) { activeID = nil }
    }

    /// Navigation tears down the old article immediately, without animating a
    /// menu back into the next article's unrelated button.
    public func reset() {
        revealTask?.cancel()
        dismissTask?.cancel()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            activeID = nil
            revealedID = nil
        }
    }

    fileprivate func dismiss(_ id: UUID, after delay: Duration) {
        guard activeID == id else { return }
        dismissTask?.cancel()
        if delay == .zero {
            dismiss()
        } else {
            dismissTask = Task { @MainActor in
                do { try await Task.sleep(for: delay) } catch { return }
                guard activeID == id else { return }
                dismiss()
            }
        }
    }

    private var animation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.28, bounce: 0.10)
    }
}

public struct MagazineMenuDismissAction {
    fileprivate let action: @MainActor (Duration) -> Void
    @MainActor public func callAsFunction(after delay: Duration = .zero) { action(delay) }
}

private struct MagazineMenuAnchor: Identifiable {
    let id: UUID
    let bounds: Anchor<CGRect>
    let title: String
    let icon: String
    let iconOnly: Bool
    let enabled: Bool
    let panelSize: CGSize
    let content: AnyView
}

private struct MagazineMenuAnchors: PreferenceKey {
    static var defaultValue: [MagazineMenuAnchor] { [] }
    static func reduce(value: inout [MagazineMenuAnchor], nextValue: () -> [MagazineMenuAnchor]) {
        value.append(contentsOf: nextValue())
    }
}

/// The source reserves the closed button's layout. Its persistent, interactive
/// surface lives in the host overlay, above ScrollView clipping, in both states.
public struct MagazineMorphingMenu<Content: View>: View {
    private let title: String
    private let icon: String
    private let iconOnly: Bool
    private let panelSize: CGSize
    private let content: (MagazineMenuDismissAction) -> Content
    @State private var id = UUID()
    @Environment(MagazineMenuPresentation.self) private var presentation
    @Environment(\.isEnabled) private var enabled

    public init(
        _ title: String, systemImage: String, width: CGFloat = 320, height: CGFloat, iconOnly: Bool = false,
        @ViewBuilder content: @escaping (MagazineMenuDismissAction) -> Content
    ) {
        self.title = title
        icon = systemImage
        self.iconOnly = iconOnly
        panelSize = CGSize(width: width, height: height)
        self.content = content
    }

    public var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).frame(width: 17)
            if !iconOnly { Text(title) }
            Color.clear.frame(width: 14, height: 14)
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 12).frame(height: 28).fixedSize()
        .hidden()
        .anchorPreference(key: MagazineMenuAnchors.self, value: .bounds) { bounds in
            [MagazineMenuAnchor(
                id: id, bounds: bounds, title: title, icon: icon, iconOnly: iconOnly, enabled: enabled,
                panelSize: panelSize,
                content: AnyView(content(MagazineMenuDismissAction { delay in
                    presentation.dismiss(id, after: delay)
                }))
            )]
        }
    }
}

public extension View {
    /// Place outside the reader's ScrollView, inside its navigation chrome.
    func magazineMorphingMenus(_ presentation: MagazineMenuPresentation) -> some View {
        modifier(MagazineMenuHost(presentation: presentation))
    }
}

private struct MagazineMenuHost: ViewModifier {
    let presentation: MagazineMenuPresentation
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedHeader: UUID?

    func body(content: Content) -> some View {
        content
            .scrollDisabled(presentation.isPresented)
            .allowsHitTesting(!presentation.isPresented)
            .accessibilityHidden(presentation.isPresented)
            .overlayPreferenceValue(MagazineMenuAnchors.self) { entries in
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        if presentation.isPresented {
                            Color.primary.opacity(0.025)
                                .contentShape(Rectangle())
                                .onTapGesture { presentation.dismiss() }
                        }
                        ForEach(entries) { entry in
                            MagazineMenuSurface(
                                entry: entry, anchor: geometry[entry.bounds], available: geometry.size,
                                presentation: presentation, focusedHeader: $focusedHeader
                            )
                            .zIndex(presentation.activeID == entry.id ? 2 : 0)
                            .allowsHitTesting(!presentation.isPresented || presentation.activeID == entry.id)
                            .accessibilityHidden(presentation.isPresented && presentation.activeID != entry.id)
                        }
                    }
                    .clipped()
                    .background {
                        MagazineMenuEscapeHandler(presentation: presentation)
                            .allowsHitTesting(false)
                    }
                    .onKeyPress(.escape) {
                        guard presentation.isPresented else { return .ignored }
                        presentation.dismiss()
                        return .handled
                    }
                    .onChange(of: geometry.size) { _, _ in presentation.reset() }
                    .onChange(of: entries.map(\.id)) { _, ids in
                        if let active = presentation.activeID, !ids.contains(active) { presentation.reset() }
                    }
                }
            }
            .environment(presentation)
            .onChange(of: presentation.activeID) { oldID, newID in
                // The same header keeps keyboard focus while morphing, including
                // after a row action, Escape or an outside click closes the panel.
                focusedHeader = newID ?? oldID
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { presentation.reset() }
            }
            .onDisappear { presentation.reset() }
    }
}

private struct MagazineMenuSurface: View {
    let entry: MagazineMenuAnchor
    let anchor: CGRect
    let available: CGSize
    let presentation: MagazineMenuPresentation
    let focusedHeader: FocusState<UUID?>.Binding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var hasContent = false

    private var expanded: Bool { presentation.activeID == entry.id }
    private var revealed: Bool { presentation.revealedID == entry.id }
    private var target: CGRect {
        let width = min(entry.panelSize.width, max(1, available.width - 32))
        let height = min(entry.panelSize.height, max(54, available.height - 32))
        let upward = available.height - anchor.minY < height + 24
        return CGRect(
            x: max(16, min(anchor.midX - width / 2, available.width - width - 16)),
            y: max(16, min(upward ? anchor.maxY - height : anchor.minY, available.height - height - 16)),
            width: width, height: height
        )
    }

    var body: some View {
        let rect = expanded ? target : anchor
        let shape = RoundedRectangle(cornerRadius: expanded ? 22 : 14)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if expanded { presentation.dismiss() }
                else { presentation.open(entry.id, reduceMotion: reduceMotion) }
            } label: {
                HStack(spacing: entry.iconOnly ? 0 : 7) {
                    Image(systemName: entry.icon).frame(width: 17)
                    if !entry.iconOnly { Text(entry.title).fixedSize() }
                    Spacer(minLength: entry.iconOnly ? 7 : 0)
                    MagazineDisclosureGlyph(progress: expanded ? 1 : 0)
                        .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                }
                .overlay(alignment: .leading) {
                    if entry.iconOnly {
                        // Reveal the heading inside the expanding surface without
                        // changing the compact button's layout or disclosure path.
                        Text(entry.title).lineLimit(1)
                            .padding(.leading, 24).padding(.trailing, 21)
                            .opacity(revealed ? 1 : 0)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, expanded ? 18 : 12)
                .frame(width: rect.width, height: expanded ? 54 : 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerStyle(entry.enabled ? .link : .default)
            .disabled(!entry.enabled)
            .focusable()
            // The platform's rectangular focus ring lags the spring's bounds.
            // Keep focus for keyboard input without a second, detached surface.
            .focusEffectDisabled()
            .focused(focusedHeader, equals: entry.id)
            .accessibilityLabel(entry.title)
            .help(entry.title)
            .accessibilityValue(Text(expanded ? "Expanded" : "Collapsed", bundle: .module))
            .onMoveCommand { direction in
                if direction == .down && !expanded && entry.enabled {
                    presentation.open(entry.id, reduceMotion: reduceMotion)
                }
            }

            if hasContent {
            ScrollView {
                entry.content
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.bottom, 12)
            }
            .scrollIndicators(.automatic)
            .frame(width: target.width, height: max(0, target.height - 54))
            .opacity(revealed ? 1 : 0)
            .offset(y: reduceMotion || revealed ? 0 : 7)
            .blur(radius: reduceMotion || revealed ? 0 : 3)
            .allowsHitTesting(expanded && revealed)
            .accessibilityHidden(!expanded || !revealed)
            }
        }
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .clipShape(shape)
        .glassEffect(.regular.tint(NookTheme.accent.opacity(0.025)).interactive(!expanded), in: shape)
        .shadow(color: .black.opacity(expanded ? (colorScheme == .dark ? 0.24 : 0.10) : 0),
                radius: expanded ? 20 : 0, y: expanded ? 8 : 0)
        .opacity(entry.enabled ? 1 : 0.5)
        .position(x: rect.midX, y: rect.midY)
        .task(id: expanded) {
            if expanded {
                hasContent = true
            } else {
                // Retain the outgoing body only through the closing animation;
                // hidden ScrollViews otherwise remain in macOS's AX tree.
                do { try await Task.sleep(for: .milliseconds(reduceMotion ? 120 : 350)) } catch { return }
                hasContent = false
            }
        }
    }
}

/// Escape key equivalents are dispatched before SwiftUI's onKeyPress on macOS.
/// Intercept only this window's open menu, before the reader's cancel shortcut.
/// A save sheet keeps its own Escape handling.
private struct MagazineMenuEscapeHandler: NSViewRepresentable {
    let presentation: MagazineMenuPresentation

    func makeNSView(context: Context) -> EscapeView { EscapeView() }
    func updateNSView(_ view: EscapeView, context: Context) { view.presentation = presentation }
    static func dismantleNSView(_ view: EscapeView, coordinator: ()) { view.stop() }

    final class EscapeView: NSView {
        var presentation: MagazineMenuPresentation?
        private var monitor: Any?

        // This bridge observes keys through a window-scoped event monitor. It
        // must never become the mouse/scroll target above the reader beneath it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window,
                          window.attachedSheet == nil, event.keyCode == 53,
                          self.presentation?.isPresented == true else { return false }
                    self.presentation?.dismiss()
                    return true
                }
                return handled ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// A persistent pair of strokes: the chevron's shared point separates into the
/// lower ends of the cross. No symbol replacement or opacity gap at either end.
private struct MagazineDisclosureGlyph: Shape {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let extent = min(rect.width, rect.height) * 0.28
        let cx = rect.midX, cy = rect.midY
        func blend(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
        var path = Path()
        path.move(to: CGPoint(x: cx - extent, y: blend(cy - extent * 0.4, cy - extent)))
        path.addLine(to: CGPoint(x: blend(cx, cx + extent), y: blend(cy + extent * 0.6, cy + extent)))
        path.move(to: CGPoint(x: blend(cx, cx - extent), y: blend(cy + extent * 0.6, cy + extent)))
        path.addLine(to: CGPoint(x: cx + extent, y: blend(cy - extent * 0.4, cy - extent)))
        return path
    }
}

/// Shared row layout also works as a ShareLink label, retaining system sharing.
public struct MagazineMenuRowLabel: View {
    private let title: String
    private let subtitle: String?
    private let icon: String
    private let selected: Bool

    public init(_ title: String, subtitle: String? = nil, systemImage: String, selected: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        icon = systemImage
        self.selected = selected
    }

    public var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon).font(.system(size: 14)).frame(width: 20)
                .foregroundStyle(selected ? NookTheme.accent : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .medium))
                if let subtitle { Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary) }
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NookTheme.accent)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .frame(minHeight: subtitle == nil ? 38 : 60)
        .background(selected ? NookTheme.accent.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
#endif
