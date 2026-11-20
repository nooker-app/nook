import AppKit
import NookKit
import Observation
import SwiftUI

@MainActor @Observable
final class LayoutSelectionCoordinator {
    static let shared = LayoutSelectionCoordinator()
    private let preference: MacLayoutPreference
    var layout: MacLayoutMode
    var showsIntroduction: Bool
    let isExistingInstallation: Bool
    var applicationIssue: String?
    struct ReaderRequest: Identifiable {
        let id = UUID()
        let articleID: String
        let recommendation: Bool
    }
    var readerRequest: ReaderRequest?
    var collectionRequest: SmartSource?
    @ObservationIgnored var routeTask: Task<Void, Never>?
    @ObservationIgnored weak var readerWindow: NSWindow?
    @ObservationIgnored var prepareToLeave: (() -> Bool)?
    @ObservationIgnored var pendingURLs: [URL] = []

    init(defaults: UserDefaults = .standard) {
        preference = MacLayoutPreference(defaults: defaults)
        layout = preference.layout
        showsIntroduction = preference.needsIntroduction
        isExistingInstallation = preference.isExistingInstallation
    }

    func apply(_ choice: MacLayoutMode) -> Bool {
        guard readerWindow?.attachedSheet == nil else {
            applicationIssue = String(localized: "Close the open dialog before changing layouts.")
            return false
        }
        guard prepareToLeave?() != false else {
            applicationIssue = String(localized: "Finish saving your writing before changing layouts.")
            return false
        }
        preference.apply(choice)
        layout = choice
        showsIntroduction = false
        applicationIssue = nil
        deliverPendingURLs()
        return true
    }

    func later() {
        preference.deferIntroduction()
        showsIntroduction = false
        deliverPendingURLs()
    }

    func canClose() -> Bool {
        guard prepareToLeave?() != false else { return false }
        if showsIntroduction && isExistingInstallation { later() }
        return true
    }

    private func deliverPendingURLs() {
        let urls = pendingURLs
        pendingURLs.removeAll()
        Task { @MainActor in
            await ReaderStore.shared.bootstrap()
            for url in urls { handleLayoutURL(url) }
        }
    }
}

@MainActor
func handleLayoutURL(_ url: URL) {
    if PlusInviteInbox.shared.accept(url) { return }
    let reader = NookReaderLink.destination(from: url)
    let source = WidgetShared.smartSourceRaw(from: url).flatMap(SmartSource.init(rawValue:))
    guard reader != nil || source != nil else { return }
    let coordinator = LayoutSelectionCoordinator.shared
    coordinator.routeTask?.cancel()
    coordinator.routeTask = Task { @MainActor in
        let store = ReaderStore.shared
        await store.bootstrap()
        guard !Task.isCancelled else { return }
        guard coordinator.prepareToLeave?() != false else {
            store.errorMessage = String(localized: "Finish saving your writing before opening another story.")
            return
        }
        if let source {
            store.isBrowserPresented = false
            store.selectedArticleID = nil
            store.selectSmartSource(source)
            if coordinator.layout == .magazine { coordinator.collectionRequest = source }
        }
        if let reader {
            guard let scope = store.syncFolderURL?.standardizedFileURL.path,
                  NookReaderLink.token(scope) == reader.libraryID else {
                store.errorMessage = String(localized: "This story belongs to another library. Open its sync folder in Settings.")
                return
            }
            let ids = store.libraryArticles.map(\.id)
            let articleID = await Task.detached(priority: .userInitiated) {
                ids.first { NookReaderLink.token($0) == reader.articleToken }
            }.value
            guard !Task.isCancelled, store.syncFolderURL?.standardizedFileURL.path == scope else { return }
            guard let articleID, store.article(withID: articleID) != nil else {
                store.errorMessage = String(localized: "This story is no longer in your library. The widget will update shortly.")
                return
            }
            coordinator.readerRequest = .init(articleID: articleID, recommendation: reader.recommendation)
        }
    }
}

struct LayoutRootView: View {
    @State private var selection = LayoutSelectionCoordinator.shared

    var body: some View {
        Group {
            if selection.showsIntroduction {
                LayoutChooserView(isIntroduction: true)
            } else if selection.layout == .classic {
                ContentView()
            } else {
                MagazineView()
            }
        }
        .frame(minWidth: 920, minHeight: 640)
    }
}

struct LayoutChooserView: View {
    let isIntroduction: Bool
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var coordinator = LayoutSelectionCoordinator.shared
    @State private var preview = LayoutSelectionCoordinator.shared.layout
    @State private var replay = [MacLayoutMode.classic: 0, .magazine: 0]

    private var isBeta: Bool { preview == .magazine }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("NOOK")
                        .font(.caption.weight(.semibold)).tracking(5)
                        .foregroundStyle(.secondary)
                    MagazineHeadline(String(localized: isIntroduction && !coordinator.isExistingInstallation
                         ? "How will you use Nook?" : "Make room for a new perspective."), size: 30)
                    Text("Two ways to read and write. One library.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isBeta ? "rectangle.grid.1x2" : "rectangle.split.3x1")
                    .font(.largeTitle).foregroundStyle(.secondary)
                    .padding(18)
                    .modifier(LayoutGlass(enabled: isBeta))
                    .accessibilityHidden(true)
            }

            HStack(alignment: .top, spacing: 22) {
                choice(.classic)
                choice(.magazine)
            }
            if let issue = coordinator.applicationIssue {
                Label(issue, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).font(.callout)
            }
            HStack {
                Text("You can change this anytime in Settings.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if !isIntroduction || coordinator.isExistingInstallation {
                    Button(isIntroduction ? "Later" : "Cancel") {
                        if isIntroduction { coordinator.later() }
                        else { dismissWindow(id: "layout-picker") }
                    }
                    .keyboardShortcut(.cancelAction)
                }
                Button("Use this layout") {
                    if coordinator.apply(preview), !isIntroduction {
                        dismissWindow(id: "layout-picker")
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(18)
            .modifier(LayoutGlass(enabled: isBeta))
        }
        .padding(32)
        .frame(maxWidth: 1120)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if isBeta {
                LinearGradient(colors: [NookTheme.card,
                                        NookTheme.accent.opacity(0.06), NookTheme.canvas],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            } else { Color(nsColor: .windowBackgroundColor) }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: preview)
        .onAppear { coordinator.applicationIssue = nil }
    }

    private func choice(_ mode: MacLayoutMode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                preview = mode
                replay[mode, default: 0] += 1
            } label: {
                VStack(alignment: .leading, spacing: 16) {
                    LayoutSkeleton(layout: mode, replay: replay[mode, default: 0])
                        .frame(height: 190)
                        .allowsHitTesting(false)
                    HStack {
                        Text(mode == .classic ? "Classic" : "Magazine")
                            .font(.system(size: 21, weight: .semibold, design: mode == .classic ? .default : .serif))
                        if mode == .magazine {
                            Text("BETA").font(.system(size: 9, weight: .bold)).tracking(1)
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(.primary.opacity(0.06), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: preview == mode ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(preview == mode ? NookTheme.accent : .secondary)
                    }
                    Text(mode == .classic
                         ? "Your familiar three-column reader, with a dedicated writing window."
                         : "An editorial canvas. Stories expand into reading, and ideas become drafts in Studio.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 44, alignment: .topLeading)
                }
                .padding(18)
                .background(NookTheme.card, in: RoundedRectangle(cornerRadius: mode == .classic ? 10 : 22))
                .overlay {
                    RoundedRectangle(cornerRadius: mode == .classic ? 10 : 22)
                        .strokeBorder(preview == mode ? NookTheme.accent : Color.primary.opacity(0.12),
                                      lineWidth: preview == mode ? 1.5 : 1)
                }
                .shadow(color: .black.opacity(preview == mode ? 0.08 : 0.02), radius: 18, y: 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .accessibilityLabel(mode == .classic ? "Classic layout" : "Magazine Beta layout")
            .accessibilityValue(preview == mode ? "Selected" : "Not selected")
            Button("Replay preview", systemImage: "arrow.clockwise") { replay[mode, default: 0] += 1 }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                .pointerStyle(.link)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct LayoutGlass: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.glassEffect(.regular.tint(NookTheme.accent.opacity(0.05)), in: RoundedRectangle(cornerRadius: 22)) }
        else { content.background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8)) }
    }
}

/// A finite demonstration, not a loading shimmer. It owns no real library data.
struct LayoutSkeleton: View {
    let layout: MacLayoutMode
    let replay: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var stage = 0
    @State private var isActive = true
    @Namespace private var hero

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(0..<3) { _ in Circle().fill(.tertiary).frame(width: 5, height: 5) }
                Spacer()
                Capsule().fill(.quaternary).frame(width: 65, height: 9)
            }
            ZStack {
                if layout == .classic { classic }
                else { magazine }
                if stage == 3 {
                    writing
                        .padding(layout == .classic ? 20 : 0)
                        .transition(.opacity)
                }
            }
            HStack(spacing: 8) {
                ForEach(0..<3) { step in
                    Capsule().fill(step == min(2, max(0, stage - 1)) ? Color.primary.opacity(0.45) : Color.primary.opacity(0.1))
                        .frame(width: 16, height: 3)
                }
                Text(stage == 3 ? "Write" : (stage == 2 ? "Read" : "Explore"))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }.frame(height: 15)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(layout == .classic
            ? "Preview: choose a list row, read in the adjacent pane, write in a sheet."
            : "Preview: explore a magazine, expand a story, write in Studio.")
        .task(id: "\(replay)-\(reduceMotion)-\(isActive)-\(scenePhase)") {
            guard !reduceMotion, isActive, scenePhase != .background else { stage = 0; return }
            stage = 0
            for next in 1...3 {
                do { try await Task.sleep(for: .milliseconds(next == 1 ? 900 : 1600)) }
                catch { return }
                withAnimation(.spring(duration: 0.35, bounce: 0.08)) { stage = next }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { notification in
            guard let window = notification.object as? NSWindow, window.isKeyWindow else { return }
            isActive = window.occlusionState.contains(.visible)
        }
    }

    private var classic: some View {
        HStack(spacing: 8) {
            lines(6).frame(width: 44)
            Divider()
            VStack(spacing: 9) {
                ForEach(0..<4) { index in
                    lines(2).padding(6)
                        .background(index == 1 && stage > 0 ? NookTheme.accent.opacity(0.2) : .clear,
                                    in: RoundedRectangle(cornerRadius: 4))
                }
            }.frame(maxWidth: .infinity)
            Divider()
            lines(stage >= 2 ? 9 : 3).frame(maxWidth: .infinity)
        }
    }

    private var magazine: some View {
        ZStack(alignment: .topLeading) {
            if stage < 2 {
                VStack(spacing: 9) {
                    story.matchedGeometryEffect(id: "story", in: hero)
                    HStack(spacing: 8) { lines(3); lines(3) }
                }
            } else {
                VStack(spacing: 14) {
                    story.matchedGeometryEffect(id: "story", in: hero)
                    lines(6)
                }
            }
        }
    }

    private var story: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 6).fill(NookTheme.accent.opacity(stage == 1 ? 0.22 : 0.09))
                .frame(height: stage < 2 ? 55 : 35)
            lines(2)
        }
    }

    private var writing: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { lines(1); Spacer(); Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
            lines(5)
            HStack { Image(systemName: "bold"); Image(systemName: "italic"); Image(systemName: "link") }
                .font(.caption).padding(8).background(.regularMaterial, in: Capsule())
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(NookTheme.card, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.08), radius: 6)
    }

    private func lines(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(index == 0 ? 0.18 : 0.08))
                    .frame(height: index == 0 ? 7 : 4)
                    .padding(.trailing, index % 3 == 2 ? 18 : 0)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Preserve SwiftUI's existing delegate, forwarding every method except the
/// close gate. The delegate is retained by the window probe, not a global window.
@MainActor
final class LayoutWindowCloseGate: NSObject, NSWindowDelegate {
    // NSObject's forwarding hooks are nonisolated. AppKit installs and queries
    // this window delegate on the main thread, including these hooks.
    nonisolated(unsafe) weak var original: (any NSWindowDelegate)?
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard LayoutSelectionCoordinator.shared.canClose() else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        original
    }
}

struct LayoutSelectionMenu: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Choose a layout…") { openWindow(id: "layout-picker") }
    }
}
