import BackgroundTasks
import NookKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// iOS settings. Mirrors the macOS Settings tabs (General, Reading, Reader,
/// Feeds, About) as a navigation drill-down — the idiomatic iOS equivalent of
/// macOS's tab bar. Reuses the same @AppStorage keys as the macOS app so
/// preferences stay consistent. Sparkle updates and the Dock badge are
/// macOS-only and intentionally omitted.
struct SettingsView: View {
    @Bindable var store: ReaderStore
    /// True when hosted as the iPhone Settings tab (no "Done" button, and the
    /// OPML import/export + sync-folder actions the sidebar owns on iPad move
    /// into a "Data" section here). Defaults to sheet presentation (iPad),
    /// leaving that path unchanged.
    var isTab: Bool = false
    /// Navigation state for the iPhone shell's custom tab bar. Reporting the
    /// stack's path depth (instead of view appear/disappear callbacks) makes a
    /// cancelled interactive pop settle back to the correct hidden state.
    var onNavigationEvent: ((NavigationEvent) -> Void)? = nil

    enum NavigationEvent {
        case depthChanged(Int)
    }
    private enum Destination: Hashable {
        case general
        case reading
        case reader
        case feeds
        case articleRules
        case filters
        case offline
        case experimental
        case about
    }
    @Environment(\.dismiss) private var dismiss
    @AppStorage(TourFlags.hasCompletedWelcomeKey) private var hasCompletedWelcome = false
    @AppStorage(TourFlags.seenReaderGestureHintKey) private var seenReaderGestureHint = false
    @AppStorage(TourFlags.seenListHintKey) private var seenListHint = false

    /// A single file importer backs both the sync-folder picker and OPML import;
    /// stacking two `.fileImporter` modifiers on one view makes only one work.
    private enum ImportKind { case folder, opml }
    @State private var importKind: ImportKind = .folder
    @State private var isImporting = false
    @State private var isExportingOPML = false
    @State private var opmlImport: OPMLImportRequest?

    /// One-shot spotlight on the sync-folder row while the library is still
    /// app-local: the tour's sync page is skippable, so Settings gets a second
    /// chance to teach that an iCloud folder syncs every device (Mac included).
    @AppStorage(TourFlags.seenSyncFolderHintKey) private var seenSyncFolderHint = false
    @State private var showSyncHint = false
    @State private var syncRowFrame: CGRect = .zero
    @State private var navigationPath: [Destination] = []

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                Section {
                    NavigationLink(value: Destination.general) {
                        Label("General", systemImage: "gearshape")
                    }
                    NavigationLink(value: Destination.reading) {
                        Label("Reading", systemImage: "book")
                    }
                    NavigationLink(value: Destination.reader) {
                        Label("Reader", systemImage: "textformat")
                    }
                    NavigationLink(value: Destination.feeds) {
                        Label("Feeds", systemImage: "dot.radiowaves.up.forward")
                    }
                    NavigationLink(value: Destination.articleRules) {
                        Label("Article Rules", systemImage: "tag")
                    }
                    NavigationLink(value: Destination.filters) {
                        Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    NavigationLink(value: Destination.offline) {
                        Label("Offline", systemImage: "arrow.down.circle")
                    }
                    NavigationLink(value: Destination.experimental) {
                        Label("Experimental", systemImage: "flask")
                    }
                    NavigationLink(value: Destination.about) {
                        Label("About", systemImage: "info.circle")
                    }
                }
                .warmRows()

                Section {
                    Button {
                        // Reset every tour flag so replay and first-run share one
                        // path, then close (on iPad) so the cover shows over the app.
                        seenReaderGestureHint = false
                        seenListHint = false
                        hasCompletedWelcome = false
                        if !isTab { dismiss() }
                    } label: {
                        Label("Replay Tutorial", systemImage: "questionmark.circle")
                    }
                } header: {
                    Text("Help")
                }
                .warmRows()

                if isTab {
                    Section("Data") {
                        Button {
                            importKind = .folder
                            isImporting = true
                        } label: {
                            Label(
                                store.isStorageConfigured ? "Change Sync Folder" : "Choose Sync Folder",
                                systemImage: store.isStorageConfigured ? "checkmark.icloud" : "icloud"
                            )
                            // Measured for the one-shot sync spotlight; the
                            // publisher unmounts once the hint has been seen.
                            .background {
                                if !seenSyncFolderHint {
                                    GeometryReader { g in
                                        Color.clear.preference(key: SyncFolderRowFrameKey.self, value: g.frame(in: .global))
                                    }
                                }
                            }
                        }
                        Button {
                            importKind = .opml
                            isImporting = true
                        } label: {
                            Label("Import OPML", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            isExportingOPML = true
                        } label: {
                            Label("Export OPML", systemImage: "square.and.arrow.up")
                        }
                        .disabled(store.feeds.isEmpty)
                    }
                    .warmRows()
                }
            }
            .warmListBackground()
            // Keep the last section above the floating tab bar (iPhone tab only).
            .modifier(TabBarInset(enabled: isTab))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isTab {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .modifier(DataActionsModifier(
                isTab: isTab,
                store: store,
                importIsFolder: importKind == .folder,
                isImporting: $isImporting,
                isExportingOPML: $isExportingOPML,
                opmlImport: $opmlImport
            ))
            .navigationDestination(for: Destination.self) { destination in
                destinationView(destination)
            }
        }
        .onAppear {
            onNavigationEvent?(.depthChanged(navigationPath.count))
            maybeShowSyncHint()
        }
        .onChange(of: navigationPath) { _, path in
            onNavigationEvent?(.depthChanged(path.count))
            // Navigating away while the hint is up counts as seen.
            if !path.isEmpty, showSyncHint { dismissSyncHint() }
        }
        // Tapping the spotlighted row means the hint found its mark.
        .onChange(of: isImporting) { _, importing in
            if importing, importKind == .folder, showSyncHint { dismissSyncHint() }
        }
        .onPreferenceChange(SyncFolderRowFrameKey.self) { frame in
            if syncRowFrame != frame { syncRowFrame = frame }
        }
        .overlay {
            if showSyncHint {
                SyncFolderHint(
                    rowFrame: syncRowFrame == .zero ? nil : syncRowFrame,
                    onDismiss: dismissSyncHint
                )
                .transition(.opacity)
            }
        }
    }

    /// Shows the sync-folder spotlight once: only in the tab presentation,
    /// after the welcome tour, while the library is still app-local, and only
    /// at the settings root.
    private func maybeShowSyncHint() {
        guard isTab, hasCompletedWelcome, !seenSyncFolderHint, !showSyncHint,
              store.usesLocalLibrary, navigationPath.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !seenSyncFolderHint, navigationPath.isEmpty else { return }
            withAnimation { showSyncHint = true }
        }
    }

    private func dismissSyncHint() {
        seenSyncFolderHint = true
        withAnimation { showSyncHint = false }
    }

    @ViewBuilder
    private func destinationView(_ destination: Destination) -> some View {
        switch destination {
        case .general:
            GeneralSettingsScreen()
        case .reading:
            ReadingSettingsScreen()
        case .reader:
            ReaderSettingsScreen()
        case .feeds:
            FeedsSettingsScreen(store: store)
        case .articleRules:
            ArticleRulesSettingsScreen(store: store)
        case .filters:
            FiltersSettingsScreen(store: store)
        case .offline:
            OfflineSettingsScreen(store: store)
        case .experimental:
            ExperimentalSettingsScreen()
        case .about:
            AboutSettingsScreen()
        }
    }
}

/// Attaches the sync-folder / OPML importers and exporters — but only when
/// Settings is hosted as the iPhone tab. On iPad (sheet) this adds nothing, so
/// that presentation path is unchanged.
private struct DataActionsModifier: ViewModifier {
    let isTab: Bool
    let store: ReaderStore
    let importIsFolder: Bool
    @Binding var isImporting: Bool
    @Binding var isExportingOPML: Bool
    @Binding var opmlImport: OPMLImportRequest?

    func body(content: Content) -> some View {
        if isTab {
            content
                .fileImporter(
                    isPresented: $isImporting,
                    allowedContentTypes: importIsFolder ? [.folder] : [.opml, .xml],
                    allowsMultipleSelection: false
                ) { result in
                    guard case .success(let urls) = result, let url = urls.first else { return }
                    if importIsFolder {
                        _ = url.startAccessingSecurityScopedResource()
                        store.configureSyncFolder(url)
                    } else {
                        let candidates = store.parseOPML(at: url)
                        if candidates.isEmpty {
                            store.errorMessage = String(localized: "No feeds found in the OPML file.")
                        } else {
                            opmlImport = OPMLImportRequest(feeds: candidates)
                        }
                    }
                }
                .fileExporter(
                    isPresented: $isExportingOPML,
                    document: OPMLDocument(feeds: store.feeds),
                    contentType: .opml,
                    defaultFilename: "NookSubscriptions.opml"
                ) { result in
                    store.handleOPMLExport(result)
                }
                .sheet(item: $opmlImport) { request in
                    OPMLImportView(
                        feeds: request.feeds,
                        existingKeys: Set(store.feeds.flatMap { [$0.feedURL.feedIdentityKey, $0.siteURL.feedIdentityKey] })
                    ) { selected in
                        store.importFeeds(selected)
                    }
                }
        } else {
            content
        }
    }
}

// MARK: - General

private struct GeneralSettingsScreen: View {
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system
    @AppStorage("showUnreadBadge") private var showUnreadBadge = true

    var body: some View {
        List {
            Section("Language") {
                Picker("Language", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }
                if appLanguage != AppLanguage.launchLanguage {
                    Text("Restart Nook to apply the language change.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .warmRows()

            Section("App Icon") {
                Toggle("Show unread count on app icon", isOn: $showUnreadBadge)
            }
            .warmRows()
        }
        .warmListBackground()
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: appLanguage) { _, newValue in
            AppLanguage.apply(newValue)
        }
    }
}

// MARK: - Reading

private struct ReadingSettingsScreen: View {
    @AppStorage("markReadOnOpen") private var markReadOnOpen = true
    @AppStorage("markReadDelaySeconds") private var markReadDelaySeconds = 3
    @AppStorage("readerViewMode") private var readerViewMode = ReaderViewMode.reader
    @AppStorage("readerLinkBehavior") private var readerLinkBehavior = ReaderLinkBehavior.inApp
    @AppStorage(ReaderStore.longPressOpensBrowserKey) private var longPressOpensBrowser = false

    var body: some View {
        List {
            Section("Reading") {
                Toggle("Mark articles as read when opened", isOn: $markReadOnOpen)
                Stepper("Mark as read after \(markReadDelaySeconds) seconds", value: $markReadDelaySeconds, in: 0...30)
                    .disabled(!markReadOnOpen)
            }
            .warmRows()

            Section("In-App Browser") {
                Picker("In-App Browser", selection: $readerViewMode) {
                    ForEach(ReaderViewMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Links Open", selection: $readerLinkBehavior) {
                    ForEach(ReaderLinkBehavior.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Press and hold article to open browser", isOn: $longPressOpensBrowser)
                Text("When on, press-and-hold the article body to open the in-app browser. The toolbar button opens it either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .warmRows()
        }
        .warmListBackground()
        .navigationTitle("Reading")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Reader

private struct ReaderSettingsScreen: View {
    @AppStorage("readerFont") private var readerFont = ReaderFont.system
    @AppStorage("readerFontSize") private var readerFontSize = 18
    @AppStorage("readerLineHeight") private var readerLineHeight = 1.7
    @AppStorage("readerLetterSpacing") private var readerLetterSpacing = 0.0
    @AppStorage("readerBackgroundOption") private var readerBackgroundOption = ReaderColorOption.automatic
    @AppStorage("readerBackgroundHex") private var readerBackgroundHex = "#FFFFFF"
    @AppStorage("readerTextOption") private var readerTextOption = ReaderColorOption.automatic
    @AppStorage("readerTextHex") private var readerTextHex = "#1A1A1A"
    // Keep the original defaults key so people who already chose a side retain
    // that exact layout after the setting is reframed around control placement.
    @AppStorage("readerControlHand") private var defaultControlSide = ReaderControlSide.right
    @AppStorage("readerHandedness") private var readerHandedness = ReaderHandedness.right
    @AppStorage("readerAdaptiveControlsEnabled") private var adaptiveControlsEnabled = true

    private var backgroundColor: Binding<Color> {
        Binding { Color(hex: readerBackgroundHex) } set: { readerBackgroundHex = $0.hexString }
    }
    private var textColor: Binding<Color> {
        Binding { Color(hex: readerTextHex) } set: { readerTextHex = $0.hexString }
    }

    var body: some View {
        List {
            Section {
                Picker("Font", selection: $readerFont) {
                    ForEach(ReaderFont.allCases) { Text($0.label).tag($0) }
                }
                Stepper("Font Size: \(readerFontSize)", value: $readerFontSize, in: 12...28)
                Stepper("Line Spacing: \(String(format: "%.1f", readerLineHeight))", value: $readerLineHeight, in: 1.2...2.4, step: 0.1)
                Stepper("Letter Spacing: \(String(format: "%.2f", readerLetterSpacing))", value: $readerLetterSpacing, in: -0.02...0.15, step: 0.01)
            } header: {
                Text("Typography")
            } footer: {
                Text("These options apply when reading in reader mode.")
            }
            .warmRows()

            Section("Colors") {
                Picker("Background", selection: $readerBackgroundOption) {
                    ForEach(ReaderColorOption.allCases) { Text($0.label).tag($0) }
                }
                if readerBackgroundOption == .custom {
                    ColorPicker("Background Color", selection: backgroundColor, supportsOpacity: false)
                }
                Picker("Text", selection: $readerTextOption) {
                    ForEach(ReaderColorOption.allCases) { Text($0.label).tag($0) }
                }
                if readerTextOption == .custom {
                    ColorPicker("Text Color", selection: textColor, supportsOpacity: false)
                }
            }
            .warmRows()

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Default Position")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        ForEach(ReaderControlSide.allCases) { side in
                            ReaderControlPositionChoice(
                                side: side,
                                isSelected: defaultControlSide == side
                            ) {
                                withAnimation(.snappy(duration: 0.25)) {
                                    defaultControlSide = side
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)

                Picker("Primary Hand", selection: $readerHandedness) {
                    Text("Left Hand").tag(ReaderHandedness.left)
                    Text("Right Hand").tag(ReaderHandedness.right)
                }
                .pickerStyle(.segmented)

                Toggle("Adapt to scrolling side", isOn: $adaptiveControlsEnabled)
            } header: {
                Text("Bottom Controls")
            } footer: {
                Text("Choose your default control position separately from your primary hand. Adaptive mode keeps that layout while you scroll with your primary hand, mirrors it after several scrolls with the other hand, and restores it when you switch back.")
            }
            .warmRows()
        }
        .warmListBackground()
        .navigationTitle("Reader")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A compact preview of the native reader bar. The accent-colored capsule shows
/// where the frequently used controls will sit, making the setting understandable
/// before someone has to leave Settings and open an article.
private struct ReaderControlPositionChoice: View {
    let side: ReaderControlSide
    let isSelected: Bool
    let action: () -> Void

    private var label: LocalizedStringKey {
        side == .left ? "Left Side" : "Right Side"
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.045))

                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.22))
                            .frame(width: 46, height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.14))
                            .frame(width: 58, height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.14))
                            .frame(width: 52, height: 4)
                        Spacer(minLength: 4)
                    }
                    .padding(.top, 12)

                    HStack(spacing: 0) {
                        controlCapsule(highlighted: side == .left)
                        Spacer(minLength: 10)
                        controlCapsule(highlighted: side == .right)
                    }
                    .padding(7)
                }
                .frame(height: 76)

                HStack(spacing: 5) {
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.55))
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.22),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func controlCapsule(highlighted: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: highlighted ? "doc.plaintext" : "square.and.arrow.up")
            Image(systemName: highlighted ? "character.bubble" : "star")
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(highlighted ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(.thinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(
                    highlighted ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.18),
                    lineWidth: 0.75
                )
        }
    }
}

// MARK: - Feeds

private struct FeedsSettingsScreen: View {
    @Bindable var store: ReaderStore
    @Environment(\.openURL) private var openURL
    @AppStorage("autoRefreshEnabled") private var autoRefreshEnabled = true
    @AppStorage("refreshIntervalMinutes") private var refreshIntervalMinutes = 30
    @AppStorage(ReaderStore.resolveMissingDatesKey) private var resolveMissingDates = true
    @AppStorage(BackgroundRefresh.enabledKey) private var newArticleNotifications = false
    @AppStorage(ReaderStorage.displayPathDefaultsKey) private var syncFolderDisplayPath = ""
    /// True when notifications are on but iOS won't actually show alert banners
    /// (denied, or authorized for badge only) — the usual reason "notifications
    /// don't arrive."
    @State private var alertsBlocked = false
    /// True when notifications are on but iOS won't run Nook in the background
    /// (Background App Refresh off, globally or for Nook) — so scheduled refreshes
    /// never fire and no new-article notification can ever arrive.
    @State private var backgroundRefreshBlocked = false
    @State private var notificationStatus = "—"
    @State private var backgroundStatus = "—"
    @State private var pendingRefreshCount = 0

    private var sortedFeeds: [Feed] {
        store.feeds.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                Toggle("Refresh feeds automatically", isOn: $autoRefreshEnabled)
                Stepper("Refresh every \(refreshIntervalMinutes) minutes", value: $refreshIntervalMinutes, in: 5...240, step: 5)
                    .disabled(!autoRefreshEnabled)
                Toggle("Fill in missing article dates", isOn: $resolveMissingDates)
            } header: {
                Text("Feeds")
            } footer: {
                Text("Some feeds omit each article's date. When enabled, Nook reads the real date from the article's page (once per article).")
            }
            .warmRows()

            Section {
                Toggle("Notify me about new articles", isOn: $newArticleNotifications)
                if newArticleNotifications && backgroundRefreshBlocked {
                    Button {
                        openSystemSettings()
                    } label: {
                        Label("Turn on Background App Refresh", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if newArticleNotifications && alertsBlocked {
                    Button {
                        openSystemSettings()
                    } label: {
                        Label("Turn on notifications in Settings", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                Button("Send Test Notification") {
                    Task {
                        await NewArticleNotifier.post(
                            title: String(localized: "New in Nook"),
                            body: String(localized: "Test notification"),
                            badge: 0
                        )
                        UserDefaults.standard.set("test submitted", forKey: BackgroundRefresh.lastNotificationResultKey)
                    }
                }
                .disabled(alertsBlocked)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if newArticleNotifications && backgroundRefreshBlocked {
                        Text("Background App Refresh is off, so Nook can't check for new articles in the background and no notifications will arrive. Tap above, then turn on Settings › General › Background App Refresh and enable it for Nook.")
                            .foregroundStyle(.orange)
                    }
                    if newArticleNotifications && alertsBlocked {
                        Text("Notification banners are turned off for Nook, so new-article alerts won't appear. Enable them in Settings › Nook › Notifications.")
                            .foregroundStyle(.orange)
                    }
                    Text("Nook checks for new articles in the background and sends a notification when some arrive. iOS decides exactly when to run this, so timing is approximate.")
                }
            }
            .warmRows()

            Section("Background Diagnostics") {
                LabeledContent("Notification Authorization", value: notificationStatus)
                LabeledContent("Background App Refresh", value: backgroundStatus)
                LabeledContent("Pending Requests", value: "\(pendingRefreshCount)")
                diagnosticRow("Last Schedule", key: BackgroundRefresh.lastScheduleKey)
                diagnosticRow("Schedule Result", key: BackgroundRefresh.lastScheduleResultKey)
                diagnosticRow("Last Run", key: BackgroundRefresh.lastRunKey)
                diagnosticRow("Fetch Result", key: BackgroundRefresh.lastFetchResultKey)
                diagnosticRow("Notification Result", key: BackgroundRefresh.lastNotificationResultKey)
            }
            .warmRows()

            Section {
                if sortedFeeds.isEmpty {
                    Text("No feeds yet. Add feeds from the sidebar.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedFeeds) { feed in
                        Picker(selection: viewModeBinding(for: feed)) {
                            Text("Default").tag(ReaderViewMode?.none)
                            Text(ReaderViewMode.reader.label).tag(ReaderViewMode?.some(.reader))
                            Text(ReaderViewMode.original.label).tag(ReaderViewMode?.some(.original))
                        } label: {
                            Text(feed.displayTitle).lineLimit(1)
                        }
                    }
                }
            } header: {
                Text("Reading View")
            } footer: {
                Text("Choose how each feed's articles open in the web view. “Default” follows the In-App Browser setting above.")
            }
            .warmRows()

            Section {
                LabeledContent("Sync Folder", value: syncFolderDisplayPath.isEmpty ? String(localized: "Not selected") : syncFolderDisplayPath)
            } header: {
                Text("Storage")
            } footer: {
                Text("Nook keeps your feeds in a folder in the cloud so they stay in sync across your devices.")
            }
            .warmRows()
        }
        .warmListBackground()
        .navigationTitle("Feeds")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: newArticleNotifications) { await checkAlerts() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await checkAlerts() }
        }
    }

    /// Notifications are "blocked" if the user turned them on but iOS won't show
    /// banners — denied, or authorized for badge only (a stale earlier grant).
    private func checkAlerts() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        alertsBlocked = settings.authorizationStatus == .denied
            || (settings.authorizationStatus == .authorized && settings.alertSetting != .enabled)
        notificationStatus = String(describing: settings.authorizationStatus)
        let refreshStatus = UIApplication.shared.backgroundRefreshStatus
        backgroundRefreshBlocked = refreshStatus != .available
        backgroundStatus = switch refreshStatus {
        case .available: "available"
        case .denied: "denied"
        case .restricted: "restricted"
        @unknown default: "unknown"
        }
        pendingRefreshCount = await withCheckedContinuation { continuation in
            BGTaskScheduler.shared.getPendingTaskRequests { requests in
                continuation.resume(returning: requests.filter { $0.identifier == BackgroundRefresh.taskIdentifier }.count)
            }
        }
    }

    /// Opens Nook's page in the system Settings app — the deepest link the OS
    /// allows. From there the user reaches Notifications and (when the global
    /// switch is on) Background App Refresh for Nook; the footer text points them
    /// to Settings › General › Background App Refresh for the global toggle.
    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }

    @ViewBuilder
    private func diagnosticRow(_ title: LocalizedStringKey, key: String) -> some View {
        let defaults = UserDefaults.standard
        if let date = defaults.object(forKey: key) as? Date {
            LabeledContent(title) { Text(date, style: .relative) }
        } else {
            LabeledContent(title, value: defaults.string(forKey: key) ?? "—")
        }
    }

    private func viewModeBinding(for feed: Feed) -> Binding<ReaderViewMode?> {
        Binding(
            get: { store.feed(for: feed.id)?.preferredViewMode },
            set: { store.setPreferredViewMode($0, feedIDs: [feed.id]) }
        )
    }
}

// MARK: - Experimental

private struct ArticleRulesSettingsScreen: View {
    let store: ReaderStore

    var body: some View {
        List {
            Section("Article Rules") {
                ArticleRulesSettingsContent(store: store)
            }
            .warmRows()
        }
        .warmListBackground()
        .navigationTitle("Article Rules")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct OfflineSettingsScreen: View {
    let store: ReaderStore

    var body: some View {
        List {
            Section("Offline Reading") {
                OfflineSettingsContent(store: store)
            }
            .warmRows()
        }
        .warmListBackground()
        .navigationTitle("Offline")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FiltersSettingsScreen: View {
    let store: ReaderStore
    @AppStorage(ReaderStore.filterGuideSeenKey) private var filterGuideSeen = false
    @State private var showGuide = false

    var body: some View {
        List {
            Section("Filters") {
                FilterSettingsContent(store: store, onShowGuide: { showGuide = true })
            }
            .warmRows()
        }
        .warmListBackground()
        .navigationTitle("Filters")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showGuide) {
            FilterGuideView(onDone: { showGuide = false })
                .presentationDragIndicator(.visible)
        }
        // Show the tutorial once, the first time the user opens Filters settings.
        .task {
            guard !filterGuideSeen else { return }
            filterGuideSeen = true
            showGuide = true
        }
    }
}

private struct ExperimentalSettingsScreen: View {
    @AppStorage(ReaderStore.readerContentByDefaultKey) private var readerContentByDefault = true
    @AppStorage(ReaderStore.translateListTitlesKey) private var translateListTitles = false
    @AppStorage(ReaderStore.coherentArticleTranslationKey) private var coherentArticleTranslation = false
    @State private var confirmingClearTranslationCache = false
    @State private var confirmingAppReset = false
    @State private var preservesGeminiCredential = false
    @State private var preservesWebSessions = false
    @State private var isResetting = false
    @State private var resetErrorMessage: String?

    var body: some View {
        List {
            Section("Translation Engine") {
                TranslationEngineSettingsContent()
            }
            .warmRows()

            Section("Reader View") {
                Toggle("Show reader view content by default", isOn: $readerContentByDefault)
                Text("Fetches the full article and shows its Reader-view content in the native reader instead of the feed's summary. Turn off to read the original feed content. If Reader view can't be loaded, the original content is shown with a notice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Coherent long-article translation", isOn: $coherentArticleTranslation)
                Text("When translating a full article, keeps the previous paragraph in context so the translation reads more consistently across a long piece. Experimental — it falls back to the standard paragraph-by-paragraph translation whenever needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .warmRows()

            Section("Article List") {
                Toggle("Translate titles in the list", isOn: $translateListTitles)
                Text("Titles of the stories on screen are translated into your language with Apple Intelligence, shown beneath the original. Only titles that stay in view are translated, and results are cached. Titles already in your language are left as-is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(role: .destructive) {
                    confirmingClearTranslationCache = true
                } label: {
                    Text("Clear Translation Cache")
                }
            }
            .warmRows()

            Section("Reset Nook") {
                Toggle("Keep Gemini API key", isOn: $preservesGeminiCredential)
                Toggle("Keep website login sessions", isOn: $preservesWebSessions)

                Button(role: .destructive) {
                    confirmingAppReset = true
                } label: {
                    HStack {
                        Text("Reset Nook…")
                        Spacer()
                        if isResetting {
                            ProgressView()
                        }
                    }
                }
                .disabled(isResetting)

                Text("Removes this device's settings, sync folder connection, offline articles, and caches. Files in your sync folder are never changed. Sign-in data is deleted unless you choose to keep it above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let resetErrorMessage {
                    Label(resetErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .warmRows()
        }
        .warmListBackground()
        .navigationTitle("Experimental")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Clear Translation Cache",
            isPresented: $confirmingClearTranslationCache,
            titleVisibility: .visible
        ) {
            Button("Clear Translation Cache", role: .destructive) {
                ListTitleTranslator.shared.clearCache()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes all saved title translations on this device. Titles are translated again as you view them.")
        }
        .confirmationDialog(
            "Reset Nook?",
            isPresented: $confirmingAppReset,
            titleVisibility: .visible
        ) {
            Button("Reset Nook", role: .destructive) {
                performAppReset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Local settings and downloaded data can't be recovered. Your sync folder will not be changed. Nook will return to the welcome screen.")
        }
    }

    private func performAppReset() {
        resetErrorMessage = nil
        isResetting = true
        let options = LocalAppResetOptions(
            preservesGeminiCredential: preservesGeminiCredential,
            preservesWebSessions: preservesWebSessions
        )
        Task {
            do {
                try await IOSAppResetCoordinator.reset(options: options)
            } catch {
                resetErrorMessage = error.localizedDescription
                isResetting = false
            }
        }
    }
}

// MARK: - About

private struct AboutSettingsScreen: View {
    static let repositoryURL = URL(string: "https://github.com/selenehyun/nook")!

    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    private var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1" }

    var body: some View {
        List {
            Section("About") {
                LabeledContent("Version", value: "\(version) (\(build))")
                if let url = feedbackURL {
                    Link(destination: url) {
                        Label("Send Feedback…", systemImage: "envelope")
                    }
                }
                Link(destination: Self.repositoryURL) {
                    Label {
                        Text(verbatim: "GitHub")
                    } icon: {
                        Image("GitHubMark").renderingMode(.template)
                    }
                }
            }
            .warmRows()
        }
        .warmListBackground()
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var feedbackURL: URL? {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let subject = String(localized: "Nook Feedback")
        let intro = String(localized: "Please describe your bug report, feature request, or idea below. Screenshots are welcome.")
        let prompts = String(localized: "• What were you trying to do?\n\n• What actually happened?\n\n• What did you expect instead?")
        let diagnosticsHeader = String(localized: "— Diagnostics (helps with troubleshooting; feel free to delete) —")
        let diagnostics = String(localized: "Nook \(version) (\(build)) · iOS \(osString)")
        let body = "\(intro)\n\n\(prompts)\n\n\n\(diagnosticsHeader)\n\(diagnostics)"

        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&?=+")
        let s = subject.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let b = body.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "mailto:rationlunas@gmail.com?subject=\(s)&body=\(b)")
    }
}

/// Gives a `List`/`Form` the app's warm tone — hiding the default system grouped
/// background and letting `ListBackground` show through transparent rows — so
/// Settings matches the article list instead of the plain (or cool frosted)
/// system background.
private extension View {
    /// Warm background for a Settings list. Rows must additionally use
    /// `.warmRows()` on each `Section` — a container-level row background does not
    /// reach grouped-list rows, leaving cool `secondarySystemGroupedBackground`
    /// cards, so the clear must be applied per-section.
    func warmListBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Color("ListBackground").ignoresSafeArea())
            // Tighten the grouped list's generous section spacing (and the large
            // gap above the first section) so the top isn't mostly whitespace.
            .listSectionSpacing(.compact)
            .contentMargins(.top, 8, for: .scrollContent)
    }

    /// Clears a `Section`'s row cards so the warm background shows through. Applied
    /// per section because that reliably reaches the rows.
    func warmRows() -> some View {
        listRowBackground(Color.clear)
    }
}
