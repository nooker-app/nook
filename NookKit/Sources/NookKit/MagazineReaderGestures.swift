#if os(macOS)
import AppKit
import SwiftUI

/// Place inside the reader's ScrollView content. Its enclosing NSScrollView is
/// the actual reader, including when a nested code/table scroller is present.
public struct MagazineReaderGestureProbe: NSViewRepresentable {
    let articleID: String
    let enabled: Bool
    let hasNext: Bool
    let hasPrevious: Bool
    let onChange: (MagazinePullPresentation) -> Void
    let onAction: (MagazineGestureAction) -> Void

    public init(articleID: String, enabled: Bool, hasNext: Bool, hasPrevious: Bool,
                onChange: @escaping (MagazinePullPresentation) -> Void,
                onAction: @escaping (MagazineGestureAction) -> Void) {
        self.articleID = articleID
        self.enabled = enabled
        self.hasNext = hasNext
        self.hasPrevious = hasPrevious
        self.onChange = onChange
        self.onAction = onAction
    }

    public func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        context.coordinator.attach(view)
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.configuration?.articleID != articleID || !enabled {
            coordinator.reset(report: false)
        }
        coordinator.configuration = self
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }
    public static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.detach() }

    private final class ProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor public final class Coordinator {
        fileprivate var configuration: MagazineReaderGestureProbe?
        private weak var probe: NSView?
        private var monitor: Any?
        private var resignObserver: NSObjectProtocol?
        private var staleTask: Task<Void, Never>?
        private var state = MagazineGestureState()
        private var haptics = MagazineResistanceHaptics()

        fileprivate func attach(_ view: NSView) {
            probe = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reset()
                }
            }
        }

        fileprivate func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            monitor = nil
            resignObserver = nil
            staleTask?.cancel()
        }

        fileprivate func reset(report: Bool = true) {
            let wasVisible = state.presentation.edge != nil
            state.reset()
            haptics.reset()
            staleTask?.cancel()
            if report && wasVisible { configuration?.onChange(state.presentation) }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let configuration, configuration.enabled,
                  let probe, let window = probe.window,
                  window.attachedSheet == nil, event.window === window,
                  let scroll = probe.enclosingScrollView else { return false }

            let phase: MagazineGestureState.Phase
            if !event.momentumPhase.isEmpty { phase = .momentum }
            else if event.phase.contains(.cancelled) { phase = .cancelled }
            else if event.phase.contains(.ended) { phase = .ended }
            else if event.phase.contains(.began) { phase = .began }
            else if !event.phase.isEmpty { phase = .changed }
            else { phase = .discrete }

            // Once engaged, still receive release if the pointer left the reader.
            // Starting over an image overlay, another pane or a nested scroller
            // must not steal its gesture.
            let hit = window.contentView?.hitTest(event.locationInWindow)
            if state.presentation.edge == nil {
                guard let hit, hit.isDescendant(of: scroll), hit.enclosingScrollView === scroll || hit === scroll else {
                    reset()
                    return false
                }
            }
            let clip = scroll.contentView
            let bounds = clip.bounds
            let minY = clip.constrainBoundsRect(CGRect(x: bounds.minX, y: -1_000_000, width: bounds.width, height: bounds.height)).minY
            let maxY = clip.constrainBoundsRect(CGRect(x: bounds.minX, y: 1_000_000, width: bounds.width, height: bounds.height)).minY
            let before = state.presentation
            let result = state.update(
                phase: phase, dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
                atTop: bounds.minY <= minY + 2, atBottom: bounds.minY >= maxY - 2,
                hasNext: configuration.hasNext, hasPrevious: configuration.hasPrevious
            )
            let after = state.presentation
            if after != before { configuration.onChange(after) }
            if let pulse = haptics.update(phase: phase, isArmed: after.isArmed,
                                          outwardTravel: result.resistanceTravel, time: event.timestamp) {
                NSHapticFeedbackManager.defaultPerformer.perform(
                    pulse == .threshold ? .levelChange : .generic, performanceTime: .now)
            }
            staleTask?.cancel()
            if after.edge != nil {
                staleTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    self?.reset()
                }
            }
            if let action = result.action {
                // The detail may disappear during close; its event monitor cannot
                // then protect the magazine from this gesture's remaining momentum.
                MagazineMomentumShield.shared.suppress(in: window)
                configuration.onAction(action)
            }
            return result.consumed
        }
    }
}

@MainActor
private final class MagazineMomentumShield {
    static let shared = MagazineMomentumShield()
    private var monitor: Any?
    private var timeout: Task<Void, Never>?

    func suppress(in window: NSWindow) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak window] event in
            guard event.window === window else { return event }
            if event.phase.contains(.began) { self?.stop(); return event }
            if !event.momentumPhase.isEmpty {
                if event.momentumPhase.contains(.ended) { self?.stop() }
                return nil
            }
            return event
        }
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            self?.stop()
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        timeout?.cancel()
        timeout = nil
    }
}

public struct MagazineReaderGestureOverlay: View {
    let pull: MagazinePullPresentation
    let nextTitle: String?
    let previousTitle: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(pull: MagazinePullPresentation, nextTitle: String?, previousTitle: String?) {
        self.pull = pull
        self.nextTitle = nextTitle
        self.previousTitle = previousTitle
    }

    public var body: some View {
        ZStack {
            if let edge = pull.edge {
                indicator(edge: edge)
                    .opacity(min(1, pull.progress * 4))
                    .offset(x: edge == .leading && !reduceMotion ? -70 + min(96, pull.distance) : 0,
                            y: reduceMotion ? 0 : (edge == .top ? -1 : edge == .bottom ? 1 : 0) * (70 - min(96, pull.distance)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: edge == .top ? .top : edge == .bottom ? .bottom : .leading)
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func indicator(edge: MagazineGestureEdge) -> some View {
        HStack(spacing: 12) {
            Image(systemName: pull.action == .close ? "arrow.left" : edge == .top ? "arrow.up" : "arrow.down")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 28)
            if edge != .leading {
                VStack(alignment: .leading, spacing: 3) {
                    Text(actionLabel).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: 226, alignment: .leading)
            }
        }
        .padding(.horizontal, edge == .leading ? 16 : 18)
        .frame(height: 60)
        .background {
            GeometryReader { geometry in
                NookTheme.accent.opacity(pull.isArmed ? 0.48 : 0.28)
                    .frame(width: geometry.size.width * pull.progress)
            }.clipShape(Capsule())
        }
        .glassEffect(.regular, in: Capsule())
        .overlay { Capsule().strokeBorder(NookTheme.accent.opacity(pull.isArmed ? 0.7 : 0.16), lineWidth: 1) }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    private var actionLabel: String {
        switch (pull.action, pull.isArmed) {
        case (.next, true): String(localized: "Release for next article", bundle: .module)
        case (.previous, true): String(localized: "Release for previous article", bundle: .module)
        case (.close, true): String(localized: "Release to close", bundle: .module)
        case (.next, false): String(localized: "Pull for next article", bundle: .module)
        case (.previous, false): String(localized: "Pull for previous article", bundle: .module)
        default: String(localized: "Pull to close", bundle: .module)
        }
    }

    private var subtitle: String {
        switch pull.action {
        case .next: nextTitle ?? ""
        case .previous: previousTitle ?? ""
        default: String(localized: "Back to Magazine", bundle: .module)
        }
    }
}
#endif
