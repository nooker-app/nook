import NookKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// The iOS reader UI. Reuses the shared `ReaderStore` from NookKit; only the
/// presentation differs from the macOS app.
///
/// The shell branches on horizontal size class: compact width (iPhone portrait)
/// opens straight into a bottom `TabView` (Home / Feeds / Starred / Settings);
/// regular width (iPad) keeps the three-column `NavigationSplitView`.
struct RootView: View {
    @Bindable private var store = ReaderStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("autoRefreshEnabled") private var autoRefreshEnabled = false
    @AppStorage("showUnreadBadge") private var showUnreadBadge = false
    @AppStorage("markReadOnOpen") private var markReadOnOpen = true
    @AppStorage("markReadDelaySeconds") private var markReadDelaySeconds = 3
    @AppStorage(BackgroundRefresh.enabledKey) private var newArticleNotifications = false
    @AppStorage(TourFlags.hasCompletedWelcomeKey) private var hasCompletedWelcome = false
    @AppStorage(ReaderStore.translateTitlesPromoSeenKey) private var hasSeenTranslatePromo = false
    @AppStorage(ReaderStore.translateListTitlesKey) private var translateListTitles = false
    @State private var isReady = false
    @State private var showWelcome = false
    @State private var showNotificationOptIn = false
    /// Answered once and never asked again — replaying the tutorial must not
    /// re-ask a question the reader has already answered.
    @AppStorage(NotificationOptInSheet.seenKey) private var hasSeenNotificationOptIn = false
    @State private var showTranslatePromo = false
    /// Drives the tutorial's hand-off from the welcome cover into the live app
    /// (add the sample feed, then hint the list). In-memory, shared via environment.
    @State private var tour = TourCoordinator()
    @State private var tabChrome = TabBarChrome()
    /// A share-extension "find the feed" request being shown as a sheet.
    @State private var discoveryRequest: FeedDiscoveryRequest?
    /// The just-saved link's title, driving the "Saved to Nook" confirmation.
    @State private var savedLinkTitle: String?

    var body: some View {
        ZStack {
            shell
                // First-run tutorial, mounted here so one cover reaches both the
                // iPhone tab shell and the iPad split view. Swipe-to-dismiss also
                // completes it (onDismiss), so it won't re-appear next launch.
                .fullScreenCover(isPresented: $showWelcome, onDismiss: {
                    hasCompletedWelcome = true
                    // Asked here and nowhere else. The tutorial is over, so the
                    // reader knows what Nook is before being asked what it may
                    // notify them about — and nothing is on to ask about until
                    // they say so. Swiping the tutorial away also lands here, so
                    // the question is not lost by skipping it.
                    if !hasSeenNotificationOptIn { showNotificationOptIn = true }
                }) {
                    WelcomeSheet(store: store, onFinish: { showWelcome = false })
                }
                .sheet(isPresented: $showNotificationOptIn) {
                    NotificationOptInSheet()
                }
                // One-time promo introducing list-title translation, shown only
                // once the tutorial is behind the user (see `.task` below).
                .sheet(isPresented: $showTranslatePromo) {
                    TranslateTitlesPromoView(
                        onEnable: {
                            translateListTitles = true
                            showTranslatePromo = false
                        },
                        onNotNow: { showTranslatePromo = false }
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
                // Replaying from Settings flips this back to false; re-present the
                // tour once the UI is up (the one-shot bootstrap trigger won't fire
                // again).
                .onChange(of: hasCompletedWelcome) { _, completed in
                    if !completed, isReady { showWelcome = true }
                }
                .onReceive(NotificationCenter.default.publisher(for: .nookDidResetLocalAppData)) { _ in
                    showTranslatePromo = false
                    hasCompletedWelcome = false
                    hasSeenTranslatePromo = false
                    tour = TourCoordinator()
                    showWelcome = true
                }
                .task {
                    // The store computes the unread count; iOS reflects it on the
                    // app icon badge (requires notification authorization).
                    store.onUnreadBadgeChange = { count in
                        UNUserNotificationCenter.current().setBadgeCount(count)
                    }
                    store.showsUnreadBadge = showUnreadBadge
                    // Cold launch is foreground; `scenePhase`'s onChange doesn't fire
                    // for the initial value, so set active here or the on-screen list
                    // would never be marked "seen" until the first background→active
                    // cycle.
                    store.setForegroundActive(true)
                    // Warm up WebKit well after launch — off the critical path so its
                    // WebContent process (and the noisy system logs it emits) spin up
                    // once the app is settled, not during launch. Independent task with
                    // its own timer so the delay is measured from launch, still ahead
                    // of the user's first article tap. Idempotent, so a tap that beats
                    // it is fine.
                    Task {
                        try? await Task.sleep(for: .seconds(6))
                        WebViewWarmer.warmUp()
                    }
                    // Overlap the splash's brand beat with bootstrap instead of
                    // serializing them: launch takes max(bootstrap, 1.85s), not the sum.
                    let splashStart = ContinuousClock.now
                    await store.bootstrap()
                    // First run (iOS only): bring a local library online so the
                    // tour can subscribe starter picks — and reading works —
                    // before any folder is ever chosen. No-op for existing
                    // users and once a real sync folder is configured.
                    await store.configureLocalStorageIfNeeded()
                    // Keep the splash up while the nest assembles and the wordmark
                    // appears, then reveal the loaded UI.
                    let remaining = .milliseconds(1850) - splashStart.duration(to: .now)
                    if remaining > .zero { try? await Task.sleep(for: remaining) }
                    withAnimation(.easeOut(duration: 0.35)) { isReady = true }
                    // First launch: after the splash reveal (so it doesn't fight the
                    // splash transition), present the welcome tour. The app is fully
                    // loaded underneath, so skipping drops straight into it.
                    if !hasCompletedWelcome {
                        // New user: run the tutorial now; the translate promo waits
                        // until a later launch (once the tutorial is fully behind
                        // them) so it never interrupts onboarding.
                        showWelcome = true
                    } else {
                        maybePresentTranslateTitlesPromo()
                    }
                    // No permission prompt here, and this is the whole point of the
                    // change. The badge used to default on, which was enough to
                    // satisfy the "are any notification features in use" check — so
                    // the system prompt appeared on the very first launch of every
                    // install, over the tutorial, before the reader knew what Nook
                    // was. A prompt is asked once and answered forever.
                    //
                    // Every notification setting now starts off, and asking happens
                    // in two places only: the sheet after the tutorial, and a toggle
                    // being switched on. Scheduling below is not a prompt and is a
                    // no-op until new-article alerts are on.
                    BackgroundRefresh.schedule()
                }
                .onChange(of: showUnreadBadge) { _, newValue in
                    store.showsUnreadBadge = newValue
                    if newValue { Task { await requestNotificationAuthorizationIfNeeded() } }
                }
                .onChange(of: newArticleNotifications) { _, enabled in
                    if enabled {
                        Task { await requestNotificationAuthorizationIfNeeded() }
                        BackgroundRefresh.schedule()
                    } else {
                        BackgroundRefresh.cancel()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // Returning to the foreground: pull another device's changes
                        // from the sync folder, then refresh feeds over the network.
                        // Foreground-active marks the on-screen list "seen" so its
                        // articles don't fire a background notification later.
                        store.setForegroundActive(true)
                        store.setSyncObservationActive(true)
                        store.syncFromDisk()
                        // In the app now: clear any lingering "new articles" banner.
                        NewArticleNotifier.clearDelivered()
                        if autoRefreshEnabled { store.refreshOnActivation(honorThrottle: true) }
                    case .background:
                        // Queue the next background refresh as we leave, and land
                        // any shard write still in its trailing-save window.
                        store.setForegroundActive(false)
                        store.setSyncObservationActive(false)
                        store.flushPendingShardSave()
                        BackgroundRefresh.schedule()
                    case .inactive:
                        store.setForegroundActive(false)
                        store.flushPendingShardSave()
                    default:
                        break
                    }
                }
                .onOpenURL { url in handleIncomingURL(url) }
                .sheet(item: $discoveryRequest) { request in
                    FeedDiscoverySheet(store: store, pageURLString: request.pageURLString)
                }
                .alert(
                    "Saved to Nook",
                    isPresented: Binding(
                        get: { savedLinkTitle != nil },
                        set: { if !$0 { savedLinkTitle = nil } }
                    ),
                    presenting: savedLinkTitle
                ) { _ in
                    Button("OK") { savedLinkTitle = nil }
                } message: { title in
                    Text(verbatim: title)
                }
                // Mark-read dwell lives here on the always-present root, keyed on the
                // selected article, so it isn't cancelled by the detail column being
                // pushed/popped in the collapsed split view (iPad) or a tab's
                // navigation stack (iPhone).
                .task(id: store.selectedArticleID) {
                    guard let id = store.selectedArticleID else { return }
                    store.retainArticle(id: id)
                    guard markReadOnOpen else { return }
                    do {
                        if markReadDelaySeconds > 0 {
                            try await Task.sleep(for: .seconds(Double(markReadDelaySeconds)))
                        } else {
                            await Task.yield()
                        }
                        store.markArticleOpened(articleID: id)
                    } catch {
                        // Navigated away before the dwell completed — leave it unread.
                    }
                }
                .alert(
                    "Something Went Wrong",
                    isPresented: Binding(
                        get: { store.errorMessage != nil },
                        set: { if !$0 { store.errorMessage = nil } }
                    ),
                    presenting: store.errorMessage
                ) { _ in
                    Button("OK", role: .cancel) { store.errorMessage = nil }
                } message: { message in
                    Text(message)
                }

            if !isReady {
                SplashView(store: store)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        // Apply Nook's signature accent explicitly across both shells (iPhone tab
        // bar and iPad split view). The asset-catalog global accent alone didn't
        // take effect, so tint the whole app root here.
        .tint(Color("AccentColor"))
        // Share the tutorial coordinator with both shells and the welcome cover.
        .environment(tour)
        .environment(tabChrome)
    }

    /// Presents the one-time list-title-translation promo — but only for a user
    /// who is already past the tutorial (this launch), so it never interrupts
    /// onboarding. New users therefore see it on a later launch, once the whole
    /// tutorial is behind them. Shown at most once (marked seen immediately), and
    /// only when Apple Intelligence is available and the feature isn't already on.
    private func maybePresentTranslateTitlesPromo() {
        guard hasCompletedWelcome,
              !hasSeenTranslatePromo,
              !translateListTitles,
              NaturalTranslator.isAvailable(for: TranslationSettings.titleProvider()) else { return }
        hasSeenTranslatePromo = true
        showTranslatePromo = true
    }

    @ViewBuilder
    private var shell: some View {
        if horizontalSizeClass == .compact {
            CompactShell(store: store)
        } else {
            RegularShell(store: store)
        }
    }

    /// Requests notification authorization, called only from a setting being
    /// switched on — never at launch.
    ///
    /// iOS shows the permission prompt only the first time, so we request the full
    /// set both features need (`alert`, `sound`, `badge`) up front. Requesting just
    /// `.badge` first would spend the one-time prompt and permanently foreclose
    /// alerts, so later enabling new-article notifications could never get
    /// banner/sound authorization.
    ///
    /// No `showUnreadBadge || newArticleNotifications` guard any more. It existed
    /// for the launch call, and because the badge defaulted on it was true on a
    /// fresh install — which is exactly how an unasked-for prompt appeared. The
    /// remaining callers are the two toggles, and reaching either one is the
    /// reader asking.
    private func requestNotificationAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Handles `nook://` deep links (sent by the share extension):
    /// - `add-feed?url=…` follows the site immediately (auto-discovery),
    /// - `discover-feed?url=…` opens the find-the-feed sheet (result + copy /
    ///   add / report),
    /// - `save-article?url=…` saves the page as a standalone article in the
    ///   managed Saved Links feed.
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "nook" else { return }
        // An invitation link carries a code for Plus setup.
        if PlusInviteInbox.shared.accept(url) { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let shared = components.queryItems?.first(where: { $0.name == "url" })?.value,
              !shared.isEmpty else { return }
        switch url.host {
        case "add-feed":
            Task {
                do {
                    try await store.addFeed(urlString: shared)
                } catch {
                    store.errorMessage = error.localizedDescription
                }
            }
        case "discover-feed":
            discoveryRequest = FeedDiscoveryRequest(pageURLString: shared)
        case "save-article":
            Task {
                do {
                    let id = try await store.saveLink(urlString: shared)
                    savedLinkTitle = store.article(withID: id)?.title ?? shared
                } catch {
                    store.errorMessage = error.localizedDescription
                }
            }
        default:
            break
        }
    }
}

// MARK: - Regular width (iPad) shell

/// The original three-column `NavigationSplitView` shell, unchanged. Owns the
/// sheet/importer state that the sidebar's ellipsis menu drives.
private struct RegularShell: View {
    @Bindable var store: ReaderStore
    @Environment(TourCoordinator.self) private var tour

    /// A single file importer backs both the sync-folder picker and OPML import;
    /// stacking two `.fileImporter` modifiers on one view makes only one work.
    enum ImportKind { case folder, opml }
    @State private var importKind: ImportKind = .folder
    @State private var isImporting = false
    @State private var isAddingFeed = false
    @State private var isExportingOPML = false
    @State private var opmlImport: OPMLImportRequest?
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var isShowingSettings = false
    /// The composer, present only while it is open — the same shape the phone uses.
    @State private var compose: ComposeSession?
    /// Kept between openings so a cancelled draft survives, and so a reader who
    /// never publishes never pays for a store.
    @State private var composeStore: PlusStore?
    /// Whether a Plus session exists, read from the flag in defaults rather than the
    /// Keychain so laying out a toolbar does not unlock it.
    @AppStorage(PlusCredential.configuredKey) private var signedInToPlus = false
    @AppStorage(PlusOwnFeed.publicationURLKey) private var ownPublicationURL = ""

    private struct ComposeSession: Identifiable {
        let id = UUID()
        let store: PlusStore
    }

    /// Opens the composer, building its store on first use — the phone's
    /// `startComposing`, kept in step with it deliberately.
    private func startComposing() {
        let store: PlusStore
        if let composeStore {
            store = composeStore
        } else {
            store = PlusStore()
            composeStore = store
        }
        store.syncFolder = { ReaderStore.shared.syncFolderURL }
        // A session read again rather than assumed: the store is kept between
        // openings, so signing in on another screen would otherwise leave Publish
        // disabled with the writing already on screen.
        Task { await store.prepareToCompose() }
        compose = ComposeSession(store: store)
    }

    /// Lands the writer on their own feed once the composer closes.
    ///
    /// Not the phone's reveal-in-the-reader flow, which fetches the new page with a
    /// banner and retries: on a split view the feed is already the middle column, so
    /// selecting it shows the post as soon as the feed carries it. Following first
    /// covers the writer who has published from another device but not this one.
    private func revealPublishedPost() {
        guard let composeStore, composeStore.lastPublishedURL != nil,
            let publication = composeStore.publicationURL.flatMap(URL.init(string:))
        else { return }
        // Consumed: one publish, one landing.
        composeStore.startNewDraft()
        Task {
            if OwnNook.followedFeed(in: store, publication: publication) == nil {
                _ = await OwnNook.follow(publication: publication, in: store)
            }
            guard let feed = OwnNook.followedFeed(in: store, publication: publication) else { return }
            store.feedSelection = [feed.id]
            store.smartSelection = nil
        }
    }

    /// Spelled out rather than inlined as a ternary: inline, the type checker gives
    /// up on the whole `NavigationSplitView` expression.
    private var composeAction: (() -> Void)? {
        signedInToPlus ? { startComposing() } : nil
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(
                store: store,
                chooseFolder: { importKind = .folder; isImporting = true },
                importOPML: { importKind = .opml; isImporting = true },
                isAddingFeed: $isAddingFeed,
                isExportingOPML: $isExportingOPML,
                isCreatingFolder: $isCreatingFolder,
                isShowingSettings: $isShowingSettings,
                onCompose: composeAction
            )
        } content: {
            ArticleList(store: store, selection: $store.selectedArticleID, onShowAllArticles: { store.selectSmartSource(.all) })
        } detail: {
            ReaderDetailView(store: store)
        }
        .navigationSplitViewStyle(.balanced)
        // Writing gets a screen of its own here too, reached from the sidebar rather
        // than from a tab bar this shell does not have.
        .sheet(item: $compose, onDismiss: revealPublishedPost) { session in
            PlusComposeView(store: session.store) { compose = nil }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: importKind == .folder ? [.folder] : [.opml, .xml],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            switch importKind {
            case .folder:
                _ = url.startAccessingSecurityScopedResource()
                store.configureSyncFolder(url)
            case .opml:
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
            document: OPMLDocument(feeds: store.exportableFeeds),
            contentType: .opml,
            defaultFilename: "NookSubscriptions.opml"
        ) { result in
            store.handleOPMLExport(result)
        }
        .sheet(isPresented: $isAddingFeed) {
            AddFeedView(folders: store.feedFolders) { feedURL, folder in
                try await store.addFeed(urlString: feedURL, toFolder: folder)
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(store: store)
        }
        .sheet(item: $opmlImport) { request in
            OPMLImportView(
                feeds: request.feeds,
                existingKeys: Set(store.feeds.flatMap { [$0.feedURL.feedIdentityKey, $0.siteURL.feedIdentityKey] })
            ) { selected in
                store.importFeeds(selected)
            }
        }
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Folder Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { store.createFolder(name) }
                newFolderName = ""
            }
        }
    }
}

// MARK: - Compact width (iPhone) shell

/// The selected tab. The shared store has one selection scope, so switching tabs
/// re-asserts the newly-active tab's scope (feeds/starred change
/// `feedSelection`/`smartSelection`, so returning to Home must restore its filter).
private enum AppTab: Hashable, CaseIterable { case home, feeds, starred, settings }

/// Drives the custom liquid-glass tab bar's collapse state from list scrolls,
/// Instagram-style: sustained scrolling down collapses the bar to the active
/// tab's pill; scrolling up, nearing the top, tapping the pill, or switching
/// tabs restores it. Hysteresis mirrors the reader's chrome auto-hide so
/// momentum jitter can't flicker the bar.
@MainActor
@Observable
final class TabBarChrome {
    private(set) var collapsed = false
    /// True while an article reader is pushed; the bar pops away entirely.
    /// Driven by `ReaderPushingList`'s pushed state (the store's
    /// `selectedArticleID` deliberately survives a pop for retention, so it
    /// can't serve as this signal).
    private(set) var readerOpen = false
    /// True while a Settings detail screen is pushed — the bar hides there too.
    private(set) var settingsDetailOpen = false

    /// Whether the bar (and its reserved bottom inset) should be gone.
    var barHidden: Bool { readerOpen || settingsDetailOpen }

    /// The explicit NavigationStack path is the source of truth. In particular,
    /// a cancelled interactive pop returns to a non-zero depth, so the bar
    /// cannot remain visible over a Settings detail screen.
    func setSettingsDetailDepth(_ depth: Int) {
        let open = depth > 0
        guard settingsDetailOpen != open else { return }
        settingsDetailOpen = open
        if !open { expand() }
    }
    /// Non-observed bookkeeping: only `collapsed` flips invalidate views.
    @ObservationIgnored private var lastY: CGFloat = 0
    @ObservationIgnored private var accum: CGFloat = 0

    /// Monotonic signal fired when the selected tab is re-tapped: the visible
    /// list scrolls back to the top, like the native tab bar's re-tap.
    private(set) var scrollToTopSignal = 0
    /// Set by an explicit user expand (tapping the bar, switching tabs) so an
    /// in-flight scroll's remaining travel can't immediately re-minimize what
    /// the user just restored. Cleared when the scroll comes to rest.
    @ObservationIgnored private var holdExpandedUntilIdle = false

    func setReaderOpen(_ open: Bool) {
        guard readerOpen != open else { return }
        readerOpen = open
        // Coming back from the reader always shows the full bar.
        if !open { expand() }
    }

    func requestScrollToTop() {
        scrollToTopSignal &+= 1
    }

    func noteScroll(offsetY: CGFloat) {
        let delta = offsetY - lastY
        lastY = offsetY
        // A different list took over (tab switch, push/pop) — resync silently.
        if abs(delta) > 300 {
            accum = 0
            return
        }
        // The bar always shows near the top.
        if offsetY < 60 {
            accum = 0
            setCollapsed(false)
            return
        }
        if (delta > 0) != (accum > 0) { accum = 0 }
        accum += delta
        if accum > 44 {
            // A user-restored bar stays restored for the rest of this scroll.
            if !holdExpandedUntilIdle { setCollapsed(true) }
        } else if accum < -44 {
            setCollapsed(false)
        }
    }

    /// The scroll settled — or a fresh gesture began. Either way the expand
    /// hold is spent: it only ever protects the remainder of the scroll that
    /// was in flight when the user tapped, never the NEXT scroll (a hold that
    /// outlived its gesture made the first scroll after a tab switch or a
    /// reader pop fail to minimize the bar).
    func releaseExpandHold() {
        holdExpandedUntilIdle = false
    }

    func expand() {
        accum = 0
        holdExpandedUntilIdle = true
        setCollapsed(false)
    }

    private func setCollapsed(_ value: Bool) {
        guard collapsed != value else { return }
        accum = 0
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            collapsed = value
        }
    }
}

/// A navigable source in the Feeds tab.
private enum FeedTarget: Hashable {
    case all
    case filtered
    case offline
    case category(String)
    case folder(String)
    case feed(Feed.ID)
}

/// The iPhone bottom-tab shell: Home (segmented Unread/Today/All), Feeds
/// (library), Starred, and Settings. The shared `ReaderStore` has a single
/// selection scope, so the shell re-asserts the active tab's scope whenever the
/// selected tab (or the Home filter / Feeds drill-down) changes.
private struct CompactShell: View {
    @Bindable var store: ReaderStore
    @Environment(TourCoordinator.self) private var tour
    @Environment(TabBarChrome.self) private var tabChrome
    @AppStorage(TourFlags.seenListHintKey) private var seenListHint = false
    @State private var selection: AppTab = .home

    /// The composer, present only while it is open.
    ///
    /// One piece of state rather than a flag plus an optional store. A sheet driven
    /// by `isPresented` builds its content from state read in the same update that
    /// set it, and got the old value: the sheet slid up empty and stayed empty until
    /// something else happened to invalidate it. An item-driven sheet is handed the
    /// value, so there is no window where it can be missing.
    @State private var compose: ComposeSession?

    /// The store outlives the sheet, so a cancelled draft is still there on the next
    /// tap, and a reader who never publishes never builds one.
    @State private var composeStore: PlusStore?

    /// The post just published, shown in the reader.
    @State private var justPublished: PublishedPost?

    /// One presentation of the reader over a just-published post.
    ///
    /// The identity is the presentation, not the article: swiping to the previous or
    /// next post inside the reader changes which article is shown, and if that were
    /// the sheet's identity the sheet would dismiss and re-present itself mid-swipe.
    private struct PublishedPost: Identifiable {
        let id = UUID()
        let article: Article
    }

    /// Progress of fetching a just-published post, which is worth showing: the
    /// public page is built after the record is written, so there is a short wait
    /// where nothing would otherwise be on screen.
    @State private var reveal: RevealPhase?

    private enum RevealPhase: Equatable {
        /// Following the writer's feed and waiting for the post to appear in it.
        case fetching
        /// Published, but not in the feed yet. Not a failure, and said as such.
        /// Carries what it was looking for, so the writer can ask again without
        /// republishing anything.
        case notInFeedYet(page: URL, feed: URL)
        /// The feed itself could not be reached.
        case failed(String)
    }

    /// Identifies one presentation of the composer.
    private struct ComposeSession: Identifiable {
        let id = UUID()
        let store: PlusStore
    }
    @State private var homeFilter: SmartSource = .unread
    @State private var feedsPath: [FeedTarget] = []
    /// Tutorial asked for the "tap a story" spotlight but it isn't shown yet
    /// (waiting to be on Home with articles). Owned here — the shell is always
    /// mounted, unlike the Home tab child whose lifecycle callbacks aren't
    /// guaranteed when it becomes the selected tab.
    @State private var listHintPending = false
    /// The spotlight is currently showing.
    @State private var showListHint = false
    /// The first article row's measured global frame, for an exact spotlight.
    /// When the Home tab was last re-tapped, for double-tap segment cycling.
    @State private var lastHomeReselect: ContinuousClock.Instant?

    var body: some View {
        TabView(selection: $selection) {
            HomeTab(store: store, filter: $homeFilter, goToSettings: { selection = .settings })
                // Nook's own nest mark (from the icon/splash twig geometry) —
                // on-brand and distinct from a generic house.
                .tabItem {
                    Image(uiImage: TabGlyph.nest)
                        .renderingMode(.template)
                        .accessibilityLabel(Text("Home"))
                }
                .modifier(NativeTabBarHider())
                .tag(AppTab.home)

            FeedsTab(store: store, path: $feedsPath)
                // Pre-rendered template rasters so the icon is outline when
                // unselected and filled when selected (the tab bar otherwise
                // force-fills symbol items on iOS 26). `list.bullet` has no filled
                // variant, so use `square.stack`.
                .tabItem {
                    Image(uiImage: TabGlyph.symbol(selection == .feeds ? "square.stack.fill" : "square.stack"))
                        .renderingMode(.template)
                        .accessibilityLabel(Text("Feeds"))
                }
                .modifier(NativeTabBarHider())
                .tag(AppTab.feeds)

            StarredTab(store: store)
                .tabItem {
                    Image(uiImage: TabGlyph.symbol(selection == .starred ? "star.fill" : "star"))
                        .renderingMode(.template)
                        .accessibilityLabel(Text("Starred"))
                }
                .modifier(NativeTabBarHider())
                .tag(AppTab.starred)

            SettingsView(store: store, isTab: true, onNavigationEvent: { event in
                switch event {
                case .depthChanged(let depth):
                    tabChrome.setSettingsDetailDepth(depth)
                }
            })
                .tabItem {
                    Image(uiImage: TabGlyph.symbol(selection == .settings ? "gearshape.fill" : "gearshape"))
                        .renderingMode(.template)
                        .accessibilityLabel(Text("Settings"))
                }
                .modifier(NativeTabBarHider())
                .tag(AppTab.settings)
        }
        // The custom liquid-glass tab bar (iOS 26): glass capsule background,
        // solid (no-glass) sliding pill under the selected item, shrinking in
        // place while the list scrolls down and popping away when the reader
        // opens. Below iOS 26 the native bar stays.
        .modifier(
            LiquidGlassTabBarHost(
                selection: $selection,
                onReselect: handleTabReselect,
                onCompose: startComposing
            )
        )
        // Writing gets a screen of its own, reached from the bar rather than from
        // Settings. The store is built on first use so a reader who never
        // publishes does not pay for it, and it is kept so a cancelled draft is
        // not thrown away by the next tap.
        .sheet(item: $compose, onDismiss: revealPublishedPost) { session in
            PlusComposeView(store: session.store) { compose = nil }
        }
        // The post that was just published, shown in the reader rather than handed
        // to Safari. Presented after the composer has gone (from its onDismiss),
        // because presenting a second sheet in the same update that dismisses the
        // first one loses it.
        .sheet(item: $justPublished) { session in
            PublishedPostReader(store: store, first: session.article) { justPublished = nil }
        }
        // Fetching it takes a moment, and a moment with nothing on screen reads as
        // nothing happening.
        .overlay(alignment: .top) {
            if reveal == .fetching {
                FetchingPostBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: reveal == .fetching)
        // Published but not in the feed yet. Not a failure, and not reported as one:
        // the record is written and the page is built. The feed is cached for up to
        // half a minute, which is longer than it is reasonable to hold a writer at a
        // spinner, so looking again is offered rather than waited out.
        .alert(
            "Your Post Is Published",
            isPresented: Binding(
                get: { if case .notInFeedYet = reveal { true } else { false } },
                set: { if !$0 { reveal = nil } }
            ),
            presenting: { if case .notInFeedYet(let page, let feed) = reveal { (page, feed) } else { nil } }()
        ) { target in
            Button("Look Again") {
                reveal = .fetching
                Task { await open(target.0, from: target.1) }
            }
            Button("OK", role: .cancel) { reveal = nil }
        } message: { _ in
            Text("Your feed hasn't picked it up yet. Feeds are cached for up to half a minute, so it will appear in My Nook shortly.")
        }
        // Following the feed failed, which is a real failure and says why.
        .alert(
            "Couldn't Open Your Post",
            isPresented: Binding(
                get: { if case .failed = reveal { true } else { false } },
                set: { if !$0 { reveal = nil } }
            ),
            presenting: { if case .failed(let why) = reveal { why } else { nil } }()
        ) { _ in
            Button("OK") { reveal = nil }
        } message: { why in
            Text("Your post is published. Nook couldn't reach your feed to show it: \(why)")
        }
        // The list spotlight is owned and drawn here at the shell — always mounted,
        // so unlike a TabView child it reliably reacts to the tutorial hand-off and
        // renders on top. Keep it showing as long as we're on Home (don't tie the
        // *keep* condition to the article count, which can blip empty on a scope
        // switch); the *start* condition below checks for articles.
        .overlay {
            if showListHint, selection == .home, store.isStorageConfigured {
                ListTapHint(
                    rowFrame: tour.firstRowFrame == .zero ? nil : tour.firstRowFrame,
                    onDismiss: dismissListHint)
                    .transition(.opacity)
            }
        }
        .onAppear { applySelection(selection) }
        .onChange(of: selection) { _, tab in
            applySelection(tab)
            tryStartListHint()
            // Switching tabs always restores the full bar (matches the native
            // minimize behavior and Instagram's).
            tabChrome.expand()
        }
        // Tutorial hand-off: the welcome cover subscribed the starter picks and
        // flipped `pendingFirstStoryHint`; the "route to Home → wait for
        // articles → spotlight the list" sequence is serialized here.
        .onChange(of: tour.pendingFirstStoryHint) { _, pending in
            guard pending else { return }
            tour.pendingFirstStoryHint = false
            guard !seenListHint else { return }
            listHintPending = true
            tour.listHintActive = true
            // Show "All" so the spotlight always has a row to point at — even on a
            // replay where every article in the starter feed is already read.
            homeFilter = .all
            selection = .home
            // Adding a feed leaves its first article selected; clear it so the next
            // non-nil selection is the user's own tap on a spotlighted row.
            store.selectedArticleID = nil
            tryStartListHint()
        }
        // Articles may arrive after the switch (async filtering / network) — retry.
        // Mounted only while the spotlight is requested: reading
        // `store.visibleArticles.count` in this body would otherwise make the
        // whole shell re-evaluate on every article-list change forever.
        .background {
            if tour.listHintActive {
                ListHintRetrigger(store: store, retry: tryStartListHint)
            }
        }
        // The user tapped a story (a selection appears) — dismiss; the reader and
        // its coach marks take over.
        .onChange(of: store.selectedArticleID) { _, id in
            if id != nil, showListHint { dismissListHint() }
        }
        .onChange(of: homeFilter) { _, _ in
            if selection == .home {
                clearSearch()
                store.selectSmartSource(homeFilter)
            }
        }
    }

    /// Observes the article count on behalf of the tutorial spotlight. Lives in
    /// its own tiny view so only this leaf — not the shell — depends on the
    /// article array; it unmounts entirely once the hint has been seen.
    /// Retries the list spotlight while it is waiting for articles to arrive.
    ///
    /// Mounted only while the spotlight is requested, which is the point: reading
    /// `store.visibleArticles.count` in the shell's own body made the whole shell
    /// re-evaluate on every article-list change, forever, for a hint shown once.
    ///
    /// It checks on appear as well as on change, and that is not belt-and-braces —
    /// it is the bug this had. `onChange` fires on transitions, not on the state it
    /// mounts with, so if the articles were already there when the spotlight was
    /// requested there was no transition left to observe and the hint never showed.
    /// The shell-wide `onChange` this replaced was always mounted, so it always saw
    /// the transition; scoping it to the hint's lifetime removed the very edge it
    /// depended on.
    private struct ListHintRetrigger: View {
        var store: ReaderStore
        var retry: () -> Void

        var body: some View {
            Color.clear
                .onAppear { retry() }
                .onChange(of: store.visibleArticles.count) { _, _ in retry() }
        }
    }

    /// The reader over a just-published post.
    ///
    /// Owns which article is showing so previous/next swipes stay inside the sheet
    /// instead of changing its identity. Clearing it is how the reader says it is
    /// done, which here means dismissing.
    private struct PublishedPostReader: View {
        var store: ReaderStore
        var onDone: () -> Void

        @State private var current: Article?

        init(store: ReaderStore, first: Article, onDone: @escaping () -> Void) {
            self.store = store
            self.onDone = onDone
            _current = State(initialValue: first)
        }

        var body: some View {
            NavigationStack {
                ReaderDetailView(store: store, articleOverride: $current)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { onDone() } label: { Text("Done") }
                        }
                    }
            }
            // A sheet does not inherit the root's tint (see the note at the app
            // root: the asset-catalogue accent alone does not take), so it has to be
            // set again here. Without it the reader's bottom bar drew its controls in
            // the system blue: it tints itself, but then resolves
            // `Color.accentColor` from the ambient environment, which was the default.
            .tint(Color("AccentColor"))
            .onChange(of: current == nil) { _, cleared in
                if cleared { onDone() }
            }
        }
    }

    /// Shown while a just-published post is fetched into the reader. A capsule at
    /// the top rather than a blocking overlay: the wait is short, and nothing about
    /// it should stop the writer from doing something else.
    private struct FetchingPostBanner: View {
        var body: some View {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Getting your post")
                    .font(.subheadline.weight(.medium))
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(background)
            .padding(.top, 8)
        }

        @ViewBuilder
        private var background: some View {
            if #available(iOS 26, *) {
                // Decorative, so .regular rather than .interactive().
                Capsule(style: .continuous).fill(.clear).glassEffect(.regular, in: .capsule)
            } else {
                Capsule(style: .continuous)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
        }
    }

    /// Opens the composer, building its store on first use.
    ///
    /// The store is created here rather than inside the sheet's content, because
    /// that closure runs during a view update and assigning to @State there is
    /// undefined. It is kept afterwards, so a cancelled draft survives and a
    /// reader who never publishes never pays for one.
    private func startComposing() {
        let store: PlusStore
        if let composeStore {
            store = composeStore
        } else {
            store = PlusStore()
            composeStore = store
        }
        // Publishing from here mirrors the writer's posts into the reader's sync
        // folder too, so the store is told where that is. The composer is the other
        // place a post is created, and a mirror only the settings screen refreshed
        // would be stale exactly when the writer just wrote something.
        store.syncFolder = { ReaderStore.shared.syncFolderURL }
        // A fresh draft, and a session read again rather than assumed. The store is
        // kept between openings, so without this the previous publish's confirmation
        // opened with the blank draft, and a session replaced by signing in on
        // another screen was never picked up — leaving Publish disabled with the
        // writing already on screen.
        //
        // Not gating: the fields are usable while this runs, and only Publish waits.
        Task { await store.prepareToCompose() }
        compose = ComposeSession(store: store)
    }

    /// Shows the post the writer just published, in the reader.
    ///
    /// Called as the composer goes away. Their publication is followed like any
    /// other feed, which is what makes the reader — offline, reader mode, starring —
    /// work on their own writing, and what puts it in the Feeds list for later.
    private func revealPublishedPost() {
        guard let composeStore, let published = composeStore.lastPublishedURL,
            let page = URL(string: published),
            let publication = composeStore.publicationURL.flatMap(URL.init(string:))
        else { return }
        // Consumed: one publish, one reveal.
        composeStore.startNewDraft()
        reveal = .fetching
        Task { await open(page, from: PlusOwnFeed.feedURL(for: publication)) }
    }

    /// Follows the writer's feed if it is not already followed, then opens the page.
    ///
    /// The public page is generated after the record is written, so the post can be
    /// missing from the feed for a moment. Refreshed a few times rather than once,
    /// and if it still has not arrived the writer is told so plainly instead of being
    /// left waiting on a sheet that never appears.
    private func open(_ page: URL, from feed: URL) async {
        do {
            // `addFeed` reuses a feed already followed at the same URL, so this is
            // safe to call on every publish.
            try await store.addFeed(urlString: feed.absoluteString)
        } catch {
            reveal = .failed(error.localizedDescription)
            return
        }

        // Adding a feed leaves its first article selected; that belongs to a reader
        // tapping a row, not to publishing.
        store.selectedArticleID = nil

        // Every wait is followed by a refresh and then another look, so the last
        // refresh is never thrown away unexamined.
        for wait in [Duration.seconds(0), .seconds(1), .seconds(3), .seconds(3)] {
            if wait > .zero {
                guard let followed = store.followedFeed(at: feed) else { break }
                do {
                    try await Task.sleep(for: wait)
                } catch {
                    reveal = nil  // Cancelled: the writer moved on.
                    return
                }
                await store.refreshFeedsAndWait(ids: [followed.id])
            }
            if let article = store.article(atPageURL: page) {
                reveal = nil
                // Route to My Nook underneath before opening the post. The reader's
                // previous/next swipe walks the visible scope, so without this the
                // writer swipes out of their own post and into whatever the last tab
                // was showing; and closing the sheet lands them somewhere that has
                // nothing to do with what they just published.
                if let followed = store.followedFeed(at: feed) {
                    selection = .feeds
                    feedsPath = [.feed(followed.id)]
                }
                justPublished = PublishedPost(article: article)
                return
            }
        }

        reveal = .notInFeedYet(page: page, feed: feed)
    }

    /// Native tab-bar re-tap semantics: a drilled-in Feeds tab pops to its
    /// root; everything else scrolls the visible list back to the top. On the
    /// Home tab, a quick second re-tap (double-tap) cycles the segment
    /// (Unread → Today → All) instead — and each further tap inside the window
    /// keeps cycling. Only re-taps count, so arriving from another tab (a
    /// selection change) can never trigger it.
    private func handleTabReselect(_ tab: AppTab) {
        if tab == .home {
            let now = ContinuousClock.now
            if let last = lastHomeReselect, last.duration(to: now) < .milliseconds(400) {
                advanceHomeFilter()
            } else {
                tabChrome.requestScrollToTop()
            }
            lastHomeReselect = now
        } else if tab == .feeds, !feedsPath.isEmpty {
            withAnimation { feedsPath.removeAll() }
        } else {
            tabChrome.requestScrollToTop()
        }
    }

    /// Cycles Home's segmented filter to the next source, wrapping around.
    private func advanceHomeFilter() {
        let order: [SmartSource] = [.unread, .today, .all]
        guard let index = order.firstIndex(of: homeFilter) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            homeFilter = order[(index + 1) % order.count]
        }
    }

    /// Starts the spotlight once we're actually on Home with something to open.
    /// Consumes the pending request only when it actually shows, so a momentary
    /// empty scope can't drop it on the floor.
    private func tryStartListHint() {
        guard listHintPending, !seenListHint,
              selection == .home,
              store.isStorageConfigured,
              !store.visibleArticles.isEmpty else { return }
        listHintPending = false
        withAnimation { showListHint = true }
    }

    private func dismissListHint() {
        seenListHint = true
        listHintPending = false
        tour.listHintActive = false
        withAnimation { showListHint = false }
    }

    /// Points the shared store at the scope the given tab shows. Also clears the
    /// shared search text, which would otherwise leak a query from the tab you
    /// left into the newly-shown scope.
    private func applySelection(_ tab: AppTab) {
        clearSearch()
        switch tab {
        case .home:
            store.selectSmartSource(homeFilter)
        case .starred:
            store.selectSmartSource(.starred)
        case .feeds:
            applyFeedTarget(feedsPath.last)
        case .settings:
            break
        }
    }

    private func applyFeedTarget(_ target: FeedTarget?) {
        guard let target else { return }
        CompactShell.applyScope(target, store: store)
    }

    private func clearSearch() {
        store.searchText = ""
        store.debounceSearch()
    }

    /// Points the shared store at a feed target's scope. Static so the Feeds tab's
    /// navigation destination can apply it directly (see `FeedsTab`).
    static func applyScope(_ target: FeedTarget, store: ReaderStore) {
        switch target {
        case .all:
            store.selectSmartSource(.all)
        case .filtered:
            store.selectSmartSource(.filtered)
        case .offline:
            store.selectSmartSource(.offline)
        case .category(let id):
            store.selectCategory(id)
        case .folder(let name):
            store.selectFolder(name)
        case .feed(let id):
            store.feedSelection = [id]
            store.smartSelection = nil
        }
    }
}

/// Minimizes the tab bar as the user scrolls down (restoring on scroll-up / at
/// the top) on iOS 26+, where the behavior is native; a no-op on earlier iOS.
/// Hides the system tab bar wherever the custom liquid-glass bar replaces it
/// (iOS 26); earlier systems keep the native bar untouched.
private struct NativeTabBarHider: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.toolbarVisibility(.hidden, for: .tabBar)
        } else {
            content
        }
    }
}

/// Reserves the custom tab bar's footprint as a bottom safe-area inset.
/// Applied to each screen's content INSIDE its NavigationStack — insets added
/// outside the stack (on the tab child or the TabView) don't reliably reach
/// the nested scroll views and fixed bottom content, which left Settings
/// buttons and list tails covered by the floating bar. Collapses to zero
/// whenever the bar is away (reader/detail pushes). No-op below iOS 26 and
/// where `enabled` is false (the iPad settings sheet).
struct TabBarInset: ViewModifier {
    var enabled: Bool = true
    @Environment(TabBarChrome.self) private var chrome

    /// The expanded bar's visual footprint: 44pt items + 8pt capsule padding
    /// + 6pt breathing room.
    static let barFootprint: CGFloat = 58

    func body(content: Content) -> some View {
        if enabled, #available(iOS 26, *) {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: chrome.barHidden ? 0 : Self.barFootprint)
                    .allowsHitTesting(false)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: chrome.barHidden)
            }
        } else {
            content
        }
    }
}

/// Overlays the custom tab bar at the bottom of the shell (iOS 26); each tab
/// reserves its footprint via `NativeTabBarHider`, so content lays out above
/// it while still scrolling under the glass strip. Below iOS 26 this is a
/// no-op and the native bar stays. Pushing a reader or a Settings detail
/// dismisses the bar with a slide-down + shrink-away pop; popping brings it
/// back the same way.
private struct LiquidGlassTabBarHost: ViewModifier {
    @Binding var selection: AppTab
    var onReselect: (AppTab) -> Void
    var onCompose: () -> Void
    @Environment(TabBarChrome.self) private var chrome
    /// Whether a Plus session exists. Read from the flag PlusCredential keeps in
    /// defaults rather than from the Keychain, so the shell does not unlock the
    /// Keychain to lay out a tab bar, and via AppStorage so signing in or out
    /// moves the button without a relaunch.
    @AppStorage(PlusCredential.configuredKey) private var signedInToPlus = false

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.overlay(alignment: .bottom) {
                ZStack {
                    if !chrome.barHidden {
                        LiquidGlassTabBar(
                            selection: $selection,
                            collapsed: chrome.collapsed,
                            onExpand: { chrome.expand() },
                            onReselect: onReselect,
                            onCompose: signedInToPlus ? onCompose : nil
                        )
                        .transition(
                            .move(edge: .bottom)
                                .combined(with: .scale(scale: 0.6, anchor: .bottom))
                                .combined(with: .opacity)
                        )
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: chrome.barHidden)
            }
        } else {
            content
        }
    }
}

/// The custom bottom bar, Instagram-on-iOS-26 style: a liquid-glass capsule
/// holding the tab icons, the selected item sitting on a solid (no-glass) pill
/// that slides between items like a segmented control. While the list scrolls
/// down the whole bar shrinks in place; scrolling up (or tapping it) restores
/// the full size.
@available(iOS 26, *)
private struct LiquidGlassTabBar: View {
    @Binding var selection: AppTab
    let collapsed: Bool
    var onExpand: () -> Void
    var onReselect: (AppTab) -> Void
    /// Nil for a reader with no publishing account, which is most people. They
    /// get the bar exactly as it was.
    var onCompose: (() -> Void)?

    /// Bumped on taps that aren't a selection change (restoring the minimized
    /// bar, re-tap scroll-to-top) so they get their own impact haptic.
    @State private var tapFeedback = 0

    /// The pill slide: a low-damping spring for a chewy, overshooting settle.
    private static let selectionSpring = Animation.spring(response: 0.4, dampingFraction: 0.62)

    private static let tabOrder: [AppTab] = [.home, .feeds, .starred, .settings]
    private static let itemWidth: CGFloat = 74
    private static let itemHeight: CGFloat = 44
    private static let itemSpacing: CGFloat = 2

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 8) {
                tabRow
                if let onCompose {
                    composeButton(onCompose)
                }
            }
        }
        // Scroll-down minimizes the bar in place (the whole capsule scales,
        // nothing rearranges); any touch or scroll-up restores it.
        .scaleEffect(collapsed ? 0.72 : 1, anchor: .bottom)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 2)
        // Hug the home indicator: sit right on the bottom safe-area edge.
        .padding(.bottom, 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: collapsed)
        // Haptics: crisp selection tick on tab changes; a light impact for the
        // non-selection taps (restore, re-tap scroll-to-top).
        .sensoryFeedback(.selection, trigger: selection)
        .sensoryFeedback(.impact(weight: .light), trigger: tapFeedback)
    }

    /// Writing sits outside the tab row on purpose. The four tabs are places to
    /// be; this is a thing to do, and giving it its own capsule keeps the
    /// selection pill from ever sliding under it.
    private func composeButton(_ action: @escaping () -> Void) -> some View {
        Button {
            if collapsed { onExpand() }
            tapFeedback &+= 1
            action()
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Self.accent)
                .frame(width: Self.itemHeight + 6, height: Self.itemHeight + 6)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // A tint this faint reads as warmth in the glass rather than as a
        // coloured button: the point is to look like the same material as the bar,
        // with Nook's colour behind it.
        .glassEffect(.regular.tint(Self.accent.opacity(0.14)).interactive(), in: Circle())
        .accessibilityLabel(Text("Write a post"))
    }

    /// Nook's brown, matching the app tint and the published pages. Shared with the
    /// Plus screens rather than copied, so the signature cannot drift in one place.
    fileprivate static let accent = PlusTheme.accent

    private var tabRow: some View {
        Group {
            HStack(spacing: Self.itemSpacing) {
                tabButton(.home, label: Text("Home"))
                tabButton(.feeds, label: Text("Feeds"))
                tabButton(.starred, label: Text("Starred"))
                tabButton(.settings, label: Text("Settings"))
            }
            // One pill translated between seats. A transform-only animation:
            // unlike matchedGeometryEffect (which re-laid-out all four buttons
            // — and thus recomposed the glass — on every spring frame, jamming
            // the same frames as the tab-content swap), an offset change
            // animates on the render server for near-free.
            .background(alignment: .leading) {
                Capsule()
                    .fill(Color(uiColor: .secondarySystemFill))
                    .frame(width: Self.itemWidth, height: Self.itemHeight)
                    .offset(x: selectionPillOffset)
            }
            .animation(Self.selectionSpring, value: selection)
            .padding(4)
            .glassEffect(.regular, in: Capsule())
        }
    }

    private func tabButton(_ tab: AppTab, label: Text) -> some View {
        Button {
            if collapsed {
                // A minimized bar's first tap just restores it, like the native
                // minimize; re-tap semantics apply only to the full-size bar.
                onExpand()
                if selection == tab { tapFeedback &+= 1 }
                selection = tab
            } else if selection == tab {
                tapFeedback &+= 1
                onReselect(tab)
            } else {
                selection = tab
            }
        } label: {
            icon(for: tab)
                .foregroundStyle(selection == tab ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: Self.itemWidth, height: Self.itemHeight)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
    }

    /// The selection pill's leading offset within the item row — the solid
    /// (no-glass) seat under the active tab, slid segmented-control style.
    private var selectionPillOffset: CGFloat {
        let index = CGFloat(Self.tabOrder.firstIndex(of: selection) ?? 0)
        return index * (Self.itemWidth + Self.itemSpacing)
    }

    @ViewBuilder
    private func icon(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            Image(uiImage: TabGlyph.nest).renderingMode(.template)
        case .feeds:
            Image(uiImage: TabGlyph.symbol(selection == .feeds ? "square.stack.fill" : "square.stack"))
                .renderingMode(.template)
        case .starred:
            Image(uiImage: TabGlyph.symbol(selection == .starred ? "star.fill" : "star"))
                .renderingMode(.template)
        case .settings:
            Image(uiImage: TabGlyph.symbol(selection == .settings ? "gearshape.fill" : "gearshape"))
                .renderingMode(.template)
        }
    }
}

// MARK: - Home tab

/// The default tab: a segmented Unread / Today / All filter over the article
/// list, with inline search. The tab item carries the unread badge.
private struct HomeTab: View {
    @Bindable var store: ReaderStore
    @Binding var filter: SmartSource
    var goToSettings: () -> Void

    private let filters: [SmartSource] = [.unread, .today, .all]

    /// Width of the tab's content (≈ the nav bar), captured so the principal
    /// segmented control can be given an explicit width — a principal toolbar item
    /// only gets its intrinsic size, so maxWidth:.infinity can't stretch it.
    @State private var contentWidth: CGFloat = 0

    /// Short labels for the nav-bar segmented control — "All Articles" is too wide
    /// there, so it shows as "All". The unread count is shown separately as a
    /// badge (see `segmentBadge`), not inline.
    private func segmentTitle(_ source: SmartSource) -> String {
        source == .all ? String(localized: "All") : source.title
    }

    /// The unread count to badge on the Unread segment (nil when zero or for
    /// other segments) — rendered as a number chip when focused, a dot otherwise.
    private func segmentBadge(_ source: SmartSource) -> Int? {
        guard source == .unread else { return nil }
        let count = store.count(for: .unread)
        return count > 0 ? count : nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.isStorageConfigured {
                    // The segmented filter lives in the navigation bar itself (no
                    // separate strip, no redundant title). Search is the full native
                    // search bar, revealed on demand by the toolbar button
                    // (ReaderPushingList's CompactSearchButton) — not an always-
                    // visible row, and not a cramped custom field.
                    ReaderPushingList(store: store, onShowAllArticles: { filter = .all })
                        .navigationBarTitleDisplayMode(.inline)
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .onChange(of: geo.size.width, initial: true) { _, w in contentWidth = w }
                            }
                        )
                        .toolbar {
                            ToolbarItem(placement: .principal) {
                                // A custom segmented control: tap a segment to switch
                                // category; tap the active one again to flip its sort
                                // order (saved per category). Native-looking (sliding
                                // capsule), like the reader's custom bottom bar.
                                SortableSegmentedControl(
                                    sources: filters,
                                    selection: $filter,
                                    title: segmentTitle,
                                    badge: segmentBadge,
                                    sortImage: { store.sortOrder(for: $0).systemImage },
                                    sortValue: {
                                        store.sortOrder(for: $0) == .newest
                                            ? String(localized: "Newest first")
                                            : String(localized: "Oldest first")
                                    },
                                    onReselect: { store.toggleSortOrder(for: $0) }
                                )
                                // Principal items only get their intrinsic size, so
                                // give an explicit width: the full content width
                                // minus room for the trailing search button, so the
                                // control stretches across to it.
                                .frame(width: max(240, contentWidth - 88))
                            }
                        }
                } else {
                    ContentUnavailableView {
                        Label("Set Up Sync", systemImage: "icloud.and.arrow.up")
                    } description: {
                        Text("Choose a sync folder so Nook keeps your feeds in sync across your devices.")
                    } actions: {
                        Button("Choose Sync Folder") { goToSettings() }
                    }
                    .background(Color("ListBackground").ignoresSafeArea())
                }
            }
        }
    }
}

/// A segmented control where tapping the already-selected segment re-fires
/// `onReselect` (used to flip the sort order) and shows a sort-direction glyph on
/// the active segment. Styled like a native segmented control — a track capsule
/// with a sliding highlight — so it fits the nav bar.
private struct SortableSegmentedControl: View {
    let sources: [SmartSource]
    @Binding var selection: SmartSource
    var title: (SmartSource) -> String
    var badge: (SmartSource) -> Int?
    var sortImage: (SmartSource) -> String
    var sortValue: (SmartSource) -> String
    var onReselect: (SmartSource) -> Void

    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Track/highlight height — matched to the adjacent nav-bar toolbar button.
    private let visualHeight: CGFloat = 44

    private var slide: Animation? {
        reduceMotion ? nil : .spring(duration: 0.38, bounce: 0.18)
    }

    var body: some View {
        ZStack {
            Capsule(style: .continuous).fill(Color(.tertiarySystemFill).opacity(0.55))

            // A single, always-present Liquid Glass pill that slides to the
            // selected segment (offset only). Per the review this is simpler and
            // more robust in a toolbar than glassEffectID/matchedGeometry, and as a
            // separate layer below the labels it never washes out the text.
            GeometryReader { proxy in
                let count = max(1, sources.count)
                let segmentWidth = proxy.size.width / CGFloat(count)
                let logical = sources.firstIndex(of: selection) ?? 0
                let visual = layoutDirection == .leftToRight ? logical : count - 1 - logical
                pill
                    .frame(width: segmentWidth, height: visualHeight)
                    .offset(x: CGFloat(visual) * segmentWidth)
                    .animation(slide, value: selection)
                    .allowsHitTesting(false)
            }

            HStack(spacing: 0) {
                ForEach(sources) { source in
                    segment(source)
                }
            }
        }
        .frame(height: visualHeight)
    }

    @ViewBuilder
    private var pill: some View {
        if #available(iOS 26, *) {
            // Decorative (non-interactive) → .regular, not .interactive().
            Color.clear.glassEffect(.regular, in: .capsule)
        } else {
            Capsule(style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        }
    }

    @ViewBuilder
    private func segment(_ source: SmartSource) -> some View {
        let selected = source == selection
        Button {
            if selected {
                onReselect(source)
            } else {
                withAnimation(slide) { selection = source }
            }
        } label: {
            HStack(spacing: 4) {
                // Unfocused: a small dot inline before the label — a natural,
                // consistent gap (not pinned far off at the edge), vertically
                // centered. The focused count is a chip overlay instead (below).
                if badge(source) != nil, !selected {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                }
                Text(title(source))
                    .lineLimit(1)
                if selected {
                    Image(systemName: sortImage(source))
                        .font(.caption2.weight(.bold))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            // Match the native segmented control: a light weight/contrast step,
            // semantic colors (adapt to light/dark), never a fixed white/accent.
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.6))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Focused: the count as a chip pinned to the top-leading corner (out of
            // the centered label's way). It's centered within a fixed-width slot so
            // a single digit sits at the same center as "99+" (stable anchor).
            .overlay(alignment: .topLeading) {
                if let count = badge(source), selected {
                    UnreadCountChip(count: count)
                        .frame(width: 30)
                        .padding(.leading, 2)
                        .padding(.top, 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title(source)))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected ? Text(sortValue(source)) : Text(""))
        .accessibilityHint(selected ? Text("Double-tap to change the sort order") : Text(""))
    }
}

/// The focused segment's unread-count chip (a small accent capsule with the
/// number). Sized to its content; the caller centers it in a fixed-width slot so
/// a single digit and "99+" share the same center.
private struct UnreadCountChip: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 10, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor))
            .fixedSize()
    }
}

// MARK: - Starred tab

private struct StarredTab: View {
    let store: ReaderStore

    var body: some View {
        NavigationStack {
            ReaderPushingList(store: store)
        }
    }
}

// MARK: - Feeds tab

/// The library: an "All Articles" row, ungrouped feeds, and folders as
/// disclosure groups. Tapping a row drills into that source's article list
/// (which pushes the reader). Folders navigate via their label link and expand
/// via the disclosure chevron.
private struct FeedsTab: View {
    @Bindable var store: ReaderStore
    @Binding var path: [FeedTarget]

    @Environment(TourCoordinator.self) private var tour
    @Environment(TabBarChrome.self) private var tabChrome
    @State private var isAddingFeed = false
    @State private var isShowingStarterPicks = false
    @State private var isCreatingFolder = false
    /// One-shot spotlight on the "+" button: the tour subscribes starter picks
    /// for the user, so the library's own add affordance needs introducing.
    @AppStorage(TourFlags.seenFeedsAddHintKey) private var seenFeedsAddHint = false
    @AppStorage(TourFlags.hasCompletedWelcomeKey) private var hasCompletedWelcome = false
    @State private var showAddHint = false
    @State private var addButtonFrame: CGRect = .zero
    @State private var newFolderName = ""
    @State private var folderPendingRename: String?
    @State private var renameFolderName = ""
    @State private var feedPendingRename: Feed.ID?
    @State private var renameFeedName = ""
    /// The writer's own publication, mirrored out of the Plus store so this screen
    /// needs neither a session nor a network call to offer it.
    @AppStorage(PlusOwnFeed.publicationURLKey) private var ownPublicationURL = ""
    @State private var isFollowingOwnFeed = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
            List {
                Section {
                    NavigationLink(value: FeedTarget.all) {
                        Label(SmartSource.all.title, systemImage: SmartSource.all.systemImage)
                    }
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))
                .id("feedsTop")

                // What the writer published, where they already look for something to
                // read. Their own publication is a feed like any other, so this is a
                // way in rather than a second kind of screen.
                if let publication = URL(string: ownPublicationURL) {
                    Section {
                        ownNookRow(publication: publication)
                    }
                    .listRowBackground(Rectangle().fill(.ultraThinMaterial))
                }

                if store.hasCategories {
                    Section("Categories") {
                        ForEach(store.categories) { category in
                            NavigationLink(value: FeedTarget.category(category.id)) {
                                HStack {
                                    Label {
                                        Text(category.name.isEmpty ? String(localized: "Untitled") : category.name)
                                    } icon: {
                                        Circle().fill(Color(nookHex: category.colorHex)).frame(width: 10, height: 10)
                                    }
                                    Spacer()
                                    let count = store.count(forCategory: category.id)
                                    if count > 0 {
                                        Text(count, format: .number).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .listRowBackground(Rectangle().fill(.ultraThinMaterial))
                }

                if !store.feedFolders.isEmpty || !store.ungroupedFeeds.isEmpty {
                    Section("Feeds") {
                        ForEach(store.ungroupedFeeds) { feed in
                            feedRow(feed)
                        }
                        ForEach(store.feedFolders, id: \.self) { folder in
                            DisclosureGroup {
                                ForEach(store.feeds(inFolder: folder)) { feed in
                                    feedRow(feed)
                                }
                            } label: {
                                NavigationLink(value: FeedTarget.folder(folder)) {
                                    Label(folder, systemImage: "folder")
                                }
                                .contextMenu {
                                    Button {
                                        renameFolderName = folder
                                        folderPendingRename = folder
                                    } label: {
                                        Label("Rename Folder", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        store.removeFolder(folder)
                                    } label: {
                                        Label("Delete Folder", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                    .listRowBackground(Rectangle().fill(.ultraThinMaterial))
                }

                // Tucked at the bottom: saved-offline articles, then filtered.
                if store.hasOfflineArticles || store.hasFilters {
                    Section {
                        if store.hasOfflineArticles {
                            NavigationLink(value: FeedTarget.offline) {
                                HStack {
                                    Label(SmartSource.offline.title, systemImage: SmartSource.offline.systemImage)
                                    Spacer()
                                    let count = store.count(for: .offline)
                                    if count > 0 {
                                        Text(count, format: .number).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if store.hasFilters {
                            NavigationLink(value: FeedTarget.filtered) {
                                HStack {
                                    Label(SmartSource.filtered.title, systemImage: SmartSource.filtered.systemImage)
                                    Spacer()
                                    let count = store.count(for: .filtered)
                                    if count > 0 {
                                        Text(count, format: .number).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .listRowBackground(Rectangle().fill(.ultraThinMaterial))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color("ListBackground").ignoresSafeArea())
            .navigationTitle("Feeds")
            .navigationDestination(for: FeedTarget.self) { target in
                // Apply this target's scope as the screen appears, so the shown
                // articles come from the navigation value itself rather than an
                // out-of-band side effect.
                ReaderPushingList(store: store)
                    .task(id: target) { CompactShell.applyScope(target, store: store) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            isAddingFeed = true
                        } label: {
                            Label("Follow a Site", systemImage: "plus")
                        }
                        Button {
                            isCreatingFolder = true
                        } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                            // Measure the button for the one-shot add-hint
                            // spotlight; the publisher unmounts once seen.
                            .background {
                                if !seenFeedsAddHint {
                                    GeometryReader { g in
                                        Color.clear.preference(key: FeedsAddButtonFrameKey.self, value: g.frame(in: .global))
                                    }
                                }
                            }
                    }
                }
            }
            .onPreferenceChange(FeedsAddButtonFrameKey.self) { frame in
                if addButtonFrame != frame { addButtonFrame = frame }
            }
            .refreshable { await store.refreshAllAndWait() }
            // Keep the library list's tail above the floating tab bar.
            .modifier(TabBarInset())
            // Skipped the tour? This is where curiosity lands — teach instead
            // of showing a bare "All Articles" row.
            .overlay {
                if store.feeds.isEmpty {
                    ContentUnavailableView {
                        Label("Follow your first site", systemImage: "plus.circle")
                    } description: {
                        Text("Nook gathers new posts from the sites you follow — start with a few picks, or any website address.")
                    } actions: {
                        Button("Browse Starter Picks") { isShowingStarterPicks = true }
                            .buttonStyle(.borderedProminent)
                        Button("Follow a Site by Address") { isAddingFeed = true }
                    }
                    .background(Color("ListBackground"))
                }
            }
            .sheet(isPresented: $isShowingStarterPicks) {
                StarterPicksSheet(store: store)
            }
            // Native re-tap semantics: at the Feeds root, re-tapping the tab
            // scrolls the library list back to the top.
            .onChange(of: tabChrome.scrollToTopSignal) { _, _ in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                    proxy.scrollTo("feedsTop", anchor: .top)
                }
            }
            }
        }
        // First visit with a library already in place (the tour subscribed the
        // starter picks for them): show once where new sites are added.
        .overlay {
            if showAddHint {
                FeedsAddHint(
                    buttonFrame: addButtonFrame == .zero ? nil : addButtonFrame,
                    onDismiss: dismissAddHint
                )
                .transition(.opacity)
            }
        }
        .onAppear {
            guard hasCompletedWelcome, !seenFeedsAddHint, !store.feeds.isEmpty else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !seenFeedsAddHint else { return }
                withAnimation { showAddHint = true }
            }
        }
        // Opening the add menu means they found the button — done teaching.
        .onChange(of: isAddingFeed) { _, adding in
            if adding, showAddHint { dismissAddHint() }
        }
        .onDisappear {
            if showAddHint { dismissAddHint() }
        }
        .sheet(isPresented: $isAddingFeed) {
            AddFeedView(folders: store.feedFolders) { feedURL, folder in
                try await store.addFeed(urlString: feedURL, toFolder: folder)
            }
        }
        // Drilling into a source while the hint is up: it's done its job.
        .onChange(of: path) { _, _ in
            if showAddHint { dismissAddHint() }
        }
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Folder Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { store.createFolder(name) }
                newFolderName = ""
            }
        }
        .alert(
            "Rename Folder",
            isPresented: Binding(
                get: { folderPendingRename != nil },
                set: { if !$0 { folderPendingRename = nil } }
            ),
            presenting: folderPendingRename
        ) { folder in
            TextField("Folder Name", text: $renameFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { store.renameFolder(folder, to: renameFolderName) }
        } message: { _ in
            Text("Enter a new name for the folder.")
        }
        .alert(
            "Rename Feed",
            isPresented: Binding(
                get: { feedPendingRename != nil },
                set: { if !$0 { feedPendingRename = nil } }
            ),
            presenting: feedPendingRename
        ) { feedID in
            TextField("Feed Name", text: $renameFeedName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { store.renameFeed(feedID, to: renameFeedName) }
        } message: { _ in
            Text("Enter a new name, or leave empty to use the feed's own name.")
        }
    }

    private func dismissAddHint() {
        seenFeedsAddHint = true
        withAnimation { showAddHint = false }
    }

    /// The way into the writer's own publication.
    ///
    /// Drills straight in once the feed is followed; follows it first if it is not,
    /// which is the case for a writer who signed in but has not published from this
    /// device yet. One row either way, so it always means the same thing.
    @ViewBuilder
    private func ownNookRow(publication: URL) -> some View {
        if let feed = OwnNook.followedFeed(in: store, publication: publication) {
            NavigationLink(value: FeedTarget.feed(feed.id)) {
                ownNookLabel(unread: store.unreadCount(feedID: feed.id))
            }
        } else {
            Button {
                Task { await followOwnFeed(publication: publication) }
            } label: {
                ownNookLabel(unread: 0)
            }
            .buttonStyle(.plain)
            .disabled(isFollowingOwnFeed)
        }
    }

    private func ownNookLabel(unread: Int) -> some View {
        OwnNookLabel(unread: unread, isFollowing: isFollowingOwnFeed)
    }

    /// Follows the publication, then opens it. Failure is reported: a row that does
    /// nothing when tapped is indistinguishable from a broken app.
    private func followOwnFeed(publication: URL) async {
        isFollowingOwnFeed = true
        defer { isFollowingOwnFeed = false }
        guard let feed = await OwnNook.follow(publication: publication, in: store) else { return }
        path.append(.feed(feed.id))
    }

    @ViewBuilder
    private func feedRow(_ feed: Feed) -> some View {
        let isRefreshing = store.isRefreshing(feedID: feed.id)
        NavigationLink(value: FeedTarget.feed(feed.id)) {
            HStack {
                ZStack {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    } else if let icon = store.faviconImage(for: feed) {
                        icon.resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    } else {
                        Image(systemName: feed.systemImage)
                            .frame(width: 18, height: 18)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .frame(width: 18, height: 18)
                .animation(.easeInOut(duration: 0.18), value: isRefreshing)
                .feedActivityFlash(trigger: store.feedUpdateToken(feedID: feed.id))
                Text(feed.displayTitle).lineLimit(1)
                if feed.healthScore <= 0, !isRefreshing {
                    // Quiet, Mail-style "couldn't sync" mark — no alert.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityLabel(Text("Couldn't refresh this feed"))
                }
                Spacer()
                let count = store.unreadCount(feedID: feed.id)
                if count > 0 {
                    Text(count, format: .number).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            // The managed Saved Links feed can't be deleted (its articles can).
            if !ReaderStore.isManagedFeed(feed.id) {
                Button(role: .destructive) {
                    store.removeFeeds(ids: [feed.id])
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                store.markFeedsRead(ids: [feed.id])
            } label: {
                Label("Mark Read", systemImage: "checkmark")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button {
                store.markFeedsRead(ids: [feed.id])
            } label: {
                Label("Mark All as Read", systemImage: "checkmark.circle")
            }
            if !ReaderStore.isManagedFeed(feed.id) {
                Button {
                    renameFeedName = feed.displayTitle
                    feedPendingRename = feed.id
                } label: {
                    Label("Rename Feed", systemImage: "pencil")
                }
                if !store.feedFolders.isEmpty {
                    Menu {
                        Button("None") { store.moveFeed(feed.id, toFolder: "") }
                        ForEach(store.feedFolders, id: \.self) { folder in
                            Button(folder) { store.moveFeed(feed.id, toFolder: folder) }
                        }
                    } label: {
                        Label("Move to Folder", systemImage: "folder")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    store.removeFeeds(ids: [feed.id])
                } label: {
                    Label("Delete Feed", systemImage: "trash")
                }
            }
        }
    }
}

// MARK: - Article list that pushes the reader

/// Wraps `ArticleList` with a navigation destination that pushes
/// `ReaderDetailView` when a row is selected. Used by Home, Starred, and each
/// drilled-into feed source. Selection is local to this view (so switching tabs
/// never pushes the reader in an inactive tab) and mirrored to
/// `store.selectedArticleID` so the reader and mark-read dwell work.
private struct ReaderPushingList<Top: View>: View {
    @Bindable var store: ReaderStore
    /// When true, this view owns the compact search UI (a toolbar button that
    /// reveals the search field on demand). Home passes false and provides its own
    /// segment-morphing search bar instead.
    var providesSearch: Bool = true
    /// Forwarded to the article list's empty state (Home passes the switch-to-All
    /// action; other sources pass nil).
    var onShowAllArticles: (() -> Void)? = nil
    let top: () -> Top
    /// The article captured when a row is tapped — the value the reader renders.
    /// Local to this stack, so another tab's scope change never blanks or swaps
    /// what this pushed reader shows.
    @State private var pushed: Article?
    @State private var isSearching = false
    @Environment(TabBarChrome.self) private var tabChrome

    init(
        store: ReaderStore,
        providesSearch: Bool = true,
        onShowAllArticles: (() -> Void)? = nil,
        @ViewBuilder top: @escaping () -> Top = { EmptyView() }
    ) {
        self.store = store
        self.providesSearch = providesSearch
        self.onShowAllArticles = onShowAllArticles
        self.top = top
    }

    var body: some View {
        VStack(spacing: 0) {
            top()
            ArticleList(store: store, selection: selectionBinding, managesSearch: false, onShowAllArticles: onShowAllArticles)
        }
        // Keep the list tail above the floating tab bar (inside the stack, so
        // the inset actually reaches the scroll view).
        .modifier(TabBarInset())
        .modifier(CompactSearchButton(searchText: $store.searchText, isSearching: $isSearching, enabled: providesSearch))
        // The custom glass tab bar pops away while a reader is pushed and
        // returns on pop (the store's selection survives pops, so the pushed
        // state here is the reliable signal).
        .onChange(of: pushed == nil) { _, popped in
            tabChrome.setReaderOpen(!popped)
        }
        .navigationDestination(item: $pushed) { _ in
            // Drive the reader from the binding (not the closure's snapshot) so
            // previous/next swipe can move it in place.
            ReaderDetailView(store: store, articleOverride: $pushed)
                // Hide the tab bar while reading (native push-driven hide; it
                // returns on pop).
                .toolbar(.hidden, for: .tabBar)
        }
    }

    /// Selecting a row captures the article's value (while it's still in the
    /// current scope) and mirrors its id into the store so the mark-read dwell
    /// runs. Clearing (back navigation) pops the reader.
    private var selectionBinding: Binding<Article.ID?> {
        Binding(
            get: { pushed?.id },
            set: { id in
                if let id, let article = store.visibleArticles.first(where: { $0.id == id }) {
                    pushed = article
                    store.selectedArticleID = id
                } else {
                    pushed = nil
                }
            }
        )
    }
}

/// The launch/loading screen. The OS launch screen is a static `LaunchBackground`
/// (cream) — the same color used here — so the hand-off is seamless; then the
/// icon's twig layers drop in from above under gravity and assemble into the
/// nest, matching the app icon.
struct SplashView: View {
    /// When set, a slow launch shows what the pipeline is doing under the
    /// wordmark (large libraries / cold iCloud reads can hold the splash well
    /// past the brand animation).
    var store: ReaderStore? = nil

    @State private var assembled = false
    @State private var showWordmark = false
    @State private var showProgress = false

    var body: some View {
        ZStack {
            Color("LaunchBackground")
                .ignoresSafeArea()

            NestAssemblyView(size: 150, assembled: assembled)

            // The wordmark fades in just below the nest once the twigs land.
            // A fixed dark-brown reads on the always-cream splash (don't use
            // .primary, which would be white in dark mode).
            Text(verbatim: "Nook")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(Color(.displayP3, red: 0.26, green: 0.19, blue: 0.10))
                .offset(y: 78 + (showWordmark ? 0 : 6))
                .opacity(showWordmark ? 1 : 0)
                .animation(.easeOut(duration: 0.3), value: showWordmark)

            // Progress readout for launches that outlast the brand beat: shown
            // only once the animation has finished AND bootstrap is still busy,
            // so fast launches never flash it. The bar fills by pipeline stage
            // (true durations are unknowable — iCloud reads dominate).
            if showProgress, let phase = store?.bootstrapPhase {
                let brown = Color(.displayP3, red: 0.26, green: 0.19, blue: 0.10)
                VStack(spacing: 12) {
                    ProgressView(value: phase.fractionComplete)
                        .progressViewStyle(.linear)
                        .tint(brown)
                        .frame(width: 180)
                        .animation(.easeInOut(duration: 0.4), value: phase.fractionComplete)
                    Text(phase.label)
                        .font(.footnote)
                        .foregroundStyle(brown.opacity(0.7))
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: phase.label)
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 64)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showProgress)
        .task {
            // Static launch background → drop the twigs → reveal the wordmark.
            try? await Task.sleep(for: .milliseconds(120))
            assembled = true
            try? await Task.sleep(for: .seconds(NestAssemblyView.duration))
            showWordmark = true
            // The brand beat ends ~1.85s after launch; anything still loading
            // beyond ~2.4s deserves an explanation.
            try? await Task.sleep(for: .milliseconds(1200))
            showProgress = true
        }
    }
}

/// A selectable sidebar entry. Binding the List selection to this (rather than
/// using plain buttons) is what lets a collapsed NavigationSplitView push to the
/// article-list column when a row is tapped on iPhone.
// MARK: - My Nook, shared by both shells

/// The writer's own publication, as both shells need it.
///
/// Extracted because they had drifted: the phone offered My Nook and a compose
/// button, and the iPad — same app, same account — offered neither, so a writer on
/// an iPad could not reach their own writing or start a post at all. One
/// implementation of "which publication, is it followed, follow it" means the next
/// change lands on both.
///
/// The publication URL comes from defaults rather than a Plus session, so neither
/// shell needs a session or a network call to decide whether to show the row.
enum OwnNook {
    /// The publication to offer, or nil when the reader has never published.
    static func publication(from stored: String) -> URL? {
        guard !stored.isEmpty else { return nil }
        return URL(string: stored)
    }

    /// The followed feed for a publication, if it is followed on this device.
    @MainActor
    static func followedFeed(in store: ReaderStore, publication: URL) -> Feed? {
        store.followedFeed(at: PlusOwnFeed.feedURL(for: publication))
    }

    /// Follows the publication and returns its feed.
    ///
    /// A writer who signed in on a second device has a publication and no feed for
    /// it, so both shells offer one row that follows on first use rather than a row
    /// that is missing until they publish again.
    @MainActor
    static func follow(publication: URL, in store: ReaderStore) async -> Feed? {
        let feedURL = PlusOwnFeed.feedURL(for: publication)
        do {
            try await store.addFeed(urlString: feedURL.absoluteString)
        } catch {
            store.errorMessage = error.localizedDescription
            return nil
        }
        // Adding a feed leaves its first article selected; that belongs to a reader
        // tapping a row.
        store.selectedArticleID = nil
        guard let feed = store.followedFeed(at: feedURL) else {
            // Added, but not findable at the URL it was added with — a redirect, most
            // likely. Saying so beats a tap that appears to do nothing.
            store.errorMessage = String(
                localized: "Your publication was followed but couldn't be opened. It is in your feed list.")
            return nil
        }
        return feed
    }
}

/// The row's contents, identical on the phone and the iPad so the place the writing
/// goes looks like the same thing in both.
struct OwnNookLabel: View {
    var unread: Int
    var isFollowing: Bool

    var body: some View {
        HStack {
            Label {
                Text("My Nook")
            } icon: {
                // The compose button's symbol and signature tint, so the place the
                // writing goes is recognisably the same thing as the place it is made.
                if isFollowing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(PlusTheme.accent)
                }
            }
            Spacer()
            if unread > 0 {
                Text(unread, format: .number).foregroundStyle(.secondary)
            }
        }
    }
}

enum SidebarItem: Hashable {
    case smart(SmartSource)
    case category(String)
    case feed(Feed.ID)
}

private struct Sidebar: View {
    @Bindable var store: ReaderStore
    var chooseFolder: () -> Void
    var importOPML: () -> Void
    @Binding var isAddingFeed: Bool
    @Binding var isExportingOPML: Bool
    @Binding var isCreatingFolder: Bool
    @Binding var isShowingSettings: Bool

    /// Opens the composer. Nil when there is no Plus session, which is what keeps
    /// the button out of the toolbar for a reader who does not publish.
    var onCompose: (() -> Void)?

    @State private var selection: SidebarItem?
    @State private var folderPendingRename: String?
    @State private var renameFolderName = ""
    @State private var feedPendingRename: Feed.ID?
    @State private var renameFeedName = ""
    /// The writer's own publication, mirrored out of the Plus store so the sidebar
    /// needs neither a session nor a network call to offer it — the same source the
    /// phone's Feeds tab reads.
    @AppStorage(PlusOwnFeed.publicationURLKey) private var ownPublicationURL = ""
    @State private var isFollowingOwnFeed = false

    var body: some View {
        List(selection: $selection) {
            if let publication = OwnNook.publication(from: ownPublicationURL) {
                Section {
                    ownNookRow(publication: publication)
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))
            }

            Section("Library") {
                ForEach(SmartSource.library) { source in
                    HStack {
                        Label(source.title, systemImage: source.systemImage)
                        Spacer()
                        let count = store.count(for: source)
                        if count > 0 {
                            Text(count, format: .number).foregroundStyle(.secondary)
                        }
                    }
                    .tag(SidebarItem.smart(source))
                }
            }
            // Frosted translucent cards (not the solid white/dark grouped fill)
            // so the warm background shows through with a glassy feel.
            .listRowBackground(Rectangle().fill(.ultraThinMaterial))

            if store.hasCategories {
                Section("Categories") {
                    ForEach(store.categories) { category in
                        HStack {
                            Label {
                                Text(category.name.isEmpty ? String(localized: "Untitled") : category.name)
                            } icon: {
                                Circle().fill(Color(nookHex: category.colorHex)).frame(width: 10, height: 10)
                            }
                            Spacer()
                            let count = store.count(forCategory: category.id)
                            if count > 0 {
                                Text(count, format: .number).foregroundStyle(.secondary)
                            }
                        }
                        .tag(SidebarItem.category(category.id))
                    }
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))
            }

            if !store.feedFolders.isEmpty || !store.ungroupedFeeds.isEmpty {
                Section("Feeds") {
                    ForEach(store.ungroupedFeeds) { feed in
                        feedRow(feed)
                    }
                    ForEach(store.feedFolders, id: \.self) { folder in
                        DisclosureGroup(folder) {
                            ForEach(store.feeds(inFolder: folder)) { feed in
                                feedRow(feed)
                            }
                        }
                        .contextMenu {
                            Button {
                                renameFolderName = folder
                                folderPendingRename = folder
                            } label: {
                                Label("Rename Folder", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                store.removeFolder(folder)
                            } label: {
                                Label("Delete Folder", systemImage: "trash")
                            }
                        }
                    }
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))
            }

            // Tucked at the bottom: saved-offline articles, then filtered.
            if store.hasOfflineArticles || store.hasFilters {
                Section {
                    if store.hasOfflineArticles {
                        HStack {
                            Label(SmartSource.offline.title, systemImage: SmartSource.offline.systemImage)
                            Spacer()
                            let count = store.count(for: .offline)
                            if count > 0 {
                                Text(count, format: .number).foregroundStyle(.secondary)
                            }
                        }
                        .tag(SidebarItem.smart(.offline))
                    }
                    if store.hasFilters {
                        HStack {
                            Label(SmartSource.filtered.title, systemImage: SmartSource.filtered.systemImage)
                            Spacer()
                            let count = store.count(for: .filtered)
                            if count > 0 {
                                Text(count, format: .number).foregroundStyle(.secondary)
                            }
                        }
                        .tag(SidebarItem.smart(.filtered))
                    }
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color("ListBackground").ignoresSafeArea())
        .onChange(of: selection) { _, item in
            switch item {
            case .smart(let source):
                store.selectSmartSource(source)
            case .category(let id):
                store.selectCategory(id)
            case .feed(let id):
                store.feedSelection = [id]
                store.smartSelection = nil
            case nil:
                break
            }
        }
        .navigationTitle("Nook")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button {
                        isAddingFeed = true
                    } label: {
                        Label("Follow a Site", systemImage: "plus")
                    }
                    Button {
                        isCreatingFolder = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    Divider()
                    Button {
                        importOPML()
                    } label: {
                        Label("Import OPML", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        isExportingOPML = true
                    } label: {
                        Label("Export OPML", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.feeds.isEmpty)
                    Divider()
                    Button {
                        chooseFolder()
                    } label: {
                        Label(
                            store.isStorageConfigured ? "Change Sync Folder" : "Choose Sync Folder",
                            systemImage: store.isStorageConfigured ? "checkmark.icloud" : "icloud"
                        )
                    }
                    Button {
                        isShowingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            // The phone puts this in the tab bar, which the iPad does not have — so
            // an iPad writer had no way to start a post at all. Same symbol and tint
            // as the phone's, and as the My Nook row above.
            if let onCompose {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onCompose) {
                        Label("Write a post", systemImage: "square.and.pencil")
                    }
                    .tint(PlusTheme.accent)
                }
            }
        }
        .refreshable { await store.refreshAllAndWait() }
        // Only prompt for a folder while none is set (first run). Once storage
        // is configured this goes away instead of sitting at the bottom.
        .safeAreaInset(edge: .bottom) {
            if !store.isStorageConfigured {
                Button {
                    chooseFolder()
                } label: {
                    Label("Choose Sync Folder", systemImage: "icloud")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
        }
        .alert(
            "Rename Folder",
            isPresented: Binding(
                get: { folderPendingRename != nil },
                set: { if !$0 { folderPendingRename = nil } }
            ),
            presenting: folderPendingRename
        ) { folder in
            TextField("Folder Name", text: $renameFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { store.renameFolder(folder, to: renameFolderName) }
        } message: { _ in
            Text("Enter a new name for the folder.")
        }
        .alert(
            "Rename Feed",
            isPresented: Binding(
                get: { feedPendingRename != nil },
                set: { if !$0 { feedPendingRename = nil } }
            ),
            presenting: feedPendingRename
        ) { feedID in
            TextField("Feed Name", text: $renameFeedName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { store.renameFeed(feedID, to: renameFeedName) }
        } message: { _ in
            Text("Enter a new name, or leave empty to use the feed's own name.")
        }
    }

    /// Selects the writer's own feed, following it first if this device has not
    /// yet. One row either way, matching the phone: a writer signed in on a second
    /// iPad has a publication and no feed for it until they follow it.
    @ViewBuilder
    private func ownNookRow(publication: URL) -> some View {
        if let feed = OwnNook.followedFeed(in: store, publication: publication) {
            OwnNookLabel(unread: store.unreadCount(feedID: feed.id), isFollowing: false)
                .tag(SidebarItem.feed(feed.id))
        } else {
            Button {
                Task {
                    isFollowingOwnFeed = true
                    defer { isFollowingOwnFeed = false }
                    guard let feed = await OwnNook.follow(publication: publication, in: store)
                    else { return }
                    // Selecting it is what the split view needs to show it, where the
                    // phone pushes onto its navigation path.
                    selection = .feed(feed.id)
                }
            } label: {
                OwnNookLabel(unread: 0, isFollowing: isFollowingOwnFeed)
            }
            .buttonStyle(.plain)
            .disabled(isFollowingOwnFeed)
        }
    }

    @ViewBuilder
    private func feedRow(_ feed: Feed) -> some View {
        let isRefreshing = store.isRefreshing(feedID: feed.id)
        HStack {
            ZStack {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                } else if let icon = store.faviconImage(for: feed) {
                    icon.resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else {
                    Image(systemName: feed.systemImage)
                        .frame(width: 18, height: 18)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(width: 18, height: 18)
            .animation(.easeInOut(duration: 0.18), value: isRefreshing)
            .feedActivityFlash(trigger: store.feedUpdateToken(feedID: feed.id))
            Text(feed.displayTitle).lineLimit(1)
            if feed.healthScore <= 0, !isRefreshing {
                // Quiet, Mail-style "couldn't sync" mark — no alert.
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(Text("Couldn't refresh this feed"))
            }
            Spacer()
            let count = store.unreadCount(feedID: feed.id)
            if count > 0 {
                Text(count, format: .number).font(.caption).foregroundStyle(.secondary)
            }
        }
        .tag(SidebarItem.feed(feed.id))
        .swipeActions(edge: .trailing) {
            // The managed Saved Links feed can't be deleted (its articles can).
            if !ReaderStore.isManagedFeed(feed.id) {
                Button(role: .destructive) {
                    store.removeFeeds(ids: [feed.id])
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                store.markFeedsRead(ids: [feed.id])
            } label: {
                Label("Mark Read", systemImage: "checkmark")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button {
                store.markFeedsRead(ids: [feed.id])
            } label: {
                Label("Mark All as Read", systemImage: "checkmark.circle")
            }
            if !ReaderStore.isManagedFeed(feed.id) {
                Button {
                    renameFeedName = feed.displayTitle
                    feedPendingRename = feed.id
                } label: {
                    Label("Rename Feed", systemImage: "pencil")
                }
                if !store.feedFolders.isEmpty {
                    Menu {
                        Button("None") { store.moveFeed(feed.id, toFolder: "") }
                        ForEach(store.feedFolders, id: \.self) { folder in
                            Button(folder) { store.moveFeed(feed.id, toFolder: folder) }
                        }
                    } label: {
                        Label("Move to Folder", systemImage: "folder")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    store.removeFeeds(ids: [feed.id])
                } label: {
                    Label("Delete Feed", systemImage: "trash")
                }
            }
        }
    }
}

/// Reveals the full native search bar on demand from a toolbar magnifying-glass
/// button. `.searchable` is attached only while searching, so there's no
/// always-visible search row; once attached, `presented` is flipped false→true
/// so the system runs its native present animation AND focuses the field (raising
/// the keyboard). The native "Cancel" dismisses it, which unmounts the bar.
private struct CompactSearchButton: ViewModifier {
    @Binding var searchText: String
    @Binding var isSearching: Bool
    let enabled: Bool
    @State private var presented = false

    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if isSearching {
            content
                .searchable(text: $searchText, isPresented: $presented, prompt: "Search Articles")
                .task { presented = true }
                .onChange(of: presented) { _, nowPresented in
                    if !nowPresented {
                        searchText = ""
                        isSearching = false
                    }
                }
        } else {
            content.toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isSearching = true } label: {
                        Label("Search Articles", systemImage: "magnifyingglass")
                    }
                }
            }
        }
    }
}

/// Applies the standard always-available search drawer only when `enabled`
/// (iPad). The compact tab shell presents search from a toolbar button instead.
private struct DrawerSearch: ViewModifier {
    @Binding var text: String
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, prompt: "Search Articles")
        } else {
            content
        }
    }
}

private struct ArticleList: View {
    @Bindable var store: ReaderStore
    @Binding var selection: Article.ID?
    /// Whether this list owns the search field. True on iPad (the split-view list
    /// shows the standard always-available search drawer); false in the compact
    /// tab shell, where `ReaderPushingList` presents search from a toolbar button.
    var managesSearch: Bool = true
    /// Provided only where switching to "All Articles" makes sense (the Unread
    /// view). When set and the empty Unread list is shown, a button offers it.
    var onShowAllArticles: (() -> Void)? = nil
    @AppStorage("readerViewMode") private var readerViewMode = ReaderViewMode.reader
    @AppStorage(ReaderStore.translateListTitlesKey) private var translateListTitles = false
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system
    @AppStorage(TranslationSettings.titleProviderKey) private var titleProvider = TranslationProvider.appleIntelligence.rawValue
    @AppStorage(TranslationSettings.geminiKeyConfiguredKey) private var geminiKeyConfigured = false
    /// Gates the tutorial-spotlight frame publisher below: mounted only while
    /// the list spotlight is requested or showing, never in steady state.
    @Environment(TourCoordinator.self) private var tour
    /// Collapse driver for the custom liquid-glass tab bar (iPhone shell).
    @Environment(TabBarChrome.self) private var tabChrome
    /// Shared, on-device title translator for the opt-in "translate list titles"
    /// experiment. Reading its `state(for:)` in `row` observes streaming updates.
    private let titleTranslator = ListTitleTranslator.shared

    var body: some View {
        ScrollViewReader { proxy in
            list
                // Read here rather than at the shell, because a preference does not
                // reliably leave a TabView page: the shell's reader saw nothing and
                // the spotlight fell back to a guessed rectangle instead of the row.
                // Handing it to the coordinator crosses the boundary the preference
                // could not, and does it from a callback rather than during layout.
                .onPreferenceChange(FirstRowFrameKey.self) { frame in
                    if tour.firstRowFrame != frame { tour.firstRowFrame = frame }
                }
                // Native re-tap semantics: re-tapping the selected tab scrolls
                // the visible list back to the top.
                .onChange(of: tabChrome.scrollToTopSignal) { _, _ in
                    guard let first = store.visibleArticles.first?.id else { return }
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                        proxy.scrollTo(first, anchor: .top)
                    }
                }
        }
    }

    private var list: some View {
        List(store.visibleArticles, selection: $selection) { article in
            row(article)
                // Drive the dwell-based, off-screen-cancelling title translation
                // queue (no-op unless the experiment is enabled).
                .onAppear { titleTranslator.rowAppeared(id: article.id, title: article.title) }
                .onDisappear { titleTranslator.rowDisappeared(id: article.id) }
                // Publish the first row's global frame so the tutorial can
                // spotlight it exactly. Mounted only while the spotlight is
                // live: an always-on GeometryReader would emit this preference
                // on every scroll frame and re-evaluate the consumer forever.
                .background {
                    if tour.listHintActive, article.id == store.visibleArticles.first?.id {
                        GeometryReader { g in
                            Color.clear.preference(key: FirstRowFrameKey.self, value: g.frame(in: .global))
                        }
                    }
                }
                .tag(article.id)
                .swipeActions(edge: .leading) {
                    Button {
                        store.setRead(articleID: article.id, isRead: !article.isRead)
                    } label: {
                        Label(
                            article.isRead ? "Unread" : "Read",
                            systemImage: article.isRead ? "circle" : "checkmark.circle"
                        )
                    }
                    .tint(.blue)
                }
                .swipeActions(edge: .trailing) {
                    Button {
                        store.toggleStarred(articleID: article.id)
                    } label: {
                        Label("Star", systemImage: article.isStarred ? "star.slash" : "star")
                    }
                    .tint(.yellow)

                    // Saving is done from Settings › Offline; the row only offers
                    // removal of an already-saved article.
                    if store.isOfflineSaved(article.id) {
                        Button(role: .destructive) {
                            store.removeOffline(article.id)
                        } label: {
                            Label("Remove Download", systemImage: "arrow.down.circle.fill")
                        }
                        .tint(.indigo)
                    }
                }
                .contextMenu {
                    Button {
                        store.setRead(articleID: article.id, isRead: !article.isRead)
                    } label: {
                        Label(article.isRead ? "Mark as Unread" : "Mark as Read",
                              systemImage: article.isRead ? "circle" : "checkmark.circle")
                    }
                    Button {
                        store.toggleStarred(articleID: article.id)
                    } label: {
                        Label(article.isStarred ? "Unstar" : "Star",
                              systemImage: article.isStarred ? "star.slash" : "star")
                    }
                    if store.isOfflineSaved(article.id) {
                        Button {
                            store.removeOffline(article.id)
                        } label: {
                            Label("Remove Download", systemImage: "arrow.down.circle.fill")
                        }
                    }
                    Menu {
                        CategoryMenuItems(store: store, article: article)
                    } label: {
                        Label("Categories", systemImage: "tag")
                    }
                    Button {
                        store.selectedArticleID = article.id
                        store.browserMode = store.feed(for: article.feedID)?.preferredViewMode ?? readerViewMode
                        store.isBrowserPresented = true
                    } label: {
                        Label("Open in Browser", systemImage: "safari")
                    }
                    ShareLink(item: article.url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                // Transparent rows so the warm list background shows through.
                .listRowBackground(Color.clear)
                // No divider above the first row or below the last — only between rows.
                .listRowSeparator(article.id == store.visibleArticles.first?.id ? .hidden : .automatic, edges: .top)
                .listRowSeparator(article.id == store.visibleArticles.last?.id ? .hidden : .automatic, edges: .bottom)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color("ListBackground").ignoresSafeArea())
        .navigationTitle(store.selectedSourceTitle)
        .modifier(DrawerSearch(text: $store.searchText, enabled: managesSearch))
        .toolbar {
            // Offline saving is done from Settings › Offline; the list only shows
            // an in-progress download's status, never a save button.
            ToolbarItem(placement: .topBarTrailing) {
                if let progress = store.offlineDownloadProgress {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text("\(progress.completed)/\(progress.total)").font(.caption).monospacedDigit()
                    }
                }
            }
        }
        .onChange(of: store.searchText) { _, _ in store.debounceSearch() }
        // Hold new title translations while the list is in motion: their row-
        // height reveal animations and streaming text updates are the main
        // source of mid-scroll jank. Queued rows start once the scroll settles.
        .onScrollPhaseChange { oldPhase, newPhase in
            titleTranslator.setScrolling(newPhase != .idle)
            // The tab bar's expand hold protects only the scroll in flight when
            // the user tapped: settling OR starting a fresh gesture releases it,
            // so the first scroll after arriving on this screen minimizes.
            if newPhase == .idle || oldPhase == .idle { tabChrome.releaseExpandHold() }
        }
        // Feed the custom tab bar's collapse hysteresis (iPhone shell; the
        // chrome is inert on iPad where no custom bar reads it). Bounded to the
        // scrollable range so elastic overscroll can't masquerade as scrolling.
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            let maxY = max(0, geo.contentSize.height - geo.containerSize.height)
            return min(max(0, geo.contentOffset.y + geo.contentInsets.top), maxY)
        } action: { _, y in
            tabChrome.noteScroll(offsetY: y)
        }
        .refreshable { await refreshCurrent() }
        .overlay {
            if store.visibleArticles.isEmpty { emptyState }
        }
        .onAppear { configureTitleTranslator() }
        .onChange(of: translateListTitles) { _, _ in configureTitleTranslator() }
        .onChange(of: appLanguage) { _, _ in configureTitleTranslator() }
        .onChange(of: titleProvider) { _, _ in configureTitleTranslator() }
        .onChange(of: geminiKeyConfigured) { _, _ in configureTitleTranslator() }
    }

    /// Feeds the shared title translator the current on/off flag and target
    /// language. Turning the flag off or switching languages cancels in-flight
    /// work inside the translator.
    private func configureTitleTranslator() {
        titleTranslator.configure(
            enabled: translateListTitles,
            targetLanguageName: titleTargetLanguageName,
            targetLanguageCode: titleTargetLanguageCode
        )
    }

    private var titleTargetLocale: Locale {
        appLanguage == .system ? Locale.current : appLanguage.locale
    }

    /// The target language's English name for the model (e.g. "Korean"),
    /// disambiguating Chinese by script — matches the reader's mapping.
    private var titleTargetLanguageName: String {
        let language = titleTargetLocale.language
        if let script = language.script?.identifier {
            if script == "Hans" { return "Simplified Chinese" }
            if script == "Hant" { return "Traditional Chinese" }
        }
        let code = language.languageCode?.identifier ?? "en"
        return Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code
    }

    private var titleTargetLanguageCode: String {
        titleTargetLocale.language.languageCode?.identifier ?? "en"
    }

    /// Empty-list states that teach instead of dead-ending: a first refresh in
    /// flight shows that posts are on their way (the moment right after the
    /// tour's "Start Reading"), an empty library points at following a site,
    /// Starred teaches the double-tap, and the empty Unread view offers All.
    @ViewBuilder
    private var emptyState: some View {
        if store.isRefreshing {
            ContentUnavailableView {
                Label {
                    Text("Fetching new posts…")
                } icon: {
                    ProgressView()
                }
            } description: {
                Text("Your sites are being checked for their latest posts.")
            }
        } else if store.feeds.isEmpty, store.activeSearchQuery.isEmpty {
            ContentUnavailableView {
                Label("Follow your first site", systemImage: "plus.circle")
            } description: {
                Text("Posts from the sites you follow will gather here.")
            }
        } else if store.smartSelection == .starred, store.feedSelection.isEmpty,
                  store.activeSearchQuery.isEmpty {
            ContentUnavailableView {
                Label("Nothing starred yet", systemImage: "star")
            } description: {
                Text("Double-tap any article while reading to star it — starred stories live here.")
            }
        } else if let onShowAllArticles,
           store.smartSelection == .unread,
           store.feedSelection.isEmpty,
           store.activeSearchQuery.isEmpty {
            ContentUnavailableView {
                Label("You're All Caught Up", systemImage: "checkmark.circle")
            } description: {
                Text("No unread articles right now.")
            } actions: {
                Button("View All Articles") { onShowAllArticles() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView("No Articles", systemImage: "newspaper")
        }
    }

    /// Pull-to-refresh: when viewing a specific feed, refresh just that feed;
    /// otherwise (a smart source like Unread/Today/All) refresh everything.
    private func refreshCurrent() async {
        if store.smartSelection == nil, !store.feedSelection.isEmpty {
            await store.refreshFeedsAndWait(ids: Array(store.feedSelection))
        } else {
            await store.refreshAllAndWait()
        }
    }

    private func row(_ article: Article) -> some View {
        ArticleRowView(
            article: article,
            store: store,
            translationBox: titleTranslator.box(for: article.id)
        )
    }
}

/// One article-list row, extracted into its own view so its observable reads
/// (feed title, category badges, offline index) register at row scope: a feed
/// or category change re-evaluates rows individually instead of forcing the
/// whole `ArticleList` body — and a translation update still touches only this
/// row via its `StateBox`.
private struct ArticleRowView: View {
    let article: Article
    let store: ReaderStore
    let translationBox: ListTitleTranslator.StateBox

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Title + its translation share a zero-spacing group so the collapsed
            // (height-zero) translation block leaves no gap above the summary.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    if !article.isRead {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    }
                    Text(article.title)
                        .font(.headline)
                        .lineLimit(2)
                        .foregroundStyle(article.isRead ? .secondary : .primary)
                    if article.isStarred {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                    if OfflineArticleStore.shared.isSaved(article.id) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Saved offline"))
                    }
                }
                // Shared leaf view observes ONLY this row's state box.
                ListTitleTranslationBlock(
                    title: article.title,
                    box: translationBox
                )
            }
            if !article.summary.isEmpty {
                Text(article.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            // Metadata + badges share a zero-spacing group so the collapsed
            // (height-zero) badge block leaves no gap below the metadata; the
            // block carries the spacing itself once it reveals.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(store.feed(for: article.feedID)?.displayTitle ?? "")
                    Text("·")
                    RelativeTimeText(article.publishedAt)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)

                CategoryBadgesBlock(
                    store.categories(forArticle: article),
                    topPadding: 4,
                    animatesReveal: !store.isBulkCategorizing
                )
            }
        }
    }
}
