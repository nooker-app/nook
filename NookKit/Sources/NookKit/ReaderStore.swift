import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
public final class ReaderStore {
    public var feeds: [Feed] = [] {
        didSet {
            // O(1) row lookups: every visible row resolves its feed title, and a
            // linear scan per row per body evaluation added up on both platforms.
            feedsByID = Dictionary(feeds.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            scheduleArticleFilter(debounced: true)
        }
    }
    /// `feeds` indexed by id, maintained in its didSet.
    private var feedsByID: [Feed.ID: Feed] = [:]
    var articles: [Article] = [] {
        didSet {
            // Classify hidden (filtered) articles first so counts and the list
            // both see the current set. Counts + unread badge then recompute on
            // every change (a single O(all) pass, cheap) so the Dock/app-icon
            // badge and sidebar counts always stay live — including a read toggle
            // made while a refresh is in flight. Only the filter+sort is
            // debounced/coalesced.
            //
            // Single-bit read/star toggles bypass this chain (see `setRead`/
            // `setStarred`): they mutate one element under `suppressArticlesDidSet`
            // and apply O(1) count deltas instead — the filter engine matches only
            // title/summary/categories, never read/star state, so the O(n)
            // reclassification here would be pure waste on the article-open path.
            guard !suppressArticlesDidSet else { return }
            recomputeFilteredIDs()
            recomputeCounts()
            updateUnreadBadge()
            scheduleArticleFilter(debounced: true)
        }
    }
    /// Reentrancy guard for the incremental single-article mutation path. The
    /// property stays stored + observable (views tracking `articles` still see
    /// the write); only the didSet recomputes are skipped.
    private var suppressArticlesDidSet = false

    /// Article ids with an active deletion tombstone, across every known shard
    /// (this device's and peers'). Deletion tombstones are applied by the CRDT
    /// `materialize`, but a refresh merge inserts whatever the feed still
    /// serves — without this guard a deleted article whose entry is still in
    /// the RSS response resurrects on every refresh, only to vanish again at
    /// the next materialize (the flapping this set exists to prevent).
    /// Maintained by `deleteArticle` and refreshed whenever shards are loaded
    /// (bootstrap, folder configure, `reloadMerged`).
    private(set) var deletedArticleIDs: Set<Article.ID> = []

    /// The active deletion tombstones across `shards`, with the same LWW merge
    /// semantics `materialize` applies.
    nonisolated static func tombstonedArticleIDs(in shards: [DeviceStateDocument]) -> Set<Article.ID> {
        let merged = DeviceStateDocument.mergedState(from: shards)
        return Set(merged.articles.compactMap { id, state in
            state.tombstone?.value == true ? id : nil
        })
    }

    // Sidebar badge counts, recomputed in a single pass whenever `articles`
    // changes, so rendering a feed/folder/source badge is an O(1)/O(feeds)
    // lookup instead of an O(articles) scan on every re-render (the sidebar
    // re-renders constantly while a refresh streams articles in).
    private(set) var unreadByFeed: [Feed.ID: Int] = [:]
    /// Unread count per category id (excludes filtered/hidden articles), for the
    /// sidebar Categories badges.
    private(set) var unreadByCategory: [String: Int] = [:]
    private(set) var totalUnread = 0
    private(set) var todayCount = 0
    private(set) var starredCount = 0
    // Library, Feeds, and Categories are independent selection scopes: a single
    // smart source acts as navigation, feeds support multiple selection, and a
    // category browses everything tagged with it.
    public var smartSelection: SmartSource? = .all { didSet { scheduleArticleFilter() } }
    public var feedSelection: Set<Feed.ID> = [] {
        didSet {
            // Selecting a feed leaves the Categories scope (they're exclusive).
            if !feedSelection.isEmpty { categorySelection = nil }
            scheduleArticleFilter()
        }
    }
    /// The category id currently being browsed, or nil. Mutually exclusive with
    /// feed/smart selection (set via `selectCategory`).
    public var categorySelection: String? = nil { didSet { scheduleArticleFilter() } }
    /// Whether the window-wide in-app browser bottom sheet is showing.
    public var isBrowserPresented = false
    /// The in-app browser's current view mode (reader vs original). Toggled
    /// instantly without changing the saved default.
    public var browserMode: ReaderViewMode = .reader

    public func toggleBrowserMode() {
        guard isBrowserPresented else { return }
        browserMode = (browserMode == .reader) ? .original : .reader
    }

    /// The in-app browser's reading mode for `article`: the feed's per-feed
    /// override, else the global default. The single source of truth so opening
    /// an article and advancing to the next one resolve the mode identically —
    /// previously "next" skipped this and stuck on the prior article's mode.
    public func resolvedBrowserMode(for article: Article) -> ReaderViewMode {
        if let feedMode = feed(for: article.feedID)?.preferredViewMode { return feedMode }
        let stored = UserDefaults.standard.string(forKey: "readerViewMode")
        return stored.flatMap(ReaderViewMode.init(rawValue:)) ?? .reader
    }
    // Articles kept visible in the current source even after being read, until
    // the user navigates to another source (Chrome-tab-close heuristic).
    // Mutation sites schedule the filter recompute explicitly (no didSet):
    // retaining an already-visible article must stay recompute-free, since it
    // happens on every article open, mid push-animation.
    private var retainedArticleIDs: Set<Article.ID> = []
    public var selectedArticleID: Article.ID?
    /// The raw text bound to the search field; updates instantly as the user types.
    public var searchText = ""
    /// The query actually used to filter articles. Trails `searchText` by a
    /// short debounce so filtering doesn't run on every keystroke.
    public private(set) var activeSearchQuery = "" { didSet { scheduleArticleFilter(animated: false) } }
    private var searchDebounceTask: Task<Void, Never>?

    /// Per-category sort order (SmartSource rawValue → order), persisted locally
    /// as a device UI preference. Feed drill-downs share the "feed" bucket.
    private var sortOrders: [String: ArticleSortOrder] = ReaderStore.loadSortOrders()
    private static let sortOrdersKey = "articleSortOrders"

    /// The filtered, sorted articles shown in the list. Recomputed off the main
    /// thread for large libraries so typing/scrolling never blocks the UI.
    private(set) var displayedArticles: [Article] = []
    private var filterTask: Task<Void, Never>?
    /// Coalesces data-driven recomputes (a sync streams articles in bursts, each
    /// mutation firing `didSet`) so the expensive filter+sort runs at most once
    /// per quiet window instead of dozens of times a second.
    private var filterDebounceTask: Task<Void, Never>?
    private static let filterDebounceInterval: Duration = .milliseconds(300)
    /// Above this many articles, filtering runs on a background executor.
    private static let backgroundFilterThreshold = 600
    var lastRefreshedAt: Date?
    public var errorMessage: String?
    /// What the launch pipeline is doing right now, for the splash screen's
    /// progress readout on slow launches (large libraries, cold iCloud reads).
    /// Nil once the library is installed (or when no folder is configured).
    public private(set) var bootstrapPhase: BootstrapPhase?

    /// Coarse stages of bringing the sync folder online, surfaced on the splash.
    public enum BootstrapPhase: Sendable {
        case connectingFolder
        case readingLibrary
        case mergingDevices

        public var label: String {
            // Storage-agnostic phrasing: the same pipeline serves both the
            // iOS local library and a synced iCloud folder.
            switch self {
            case .connectingFolder: String(localized: "Opening your library…", bundle: .module)
            case .readingLibrary: String(localized: "Loading your articles…", bundle: .module)
            case .mergingDevices: String(localized: "Merging changes from your devices…", bundle: .module)
            }
        }

        /// Coarse completion fraction for the splash progress bar. The real
        /// durations are unknowable up front (iCloud reads dominate), so the
        /// bar communicates "which stage, of how many" rather than time.
        public var fractionComplete: Double {
            switch self {
            case .connectingFolder: 0.15
            case .readingLibrary: 0.45
            case .mergingDevices: 0.8
            }
        }
    }
    /// Mirrors the "show unread badge" preference. Held in the store (not only
    /// the view) so the Dock badge is a deterministic function of store state
    /// rather than of SwiftUI view-lifecycle timing.
    public var showsUnreadBadge = true { didSet { updateUnreadBadge() } }
    /// Whether the reading surface is currently being attended, set by each
    /// platform app from its scene/activity signals. macOS intentionally requires
    /// more than a frontmost process: its reader window must be visible and the
    /// Mac recently used. While active, articles surfaced in the list are marked
    /// "seen" so they never fire a later "new article" notification (on this
    /// device or, via shard sync, any other). Defaults `false` so a background
    /// refresh — the one path that *should* notify — never marks seen.
    public private(set) var isForegroundActive = false
    public private(set) var syncFolderDisplayPath: String?
    private(set) var feedIcons: [Feed.ID: PlatformImage] = [:]
    private(set) var folders: [String] = []
    /// User-defined article filters, synced across devices via the state shard.
    /// Read-only to the UI; mutate through `addFilter`/`updateFilter`/etc., which
    /// re-classify hidden articles and record the change to the shard.
    public private(set) var filters: [ArticleFilter] = []
    /// User-defined categories (definitions), synced across devices via the state
    /// shard. Read-only to the UI; mutate through `addCategory`/`updateCategory`/
    /// etc. Per-article assignments live on `Article.categories`.
    public private(set) var categories: [ArticleCategory] = [] {
        didSet {
            // O(1) badge lookups: `categories(forArticle:)` runs per visible row
            // and was rebuilding this dictionary on every call.
            categoriesByID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }
    /// `categories` indexed by id, maintained in its didSet.
    private var categoriesByID: [String: ArticleCategory] = [:]
    /// Progress of an in-flight "classify existing articles" migration (completed,
    /// total), or nil when idle. Observed for the settings progress indicator.
    public private(set) var categorizeAllProgress: (completed: Int, total: Int)?
    /// Progress of an in-flight OPML import's content fetch (completed, total), or
    /// nil when no import is running. The feeds and their folders appear at once
    /// the moment the import starts (Phase 1); this counter tracks Phase 2, where
    /// each feed's articles stream in over the network. Observed so both platforms
    /// can show a determinate native progress indicator during the import.
    public private(set) var importProgress: (completed: Int, total: Int)?
    /// True while a bulk pass is applying categories in batches. Article rows read
    /// it to skip the badge reveal animation: a batch can tag many on-screen rows
    /// at once, and animating them together makes each row invalidate the native
    /// list height on every frame of its reveal.
    ///
    /// Deliberately **not** observable — a row reads this while it is already being
    /// re-evaluated for its own category change, and making it observable would
    /// subscribe every visible row to a flag that flips mid-migration.
    @ObservationIgnored public private(set) var isBulkCategorizing = false
    private var bulkCategorizeTask: Task<Void, Never>?
    /// Background FIFO queue of new article ids awaiting AI categorization, drained
    /// serially so a refresh's new articles are classified without a burst of model
    /// calls. Only used when AI categorization is enabled.
    private var aiCategorizeQueue: [Article.ID] = []
    private var aiCategorizeRunning = false
    /// Guards the post-merge classification sweep (one at a time; merges landing
    /// while it runs are picked up by the next merge's sweep).
    private var classificationSweepRunning = false
    /// Ids of articles hidden by the enabled filters. Excluded from every normal
    /// list and from all unread/badge counts (a filtered article is never treated
    /// as unread); surfaced only under the `.filtered` source. Recomputed whenever
    /// `articles` or `filters` change.
    private var filteredArticleIDs: Set<Article.ID> = []
    /// The text-filter-only subset of `filteredArticleIDs` (excludes articles
    /// hidden purely by category). Kept as the incremental cache's reuse basis, so
    /// un-hiding a category doesn't leave an article wrongly text-filtered.
    private var textFilteredArticleIDs: Set<Article.ID> = []
    /// One entry per active filter, with its regex compiled once. Rebuilt only
    /// when `filters` change (not per article mutation), so a refresh that streams
    /// articles in doesn't recompile regexes on every merge.
    private var activeCompiledFilters: [CompiledFilter] = []
    /// The filter set the engine was last compiled from, so `rebuildFilterEngine`
    /// can no-op (keeping the classify cache) when a sync didn't change filters.
    private var compiledFilterSource: [ArticleFilter] = []
    /// Per-article content hash from its last classification under the current
    /// engine. Lets `recomputeFilteredIDs` skip re-testing an article whose title/
    /// summary hasn't changed — so a multi-feed refresh only runs the (possibly
    /// expensive, regex) match on genuinely new/changed articles. Cleared whenever
    /// the filter engine is rebuilt.
    private var filterClassifyCache: [Article.ID: Int] = [:]

    private struct CompiledFilter {
        let filter: ArticleFilter
        let regex: NSRegularExpression?
    }

    // Favicon fetching is deduplicated by host and rate-limited so a large
    // library doesn't spawn a storm of concurrent requests on launch.
    private var faviconAttemptedKeys: Set<String> = []
    private var faviconQueue: [Feed] = []
    private var activeFaviconFetches = 0
    private static let maxConcurrentFaviconFetches = 4

    /// How a full refresh should spend resources. An explicit, user-triggered
    /// refresh wants results fast; automatic refreshes that may run while the
    /// user is interacting stay quiet and light so content trickles in without
    /// jolting the UI, while the UI-less iOS background task fetches fast to fit
    /// the OS's time budget.
    public enum RefreshMode: Sendable {
        /// User asked (Refresh All, pull-to-refresh): fast, animated.
        case interactive
        /// Automatic and possibly concurrent with app use (activation sync,
        /// macOS periodic timer): low concurrency/priority, no animation.
        case ambient
        /// iOS background task: no visible UI, so fetch fast (fit the budget) but
        /// don't animate.
        case background

        /// Feeds fetched over the network at once. Higher = faster but heavier.
        var maxConcurrentFetches: Int {
            switch self {
            case .interactive, .background: 6
            case .ambient: 2
            }
        }

        /// QoS for the network fetch + XML parse, so an automatic refresh yields
        /// to interactive UI work instead of competing with it.
        var fetchPriority: TaskPriority {
            switch self {
            case .interactive: .userInitiated
            case .ambient, .background: .utility
            }
        }

        /// Whether newly arrived articles animate into the list. Off for
        /// automatic refreshes so rows appear quietly rather than sliding under
        /// the user mid-scroll.
        var animatesInsertion: Bool {
            switch self {
            case .interactive: true
            case .ambient, .background: false
            }
        }

        /// Whether the per-feed sidebar spinner shows while fetching. On only for
        /// user-initiated refreshes; automatic (ambient/background) refreshes stay
        /// visually silent so returning to Nook or a periodic tick doesn't flip
        /// every feed icon to a spinner. New content is signalled by a brief
        /// per-feed flash instead (see `feedUpdateTokens`).
        var showsSpinner: Bool {
            switch self {
            case .interactive: true
            case .ambient, .background: false
            }
        }
    }

    private let feedService = RSSFeedService()
    private let faviconService = FaviconService()
    private let opmlService = OPMLService()
    private var storage: ReaderStorage?
    private var securityScopedDirectoryURL: URL?

    // File events are rescan hints for legacy input and v2 shard directories;
    // correctness comes from the durable replica merge, not event delivery.
    private var fileObservers: [LibraryFileObserver] = []
    private var lastKnownLibraryModDate: Date?
    private var lastKnownStateModDate: Date?
    private var lastKnownContentModDate: Date?
    private var lastKnownBodiesModDate: Date?
    private var externalReloadTask: Task<Void, Never>?

    // Coalesced background persistence: the latest snapshot waiting to be
    // written, and whether a writer task is already draining them.
    private var pendingSave: ReaderLibrary?
    private var isDrainingSaves = false
    private var saveDrainTask: Task<Void, Never>?
    // While a full refresh runs, per-feed saves are held so the whole (large)
    // library isn't re-encoded and rewritten once per feed; one write flushes
    // the final state when the refresh finishes.
    private var isBatchRefreshing = false
    private var isAccessingSecurityScopedResource = false
    // Every feed with a network fetch in flight, in any mode. Drives the global
    // `isRefreshing` (concurrency guards, disabled buttons) so an automatic
    // refresh still coalesces with user-initiated ones.
    private var refreshingFeedIDs: Set<Feed.ID> = []
    // Feeds whose per-feed spinner should show — populated only for user-initiated
    // (interactive) refreshes, so automatic ones update content without flipping
    // feed icons to a spinner on every tick.
    private var spinningFeedIDs: Set<Feed.ID> = []
    // A per-feed counter bumped every time a refresh brings in new articles. The
    // sidebar animates a flash whenever a feed's token changes; a refresh that
    // adds nothing leaves the token — and the UI — untouched.
    private(set) var feedUpdateTokens: [Feed.ID: Int] = [:]

    /// The state of reader-mode extraction for an article, driving the native
    /// reader when the "reader content by default" experiment is on.
    public enum ReaderContentState: Equatable, Sendable {
        case loading
        case ready(String)
        case failed
        /// The original page returned 404/410 — it's gone from the source, so the
        /// reader offers to delete the lingering local copy.
        case gone
    }

    /// Per-article reader-mode extraction state, observed by the reader views.
    /// Rebuilt per session; the durable results live in the CRDT reader shards.
    private(set) var readerContentStates: [Article.ID: ReaderContentState] = [:]
    private var readerContentTasks: [Article.ID: Task<Void, Never>] = [:]

    /// Which parser produced the content currently on screen for an article.
    ///
    /// Kept beside the state rather than inside `.ready` so every existing
    /// `case .ready(let html)` keeps working: the reader needs this only to
    /// check-mark the right item in its parser menu and to name the other engine
    /// in a failure notice.
    private(set) var readerContentEngines: [Article.ID: ReaderParserEngine] = [:]

    /// Bodies this session has already extracted, per article and parser.
    ///
    /// This is what makes the reader's parser switch instant on the way back. The
    /// synced cache holds one body per article, so returning to the previous
    /// parser would otherwise re-load the page and re-parse it for a result that
    /// was on screen ten seconds ago.
    private var readerContentByEngine: [Article.ID: [ReaderParserEngine: String]] = [:]
    /// How many articles' per-engine bodies to keep. Reading moves forward, so the
    /// value of an older article's alternate body falls off quickly, and each entry
    /// is a whole article's markup.
    private static let maxReaderContentByEngine = 8
    private var readerContentByEngineOrder: [Article.ID] = []

    /// Articles being re-read with a different parser right now.
    ///
    /// A re-parse deliberately does NOT drop back to `.loading`: the header and the
    /// body share one scroll view, so replacing a full article with a one-line
    /// spinner collapses the content height and throws the reader back to the top of
    /// a piece they were halfway through. The old body stays up, with a progress
    /// chip, until the new one is in hand.
    private(set) var reparsingArticles: [Article.ID: ReaderReparse] = [:]

    /// Why an article's body is being fetched again while the old one is still on
    /// screen. The reader says which, because "re-reading with Readability" and
    /// "refreshing" are two different waits and the difference is the whole reason
    /// the reader asked.
    public enum ReaderReparse: Equatable, Sendable {
        /// The reader chose the other parser for this article.
        case parser(ReaderParserEngine)
        /// The reader asked for the page again, whatever the parser.
        case refresh
    }

    /// Allowlisted video/CodePen embeds the page carried that the parser on screen
    /// discarded. legibility's sanitizer drops them; Readability keeps them.
    private(set) var readerDroppedEmbeds: [Article.ID: Int] = [:]

    /// The discussion on each article's page, for the reader to draw under the body.
    ///
    /// Populated from the extraction, and on a body served from cache by a read of
    /// this device's local database. Kept out of the synced shard on purpose — see
    /// `ReplicaStore.saveComments`.
    private(set) var readerCommentThreads: [Article.ID: ReaderCommentThread] = [:]
    /// Articles whose local thread has already been looked for, so a page with no
    /// discussion is not queried on every open.
    private var readerCommentsLoaded: Set<Article.ID> = []

    /// An observable mirror of the parser preference.
    ///
    /// `ReaderParserEngine.preferred` reads `UserDefaults` directly, which nothing
    /// observes — so on macOS, where Settings and a reader window are visible at
    /// once, changing the parser left the reader's menu showing the old one until
    /// something unrelated redrew. Views read this; the extractor reads the raw
    /// preference.
    public private(set) var preferredParser: ReaderParserEngine = .preferred

    /// A parser chosen for one article from inside the reader, overriding the
    /// preference for that article only.
    ///
    /// Session-scoped and deliberately not synced: it is a "read this one the other
    /// way" gesture, not a setting, and it belongs to the reading session it was
    /// made in. Both reading surfaces honour it, so switching in the browser and
    /// switching in the native reader are the same act.
    private var readerParserOverrides: [Article.ID: ReaderParserEngine] = [:]

    /// Which parsers have been tried on an article this session, so a page that no
    /// engine can read is not re-loaded once per engine per sync.
    ///
    /// A cached *failure* from the other engine is worth reconsidering — legibility
    /// reads short posts Readability rejects — but only once. Without this, two
    /// devices on different parsers would take turns re-fetching a page that has no
    /// article in it every time a shard merged.
    private var readerParsersTried: [Article.ID: Set<ReaderParserEngine>] = [:]

    /// The CRDT-synced cache of extracted reader content (separate from every
    /// other store; see `ReaderContentStore`). Created with storage.
    private var readerContentStore: ReaderContentStore?
    /// Headless page loader + parser driver, created on first use.
    private var readerModeExtractor: ReaderModeExtractor?

    // Article bodies live in a separate sidecar so the launch baseline stays
    // small. This in-memory cache lets a re-merge (which reloads the light
    // baseline) restore bodies without re-reading the sidecar each time.
    private var bodyCache: [Article.ID: ArticleBody] = [:]
    private var didLoadBodyCache = false
    private var isLoadingBodyCache = false
    /// Bodies are kept on disk for at most this many of the most-recent articles.
    private nonisolated static let bodyRetentionLimit = 600

    // Git-like per-device sync. This device authors its own shard of user state
    // (read/starred flags, folders, per-feed overrides, feed deletions), each
    // change stamped with a monotonic HLC and materialized over content shards.
    private var deviceID = ""
    private var lastHLC: HLC = .zero
    private var ownShard = DeviceStateDocument(deviceID: "")
    private var pendingShard: DeviceStateDocument?
    private var isDrainingShardSaves = false
    private var shardSaveDrainTask: Task<Void, Never>?
    /// The open trailing-save window for the shard (see `scheduleShardSave`).
    private var shardSaveDebounceTask: Task<Void, Never>?
    private var replicaStore: ReplicaStore?
    private var appliedReplicaRevision: UInt64 = 0

    /// App-global instance. A singleton so the separate Settings scene can reach
    /// the same feeds/state as the main window (SwiftUI scenes can't share a
    /// view's `@State`).
    public static let shared = ReaderStore()

    private var didBootstrap = false
    private var isBootstrapping = false
    private var bootstrapWaiters: [CheckedContinuation<Void, Never>] = []
    public private(set) var isPreparingLocalReset = false
    private var didQuiesceForLocalReset = false

    private init() {
        // These preferences are read out of `UserDefaults` by non-view code, and
        // nothing observes that. Mirroring them here — and refreshing on the defaults
        // notification the Settings controls trigger — is what makes an open reader
        // follow a change made in the Settings window beside it. Retained for the
        // store's lifetime, which is the app's.
        readerPreferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { ReaderStore.shared.refreshReaderPreferences() }
        }
    }

    private var readerPreferenceObserver: NSObjectProtocol?

    private func refreshReaderPreferences() {
        let parser = ReaderParserEngine.preferred
        if preferredParser != parser { preferredParser = parser }

        let comments = UserDefaults.standard.object(forKey: Self.showReaderCommentsKey) as? Bool ?? true
        guard showsComments != comments else { return }
        showsComments = comments
        // Turned on with an article already open: the thread was never looked for, so
        // ask for it now rather than waiting for the next article.
        guard comments, let article = selectedArticle else { return }
        Task { await loadCommentsIfNeeded(for: article) }
    }

    /// Loads the persisted library and starts filtering. Runs its heavy work
    /// only once, no matter how often it is called.
    ///
    /// Kept out of `init()` on purpose: SwiftUI re-evaluates the app/window body
    /// many times while the graph settles, re-running `ContentView.init()`. With
    /// the JSON load in `init()`, that decoded `NookLibrary.json` synchronously on
    /// the main thread repeatedly and pinned the CPU near 100%. Deferring it to a
    /// one-time call from `.task` keeps those re-evaluations cheap.
    public func bootstrap() async {
        guard !didBootstrap, !isPreparingLocalReset else { return }
        didBootstrap = true
        isBootstrapping = true
        defer {
            isBootstrapping = false
            let waiters = bootstrapWaiters
            bootstrapWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        deviceID = DeviceIdentity.current()
        ownShard = DeviceStateDocument(deviceID: deviceID)
        // Read the offline index off-main while storage restores, so the first
        // row render / purge below doesn't do the disk read on the main actor.
        async let offlineIndexPreload: Void = OfflineArticleStore.shared.preloadIndex()
        await restoreStorageIfPossible()
        await offlineIndexPreload
        guard !isPreparingLocalReset else { return }
        // Drop offline copies past their expiry (device-local; independent of the
        // sync folder), so stale downloads don't linger or inflate the count.
        purgeExpiredOffline()
        scheduleArticleFilter()
    }

    /// Stops every tracked operation that can feed a later local or sync write.
    /// Reset deliberately drops pending snapshots instead of flushing them: the
    /// selected sync folder must remain byte-for-byte untouched.
    public func beginPreparingForLocalReset() {
        isPreparingLocalReset = true
    }

    public func prepareForLocalReset() async {
        beginPreparingForLocalReset()
        guard !didQuiesceForLocalReset else { return }
        didQuiesceForLocalReset = true

        if isBootstrapping {
            await withCheckedContinuation { continuation in
                bootstrapWaiters.append(continuation)
            }
        }

        stopObservingLibrary()
        searchDebounceTask?.cancel()
        filterTask?.cancel()
        filterDebounceTask?.cancel()
        bulkCategorizeTask?.cancel()
        externalReloadTask?.cancel()
        allFeedsRefreshTask?.cancel()
        dateResolutionTask?.cancel()
        bulkDownloadTask?.cancel()
        let offlineSaveTasks = Array(offlineSaveTasks.values)
        offlineSaveTasks.forEach { $0.cancel() }
        let readerContentTasks = Array(readerContentTasks.values)
        readerContentTasks.forEach { $0.cancel() }
        batchMergeFlushTask?.cancel()
        shardSaveDebounceTask?.cancel()

        pendingSave = nil
        pendingShard = nil
        pendingBatchMerges.removeAll()
        aiCategorizeQueue.removeAll()

        await allFeedsRefreshTask?.value
        await dateResolutionTask?.value
        await bulkDownloadTask?.value
        await bulkCategorizeTask?.value
        await externalReloadTask?.value
        await batchMergeFlushTask?.value
        for task in offlineSaveTasks { await task.value }
        for task in readerContentTasks { await task.value }
        // A drain may already be inside an atomic coordinated write. Waiting for
        // it before releasing the security scope prevents an in-flight writer
        // from racing the reset boundary.
        await saveDrainTask?.value
        await shardSaveDrainTask?.value

        allFeedsRefreshTask = nil
        dateResolutionTask = nil
        bulkDownloadTask = nil
        bulkCategorizeTask = nil
        externalReloadTask = nil
        batchMergeFlushTask = nil
        self.offlineSaveTasks.removeAll()
        self.readerContentTasks.removeAll()
        self.readerContentGenerations.removeAll()
        saveDrainTask = nil
        shardSaveDrainTask = nil
        refreshingFeedIDs.removeAll()
        spinningFeedIDs.removeAll()
        isRefreshing = false
        isBatchRefreshing = false
        isDrainingSaves = false
        isDrainingShardSaves = false

        ListTitleTranslator.shared.clearCache()
        readerContentStore = nil
        readerModeExtractor = nil
        replicaStore = nil
        storage = nil

        if isAccessingSecurityScopedResource {
            securityScopedDirectoryURL?.stopAccessingSecurityScopedResource()
        }
        securityScopedDirectoryURL = nil
        isAccessingSecurityScopedResource = false
    }

    /// Reinitializes this long-lived singleton after an in-process reset. macOS
    /// relaunches instead; iOS cannot relaunch itself, so it uses this path and
    /// then runs the normal first-launch bootstrap again.
    public func restartAfterLocalReset() async {
        guard didQuiesceForLocalReset else { return }

        feeds = []
        articles = []
        displayedArticles = []
        folders = []
        filters = []
        categories = []
        feedsByID = [:]
        categoriesByID = [:]
        unreadByFeed = [:]
        unreadByCategory = [:]
        totalUnread = 0
        todayCount = 0
        starredCount = 0
        retainedArticleIDs = []
        filteredArticleIDs = []
        textFilteredArticleIDs = []
        activeCompiledFilters = []
        compiledFilterSource = []
        filterClassifyCache = [:]
        smartSelection = .all
        feedSelection = []
        categorySelection = nil
        selectedArticleID = nil
        searchText = ""
        activeSearchQuery = ""
        sortOrders = Self.loadSortOrders()
        syncFolderDisplayPath = nil
        feedIcons = [:]
        faviconAttemptedKeys = []
        faviconQueue = []
        activeFaviconFetches = 0
        feedUpdateTokens = [:]
        readerContentStates = [:]
        readerContentEngines = [:]
        readerContentGenerations = [:]
        reparsingArticles = [:]
        readerDroppedEmbeds = [:]
        readerCommentThreads = [:]
        readerCommentsLoaded = []
        readerParserOverrides = [:]
        readerContentByEngine = [:]
        readerContentByEngineOrder = []
        readerParsersTried = [:]
        bodyCache = [:]
        didLoadBodyCache = false
        isLoadingBodyCache = false
        datelessArticleIDs = []
        offlineDownloadProgress = nil
        categorizeAllProgress = nil
        importProgress = nil
        aiCategorizeRunning = false
        lastRefreshedAt = nil
        errorMessage = nil
        bootstrapPhase = nil
        isBrowserPresented = false
        browserMode = .reader
        activationRefreshInFlight = false
        isRetryingFailedFeeds = false
        lastKnownLibraryModDate = nil
        lastKnownStateModDate = nil
        lastKnownContentModDate = nil
        lastKnownBodiesModDate = nil
        appliedReplicaRevision = 0
        lastHLC = .zero

        deviceID = DeviceIdentity.current()
        ownShard = DeviceStateDocument(deviceID: deviceID)
        OfflineArticleStore.shared.resetAfterLocalAppReset()

        didBootstrap = false
        didQuiesceForLocalReset = false
        isPreparingLocalReset = false
        await bootstrap()
    }

    public var isStorageConfigured: Bool {
        storage != nil
    }

    /// The folder the reader was pointed at, when one has been chosen.
    ///
    /// Exposed so a writer's own published posts can be mirrored into it as Markdown
    /// files. Everything else Nook keeps — feeds, article caches, icons — already
    /// lives there; posts were the one thing a writer makes themselves and could not
    /// open in Finder.
    public var syncFolderURL: URL? {
        storage?.directoryURL
    }

    /// Stored, and written only when it actually changes.
    ///
    /// It used to be `!refreshingFeedIDs.isEmpty`. Reading it subscribed the reader to
    /// the whole set, so every feed starting and finishing republished it — two
    /// invalidations per feed per refresh, each one costing 3-11ms of revalidation on
    /// an open article with a comment thread, for a Bool that changed twice.
    public private(set) var isRefreshing = false

    private func syncIsRefreshing() {
        let refreshing = !refreshingFeedIDs.isEmpty
        if isRefreshing != refreshing {
            isRefreshing = refreshing
        }
    }

    public var selectedArticle: Article? {
        guard let selectedArticleID else { return nil }
        return articles.first { $0.id == selectedArticleID }
    }

    /// The list-backing articles. Backed by `displayedArticles`, which is
    /// recomputed (off-main for large libraries) whenever a filter input changes.
    public var visibleArticles: [Article] { displayedArticles }

    /// Read-only view of the full loaded library, for features that sample
    /// article content (Reading Fit draws its test paragraphs from here).
    public var libraryArticles: [Article] { articles }

    /// Recomputes `displayedArticles` from the current inputs.
    ///
    /// User-driven changes (source/feed selection, search) pass `debounced:
    /// false` for an instant response. Data-driven changes that arrive in
    /// bursts (articles/feeds streaming in during a sync) pass `debounced: true`
    /// so the recompute is deferred until the burst settles, capturing the
    /// latest snapshot once instead of re-sorting on every mutation.
    private func scheduleArticleFilter(debounced: Bool = false, animated: Bool = true) {
        guard !isPreparingLocalReset else { return }
        guard debounced else {
            filterDebounceTask?.cancel()
            filterDebounceTask = nil
            performArticleFilter(animated: animated)
            return
        }

        filterDebounceTask?.cancel()
        filterDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.filterDebounceInterval)
            guard !Task.isCancelled, let self else { return }
            self.performArticleFilter(animated: animated)
        }
    }

    /// Captures the current inputs and recomputes `displayedArticles`. Small
    /// libraries are filtered synchronously (instant, animatable); large ones
    /// are filtered on a background executor so the main thread stays responsive.
    private func performArticleFilter(animated: Bool = true) {
        filterTask?.cancel()

        let snapshot = articles
        let feedTitles = Dictionary(feeds.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let feedSelection = self.feedSelection
        let smartSelection = self.smartSelection
        let categorySelection = self.categorySelection
        let retained = retainedArticleIDs
        let filteredIDs = filteredArticleIDs
        let query = activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let order = currentSortOrder

        // The Downloaded source is driven by the offline store itself, not the
        // in-memory library, so a saved article that was deleted from a feed or
        // aged out of the baseline still lists (and can be removed) — the whole
        // point of a durable download. Built on the main actor from the (small,
        // capped) offline index; newest-saved first.
        if feedSelection.isEmpty, smartSelection == .offline {
            applyDisplayed(offlineDisplayArticles(query: query, filteredIDs: filteredIDs), animated: animated)
            return
        }

        // Only the empty-query, small-library path filters synchronously (cheap set
        // /enum checks + sort, and it should stay sync so it can still animate). Any
        // text query does an O(n·paragraphs) locale scan, so route it off the main
        // actor even under the threshold, so search never hitches the main thread.
        if query.isEmpty && snapshot.count < Self.backgroundFilterThreshold {
            #if DEBUG && os(macOS)
            // The synchronous path, so its cost is main-thread cost. The background
            // one is not counted here: it is not on this thread.
            let outerActivity = MainThreadLog.activity("list.filter")
            defer { MainThreadLog.activity(outerActivity) }
            let filterStarted = ProcessInfo.processInfo.systemUptime
            defer {
                MainThreadLog.add(
                    "list.filter",
                    ms: (ProcessInfo.processInfo.systemUptime - filterStarted) * 1000)
            }
            #endif
            applyDisplayed(Self.computeVisibleArticles(
                snapshot, feedTitles: feedTitles, feedSelection: feedSelection,
                smartSelection: smartSelection, categorySelection: categorySelection, retained: retained, filteredIDs: filteredIDs, query: query, order: order
            ), animated: animated)
            return
        }

        filterTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.computeVisibleArticles(
                    snapshot, feedTitles: feedTitles, feedSelection: feedSelection,
                    smartSelection: smartSelection, categorySelection: categorySelection, retained: retained, filteredIDs: filteredIDs, query: query, order: order
                )
            }.value
            guard !Task.isCancelled, let self else { return }
            self.applyDisplayed(result, animated: animated)
        }
    }

    /// The projection of an article that list rows actually render (both
    /// platforms): identity, texts, flags, date, feed, categories. Deliberately
    /// excludes body content and `hasExplicitPublishDate` — rows don't render
    /// them, and body hydration would otherwise defeat the equality guard in
    /// `applyDisplayed`. Readers are unaffected: they re-resolve articles by ID
    /// from `articles`, never from the displayed array.
    private struct RowProjection: Equatable {
        let title: String
        let summary: String
        let isRead: Bool
        let isStarred: Bool
        let publishedAt: Date
        let feedID: Feed.ID
        let estimatedReadMinutes: Int
        let categories: [String]

        init(_ article: Article) {
            title = article.title
            summary = article.summary
            isRead = article.isRead
            isStarred = article.isStarred
            publishedAt = article.publishedAt
            feedID = article.feedID
            estimatedReadMinutes = article.estimatedReadMinutes
            categories = article.categories
        }
    }

    private func applyDisplayed(_ result: [Article], animated: Bool = true) {
        // Animate only when the visible rows actually change and still overlap
        // the current list — i.e. articles arriving (or filtering out) — so new
        // stories slide in instead of the list snapping/jumping. A full swap
        // (switching source) or the very first fill isn't animated, which would
        // otherwise look like a jarring reshuffle. This runs for both the sync
        // and background filter paths, so large libraries animate too.
        let oldIDs = displayedArticles.map(\.id)
        let newIDs = result.map(\.id)
        // @Observable republishes on every assignment, invalidating every row —
        // skip it entirely when nothing a row renders has changed (identical
        // recomputes are common: selection retention, no-op merges, re-sorts).
        if oldIDs == newIDs,
           zip(displayedArticles, result).allSatisfy({ RowProjection($0) == RowProjection($1) }) {
            #if DEBUG && os(macOS)
            // Counted because it is the good case, and its ratio to `list.publish` is
            // what says whether the guard is earning its keep.
            MainThreadLog.add("list.publish.skipped", ms: 0)
            #endif
            pruneSelectionIfHidden()
            markVisibleArticlesSeen()
            return
        }
        let oldSet = Set(oldIDs)
        let willAnimate = animated && oldIDs != newIDs && !oldSet.isEmpty
            && !oldSet.isDisjoint(with: newIDs)
        #if DEBUG && os(macOS)
        // Every republish invalidates every row, and the list is a thousand of them.
        // Three separate questions, so three counters: how often the list is handed a
        // new array at all, how many rows it holds when that happens, and whether the
        // swap was animated — SwiftUI has to interpolate a thousand row identities
        // when it is. The row-body counter on the other side (`list.row`) says how
        // many rows each of these actually cost.
        let outerActivity = MainThreadLog.activity(
            willAnimate ? "list.publish.animated" : "list.publish")
        defer { MainThreadLog.activity(outerActivity) }
        MainThreadLog.add(willAnimate ? "list.publish.animated" : "list.publish", ms: 0)
        MainThreadLog.note(
            "list.publish",
            extra: "rows=\(oldIDs.count)->\(newIDs.count) animated=\(willAnimate)")
        #endif
        if willAnimate {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                displayedArticles = result
            }
        } else {
            displayedArticles = result
        }
        pruneSelectionIfHidden()
        // The list the user is looking at now counts as "seen"; suppress future
        // notifications for it (no-op unless the app is foreground-active).
        markVisibleArticlesSeen()
    }

    /// Pure filtering + sorting over a snapshot. `nonisolated` so it can run on
    /// a background executor; all inputs are value types (`Sendable`).
    nonisolated private static func computeVisibleArticles(
        _ articles: [Article],
        feedTitles: [Feed.ID: String],
        feedSelection: Set<Feed.ID>,
        smartSelection: SmartSource?,
        categorySelection: String?,
        retained: Set<Article.ID>,
        filteredIDs: Set<Article.ID>,
        query: String,
        order: ArticleSortOrder
    ) -> [Article] {
        func matchesSource(_ article: Article) -> Bool {
            if !feedSelection.isEmpty { return feedSelection.contains(article.feedID) }
            if let smartSelection { return article.matches(.smart(smartSelection)) }
            return true
        }

        func matchesSourceIgnoringReadState(_ article: Article) -> Bool {
            if !feedSelection.isEmpty { return feedSelection.contains(article.feedID) }
            switch smartSelection {
            case .some(.unread), .some(.all), .none: return true
            case .some(.today): return Calendar.current.isDateInToday(article.publishedAt)
            case .some(.starred): return article.isStarred
            case .some(.filtered): return false
            // The Downloaded source is handled before this compute (from the
            // offline store), so it's never the selection here.
            case .some(.offline): return false
            }
        }

        func matchesQuery(_ article: Article) -> Bool {
            guard !query.isEmpty else { return true }
            if article.title.localizedStandardContains(query) { return true }
            if article.summary.localizedStandardContains(query) { return true }
            if let title = feedTitles[article.feedID], title.localizedStandardContains(query) { return true }
            // Scan paragraphs lazily instead of joining the whole body up front.
            return article.bodyParagraphs.contains { $0.localizedStandardContains(query) }
        }

        // Browsing a category: everything tagged with it, regardless of read or
        // hidden state (you can open a category you've also chosen to hide).
        if feedSelection.isEmpty, let categoryID = categorySelection {
            return articles
                .filter { $0.categories.contains(categoryID) && matchesQuery($0) }
                .sorted { Article.isOrdered($0, $1, by: order) }
        }

        // The Filtered source shows exactly the hidden articles (regardless of
        // read state); every other source hides them.
        if feedSelection.isEmpty, smartSelection == .filtered {
            return articles
                .filter { filteredIDs.contains($0.id) && matchesQuery($0) }
                .sorted { Article.isOrdered($0, $1, by: order) }
        }

        return articles
            .filter {
                !filteredIDs.contains($0.id)
                    && (matchesSource($0) || (retained.contains($0.id) && matchesSourceIgnoringReadState($0)))
                    && matchesQuery($0)
            }
            .sorted { Article.isOrdered($0, $1, by: order) }
    }

    public var syncFolderName: String? {
        guard let syncFolderDisplayPath, !syncFolderDisplayPath.isEmpty else { return nil }
        return (syncFolderDisplayPath as NSString).lastPathComponent
    }

    public var selectedSourceTitle: String {
        if !feedSelection.isEmpty {
            if feedSelection.count == 1, let id = feedSelection.first {
                return feed(for: id)?.title ?? String(localized: "Feed", bundle: Bundle.module)
            }
            return String(localized: "\(feedSelection.count) selected", bundle: Bundle.module)
        }
        if let categoryID = categorySelection,
           let category = categories.first(where: { $0.id == categoryID }) {
            return category.name.isEmpty ? String(localized: "Untitled", bundle: Bundle.module) : category.name
        }
        return smartSelection?.title ?? String(localized: "Articles", bundle: Bundle.module)
    }

    /// The feed IDs currently selected, for batch feed actions.
    public var selectedFeedIDs: [Feed.ID] { Array(feedSelection) }

    /// Selecting a smart source is single-select navigation and clears any
    /// feed selection, keeping the two scopes independent.
    public func selectSmartSource(_ source: SmartSource) {
        categorySelection = nil
        smartSelection = source
        feedSelection = []
        clearRetainedArticles()
        pruneSelectionIfHidden()
    }

    /// Browses everything tagged with a category. Mutually exclusive with the
    /// smart-source and feed scopes.
    public func selectCategory(_ id: String) {
        smartSelection = nil
        feedSelection = []
        categorySelection = id
        clearRetainedArticles()
        pruneSelectionIfHidden()
    }

    /// Unread count for a category (for the sidebar badge).
    public func count(forCategory id: String) -> Int { unreadByCategory[id] ?? 0 }

    /// Whether any categories exist (drives the sidebar Categories section).
    public var hasCategories: Bool { !categories.isEmpty }

    // MARK: - Sort order (per category, persisted)

    /// The saved sort order for a category (defaults to newest-first).
    public func sortOrder(for source: SmartSource) -> ArticleSortOrder {
        sortOrders[source.rawValue] ?? .newest
    }

    /// Toggles a category's sort order (re-tapping its segment), persists it, and
    /// re-sorts the list immediately.
    public func toggleSortOrder(for source: SmartSource) {
        sortOrders[source.rawValue] = sortOrder(for: source).toggled()
        persistSortOrders()
        scheduleArticleFilter()
    }

    /// The order to apply to the list currently on screen: the selected smart
    /// source's, or the shared "feed" bucket when a specific feed is shown.
    private var currentSortOrder: ArticleSortOrder {
        if let smartSelection { return sortOrders[smartSelection.rawValue] ?? .newest }
        return sortOrders["feed"] ?? .newest
    }

    private func persistSortOrders() {
        UserDefaults.standard.set(sortOrders.mapValues(\.rawValue), forKey: Self.sortOrdersKey)
    }

    private static func loadSortOrders() -> [String: ArticleSortOrder] {
        guard let raw = UserDefaults.standard.dictionary(forKey: sortOrdersKey) as? [String: String] else { return [:] }
        return raw.reduce(into: [:]) { result, pair in
            if let order = ArticleSortOrder(rawValue: pair.value) { result[pair.key] = order }
        }
    }

    func handleSyncFolderSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let directoryURL = urls.first else { return }
            configureSyncFolder(directoryURL)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    /// Points the store at a user-selected sync folder. The entry point stays
    /// synchronous so the platform folder pickers (NSOpenPanel sheet completion
    /// on macOS) call it unchanged; the heavy bring-online work — reconcile,
    /// shard loads, CRDT materialize — runs off the main actor. Previously this
    /// ran the whole sequence synchronously on main, a guaranteed multi-second
    /// hang on big libraries the moment the user picked a folder.
    public func configureSyncFolder(_ directoryURL: URL) {
        do {
            try ReaderStorage.saveBookmark(for: directoryURL)
            // A real folder supersedes the app-local library mode; the flag
            // must clear so a later broken bookmark can't silently fall back
            // to (and shadow the real library with) stale local data.
            UserDefaults.standard.set(false, forKey: Self.usesLocalLibraryKey)
            startAccessing(directoryURL)

            let storage = ReaderStorage(directoryURL: directoryURL)
            self.storage = storage
            syncFolderDisplayPath = directoryURL.path(percentEncoded: false)

            Task {
                do {
                    try await bringSyncFolderOnline(storage: storage, directoryURL: directoryURL)
                    pruneSelectionIfHidden()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Cross-device sync

    /// Begins watching the library file so another device's edits (arriving via
    /// iCloud) are applied while the app is open, and asks iCloud to download
    /// the latest copy now.
    private func startObservingLibrary() {
        guard let storage else { return }
        storage.startDownloadingLibraryIfNeeded()
        storage.startDownloadingStateIfNeeded()

        stopObservingLibrary()
        let onChange: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.scheduleExternalReload() }
        }
        // Watch legacy input and all three v2 shard directories.
        fileObservers = [
            LibraryFileObserver(fileURL: storage.libraryURL, onChange: onChange),
            LibraryFileObserver(fileURL: storage.contentDirectoryURL, onChange: onChange),
            LibraryFileObserver(fileURL: storage.bodiesDirectoryURL, onChange: onChange),
            LibraryFileObserver(fileURL: storage.stateDirectoryURL, onChange: onChange),
        ]
    }

    private func stopObservingLibrary() {
        for observer in fileObservers { observer.stop() }
        fileObservers.removeAll()
    }

    /// iOS removes file presenters while backgrounded; foreground activation
    /// re-registers them and requests an idempotent rescan. Correctness never
    /// depends on receiving every presenter callback.
    public func setSyncObservationActive(_ active: Bool) {
        if active {
            startObservingLibrary()
            scheduleExternalReload()
        } else {
            stopObservingLibrary()
        }
    }

    /// Coalesces a burst of file-change notifications into a single re-merge,
    /// skipping this device's own writes by comparing modification dates. Fires
    /// for legacy and shard changes, so a read on another device shows up
    /// live without a relaunch.
    private func scheduleExternalReload() {
        guard !isPreparingLocalReset else { return }
        externalReloadTask?.cancel()
        externalReloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let storage = self.storage, !self.isRefreshing else { return }

            let baselineDate = storage.libraryModificationDate
            let stateDate = storage.stateDirectoryModificationDate
            let contentDate = storage.contentDirectoryModificationDate
            let bodiesDate = storage.bodiesDirectoryModificationDate
            guard Self.isNewer(baselineDate, than: self.lastKnownLibraryModDate)
                || Self.isNewer(stateDate, than: self.lastKnownStateModDate)
                || Self.isNewer(contentDate, than: self.lastKnownContentModDate)
                || Self.isNewer(bodiesDate, than: self.lastKnownBodiesModDate) else {
                return
            }

            // reloadMerged decodes off-main and records the mod dates itself.
            await self.reloadMerged()
        }
    }

    /// Whether `date` is strictly newer than the last one we recorded — treating
    /// "no recorded date yet" as a change and "item gone" as no change.
    private static func isNewer(_ date: Date?, than known: Date?) -> Bool {
        guard let date else { return false }
        guard let known else { return true }
        return date > known
    }

    /// Restores this device's shard (its clock and authored registers) from disk,
    /// or seeds an empty one on first run — the one-time migration for an existing
    /// `NookLibrary.json`, whose read/starred state stays valid as the merge
    /// baseline. Seeding also registers this device so peers can see it.
    private func restoreOwnShard(storage: ReaderStorage) {
        if let own = storage.loadOwnShard(deviceID: deviceID) {
            ownShard = own
            lastHLC = own.clock
        } else {
            ownShard = DeviceStateDocument(deviceID: deviceID)
            lastHLC = .zero
            try? storage.saveShard(ownShard)
        }
    }

    /// v1 stored untouched read/starred flags and folder membership only in the
    /// shared baseline. v2 content intentionally has no user state, so seed any
    /// still-missing registers before the first v2 materialization. Existing
    /// registers always win and the completion marker is written only after the
    /// device shard is durable.
    private func migrateLegacyUserStateIfNeeded(replica: ReplicaStore, storage: ReaderStorage) throws {
        guard let legacy = try replica.pendingLegacyStateSeed(from: storage) else { return }
        let peerShards = ((try? storage.loadShards()) ?? []).filter { $0.deviceID != deviceID }
        witness(peerShards + [ownShard])
        lastHLC = ownShard.seedLegacyUserState(
            from: legacy,
            whereMissingFrom: peerShards,
            after: lastHLC,
            node: deviceID
        )
        ownShard.updatedAt = Date()
        ownShard.generation &+= 1
        try storage.saveShard(ownShard)
        try replica.markLegacyStateSeedComplete()
        lastKnownStateModDate = storage.stateDirectoryModificationDate
    }

    /// Merges the content baseline with every device's shard and applies the
    /// result, advancing this device's clock past everything it has observed so
    /// its next write beats any peer's latest edit.
    private func mergeShardsAndApply(base: ReaderLibrary, storage: ReaderStorage) {
        let shards = observedShards(from: storage)
        witness(shards)
        // Freshly loaded shards are the authority on deletions (peers' too).
        deletedArticleIDs = Self.tombstonedArticleIDs(in: shards)
        apply(DeviceStateDocument.materialize(base: base, shards: shards))
    }

    /// All shards on disk, but with this device's on-disk shard replaced by the
    /// authoritative in-memory `ownShard` so a not-yet-flushed local edit is
    /// never dropped when re-merging.
    private func observedShards(from storage: ReaderStorage) -> [DeviceStateDocument] {
        var shards = (try? storage.loadShards()) ?? []
        shards.removeAll { $0.deviceID == deviceID }
        shards.append(ownShard)
        return shards
    }

    private func witness(_ shards: [DeviceStateDocument]) {
        for shard in shards where shard.deviceID != deviceID {
            lastHLC = lastHLC.witnessed(shard.maxObservedHLC)
        }
        ownShard.clock = lastHLC
    }

    /// Re-scans legacy input + all shards, merges, and applies the result only
    /// when it differs from what's in memory — so peer edits show up without
    /// churning the UI on our own writes. Preserves UI state (selection, search).
    ///
    /// The disk read and JSON decode (the baseline can be several MB) run off the
    /// main actor so a foreground/observer wake never stalls the UI; only the
    /// merge with our in-memory shard and the apply run on the main actor.
    private func reloadMerged() async {
        guard !isPreparingLocalReset, let storage else { return }

        // Pull any peer's reader-mode extractions (CRDT-merged) so content a
        // sibling device already extracted shows here without re-fetching.
        await readerContentStore?.reload()

        guard let replicaStore else { return }
        // Snapshot the in-memory shard for the off-main merge; the generation is
        // re-checked after the hop so a local edit landing mid-merge can't be
        // clobbered by a materialize that didn't see it.
        let ownShardSnapshot = ownShard
        let generationBefore = ownShardSnapshot.generation
        let deviceID = deviceID
        let loaded = await Task.detached(priority: .userInitiated) {
            () -> (ReplicaSnapshot, HLC, ReaderLibrary, PrecomputedFilterState, Set<Article.ID>)? in
            guard let snapshot = try? replicaStore.reconcile(storage: storage) else { return nil }
            try? replicaStore.publishIfNeeded(to: storage)
            // Fold in this device's authoritative in-memory shard (a
            // not-yet-flushed local edit must never be dropped). The HLC fold
            // and the materialize are both O(all registers) — off-main here.
            let peers = ((try? storage.loadShards()) ?? []).filter { $0.deviceID != deviceID }
            var folded = HLC.zero
            for shard in peers { folded = folded.witnessed(shard.maxObservedHLC) }
            let merged = DeviceStateDocument.materialize(
                base: snapshot.library, shards: peers + [ownShardSnapshot]
            )
            let precomputed = ReaderStore.precomputeFilterState(
                articles: merged.articles, filters: merged.filters, categories: merged.categories
            )
            let deleted = ReaderStore.tombstonedArticleIDs(in: peers + [ownShardSnapshot])
            return (snapshot, folded, merged, precomputed, deleted)
        }.value
        guard !isPreparingLocalReset,
              let (snapshot, foldedPeerHLC, mergedRaw, precomputed, deleted) = loaded,
              snapshot.revision >= appliedReplicaRevision else { return }
        // A refresh may have started during the off-main decode; its in-memory
        // articles would be newer than this disk snapshot, so don't clobber them.
        guard !isRefreshing else { return }
        // A local edit landed while the merge ran: the materialized result is
        // stale against it. Bail — the edit's own save republishes, and the next
        // sync event re-runs this merge against the current shard.
        guard ownShard.generation == generationBefore else { return }

        lastHLC = lastHLC.witnessed(foldedPeerHLC)
        ownShard.clock = lastHLC
        // The shard scan is the authority on deletions, including peers'
        // (a peer-deleted article must not resurrect via OUR next refresh).
        deletedArticleIDs = deleted
        // Fill bodies from the cache so the (list-light) baseline's stripped
        // bodies don't read as a change and the applied result keeps content.
        // Hydration stays on the main actor: `bodyCache` can advance while the
        // merge runs off-main (body hydration doesn't bump the shard
        // generation), and hydrating against a stale snapshot would compare —
        // and apply — unhydrated bodies over hydrated ones.
        if !snapshot.bodies.isEmpty { bodyCache.merge(snapshot.bodies) { _, new in new } }
        let merged = hydratedFromCache(mergedRaw)

        // Compare against the same folder normalization `apply` produces.
        let impliedFolders = merged.feeds.map(\.folderName).filter { !$0.isEmpty }
        let mergedFolders = Set(merged.folders).union(impliedFolders)
        if merged.feeds != feeds || merged.articles != articles || mergedFolders != Set(folders) || merged.filters != filters || merged.categories != categories {
            // The precomputed state was built from the unhydrated articles;
            // classification hashes only title/summary and counts only flags,
            // so body hydration doesn't invalidate it.
            apply(merged, precomputed: precomputed)
            pruneSelectionIfHidden()
        }
        lastKnownLibraryModDate = storage.libraryModificationDate
        lastKnownStateModDate = storage.stateDirectoryModificationDate
        lastKnownContentModDate = storage.contentDirectoryModificationDate
        lastKnownBodiesModDate = storage.bodiesDirectoryModificationDate
        appliedReplicaRevision = max(appliedReplicaRevision, snapshot.revision)
    }

    private func applyReplicaSnapshot(_ snapshot: ReplicaSnapshot, storage: ReaderStorage) {
        guard snapshot.revision >= appliedReplicaRevision else { return }
        if !snapshot.bodies.isEmpty { bodyCache.merge(snapshot.bodies) { _, new in new } }
        mergeShardsAndApply(base: snapshot.library, storage: storage)
        appliedReplicaRevision = snapshot.revision
    }

    /// Loads the content sidecar once (off-main) into the in-memory body cache,
    /// then fills the current articles' bodies from it. The list already shows
    /// from the light baseline, so this runs after launch without blocking it.
    private func loadBodyCacheIfNeeded() async {
        guard !didLoadBodyCache, !isLoadingBodyCache, let storage else { applyBodyCache(); return }
        isLoadingBodyCache = true
        let bodies = await Task.detached(priority: .userInitiated) { storage.loadContent() }.value
        isLoadingBodyCache = false
        didLoadBodyCache = true
        if !bodies.isEmpty {
            bodyCache.merge(bodies) { current, _ in current }
            scheduleSave()
        }
        applyBodyCache()
    }

    /// Fills bodies into any in-memory article that is missing one, from the
    /// cache. Bodies aren't shown in the list, so this never churns it.
    private func applyBodyCache() {
        guard !bodyCache.isEmpty else { return }
        // Mutate a local copy and assign once: `articles` has a didSet that
        // recomputes counts and the filter, so per-element writes would make
        // this O(n²) and stall the main actor.
        var updated = articles
        var changed = false
        for index in updated.indices where !updated[index].hasBody {
            if let body = bodyCache[updated[index].id] {
                updated[index].bodyParagraphs = body.bodyParagraphs
                updated[index].contentHTML = body.contentHTML
                changed = true
            }
        }
        if changed { articles = updated }
    }

    /// Returns `library` with each article's body filled in from the cache where
    /// the (list-light) baseline left it empty, so a re-merge comparison ignores
    /// the stripped bodies and the applied result keeps its content.
    private func hydratedFromCache(_ library: ReaderLibrary) -> ReaderLibrary {
        guard !bodyCache.isEmpty else { return library }
        var library = library
        for index in library.articles.indices where !library.articles[index].hasBody {
            if let body = bodyCache[library.articles[index].id] {
                library.articles[index].bodyParagraphs = body.bodyParagraphs
                library.articles[index].contentHTML = body.contentHTML
            }
        }
        return library
    }

    /// The ids whose bodies are worth persisting: the most recent articles, so
    /// the content sidecar stays bounded.
    nonisolated static func recentArticleIDs(from articles: [Article]) -> Set<Article.ID> {
        guard articles.count > bodyRetentionLimit else { return Set(articles.map(\.id)) }
        let recent = articles.sorted(by: Article.isOrderedBefore).prefix(bodyRetentionLimit)
        return Set(recent.map(\.id))
    }

    /// Pulls the latest legacy input and every peer shard, then re-merges.
    /// Call this when the app returns to the foreground so device switches sync
    /// promptly — it bypasses the baseline mtime gate so shard-only edits (a read
    /// on another device) are pulled even when the baseline is unchanged.
    public func syncFromDisk() {
        guard !isPreparingLocalReset, let storage, !isRefreshing else { return }
        storage.startDownloadingLibraryIfNeeded()
        storage.startDownloadingStateIfNeeded()
        // reloadMerged decodes off-main and records the mod dates itself.
        Task { await reloadMerged() }
    }

    public func feed(for feedID: Feed.ID) -> Feed? {
        feedsByID[feedID]
    }

    public func faviconImage(for feed: Feed) -> Image? {
        feedIcons[feed.id].map(Image.init(platformImage:))
    }

    /// All folder names (including empty ones), in natural order.
    public var feedFolders: [String] {
        folders.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func feeds(inFolder folder: String) -> [Feed] {
        feeds.filter { $0.folderName == folder }
            .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
    }

    func feedCount(inFolder folder: String) -> Int {
        feeds.reduce(0) { $1.folderName == folder ? $0 + 1 : $0 }
    }

    public var ungroupedFeeds: [Feed] {
        feeds.filter { $0.folderName.isEmpty }
            .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
    }

    public func createFolder(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !folders.contains(trimmed) else { return }
        folders.append(trimmed)
        recordFolder(trimmed, present: true)
        scheduleShardSave()
        saveAfterMutation()
    }

    /// Removes a folder and every feed inside it.
    public func removeFolder(_ name: String) {
        let removedIDs = Set(feeds.filter { $0.folderName == name }.map(\.id))
        // Same resurrection guard as removeFeed: buffered fetch results for
        // these feeds must not be applied after the delete.
        for id in removedIDs { discardPendingBatchMerges(forFeedID: id) }
        feeds.removeAll { removedIDs.contains($0.id) }
        articles.removeAll { removedIDs.contains($0.feedID) }
        for id in removedIDs {
            feedIcons[id] = nil
            feedSelection.remove(id)
        }
        folders.removeAll { $0 == name }
        for id in removedIDs { recordFeedDeleted(id) }
        recordFolder(name, present: false)
        scheduleShardSave()
        pruneSelectionIfHidden()
        saveAfterMutation()
    }

    /// Renames a folder, moving every feed inside it to the new name. No-op if
    /// the new name is empty, unchanged, or already taken by another folder.
    public func renameFolder(_ oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName,
              folders.contains(oldName), !folders.contains(trimmed) else {
            return
        }
        for index in feeds.indices where feeds[index].folderName == oldName {
            feeds[index].category = trimmed
            recordCategory(feeds[index].id, trimmed)
        }
        if let index = folders.firstIndex(of: oldName) {
            folders[index] = trimmed
        }
        recordFolder(oldName, present: false)
        recordFolder(trimmed, present: true)
        scheduleShardSave()
        saveAfterMutation()
    }

    /// Moves a feed into a folder (empty string moves it back to top level).
    public func moveFeed(_ feedID: Feed.ID, toFolder folder: String) {
        guard !Self.isManagedFeed(feedID) else { return }
        guard let index = feeds.firstIndex(where: { $0.id == feedID }),
              feeds[index].category != folder else {
            return
        }
        feeds[index].category = folder
        recordCategory(feedID, folder)
        if !folder.isEmpty, !folders.contains(folder) {
            folders.append(folder)
            recordFolder(folder, present: true)
        }
        scheduleShardSave()
        saveAfterMutation()
    }

    /// Renames a feed. A trimmed non-empty name becomes the feed's custom title;
    /// an empty name clears the override so the feed-provided title is used again
    /// (and keeps updating on refresh). No-op if nothing changed.
    public func renameFeed(_ feedID: Feed.ID, to newName: String) {
        guard !Self.isManagedFeed(feedID) else { return }
        guard let index = feeds.firstIndex(where: { $0.id == feedID }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? nil : trimmed
        guard feeds[index].customTitle != value else { return }
        feeds[index].customTitle = value
        recordCustomTitle(feedID, value)
        scheduleShardSave()
        saveAfterMutation()
    }

    public func isRefreshing(feedID: Feed.ID) -> Bool {
        spinningFeedIDs.contains(feedID)
    }

    /// A value that changes each time the feed gains new articles. The sidebar
    /// uses it as an animation trigger to flash the feed; a stable token means no
    /// new content, so no flash.
    public func feedUpdateToken(feedID: Feed.ID) -> Int {
        feedUpdateTokens[feedID] ?? 0
    }

    /// Marks a feed's fetch as in flight. `spinner` shows the per-feed spinner;
    /// automatic refreshes pass false so the icon stays put.
    private func beginFeedFetch(_ id: Feed.ID, spinner: Bool) {
        refreshingFeedIDs.insert(id)
        if spinner { spinningFeedIDs.insert(id) }
        syncIsRefreshing()
    }

    private func endFeedFetch(_ id: Feed.ID) {
        refreshingFeedIDs.remove(id)
        spinningFeedIDs.remove(id)
        syncIsRefreshing()
    }

    /// Bumps a feed's update token so the sidebar flashes it once. The token only
    /// moves when real new content arrives, so the flash never repeats on an
    /// unchanged refresh and needs no timer to clear.
    private func flashFeedUpdate(_ feedID: Feed.ID) {
        feedUpdateTokens[feedID, default: 0] += 1
    }

    /// Sets the per-feed reading-view override (`nil` = follow the global
    /// default) for one or more feeds, so their articles always open in the
    /// chosen mode without toggling each time.
    public func setPreferredViewMode(_ mode: ReaderViewMode?, feedIDs: [Feed.ID]) {
        var changed = false
        for id in feedIDs {
            guard let index = feeds.firstIndex(where: { $0.id == id }),
                  feeds[index].preferredViewMode != mode else { continue }
            feeds[index].preferredViewMode = mode
            recordViewMode(id, mode)
            changed = true
        }
        if changed {
            scheduleShardSave()
            saveAfterMutation()
        }
    }

    /// Total unread across every feed, used for the app icon badge.
    var totalUnreadCount: Int { totalUnread }

    /// Recomputes every sidebar count in one pass over `articles`. Called from
    /// the `articles` didSet so the cached values stay exact without the sidebar
    /// re-scanning all articles per badge, per render.
    private func recomputeCounts() {
        var byFeed: [Feed.ID: Int] = [:]
        var byCategory: [String: Int] = [:]
        var total = 0
        var today = 0
        var starred = 0
        let calendar = Calendar.current
        // Compute today's [start, next-midnight) once instead of re-deriving
        // calendar components per article via isDateInToday. Half-open interval
        // matches isDateInToday exactly (and the .today filter at line ~359).
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)
        for article in articles {
            // A filtered article is hidden everywhere and must never count toward
            // unread / today / starred / per-feed badges (nor the Dock badge).
            if filteredArticleIDs.contains(article.id) { continue }
            if !article.isRead {
                byFeed[article.feedID, default: 0] += 1
                total += 1
                for categoryID in article.categories { byCategory[categoryID, default: 0] += 1 }
            }
            if article.isStarred { starred += 1 }
            if let startOfTomorrow {
                if article.publishedAt >= startOfToday && article.publishedAt < startOfTomorrow { today += 1 }
            } else if calendar.isDateInToday(article.publishedAt) {
                today += 1
            }
        }
        // Compare before assigning: these are @Observable properties the sidebar
        // and badges read, and the didSet chain recomputes them on every article
        // mutation — an unchanged republish would invalidate those views for free.
        if unreadByFeed != byFeed { unreadByFeed = byFeed }
        if unreadByCategory != byCategory { unreadByCategory = byCategory }
        if totalUnread != total { totalUnread = total }
        if todayCount != today { todayCount = today }
        if starredCount != starred { starredCount = starred }
    }

    /// Recompiles the active filters (enabled, non-empty pattern) into
    /// `activeCompiledFilters`, compiling each regex once. Called only when the
    /// filter set changes — NOT on every article mutation — so a refresh doesn't
    /// recompile. Clears the classify cache, since a changed engine invalidates
    /// every prior verdict. No-op when the active set is unchanged (apply() runs
    /// on every peer sync; wiping the cache each time re-classified the whole
    /// library for syncs that didn't touch filters).
    private func rebuildFilterEngine() {
        let source = filters.filter { $0.enabled && !$0.pattern.isEmpty }
        guard source != compiledFilterSource else { return }
        compiledFilterSource = source
        activeCompiledFilters = source.map(Self.compileFilter)
        filterClassifyCache.removeAll(keepingCapacity: true)
    }

    nonisolated private static func compileFilter(_ filter: ArticleFilter) -> CompiledFilter {
        switch filter.kind {
        case .plainText:
            return CompiledFilter(filter: filter, regex: nil)
        case .regex:
            let options: NSRegularExpression.Options = filter.caseSensitive ? [] : [.caseInsensitive]
            return CompiledFilter(filter: filter, regex: try? NSRegularExpression(pattern: filter.pattern, options: options))
        }
    }

    /// The filter-classification and count state that `articles`' didSet derives,
    /// computed as pure values so the launch/sync pipelines can build it off the
    /// main actor and `apply` can install it without the O(n) didSet storm.
    struct PrecomputedFilterState: Sendable {
        var textFilteredIDs: Set<Article.ID>
        var classifyCache: [Article.ID: Int]
        var filteredIDs: Set<Article.ID>
        var unreadByFeed: [Feed.ID: Int]
        var unreadByCategory: [String: Int]
        var totalUnread: Int
        var todayCount: Int
        var starredCount: Int
    }

    /// Pure mirror of `rebuildFilterEngine` + `recomputeFilteredIDs` (cold, no
    /// prior cache) + `recomputeCounts`, over value snapshots. Compiled regexes
    /// stay local to the call (NSRegularExpression isn't Sendable).
    nonisolated private static func precomputeFilterState(
        articles: [Article], filters: [ArticleFilter], categories: [ArticleCategory]
    ) -> PrecomputedFilterState {
        let compiled = filters.filter { $0.enabled && !$0.pattern.isEmpty }.map(compileFilter)
        let hiddenCategoryIDs = Set(categories.filter { $0.hidden }.map(\.id))

        var textIDs = Set<Article.ID>()
        var cache = [Article.ID: Int](minimumCapacity: articles.count)
        if !compiled.isEmpty {
            for article in articles {
                cache[article.id] = filterContentHash(article)
                let isFiltered = compiled.contains { entry in
                    filterMatches(
                        entry.filter,
                        regex: entry.regex,
                        in: entry.filter.candidateText(title: article.title, summary: article.summary)
                    )
                }
                if isFiltered { textIDs.insert(article.id) }
            }
        }

        var filteredIDs = textIDs
        if !hiddenCategoryIDs.isEmpty {
            for article in articles where article.categories.contains(where: { hiddenCategoryIDs.contains($0) }) {
                filteredIDs.insert(article.id)
            }
        }

        // Counts, mirroring recomputeCounts exactly.
        var byFeed: [Feed.ID: Int] = [:]
        var byCategory: [String: Int] = [:]
        var total = 0
        var today = 0
        var starred = 0
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)
        for article in articles {
            if filteredIDs.contains(article.id) { continue }
            if !article.isRead {
                byFeed[article.feedID, default: 0] += 1
                total += 1
                for categoryID in article.categories { byCategory[categoryID, default: 0] += 1 }
            }
            if article.isStarred { starred += 1 }
            if let startOfTomorrow {
                if article.publishedAt >= startOfToday && article.publishedAt < startOfTomorrow { today += 1 }
            } else if calendar.isDateInToday(article.publishedAt) {
                today += 1
            }
        }

        return PrecomputedFilterState(
            textFilteredIDs: textIDs, classifyCache: cache, filteredIDs: filteredIDs,
            unreadByFeed: byFeed, unreadByCategory: byCategory,
            totalUnread: total, todayCount: today, starredCount: starred
        )
    }

    /// Rebuilds `filteredArticleIDs` using the precompiled engine. Incremental: an
    /// article whose title/summary is unchanged since its last classification
    /// (same engine) reuses its prior verdict instead of re-running the match, so
    /// a multi-feed refresh only tests genuinely new/changed articles.
    private func recomputeFilteredIDs() {
        let hiddenCategoryIDs = Set(categories.filter { $0.hidden }.map(\.id))
        guard !activeCompiledFilters.isEmpty || !hiddenCategoryIDs.isEmpty else {
            if !filteredArticleIDs.isEmpty { filteredArticleIDs = [] }
            if !textFilteredArticleIDs.isEmpty { textFilteredArticleIDs = [] }
            if !filterClassifyCache.isEmpty { filterClassifyCache.removeAll(keepingCapacity: true) }
            return
        }

        // 1) Text filters (incremental, possibly regex), cached against the
        //    text-only basis so a category-hide change never corrupts the reuse.
        var textIDs = Set<Article.ID>()
        var cache = Dictionary<Article.ID, Int>(minimumCapacity: articles.count)
        if !activeCompiledFilters.isEmpty {
            textIDs.reserveCapacity(textFilteredArticleIDs.count)
            for article in articles {
                let hash = Self.filterContentHash(article)
                let isFiltered: Bool
                if filterClassifyCache[article.id] == hash {
                    isFiltered = textFilteredArticleIDs.contains(article.id)
                } else {
                    isFiltered = activeCompiledFilters.contains { compiled in
                        Self.filterMatches(
                            compiled.filter,
                            regex: compiled.regex,
                            in: compiled.filter.candidateText(title: article.title, summary: article.summary)
                        )
                    }
                }
                if isFiltered { textIDs.insert(article.id) }
                cache[article.id] = hash
            }
        }
        textFilteredArticleIDs = textIDs
        filterClassifyCache = cache

        // 2) Category hiding: cheap set-intersection, recomputed fresh (no cache),
        //    unioned onto the text result.
        if hiddenCategoryIDs.isEmpty {
            filteredArticleIDs = textIDs
        } else {
            var combined = textIDs
            for article in articles where article.categories.contains(where: { hiddenCategoryIDs.contains($0) }) {
                combined.insert(article.id)
            }
            filteredArticleIDs = combined
        }
    }

    /// A cheap content fingerprint of the fields filters match against, to detect
    /// whether an article needs re-testing. In-memory only (process-seeded hash).
    nonisolated private static func filterContentHash(_ article: Article) -> Int {
        var hasher = Hasher()
        hasher.combine(article.title)
        hasher.combine(article.summary)
        return hasher.finalize()
    }

    /// Whether one filter matches the given text. Plain-text is a (case-optional)
    /// substring test; regex uses the precompiled expression (a nil/invalid regex
    /// never matches, so a malformed pattern hides nothing).
    nonisolated private static func filterMatches(_ filter: ArticleFilter, regex: NSRegularExpression?, in text: String) -> Bool {
        switch filter.kind {
        case .plainText:
            let options: String.CompareOptions = filter.caseSensitive ? [] : [.caseInsensitive]
            return text.range(of: filter.pattern, options: options) != nil
        case .regex:
            guard let regex else { return false }
            let range = NSRange(text.startIndex..., in: text)
            return regex.firstMatch(in: text, options: [], range: range) != nil
        }
    }

    /// Re-classify after a filter change, then refresh counts, badge, and list.
    private func applyFilterChange() {
        rebuildFilterEngine()
        recomputeFilteredIDs()
        // Removing/disabling/clearing the last active filter hides the "Filtered"
        // sidebar entry, so a user sitting on that source would be stranded on a
        // now-unreachable, empty list — send them back to All Articles. Uses the
        // same `hasFilters` condition that gates the sidebar row.
        if !hasFilters, feedSelection.isEmpty, smartSelection == .filtered {
            selectSmartSource(.all)
        }
        recomputeCounts()
        updateUnreadBadge()
        scheduleArticleFilter()
    }

    // MARK: - Article filters (public API)

    /// Appends a new filter (after the current last), then persists/syncs it and
    /// re-classifies articles.
    @discardableResult
    public func addFilter(
        kind: ArticleFilter.Kind = .plainText,
        pattern: String = "",
        matchTarget: ArticleFilter.MatchTarget = .titleAndSummary
    ) -> ArticleFilter {
        let order = (filters.map(\.order).max() ?? -1) + 1
        let filter = ArticleFilter(kind: kind, pattern: pattern, matchTarget: matchTarget, order: order)
        filters.append(filter)
        recordFilter(filter)
        scheduleShardSave()
        applyFilterChange()
        return filter
    }

    /// Replaces the filter with the same id (an edit from the settings UI).
    public func updateFilter(_ filter: ArticleFilter) {
        guard let index = filters.firstIndex(where: { $0.id == filter.id }) else { return }
        guard filters[index] != filter else { return }
        filters[index] = filter
        recordFilter(filter)
        scheduleShardSave()
        applyFilterChange()
    }

    /// Removes a filter; its articles reappear in the normal lists. Records a
    /// tombstone so the deletion syncs (and doesn't resurrect from a peer's copy).
    public func removeFilter(id: ArticleFilter.ID) {
        guard filters.contains(where: { $0.id == id }) else { return }
        filters.removeAll { $0.id == id }
        recordFilterRemoval(id)
        scheduleShardSave()
        applyFilterChange()
    }

    /// Reorders filters (UI convenience). Order doesn't affect matching, so this
    /// re-stamps each moved filter's `order` and persists — no re-classification.
    public func moveFilters(fromOffsets: IndexSet, toOffset: Int) {
        filters.move(fromOffsets: fromOffsets, toOffset: toOffset)
        for index in filters.indices where filters[index].order != index {
            filters[index].order = index
            recordFilter(filters[index])
        }
        scheduleShardSave()
        scheduleArticleFilter()
    }

    // MARK: - Categories (public API)

    /// Re-classify (a hidden category changes the filtered set) and refresh
    /// counts/badge/list after a category definition change.
    private func applyCategoryChange() {
        recomputeFilteredIDs()
        if !hasFilters, feedSelection.isEmpty, smartSelection == .filtered {
            selectSmartSource(.all)
        }
        // Don't strand the user browsing a category that was just deleted.
        if let selected = categorySelection, !categories.contains(where: { $0.id == selected }) {
            selectSmartSource(.all)
        }
        recomputeCounts()
        updateUnreadBadge()
        scheduleArticleFilter()
    }

    @discardableResult
    public func addCategory(name: String = "") -> ArticleCategory {
        let order = (categories.map(\.order).max() ?? -1) + 1
        let color = ArticleCategory.defaultPalette[categories.count % ArticleCategory.defaultPalette.count]
        let category = ArticleCategory(name: name, colorHex: color, order: order)
        categories.append(category)
        recordCategoryDefinition(category)
        scheduleShardSave()
        applyCategoryChange()
        return category
    }

    public func updateCategory(_ category: ArticleCategory) {
        guard let index = categories.firstIndex(where: { $0.id == category.id }) else { return }
        guard categories[index] != category else { return }
        categories[index] = category
        recordCategoryDefinition(category)
        scheduleShardSave()
        applyCategoryChange()
    }

    /// Deletes a category (tombstone syncs it) and strips its id from every
    /// article that had it, so no article keeps a dangling assignment.
    public func removeCategory(id: String) {
        guard categories.contains(where: { $0.id == id }) else { return }
        categories.removeAll { $0.id == id }
        recordCategoryRemoval(id)
        var updated = articles
        var changed = false
        for index in updated.indices where updated[index].categories.contains(id) {
            let previous = updated[index].categories
            updated[index].categories.removeAll { $0 == id }
            recordArticleCategories(updated[index].id, from: previous, to: updated[index].categories)
            changed = true
        }
        if changed { articles = updated }   // single didSet → one recompute
        scheduleShardSave()
        applyCategoryChange()
    }

    public func moveCategories(fromOffsets: IndexSet, toOffset: Int) {
        categories.move(fromOffsets: fromOffsets, toOffset: toOffset)
        for index in categories.indices where categories[index].order != index {
            categories[index].order = index
            recordCategoryDefinition(categories[index])
        }
        scheduleShardSave()
    }

    /// The category definitions assigned to an article, in the stored order — for
    /// the list badges. Reads `categories`, so a row calling this observes it.
    public func categories(forArticle article: Article) -> [ArticleCategory] {
        guard !article.categories.isEmpty, !categoriesByID.isEmpty else { return [] }
        return article.categories.compactMap { categoriesByID[$0] }
    }

    /// Toggles one category on/off for an article (from a menu). No-op if the id
    /// isn't a real category or the article isn't loaded.
    public func toggleCategory(_ id: String, forArticle articleID: Article.ID) {
        guard categories.contains(where: { $0.id == id }),
              let article = articles.first(where: { $0.id == articleID }) else { return }
        var next = article.categories
        if let index = next.firstIndex(of: id) { next.remove(at: index) } else { next.append(id) }
        setArticleCategories(articleID: articleID, next)
    }

    /// Sets the categories assigned to one article (manual add/remove from the UI).
    public func setArticleCategories(articleID: Article.ID, _ ids: [String]) {
        guard let index = articles.firstIndex(where: { $0.id == articleID }) else { return }
        // Keep only ids that are real categories, de-duplicated, order preserved.
        let valid = Set(categories.map(\.id))
        var seen = Set<String>()
        let cleaned = ids.filter { valid.contains($0) && seen.insert($0).inserted }
        guard articles[index].categories != cleaned else { return }
        let previous = articles[index].categories
        articles[index].categories = cleaned
        recordArticleCategories(articleID, from: previous, to: cleaned)
        scheduleShardSave()
    }

    // MARK: - Classification

    /// Category ids whose keywords match the article, in category order.
    private func keywordCategoryIDs(title: String, summary: String) -> [String] {
        categories
            .filter { $0.matchesKeywords(title: title, summary: summary) }
            .sorted { ($0.order, $0.id) < ($1.order, $1.id) }
            .map(\.id)
    }

    /// Keyword-only auto categories for a new article, capped at 3.
    private func keywordAutoCategories(for article: Article) -> [String] {
        Array(keywordCategoryIDs(title: article.title, summary: article.summary).prefix(ArticleCategory.maxPerArticle))
    }

    /// Enqueues an article for background AI categorization (no-op unless AI is
    /// enabled and usable). Keyword categories are applied separately, up front.
    private func enqueueAICategorization(_ id: Article.ID) {
        guard isAICategorizationActive else { return }
        if !aiCategorizeQueue.contains(id) { aiCategorizeQueue.append(id) }
        guard !aiCategorizeRunning else { return }
        aiCategorizeRunning = true
        Task { await drainAICategorizeQueue() }
    }

    /// Drains the queue in batches, the way `performBulkCategorize` already does.
    ///
    /// It used to assign each article as its answer came back, and each assignment
    /// writes `articles` — one republish of the whole array per classified article,
    /// up to sixty-four per sweep, arriving every half-second to few seconds for
    /// minutes after any sync, while nobody is touching the machine. Anything reading
    /// `articles` is invalidated by each one, and the reader reads it at the top of
    /// its body, so an open article and its whole comment thread were revalidated on
    /// every tick: 3ms on a plain article, 11ms on a long one with a thread.
    ///
    /// Batched, that is one republish per twenty-five. The badges appear in groups
    /// rather than one at a time, which is what the bulk path deliberately does too.
    private func drainAICategorizeQueue() async {
        defer { aiCategorizeRunning = false }
        let provider = TranslationSettings.categoryProvider()
        var pending: [Article.ID: [String]] = [:]
        let flushEvery = 25

        func flush() {
            guard !pending.isEmpty else { return }
            var updated = articles
            let indexByID = Dictionary(
                updated.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (id, cats) in pending {
                if let index = indexByID[id] {
                    let previous = updated[index].categories
                    guard previous != cats else { continue }
                    updated[index].categories = cats
                    recordArticleCategories(id, from: previous, to: cats)
                } else {
                    // Left the library mid-pass; recorded additively so the
                    // assignment still syncs if it comes back.
                    recordArticleCategories(id, from: [], to: cats)
                }
            }
            articles = updated
            scheduleShardSave()
            pending.removeAll(keepingCapacity: true)
        }

        while !aiCategorizeQueue.isEmpty {
            let id = aiCategorizeQueue.removeFirst()
            guard let article = articles.first(where: { $0.id == id }) else { continue }
            if let combined = await classification(for: article, provider: provider) {
                pending[id] = combined
            }
            if pending.count >= flushEvery { flush() }
        }
        flush()
    }

    /// Classifies one article with AI and merges the result onto its existing
    /// (keyword) categories, capped at 3. AI never removes; if it finds none,
    /// nothing is added.
    /// The categories this article should end up with, or nil to leave it alone.
    ///
    /// Returns rather than assigns so the caller can batch the writes; assigning here
    /// republished the whole `articles` array once per article.
    private func classification(
        for article: Article, provider: TranslationProvider
    ) async -> [String]? {
        guard article.categories.count < ArticleCategory.maxPerArticle, !categories.isEmpty
        else { return nil }
        let names = await NaturalTranslator.classify(
            title: article.title, summary: article.summary,
            into: categories.map(\.name), provider: provider
        )
        guard !names.isEmpty else { return nil }
        let idByName = Dictionary(categories.map { ($0.name.lowercased(), $0.id) }, uniquingKeysWith: { first, _ in first })
        // Re-read the current assignment (it may have changed while awaiting).
        guard let current = articles.first(where: { $0.id == article.id })?.categories else { return nil }
        var combined = current
        for cid in names.compactMap({ idByName[$0.lowercased()] }) where !combined.contains(cid) && combined.count < ArticleCategory.maxPerArticle {
            combined.append(cid)
        }
        // Only ids that are real categories survive, de-duplicated, order preserved —
        // the cleaning `setArticleCategories` used to do on the way in.
        let valid = Set(categories.map(\.id))
        var seen = Set<String>()
        let cleaned = combined.filter { valid.contains($0) && seen.insert($0).inserted }
        return cleaned == current ? nil : cleaned
    }

    // MARK: - Classification backlog sweep

    /// Max articles the sweep picks up per merge. Bounds the AI spend and the
    /// main-actor work per sync; the per-device receipts make consecutive
    /// sweeps advance through the backlog instead of retrying the same slice.
    /// `nonisolated` so the off-main selection task can read it.
    private nonisolated static let classificationSweepBatch = 64

    /// Tags articles that arrived *already fetched* from another device. The
    /// network-arrival path classifies new articles as they land, but an
    /// article synced in via the shared baseline skips that path entirely — if
    /// the device that fetched it never classified it (AI off there, app not
    /// yet updated), it stays untagged everywhere. Runs after each merge:
    /// keyword rules apply immediately in one batched write, AI classification
    /// feeds the existing one-at-a-time queue, and a per-device receipt marks
    /// each article attempted so a sweep never re-pays for an article that
    /// classification already declined to tag.
    private func scheduleClassificationSweep() {
        guard !classificationSweepRunning,
              !isPreparingLocalReset,
              !isBulkCategorizing,
              hasCategories,
              replicaStore != nil else { return }
        // Nothing could possibly tag right now (no AI, no keyword rules): skip
        // WITHOUT writing receipts, so enabling either later still sees the
        // whole backlog.
        guard isAICategorizationActive || categories.contains(where: { !$0.keywords.isEmpty }) else { return }
        classificationSweepRunning = true
        Task { [weak self] in
            await self?.sweepClassificationBacklog()
            self?.classificationSweepRunning = false
        }
    }

    private func sweepClassificationBacklog() async {
        guard let replicaStore else { return }
        // Hidden (filtered) articles never surface in the lists, so tagging
        // them would spend AI calls on content the user asked not to see.
        let candidates = articles.filter { $0.categories.isEmpty && !filteredArticleIDs.contains($0.id) }
        guard !candidates.isEmpty else { return }

        // Receipt filtering and newest-first selection are O(backlog) — off-main.
        let batchIDs = await Task.detached(priority: .utility) { () -> [Article.ID] in
            let needing = Set((try? replicaStore.articleIDsNeedingClassification(candidates.map(\.id))) ?? [])
            guard !needing.isEmpty else { return [] }
            return candidates
                .filter { needing.contains($0.id) }
                .sorted { $0.publishedAt > $1.publishedAt }   // recent stories first
                .prefix(Self.classificationSweepBatch)
                .map(\.id)
        }.value
        guard !batchIDs.isEmpty, !isPreparingLocalReset, !isBulkCategorizing else { return }

        // Keyword rules first (cheap, local): one batched articles write.
        var updated = articles
        let indexByID = Dictionary(updated.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var keywordChanged = false
        for id in batchIDs {
            guard let index = indexByID[id], updated[index].categories.isEmpty else { continue }
            let cats = keywordAutoCategories(for: updated[index])
            guard !cats.isEmpty else { continue }
            updated[index].categories = cats
            recordArticleCategories(id, from: [], to: cats)
            keywordChanged = true
        }
        if keywordChanged {
            articles = updated          // one didSet → one recompute for the batch
            scheduleShardSave()
        }

        // AI fills in what keywords didn't (serial queue; no-op when AI is off).
        for id in batchIDs {
            guard let index = indexByID[id], updated[index].categories.isEmpty else { continue }
            enqueueAICategorization(id)
        }
        try? replicaStore.markClassificationAttempted(batchIDs)
    }

    // MARK: - Migration (classify existing articles)

    /// Classifies existing articles in a background pass (settings migration).
    /// `provider` lets a Gemini user run this once on Apple Intelligence.
    public func classifyAllExisting(provider: TranslationProvider, onlyUncategorized: Bool = true) {
        // Guard on the task AND set progress synchronously, so a rapid second tap
        // can't slip past (progress is otherwise only set inside the async body).
        guard categorizeAllProgress == nil, bulkCategorizeTask == nil, !categories.isEmpty else { return }
        let targets = articles
            .filter { onlyUncategorized ? $0.categories.isEmpty : true }
            .map(\.id)
        guard !targets.isEmpty else { return }
        categorizeAllProgress = (0, targets.count)
        isBulkCategorizing = true
        bulkCategorizeTask = Task { await performBulkCategorize(targets, provider: provider) }
    }

    public func cancelClassifyAll() {
        bulkCategorizeTask?.cancel()
        bulkCategorizeTask = nil
        categorizeAllProgress = nil
    }

    private func performBulkCategorize(_ ids: [Article.ID], provider: TranslationProvider) async {
        defer {
            categorizeAllProgress = nil
            bulkCategorizeTask = nil
        }
        let idByName = Dictionary(categories.map { ($0.name.lowercased(), $0.id) }, uniquingKeysWith: { first, _ in first })
        // Accumulate results and flush them onto `articles` in batches, so a large
        // migration triggers one recompute per batch instead of one per article
        // (the O(N²) main-actor cost the review flagged). Each flush re-reads the
        // current `articles` by id, so a refresh landing mid-migration isn't lost.
        var pending: [Article.ID: [String]] = [:]
        let flushEvery = 25

        func flush() {
            guard !pending.isEmpty else { return }
            var updated = articles
            let indexByID = Dictionary(updated.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (id, cats) in pending {
                if let index = indexByID[id] {
                    let previous = updated[index].categories
                    updated[index].categories = cats
                    recordArticleCategories(id, from: previous, to: cats)
                } else {
                    // The article left the library mid-pass; record additively so
                    // the assignment still syncs if it resurfaces.
                    recordArticleCategories(id, from: [], to: cats)
                }
            }
            articles = updated          // one didSet → one recompute for the batch
            scheduleShardSave()
            pending.removeAll(keepingCapacity: true)
        }

        for (offset, id) in ids.enumerated() {
            if Task.isCancelled { break }
            if let article = articles.first(where: { $0.id == id }) {
                var combined = keywordAutoCategories(for: article)   // keyword first (priority)
                if combined.count < ArticleCategory.maxPerArticle {
                    let names = await NaturalTranslator.classify(
                        title: article.title, summary: article.summary,
                        into: categories.map(\.name), provider: provider
                    )
                    for cid in names.compactMap({ idByName[$0.lowercased()] }) where !combined.contains(cid) && combined.count < ArticleCategory.maxPerArticle {
                        combined.append(cid)
                    }
                }
                if combined != article.categories { pending[id] = combined }
            }
            if pending.count >= flushEvery { flush() }
            categorizeAllProgress = (offset + 1, ids.count)
        }
        flush()
        // Hand the badge reveal animation back only after SwiftUI has had a turn
        // to render the final batch, so the last flush lands instantly like every
        // earlier one. Owned solely by this tail — `cancelClassifyAll` drops the
        // task handle but the body still runs to here.
        await Task.yield()
        isBulkCategorizing = false
    }

    /// Installed by the platform app to reflect the unread badge (macOS Dock,
    /// iOS app icon). Called with the count to show, or 0 to clear.
    @ObservationIgnored public var onUnreadBadgeChange: ((Int) -> Void)?

    /// The single writer of the unread badge. Invoked automatically whenever the
    /// article set or the preference changes (via their `didSet`), so the badge
    /// can never drift out of sync with the unread count — on launch, during a
    /// refresh, or when read state changes — regardless of view timing. The
    /// actual Dock/app-icon update is delegated to `onUnreadBadgeChange` so the
    /// core stays platform-agnostic.
    private func updateUnreadBadge() {
        onUnreadBadgeChange?(showsUnreadBadge ? totalUnreadCount : 0)
    }

    // MARK: - "Seen" tracking (notification suppression)

    /// Called by the platform app when attended-foreground state changes. Becoming
    /// active marks the articles already on screen as seen (the user is looking at
    /// the synced list right now), so a later background refresh won't re-announce
    /// them.
    public func setForegroundActive(_ active: Bool) {
        guard active != isForegroundActive else { return }
        isForegroundActive = active
        if active { markVisibleArticlesSeen() }
    }

    /// While the app is foreground-active, records every currently-visible unread
    /// article as "seen" in this device's shard, so it never triggers a
    /// new-article notification later. Reads only in-memory `ownShard` (no disk
    /// I/O) and writes a register only for articles not already seen, so the
    /// common "nothing new on screen" case is a cheap scan. Seen state syncs to
    /// peers via the shard, suppressing the notification on the other device too.
    private func markVisibleArticlesSeen() {
        guard isForegroundActive, storage != nil else { return }
        var wrote = false
        for article in displayedArticles where !article.isRead {
            if ownShard.articleState[article.id]?.seen?.value == true { continue }
            ownShard.setArticleSeen(article.id, true, hlc: nextHLC())
            wrote = true
        }
        if wrote { scheduleShardSave() }
    }

    /// Article ids marked "seen" across every device's shard (peers + this
    /// device's authoritative in-memory shard). Used by the background refresh to
    /// skip notifying about articles the user already saw on any device.
    private func mergedSeenArticleIDs(storage: ReaderStorage) -> Set<Article.ID> {
        let merged = DeviceStateDocument.mergedState(from: observedShards(from: storage))
        var ids: Set<Article.ID> = []
        for (id, state) in merged.articles where state.seen?.value == true { ids.insert(id) }
        return ids
    }

    public func unreadCount(feedID: Feed.ID? = nil) -> Int {
        guard let feedID else { return totalUnread }
        return unreadByFeed[feedID] ?? 0
    }

    public func unreadCount(inFolder folder: String) -> Int {
        feeds.reduce(0) { $1.folderName == folder ? $0 + (unreadByFeed[$1.id] ?? 0) : $0 }
    }

    /// Selecting a folder selects all feeds inside it, so the article list
    /// shows the folder's combined articles.
    public func selectFolder(_ folder: String) {
        // Leave the category scope even for an empty folder (feedSelection's didSet
        // only clears it when non-empty).
        categorySelection = nil
        feedSelection = Set(feeds.filter { $0.folderName == folder }.map(\.id))
        clearRetainedArticles()
        pruneSelectionIfHidden()
    }

    public func isFolderSelected(_ folder: String) -> Bool {
        let ids = Set(feeds.filter { $0.folderName == folder }.map(\.id))
        return !ids.isEmpty && feedSelection == ids
    }

    public func count(for source: SmartSource) -> Int {
        switch source {
        case .unread: totalUnread
        case .today: todayCount
        case .starred: starredCount
        // `.all` excludes filtered articles (they live only under `.filtered`).
        case .all: articles.count - filteredArticleIDs.count
        case .filtered: filteredArticleIDs.count
        case .offline: OfflineArticleStore.shared.totalCount
        }
    }

    /// Whether the user has any articles saved offline (drives the sidebar entry).
    public var hasOfflineArticles: Bool { OfflineArticleStore.shared.totalCount > 0 }

    /// Whether a specific article is saved offline — the per-row icon signal.
    /// Reads `OfflineArticleStore.shared`, so the row observes its saved set.
    public func isOfflineSaved(_ id: Article.ID) -> Bool { OfflineArticleStore.shared.isSaved(id) }

    /// Whether any filter is actually active (enabled with a non-empty pattern).
    /// Drives whether the sidebar surfaces the "Filtered" entry — so a freshly
    /// added blank filter or an only-disabled filter doesn't show an empty row.
    public var hasFilters: Bool {
        filters.contains { $0.enabled && !$0.pattern.isEmpty } || categories.contains { $0.hidden }
    }

    // MARK: - Saved links (share-sheet "save page as article")

    /// The fully managed pseudo-feed holding pages the user saved as articles
    /// (e.g. via the share sheet when a site offers no feed). The feed itself
    /// cannot be deleted, renamed, or moved; its articles behave exactly like
    /// any other — read/star/delete, and they sync through the same baseline +
    /// shard pipeline.
    public nonisolated static let savedLinksFeedID = "nook://saved-links"

    /// Whether a feed is app-managed (excluded from delete/rename/move and
    /// from network refreshes).
    public nonisolated static func isManagedFeed(_ id: Feed.ID) -> Bool {
        id == savedLinksFeedID
    }

    /// Feeds suitable for OPML export — the managed pseudo-feed has no real
    /// feed URL and must not leak into subscription lists.
    public var exportableFeeds: [Feed] {
        feeds.filter { !Self.isManagedFeed($0.id) }
    }

    /// Saves a web page as a standalone article in the managed Saved Links
    /// feed: fetches the page title (best-effort), creates the article with a
    /// deterministic id (so the same link saved on two devices converges), and
    /// persists through the normal library pipeline. Re-saving a previously
    /// deleted link clears its tombstone.
    @discardableResult
    public func saveLink(urlString: String) async throws -> Article.ID {
        guard isStorageConfigured else { throw ReaderStorageError.noDirectorySelected }
        let pageURL = try feedService.normalizedFeedURL(from: urlString)
        let articleID = "\(Self.savedLinksFeedID)#\(pageURL.absoluteString)"

        // Already saved: just resurface it (clearing a deletion if needed).
        if let existing = articles.first(where: { $0.id == articleID }) {
            clearArticleTombstoneIfNeeded(articleID)
            return existing.id
        }

        let title = await feedService.fetchPageTitle(url: pageURL)
            ?? pageURL.host(percentEncoded: false)
            ?? pageURL.absoluteString

        ensureSavedLinksFeed()
        clearArticleTombstoneIfNeeded(articleID)
        let article = Article(
            id: articleID,
            feedID: Self.savedLinksFeedID,
            title: title,
            summary: "",
            bodyParagraphs: [],
            publishedAt: Date.now,
            url: pageURL,
            estimatedReadMinutes: 1,
            isRead: false,
            isStarred: false
        )
        articles.append(article)
        scheduleSave()
        return articleID
    }

    /// Creates the managed Saved Links feed on first use, CRDT-seeded so peers
    /// materialize it too.
    private func ensureSavedLinksFeed() {
        guard !feeds.contains(where: { $0.id == Self.savedLinksFeedID }) else { return }
        let feed = Feed(
            id: Self.savedLinksFeedID,
            title: String(localized: "Saved Links", bundle: .module),
            siteDescription: "",
            category: "",
            systemImage: "bookmark",
            feedURL: URL(string: Self.savedLinksFeedID)!,
            siteURL: URL(string: Self.savedLinksFeedID)!,
            healthScore: 1
        )
        feeds.append(feed)
        // Clears any stale deletion from before the feed became managed, and
        // seeds membership so peers reconstruct it.
        recordFeedRestored(feed.id)
        recordFeedSeed(feed)
        scheduleShardSave()
    }

    /// Un-deletes an article id (LWW: the fresh `false` register outranks the
    /// old tombstone) so a re-saved link can live again on every device.
    private func clearArticleTombstoneIfNeeded(_ id: Article.ID) {
        guard deletedArticleIDs.contains(id) else { return }
        ownShard.setArticleTombstone(id, false, hlc: nextHLC())
        deletedArticleIDs.remove(id)
        scheduleShardSave()
    }

    public func addFeed(urlString: String, toFolder folder: String = "") async throws {
        guard isStorageConfigured else {
            throw ReaderStorageError.noDirectorySelected
        }

        // Adding a feed takes priority over a full refresh: cancel any in-flight
        // one so the add isn't queued behind dozens of feed fetches (and its save
        // isn't held by the batch). Re-run the refresh afterward so the rest of
        // the feeds still update.
        let interruptedRefresh = isBatchRefreshing
        allFeedsRefreshTask?.cancel()

        let url = try feedService.normalizedFeedURL(from: urlString)
        // Reuse an existing feed's id when this URL normalizes to one we already
        // have (trailing slash / casing), so re-adding it doesn't split into a
        // duplicate feed identity. (OPML import already dedupes this way.)
        let existingFeedID = feeds.first {
            $0.feedURL.feedIdentityKey == url.feedIdentityKey || $0.siteURL.feedIdentityKey == url.feedIdentityKey
        }?.id
        let parsedFeed = try await fetch(url: url, existingFeedID: existingFeedID)
        if !folder.isEmpty {
            moveFeed(parsedFeed.feed.id, toFolder: folder)
        }
        feedSelection = [parsedFeed.feed.id]
        selectedArticleID = parsedFeed.articles.first?.id
        errorMessage = nil

        if interruptedRefresh {
            startAllFeedsRefresh()
        }
    }

    /// Result of a background refresh: how many genuinely new (previously
    /// unseen, unread) articles arrived, and their titles (most-recent first) for
    /// the notification summarizer.
    public struct BackgroundRefreshResult: Sendable {
        public let newArticleCount: Int
        public let sampleTitles: [String]
        public let articleIDs: [Article.ID]
        /// The value the app-icon badge should show — total unread (or 0 when the
        /// unread-badge preference is off). The delivered notification carries
        /// this so the badge reflects *all* unread articles, not just how many
        /// arrived this run, and stays correct even on a cold background launch
        /// where the store's badge callback isn't wired up.
        public let badgeCount: Int

        public init(
            newArticleCount: Int,
            sampleTitles: [String],
            articleIDs: [Article.ID] = [],
            badgeCount: Int = 0
        ) {
            self.newArticleCount = newArticleCount
            self.sampleTitles = sampleTitles
            self.articleIDs = articleIDs
            self.badgeCount = badgeCount
        }
    }

    /// Refreshes all feeds from a background launch and reports newly-arrived
    /// unread articles. Loads the library first if the process is fresh, and
    /// writes it synchronously so the result is saved before the OS suspends
    /// the app again.
    public func refreshForBackground(includingHeldAlerts: Bool = false) async -> BackgroundRefreshResult {
        if !didBootstrap { await bootstrap() }
        // The iOS background task runs with no visible UI but a tight OS time
        // budget, so fetch fast (like interactive) yet without animation.
        let result = await refreshAllReportingNew(
            mode: .background,
            includingHeldAlerts: includingHeldAlerts
        )
        // Write synchronously so the result is saved before the OS suspends the
        // app again (the iOS background-task caller depends on this).
        try? persistReplica()
        return result
    }

    /// Refreshes all feeds and reports the genuinely new (previously unseen,
    /// unread) articles that arrived, so a background refresher can decide
    /// whether to notify. Assumes the library is already loaded.
    ///
    /// Pass `includingHeldAlerts` to also report articles reserved by an earlier
    /// run that deliberately withheld their alert — what iOS quiet hours do. It
    /// is opt-in because a caller that reserves without always marking the result
    /// delivered (macOS skips the mark when notifications are off or the reader is
    /// in use) would otherwise re-report the same articles forever.
    public func refreshAllReportingNew(
        mode: RefreshMode = .ambient,
        includingHeldAlerts: Bool = false
    ) async -> BackgroundRefreshResult {
        guard !isPreparingLocalReset, isStorageConfigured, !feeds.isEmpty else {
            return BackgroundRefreshResult(newArticleCount: 0, sampleTitles: [])
        }

        // Sync every content/state shard first, so an article
        // another device already fetched (and possibly read) is already known
        // here and isn't re-announced as new.
        await reloadMerged()
        guard !isPreparingLocalReset else {
            return BackgroundRefreshResult(newArticleCount: 0, sampleTitles: [])
        }
        // Already synced above; skip the redundant reload inside refreshAllFeeds.
        // Runs through the shared batch slot so a background/periodic refresh never
        // reenters a foreground one; forward OS cancellation into the batch.
        let refreshTask = startBatchedFetch { await $0.refreshAllFeeds(syncFirst: false, mode: mode) }
        await withTaskCancellationHandler {
            _ = await refreshTask.value
        } onCancel: {
            refreshTask.cancel()
        }
        guard !isPreparingLocalReset else {
            return BackgroundRefreshResult(newArticleCount: 0, sampleTitles: [])
        }
        try? persistReplica()
        // Never notify about an article the user already saw in the list on any
        // device — "seen" syncs via the shards, so it suppresses across devices.
        let seen = storage.map { mergedSeenArticleIDs(storage: $0) } ?? []
        // A filtered article is hidden and never treated as unread, so it must
        // never fire a "new article" notification either.
        let candidates = articles.filter { !$0.isRead && !seen.contains($0.id) && !filteredArticleIDs.contains($0.id) }
        let reserved = (try? replicaStore?.reserveNotifications(for: candidates)) ?? []
        // A refresh inside the user's quiet hours fetches and reserves as usual —
        // feeds drop old items, so collection must never pause — but holds the
        // delivery, leaving those articles queued. Pick them up here so the first
        // refresh after the window opens announces the whole batch. Re-filtering
        // through `candidates` drops anything read (here or on another device)
        // while it waited, so the digest can't announce stale news.
        let held: [Article]
        if includingHeldAlerts, let pending = try? replicaStore?.pendingNotificationIDs() {
            let reservedIDs = Set(reserved.map(\.id))
            held = candidates.filter { pending.contains($0.id) && !reservedIDs.contains($0.id) }
        } else {
            held = []
        }
        let fresh = reserved + held
        let sorted = fresh.sorted(by: Article.isOrderedBefore)
        return BackgroundRefreshResult(
            newArticleCount: fresh.count,
            // Carry enough titles for the summarizer to condense; it caps its own
            // input, and the plain-list fallback trims to a few lines.
            sampleTitles: sorted.prefix(12).map(\.title),
            articleIDs: fresh.map(\.id),
            badgeCount: showsUnreadBadge ? totalUnreadCount : 0
        )
    }

    public func markNotificationsDelivered(_ articleIDs: [Article.ID]) {
        try? replicaStore?.markNotificationsDelivered(articleIDs)
    }

    /// Article ids marked read in any device's on-disk shard. The read registers
    /// are keyed by article id, so this catches a peer's read even before the
    /// article itself has synced into this device's baseline.
    private func readArticleIDsAcrossShards() async -> Set<Article.ID> {
        guard let storage else { return [] }
        let shards = await Task.detached(priority: .userInitiated) {
            (try? storage.loadShards()) ?? []
        }.value
        var ids: Set<Article.ID> = []
        for shard in shards {
            for (id, state) in shard.articleState where state.isRead?.value == true {
                ids.insert(id)
            }
        }
        return ids
    }

    /// Parses an OPML file into feed candidates for the import preview. Returns
    /// an empty array (and sets `errorMessage`) on failure.
    public func parseOPML(at fileURL: URL) -> [OPMLFeed] {
        guard isStorageConfigured else {
            errorMessage = ReaderStorageError.noDirectorySelected.localizedDescription
            return []
        }

        let isAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let candidates = try opmlService.importFeeds(from: fileURL)
            errorMessage = nil
            return candidates
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// Fetches and merges only the feeds the user chose in the import preview,
    /// deduplicating against existing feeds (their read/starred state is kept).
    public func importFeeds(_ opmlFeeds: [OPMLFeed]) {
        guard isStorageConfigured, !opmlFeeds.isEmpty else { return }

        Task {
            await importSelectedFeeds(opmlFeeds)
        }
    }

    public func handleOPMLExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            errorMessage = nil
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    public func refreshAll() {
        guard !feeds.isEmpty else { return }
        startAllFeedsRefresh()
    }

    /// The in-flight full refresh, held so a higher-priority action (adding a
    /// feed) can cancel it and re-run it afterward.
    private var allFeedsRefreshTask: Task<Void, Never>?

    /// Feed items seen without a real publish date; a background pass tries to
    /// recover the real date from each article's page (see `resolveMissingDates`).
    private var datelessArticleIDs: Set<Article.ID> = []
    private var dateResolutionTask: Task<Void, Never>?
    private static let maxConcurrentDateResolutions = 4
    /// `UserDefaults` key for the "recover missing article dates" preference.
    public static let resolveMissingDatesKey = "resolveMissingArticleDates"

    private var resolvesMissingDates: Bool {
        UserDefaults.standard.object(forKey: Self.resolveMissingDatesKey) as? Bool ?? true
    }

    // MARK: - Reader-mode content (experimental)

    /// `UserDefaults` key for the "show reader-mode content by default"
    /// experiment. Shared so both platforms read the same flag. Defaults on.
    public static let readerContentByDefaultKey = "readerContentByDefault"

    /// `UserDefaults` key for the opt-in "press-and-hold the article body to open
    /// the in-app browser" gesture (iOS). Defaults off.
    public static let longPressOpensBrowserKey = "longPressOpensBrowser"

    /// `UserDefaults` key for the opt-in "translate on-screen article-list titles
    /// into my language" experiment (iOS). Defaults off.
    public static let translateListTitlesKey = "translateListTitles"

    /// `UserDefaults` key recording that the one-time "turn on title translation"
    /// promo has been shown, so it never appears again. Per-app (not synced), so
    /// each platform shows it independently. Defaults false.
    public static let translateTitlesPromoSeenKey = "translateTitlesPromoSeen"

    /// `UserDefaults` key for the experimental "coherent long-article translation"
    /// mode: the native reader keeps one prior translated paragraph as rolling
    /// context so blocks read together. Falls back to per-block translation on any
    /// trouble. Defaults off.
    public static let coherentArticleTranslationKey = "coherentArticleTranslation"

    /// `UserDefaults` key recording that the one-time filters tutorial has been
    /// shown (the first time the user opens Filters settings). Per-app, not synced
    /// — seeing the guide is per-install UI state. Defaults false.
    public static let filterGuideSeenKey = "filterGuideSeen"

    /// `UserDefaults` key for how long saved-offline articles are kept before
    /// auto-removal (an `OfflineExpiry` raw value). Device-local. Defaults to two
    /// weeks.
    public static let offlineExpiryKey = "offlineExpiry"

    /// The configured offline auto-expiry (defaults to two weeks).
    public var offlineExpiry: OfflineExpiry {
        (UserDefaults.standard.string(forKey: Self.offlineExpiryKey)).flatMap(OfflineExpiry.init(rawValue:)) ?? .twoWeeks
    }

    /// `UserDefaults` key for whether AI-based categorization is enabled (opt-in,
    /// default off). Keyword rules apply regardless; only AI classification is
    /// gated by this.
    public static let aiCategorizationEnabledKey = "aiCategorizationEnabled"

    /// Whether AI categorization is on AND its provider is actually usable
    /// (on-device model available, or a Gemini key stored).
    public var isAICategorizationActive: Bool {
        UserDefaults.standard.bool(forKey: Self.aiCategorizationEnabledKey)
            && NaturalTranslator.isAvailable(for: TranslationSettings.categoryProvider())
    }

    /// How many currently-loaded articles a single filter would hide, for the live
    /// feedback shown next to it in settings. Computed off the main actor so a big
    /// library doesn't hitch typing; returns 0 for a disabled/empty/invalid filter.
    public func matchCount(for filter: ArticleFilter) async -> Int {
        guard filter.enabled, !filter.pattern.isEmpty else { return 0 }
        let snapshot = articles
        return await Task.detached(priority: .utility) {
            let regex: NSRegularExpression?
            if filter.kind == .regex {
                let options: NSRegularExpression.Options = filter.caseSensitive ? [] : [.caseInsensitive]
                guard let compiled = try? NSRegularExpression(pattern: filter.pattern, options: options) else { return 0 }
                regex = compiled
            } else {
                regex = nil
            }
            return snapshot.reduce(into: 0) { count, article in
                let text = filter.candidateText(title: article.title, summary: article.summary)
                if ReaderStore.filterMatches(filter, regex: regex, in: text) { count += 1 }
            }
        }.value
    }

    /// Whether the native reader should show reader-mode-extracted content
    /// instead of the raw feed body by default.
    public var usesReaderContentByDefault: Bool {
        UserDefaults.standard.object(forKey: Self.readerContentByDefaultKey) as? Bool ?? true
    }

    /// The current reader-mode extraction state for an article (nil = not started).
    public func readerContentState(for article: Article) -> ReaderContentState? {
        readerContentStates[article.id]
    }

    /// Which parser produced the body the reader is showing for this article, or
    /// nil when nothing has been extracted yet.
    ///
    /// Not the same as `ReaderParserEngine.preferred`: an article extracted before
    /// the preference changed keeps its body, and an explicit in-reader switch
    /// changes this for one article without touching the preference.
    public func readerContentEngine(for article: Article) -> ReaderParserEngine? {
        readerContentEngines[article.id]
    }

    /// The parser this article is being read with: whatever actually produced the
    /// body on screen, else an in-reader override, else the preference.
    ///
    /// The first term matters. A body already extracted is served whichever parser
    /// produced it (see `ReaderContentValue.isCurrent(for:)`), so on an article read
    /// before the preference changed, the honest answer is the old engine — and a
    /// parser menu that check-marked the preference instead would be telling the
    /// reader something they can see is untrue.
    public func displayedReaderParser(for article: Article) -> ReaderParserEngine {
        readerContentEngines[article.id] ?? readerParserOverrides[article.id] ?? preferredParser
    }

    /// The parser the in-app browser should render with.
    ///
    /// Deliberately does **not** consult `readerContentEngines`. That value is the
    /// provenance of the *native* body and changes asynchronously — when a
    /// background extraction lands, or when a peer's Readability body arrives over
    /// sync. Reading it here meant an extraction the reader never asked for could
    /// re-render the page they were in the middle of and scroll it to the top.
    public func browserParser(for article: Article) -> ReaderParserEngine {
        readerParserOverrides[article.id] ?? preferredParser
    }

    /// Whether an in-place re-parse is in flight for this article, so the reader can
    /// say so while keeping the current body on screen.
    public func isReparsing(_ article: Article) -> Bool {
        reparsingArticles[article.id] != nil
    }

    /// What the reader is waiting for, or nil when it is not waiting.
    public func reparse(for article: Article) -> ReaderReparse? {
        reparsingArticles[article.id]
    }

    /// Embeds the parser on screen dropped, if any — the one visible difference
    /// between the two engines, which is otherwise silent.
    public func droppedEmbedCount(for article: Article) -> Int {
        guard displayedReaderParser(for: article) == .legibility else { return 0 }
        return readerDroppedEmbeds[article.id] ?? 0
    }

    /// `UserDefaults` key for showing the page's comment thread under the article.
    /// Per-device and defaults on: the discussion comes out of a page the reader has
    /// already fetched, so showing it costs nothing beyond the drawing.
    public static let showReaderCommentsKey = "showReaderComments"

    /// Observable, so switching the setting redraws a reader that is already open.
    public private(set) var showsComments =
        UserDefaults.standard.object(forKey: ReaderStore.showReaderCommentsKey) as? Bool ?? true

    /// The discussion to draw under an article, or nil when there is none to draw.
    ///
    /// Only legibility extracts comments, but the thread belongs to the *page* rather
    /// than to a parser, so one already extracted stays available whichever body is on
    /// screen. Reading Readability's article and the page's replies together is not a
    /// contradiction.
    public func readerComments(for article: Article) -> ReaderCommentThread? {
        guard showsComments else { return nil }
        guard let thread = readerCommentThreads[article.id], !thread.isEmpty else { return nil }
        return thread
    }

    /// Chooses the parser for one article *without* redoing the native reader's body.
    ///
    /// What the in-app browser's switch calls. The browser keeps its own copy of the
    /// page and re-renders from it, so the switch is free there; running the native
    /// reader's full re-extraction as a side effect would download the article again
    /// and throw away the body waiting behind the sheet.
    public func setBrowserParser(_ engine: ReaderParserEngine, for article: Article) {
        guard browserParser(for: article) != engine else { return }
        readerParserOverrides[article.id] = engine
    }

    /// Reads this one article with `engine`, in place, without leaving the reader.
    ///
    /// Both surfaces follow it: the in-app browser re-renders from its stashed copy
    /// of the page with no second download, and the native reader serves this
    /// session's copy instantly if the engine has already run on this article, or
    /// re-extracts if it has not. A no-op when that parser is already what is being
    /// read, so tapping the checked item does not throw away what is on screen.
    public func setReaderParser(_ engine: ReaderParserEngine, for article: Article) {
        guard displayedReaderParser(for: article) != engine else { return }
        readerParserOverrides[article.id] = engine

        // The native reader has no extracted body to redo — the reader-content
        // setting is off, or this article was never opened there. The override still
        // stands, so the browser picks it up and the reader will use it if it ever
        // does extract.
        guard readerContentStates[article.id] != nil else { return }

        if let cached = readerContentByEngine[article.id]?[engine], !cached.isEmpty {
            // Stop whatever switch this one supersedes. Without this, switching away
            // and straight back left the earlier extraction running: its chip stayed
            // up and its result landed on top of the body just restored.
            readerContentTasks[article.id]?.cancel()
            readerContentTasks[article.id] = nil
            readerContentGenerations[article.id] = nil
            reparsingArticles[article.id] = nil
            noteReaderContentByEngine(cached, engine: engine, for: article.id)
            readerContentEngines[article.id] = engine
            readerContentStates[article.id] = .ready(cached)
            return
        }

        // Keep the article on screen while the new body is fetched. Dropping to
        // `.loading` would blank it and lose the reader's place; the parser menu's
        // check-mark moves immediately (the override drives it once the provenance is
        // cleared), and the reader shows a "re-reading" chip.
        if case .ready = readerContentStates[article.id] {
            reparsingArticles[article.id] = .parser(engine)
        } else {
            readerContentStates[article.id] = .loading
        }
        readerContentEngines[article.id] = nil
        startReaderContentTask(for: article) {
            // `immediate`: the reader is already on screen and the person just
            // asked for this, so the transition-protecting delay would only read
            // as lag.
            await self.loadReaderContent(
                for: article, forceRefresh: true, engine: engine, immediate: true,
                // The synced cache holds one body per article. If it happens to be
                // this engine's, use it: re-loading the page to re-derive a body
                // already in the sync folder is the one case where "force refresh"
                // costs a download and buys nothing.
                acceptCacheFrom: engine)
        }
    }

    /// Puts back what was on screen when a re-parse comes up empty.
    ///
    /// A switch that finds nothing should read as "that parser can't read this one",
    /// not as the article disappearing — so the surviving body keeps its place and
    /// the check-mark returns to whichever engine produced it.
    private func abandonReparse(for article: Article) -> Bool {
        guard reparsingArticles.removeValue(forKey: article.id) != nil else { return false }
        guard case .ready(let previous)? = readerContentStates[article.id],
              !previous.isEmpty
        else { return false }
        readerContentEngines[article.id] = readerContentByEngine[article.id]?
            .first(where: { $0.value == previous })?.key
        readerParserOverrides[article.id] = nil
        return true
    }

    /// Records a body against the engine that produced it, evicting the oldest
    /// article once the session cache is full.
    private func noteReaderContentByEngine(
        _ html: String, engine: ReaderParserEngine, for id: Article.ID
    ) {
        if readerContentByEngine[id] == nil {
            readerContentByEngineOrder.removeAll { $0 == id }
            readerContentByEngineOrder.append(id)
            while readerContentByEngineOrder.count > Self.maxReaderContentByEngine {
                let oldest = readerContentByEngineOrder.removeFirst()
                readerContentByEngine[oldest] = nil
            }
        }
        readerContentByEngine[id, default: [:]][engine] = html
    }

    /// Kicks off reader-mode extraction for an article when the experiment is on
    /// and we haven't already started (or finished) it this session. Idempotent.
    public func ensureReaderContent(for article: Article) {
        guard readerContentStates[article.id] == nil else { return }
        // Saved offline → serve the stored copy (no network) so it opens even
        // with no connection, regardless of the reader-content-by-default
        // toggle. The disk read, block parse, and styled-text warm all happen
        // off the transition frames now (mirroring the extraction path below);
        // the synchronous `.loading` write keeps this idempotent.
        if OfflineArticleStore.shared.isSaved(article.id) {
            readerContentStates[article.id] = .loading
            startReaderContentTask(for: article) {
                await self.loadOfflineReaderContent(for: article)
            }
            return
        }
        guard usesReaderContentByDefault else { return }
        readerContentStates[article.id] = .loading
        let engine = readerParserOverrides[article.id] ?? .preferred
        startReaderContentTask(for: article) {
            await self.loadReaderContent(for: article, forceRefresh: false, engine: engine)
        }
    }

    /// Re-extracts and re-saves an offline copy whose Nook post has been edited.
    ///
    /// Nil whenever the copy on disk is the one to show: not a Nook post, unchanged
    /// since it was saved, or changed but not re-extractable right now. That last
    /// case is why this returns the new content instead of clearing the old: the
    /// reader may be offline, and a saved article that opens empty would be a worse
    /// outcome than one showing the previous wording.
    private func refreshedOfflineCopy(
        for article: Article
    ) async -> (html: String, engine: ReaderParserEngine)? {
        let saved = OfflineArticleStore.shared.info(for: article.id)
        guard !NookPostOrigin.cachedBodyIsCurrent(saved?.sourceFingerprint, for: article) else {
            return nil
        }
        if readerModeExtractor == nil { readerModeExtractor = ReaderModeExtractor() }
        guard case .success(let extracted)? = await readerModeExtractor?.extract(url: article.url),
            !extracted.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let (html, engine) = (extracted.html, extracted.engine)

        OfflineArticleStore.shared.save(
            id: article.id, title: article.title, url: article.url,
            feedTitle: saved?.feedTitle ?? feed(for: article.feedID)?.displayTitle ?? "",
            html: html, now: Date(),
            sourceFingerprint: NookPostOrigin.fingerprint(of: article))
        return (html, engine)
    }

    /// Serves an offline-saved article like the extraction path serves a cache
    /// hit: read the file off-main, pre-warm the block parse and above-the-fold
    /// styled-text imports, and only then flip to `.ready` — so opening a saved
    /// article carries no parse or importer burst on the push transition.
    private func loadOfflineReaderContent(for article: Article) async {
        #if os(iOS)
        // Let the reader's push transition settle first (mirrors
        // `loadReaderContent`); the loading placeholder is already up.
        try? await Task.sleep(for: .milliseconds(350))
        if Task.isCancelled { return }
        #endif
        let html = await OfflineArticleStore.shared.contentAsync(for: article.id)
        if let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A Nook post the author edited: the saved copy is the old text, so show
            // the new one and re-save it. Replaced rather than invalidated — a saved
            // article has to open with no network, so the copy stays until a
            // replacement is actually in hand, and a failed refresh is invisible.
            if let refreshed = await refreshedOfflineCopy(for: article) {
                await warmReaderContent(html: refreshed.html, baseURL: article.url)
                await loadCommentsIfNeeded(for: article)
                note(html: refreshed.html, engine: refreshed.engine, for: article)
                return
            }
            await warmReaderContent(html: html, baseURL: article.url)
            // A downloaded article keeps whatever discussion was stored with it, which
            // is what makes the thread readable with no network.
            await loadCommentsIfNeeded(for: article)
            // A downloaded body carries no record of which parser produced it —
            // `OfflineArticleStore` stores the HTML and nothing about where it came
            // from. So there is nothing to attribute it to, and the parser menu falls
            // back to showing the preference. Choosing the other parser still works:
            // it re-extracts over the network, which is the honest cost of asking a
            // question a saved copy cannot answer.
            readerContentEngines[article.id] = nil
            readerContentStates[article.id] = .ready(html)
            return
        }
        // Empty/missing saved copy: fall back to normal extraction, matching
        // what the old synchronous guard did by falling through.
        if usesReaderContentByDefault {
            await loadReaderContent(for: article, forceRefresh: false)
        } else {
            readerContentStates[article.id] = nil
        }
    }

    // MARK: - Offline caching

    /// Progress of an in-flight "download all" (completed, total), or nil when
    /// idle. Observed so the UI can show a progress indicator.
    public private(set) var offlineDownloadProgress: (completed: Int, total: Int)?
    private var bulkDownloadTask: Task<Void, Never>?
    private var offlineSaveTasks: [Article.ID: Task<Void, Never>] = [:]

    /// Saved-offline articles, newest first (for the management list).
    public func offlineInfos() -> [OfflineArticleInfo] { OfflineArticleStore.shared.infos() }

    /// The Downloaded source's articles, built from the offline store (not the
    /// library) so a saved article survives its feed being deleted or the article
    /// aging out of the baseline. Uses the live library article when present (real
    /// read/starred/feed), else a lightweight stand-in from the saved metadata so
    /// it still lists, opens (served from the offline copy), and can be removed.
    private func offlineDisplayArticles(query: String, filteredIDs: Set<Article.ID>) -> [Article] {
        let byID = Dictionary(articles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return OfflineArticleStore.shared.infos().compactMap { info in
            if filteredIDs.contains(info.id) { return nil }
            let article = byID[info.id] ?? Article(
                id: info.id, feedID: "", title: info.title, summary: "", bodyParagraphs: [],
                publishedAt: info.savedAt, url: info.url, estimatedReadMinutes: 0,
                isRead: true, isStarred: false
            )
            if !query.isEmpty {
                let haystack = "\(article.title) \(article.summary) \(info.feedTitle)"
                guard haystack.localizedStandardContains(query) else { return nil }
            }
            return article
        }
    }
    /// Total bytes of saved offline content (for the storage readout).
    public var offlineTotalBytes: Int { OfflineArticleStore.shared.totalBytes }

    /// Saves one article for offline reading (extract if needed; always stores
    /// something readable). Fire-and-forget from the UI.
    public func saveOffline(_ article: Article) {
        guard !isPreparingLocalReset else { return }
        offlineSaveTasks[article.id]?.cancel()
        offlineSaveTasks[article.id] = Task { [weak self] in
            guard let self else { return }
            await self.performSaveOffline(article)
            self.offlineSaveTasks[article.id] = nil
        }
    }

    /// Removes one article's offline copy.
    public func removeOffline(_ id: Article.ID) {
        OfflineArticleStore.shared.remove(id)
        // Don't strand the user on an empty Downloaded source.
        if smartSelection == .offline, feedSelection.isEmpty, !hasOfflineArticles {
            selectSmartSource(.all)
        } else {
            scheduleArticleFilter()
        }
    }

    /// Downloads the articles the user selected in the offline download picker,
    /// extracting them one at a time so a big batch doesn't spawn dozens of
    /// extraction WebViews at once. Skips already-saved articles.
    public func downloadOffline(_ articles: [Article]) {
        let pending = articles.filter { !OfflineArticleStore.shared.isSaved($0.id) }
        guard !pending.isEmpty, offlineDownloadProgress == nil else { return }
        bulkDownloadTask = Task { await performBulkDownload(pending) }
    }

    /// Deletes every saved offline article.
    public func clearOfflineCache() {
        // Stop an in-flight bulk download so it can't re-populate what we clear.
        bulkDownloadTask?.cancel()
        bulkDownloadTask = nil
        offlineDownloadProgress = nil
        OfflineArticleStore.shared.removeAll()
        if smartSelection == .offline, feedSelection.isEmpty {
            selectSmartSource(.all)
        } else {
            scheduleArticleFilter()
        }
    }

    /// Removes offline copies older than the configured expiry. Run at launch.
    public func purgeExpiredOffline() {
        OfflineArticleStore.shared.loadIfNeeded()
        guard let maxAge = offlineExpiry.maxAge else { return }
        OfflineArticleStore.shared.purge(olderThan: maxAge, now: Date())
    }

    private func performSaveOffline(_ article: Article, refreshList: Bool = true) async {
        let html = await offlineHTML(for: article)
        let feedTitle = feed(for: article.feedID)?.displayTitle ?? ""
        OfflineArticleStore.shared.save(
            id: article.id, title: article.title, url: article.url,
            feedTitle: feedTitle, html: html, now: Date(),
            sourceFingerprint: NookPostOrigin.fingerprint(of: article)
        )
        if refreshList { scheduleArticleFilter() }
    }

    private func performBulkDownload(_ articles: [Article]) async {
        let total = articles.count
        offlineDownloadProgress = (0, total)
        // Extract one at a time: each extraction spins an offscreen WKWebView, so
        // going serial keeps a big batch from spawning dozens at once (memory) and
        // from hammering the network. Progress updates after each.
        for (offset, article) in articles.enumerated() {
            if Task.isCancelled { break }
            await performSaveOffline(article, refreshList: false)
            offlineDownloadProgress = (offset + 1, total)
        }
        offlineDownloadProgress = nil
        scheduleArticleFilter()
    }

    /// The HTML to store for offline: a synced/cached extraction if present, else
    /// a fresh extraction, else the feed body wrapped as HTML — so a saved article
    /// always has something readable, even for a summary-only feed we couldn't
    /// extract.
    private func offlineHTML(for article: Article) async -> String {
        if readerContentStore == nil, let storage {
            readerContentStore = ReaderContentStore(storage: storage, deviceID: deviceID)
        }
        if let cached = await readerContentStore?.value(for: article.id),
           cached.status == .success, let html = cached.html,
           !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return html
        }
        if readerModeExtractor == nil { readerModeExtractor = ReaderModeExtractor() }
        if case .success(let extracted)? = await readerModeExtractor?.extract(url: article.url),
           !extracted.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A fallback body is not filed as the chosen parser's work; see
            // `loadReaderContent`. The download itself still keeps it.
            if !extracted.fellBack {
                await readerContentStore?.record(
                    ReaderContentValue(
                        status: .success, html: extracted.html,
                        sourceFingerprint: NookPostOrigin.fingerprint(of: article),
                        engine: extracted.engine),
                    for: article.id)
            }
            return extracted.html
        }
        return Self.feedBodyHTML(for: article)
    }

    /// A last-resort offline body from the already-local feed content, so even an
    /// unextractable article is readable offline.
    private static func feedBodyHTML(for article: Article) -> String {
        if let html = article.contentHTML, !html.isEmpty { return html }
        let paragraphs = article.bodyParagraphs.filter { !$0.isEmpty }
        if !paragraphs.isEmpty { return paragraphs.map { "<p>\($0)</p>" }.joined() }
        return "<p>\(article.summary)</p>"
    }

    /// Fetches the article page again and parses it again, whether or not a body is
    /// already in hand.
    ///
    /// Two callers, one behaviour: "Try Again" on the failure notice, where there is
    /// nothing on screen to keep, and Refresh in the reader, where there is. The
    /// difference is only what the reader sees while it waits — a placeholder in the
    /// first case, the article they were reading in the second.
    ///
    /// Keeps whichever parser is showing. Refresh means the page may have changed;
    /// silently changing the parser as well would make it indistinguishable from the
    /// separate "read this with the other parser" action.
    public func refreshReaderContent(for article: Article) {
        guard !isReparsing(article) else { return }
        let engine = displayedReaderParser(for: article)

        if case .ready = readerContentStates[article.id] {
            // The body stays up while the new one is fetched — the header and the
            // article share one scroll view, so a placeholder would collapse the
            // content height and lose the reader's place in a piece they are part-way
            // through.
            reparsingArticles[article.id] = .refresh
        } else {
            readerContentStates[article.id] = .loading
        }

        // Every body this session holds for this article is from the old page. Keeping
        // them would let a parser switch after a refresh serve a pre-refresh body from
        // the session cache, which is the one thing a refresh was asked to rule out.
        readerContentByEngine[article.id] = nil
        readerContentByEngineOrder.removeAll { $0 == article.id }
        readerParsersTried[article.id] = nil
        // The discussion is re-extracted with the body, so this device's stored copy is
        // about to be replaced. Looking it up again in the meantime would restore the
        // old thread over the new one.
        readerCommentsLoaded.insert(article.id)

        startReaderContentTask(for: article) {
            await self.loadReaderContent(
                for: article, forceRefresh: true, engine: engine, immediate: true,
                reloadFromOrigin: true)
        }
    }

    /// The failure notice's "Try Again", which is a refresh with nothing on screen to
    /// preserve.
    public func retryReaderContent(for article: Article) {
        refreshReaderContent(for: article)
    }

    private func startReaderContentTask(
        for article: Article,
        operation: @escaping @MainActor () async -> Void
    ) {
        guard !isPreparingLocalReset else { return }
        readerContentTasks[article.id]?.cancel()
        // Stamped, and only cleared by the task that is still the current one. An
        // extraction cannot be interrupted once it is in flight, so a superseded task
        // finishes late — and clearing the slot unconditionally handed away the
        // *successor's* cancellation handle, which meant a third parser switch had
        // nothing to cancel the second with.
        readerContentGeneration &+= 1
        let generation = readerContentGeneration
        readerContentGenerations[article.id] = generation
        readerContentTasks[article.id] = Task { [weak self] in
            await operation()
            guard let self, readerContentGenerations[article.id] == generation else { return }
            readerContentTasks[article.id] = nil
            readerContentGenerations[article.id] = nil
        }
    }

    private var readerContentGeneration = 0
    private var readerContentGenerations: [Article.ID: Int] = [:]

    private func loadReaderContent(
        for article: Article,
        forceRefresh: Bool,
        engine: ReaderParserEngine = .preferred,
        immediate: Bool = false,
        acceptCacheFrom: ReaderParserEngine? = nil,
        reloadFromOrigin: Bool = false
    ) async {
        if readerContentStore == nil, let storage {
            readerContentStore = ReaderContentStore(storage: storage, deviceID: deviceID)
        }

        // Let the reader's open/push transition finish before doing any heavy
        // main-thread work — the styled-text import (cache path) and the
        // extractor's offscreen WKWebView (miss path) both stall the slide-in if
        // run on the transition frame. The loading placeholder is already showing,
        // so this is invisible.
        //
        // Skipped for an in-reader parser switch: the reader has been up for a
        // while, nothing is transitioning, and a third of a second of nothing after
        // a deliberate tap reads as lag.
        if !immediate {
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
        }

        readerParsersTried[article.id, default: []].insert(engine)

        // Serve a synced/cached result first (from this device or a peer), so a
        // page already extracted anywhere isn't re-fetched.
        // A cached failure from an older extractor — or from the other parser, which
        // may simply not read this kind of page — is ignored, so improving
        // extraction reaches articles that already failed. Without this the fix
        // for short posts would never have been seen: the failure was cached and
        // synced, and a cache hit never re-extracts.
        // A Nook post the author edited is the one case where a cached body is the
        // wrong body. Its fingerprint no longer matches what the feed serves, so the
        // extraction is redone; every other source keeps exactly what it fetched.
        if Task.isCancelled { return }

        if let cached = await readerContentStore?.value(for: article.id),
            !forceRefresh
                || (cached.status == .success && cached.recordedEngine == acceptCacheFrom),
            cached.isCurrent(for: engine) || alreadyTriedBothParsers(article.id),
            NookPostOrigin.cachedBodyIsCurrent(cached.sourceFingerprint, for: article)
        {
            if cached.status == .success, let html = cached.html, !html.isEmpty {
                await warmReaderContent(html: html, baseURL: article.url)
                await loadCommentsIfNeeded(for: article)
                note(html: html, engine: cached.recordedEngine, for: article)
                // Cached content can outlive the source page. Check the original's
                // status in the background (non-blocking) and offer deletion if it
                // now returns 404/410 — a fresh extraction would catch this, but a
                // cache hit never re-fetches.
                revalidateCachedOriginal(article: article)
            } else if !abandonReparse(for: article) {
                readerContentStates[article.id] = .failed
                readerContentEngines[article.id] = cached.recordedEngine
            }
            return
        }

        // Check the original's status up front. WKWebView can be served a cached
        // 200 for a page that's really gone (so extraction "succeeds" on the error
        // page and Try Again would show it as content) — an explicit HEAD 404/410
        // is authoritative, so treat it as gone without extracting.
        if await originalIsGone(url: article.url, ignoringCache: reloadFromOrigin) {
            if Task.isCancelled { return }
            reparsingArticles[article.id] = nil
            readerContentStates[article.id] = .gone
            readerContentEngines[article.id] = engine
            await recordReaderFailureUnlessBodyCached(
                engine: engine, fingerprint: NookPostOrigin.fingerprint(of: article),
                for: article.id)
            return
        }

        if readerModeExtractor == nil { readerModeExtractor = ReaderModeExtractor() }
        let outcome = await readerModeExtractor?.extract(
            url: article.url, engine: engine, reloadFromOrigin: reloadFromOrigin) ?? .timedOut
        // Cancellation does not stop an extraction that is already in flight, so a
        // superseded load returns here with a real answer. Publishing it would let the
        // parser the reader switched away from overwrite the one they switched to.
        if Task.isCancelled { return }
        let fingerprint = NookPostOrigin.fingerprint(of: article)
        switch outcome {
        case .success(let extracted) where !extracted.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            // Parse into native blocks AND import their styled text into the caches
            // BEFORE flipping to .ready, so the reader renders fully styled from a
            // warm cache on the first frame — no parse or importer burst on the
            // transition frame, and no placeholder→styled reflow.
            await warmReaderContent(html: extracted.html, baseURL: article.url)
            // Written only for the parser that drops them. Readability keeps embeds and
            // always reports zero, and letting that zero overwrite the count meant the
            // notice never came back when the reader switched to legibility again.
            if extracted.engine == .legibility {
                readerDroppedEmbeds[article.id] = extracted.droppedEmbeds
            }
            noteComments(extracted.comments, engine: extracted.engine, for: article.id)
            if let thread = extracted.comments {
                await warmComments(thread, baseURL: article.url)
            }
            note(html: extracted.html, engine: extracted.engine, for: article)
            // A fallback body is not written to the synced cache. The parser the
            // reader chose could not run *this time*; recording Readability's answer
            // as a success would pin the article to it on every device for good,
            // because a cached success is never reconsidered.
            guard !extracted.fellBack else { return }
            await readerContentStore?.record(
                ReaderContentValue(
                    status: .success, html: extracted.html,
                    sourceFingerprint: fingerprint,
                    engine: extracted.engine),
                for: article.id)
        case .gone:
            // The original is gone (404/410); the reader will offer to delete it. The
            // cached body is deliberately left alone — it is the only copy of an
            // article that no longer exists anywhere, and `revalidateCachedOriginal`
            // has always shown `.gone` over a kept body rather than replacing it.
            reparsingArticles[article.id] = nil
            readerContentStates[article.id] = .gone
            readerContentEngines[article.id] = engine
            await recordReaderFailureUnlessBodyCached(
                engine: engine, fingerprint: fingerprint, for: article.id)
        case .timedOut:
            // Nook ran out of time. Not recorded: a cached failure is synced and then
            // believed on every device, and a slow network is not a fact about the
            // page. The reader offers Try Again, and a later open re-extracts.
            if abandonReparse(for: article) { return }
            readerContentStates[article.id] = .failed
            readerContentEngines[article.id] = engine
        default:
            // Recorded before the body is put back, and whether or not it is: this
            // parser looked at this page and found nothing, and that is worth knowing
            // so the next attempt does not download it again to learn the same thing.
            await recordReaderFailureUnlessBodyCached(
                engine: engine, fingerprint: fingerprint, for: article.id)
            if abandonReparse(for: article) { return }
            readerContentStates[article.id] = .failed
            readerContentEngines[article.id] = engine
        }
    }

    /// Records that `engine` found no article, keeping whatever verdict the shard
    /// already held so a page neither parser can read converges instead of two
    /// devices overwriting each other forever.
    private func recordReaderFailureUnlessBodyCached(
        engine: ReaderParserEngine, fingerprint: String?, for id: Article.ID
    ) async {
        let previous = await readerContentStore?.value(for: id)
        // A body already extracted is worth more than a verdict about the parser that
        // just came up empty — most of all when the page has gone, where the cached
        // copy is the only one left anywhere.
        guard previous?.status != .success || previous?.html?.isEmpty != false else { return }
        await readerContentStore?.record(
            ReaderContentValue.failure(
                engine: engine, previous: previous, sourceFingerprint: fingerprint),
            for: id)
    }

    /// Records a freshly-extracted discussion, and files it on this device.
    ///
    /// Only a legibility read says anything about the comments: it either found a
    /// thread, or looked and there was none — and "none" has to clear the stored copy,
    /// or a discussion deleted at the source would be drawn forever. Readability
    /// reports nothing because it never looks, which is not the same claim, so it
    /// leaves the page's thread exactly where it was.
    private func noteComments(
        _ thread: ReaderCommentThread?, engine: ReaderParserEngine, for id: Article.ID
    ) {
        guard engine == .legibility else { return }
        readerCommentsLoaded.insert(id)
        if let thread, !thread.isEmpty {
            readerCommentThreads[id] = thread
            persistComments(thread, for: id)
        } else {
            readerCommentThreads[id] = nil
            forgetComments(for: id)
        }
    }

    private func persistComments(_ thread: ReaderCommentThread, for id: Article.ID) {
        guard let replicaStore else { return }
        // Off-main: encoding a long thread and writing it to SQLite has no business on
        // the frame that is about to draw the article.
        Task.detached(priority: .utility) {
            guard let payload = try? JSONEncoder().encode(thread) else { return }
            try? replicaStore.saveComments(payload, for: id)
        }
    }

    private func forgetComments(for id: Article.ID) {
        guard let replicaStore else { return }
        Task.detached(priority: .utility) { try? replicaStore.deleteComments(for: id) }
    }

    /// Reads this device's stored discussion for an article, once per session.
    ///
    /// The path that matters is a body served from cache — this device's or a peer's —
    /// where no extraction ran and the thread would otherwise be missing from an
    /// article that plainly has one.
    /// Takes the article rather than its id so the base URL is always in hand. It was
    /// an id, and the warm below had nothing to pass — so it passed nil, the block
    /// cache is keyed on `(html, baseURL)`, and every warmed entry landed under a key
    /// no row would ever ask for. The warm was dead on the path that needs it most,
    /// and all thirty comment bodies parsed on the main actor as they mounted.
    private func loadCommentsIfNeeded(for article: Article) async {
        let id = article.id
        guard showsComments, !readerCommentsLoaded.contains(id) else { return }
        // Only once the store exists. Marking the article looked-at before that would
        // make an open during launch — before storage has been restored — the one open
        // that permanently has no comments.
        guard let replicaStore else { return }
        readerCommentsLoaded.insert(id)
        let thread = await Task.detached(priority: .userInitiated) { () -> ReaderCommentThread? in
            guard let payload = try? replicaStore.comments(for: id) else { return nil }
            return try? JSONDecoder().decode(ReaderCommentThread.self, from: payload)
        }.value
        guard let thread, !thread.isEmpty else { return }
        readerCommentThreads[id] = thread
        await warmComments(thread, baseURL: article.url)
    }

    /// Warms the styled text of the comment bodies the reader is about to draw.
    ///
    /// Not the block parse. That was the first thing this did and it measured as dead
    /// work — 5.2ms spent, 0ms saved, with the right cache key as much as the wrong
    /// one — because a comment body is a few hundred bytes and parsing it was never
    /// the cost. The cost is the one the article has: the main-actor styled-text
    /// import each body runs after it mounts, which also changes its height. Warming
    /// that is what the rows need.
    private func warmComments(_ thread: ReaderCommentThread, baseURL: URL) async {
        for comment in thread.items.prefix(ReaderCommentsSection.firstPage) {
            guard let html = comment.renderableHTML else { continue }
            if Task.isCancelled { return }
            await HTMLContentText.warmReaderAttributedCache(
                html: html, baseURL: baseURL, typography: .current(), maxBlocks: nil)
        }
    }

    /// Publishes a freshly-resolved body: flips the reader to `.ready`, records
    /// which parser produced it, and keeps it for an instant switch back.
    private func note(html: String, engine: ReaderParserEngine, for article: Article) {
        noteReaderContentByEngine(html, engine: engine, for: article.id)
        reparsingArticles[article.id] = nil
        readerContentEngines[article.id] = engine
        readerContentStates[article.id] = .ready(html)
    }

    /// Whether both parsers have already had a go at this article this session.
    ///
    /// Once they have, a cached failure is the answer however it is stamped —
    /// re-loading the page again would find the same nothing.
    private func alreadyTriedBothParsers(_ id: Article.ID) -> Bool {
        (readerParsersTried[id]?.count ?? 0) >= ReaderParserEngine.allCases.count
    }

    /// Background HEAD check of a cached article's original URL. If the source now
    /// returns 404/410 the page is gone, so flip to `.gone` (offering deletion)
    /// while leaving the cached content up until then. Only ever downgrades from
    /// `.ready`.
    private func revalidateCachedOriginal(article: Article) {
        let id = article.id
        let url = article.url
        Task { [weak self] in
            guard let gone = await self?.originalIsGone(url: url), gone, let self else { return }
            if case .ready = self.readerContentStates[id] {
                self.readerContentStates[id] = .gone
            }
        }
    }

    /// Whether the article's original URL explicitly reports gone (404/410) via a
    /// lightweight HEAD request. Conservative: any other status, a rejected HEAD,
    /// or a transient error returns false, so a live page is never flagged.
    private func originalIsGone(url: URL, ignoringCache: Bool = false) async -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 12
        // A refresh asks the server, not the cache — otherwise this check can answer
        // from a stored response for a page whose status has since changed, in either
        // direction.
        if ignoringCache { request.cachePolicy = .reloadIgnoringLocalCacheData }
        let status = (try? await URLSession.shared.data(for: request))
            .flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
        return status == 404 || status == 410
    }

    /// Warms both caches the reader reads from before content is shown: the block
    /// parse (off-main) and the styled-text import for the above-the-fold blocks
    /// (main actor, but done here while the loading placeholder shows). By the time
    /// the state flips to `.ready`, the first screenful renders styled on the first
    /// frame — the transition carries no parse and no importer burst.
    private func warmReaderContent(html: String, baseURL: URL?) async {
        await warmReaderBlocks(html: html, baseURL: baseURL)
        // Only the first blocks are warmed before `.ready`, because a very long
        // article must not hold the content back importing all of it: measured on the
        // fourteen longest articles in a real library, warming the whole document up
        // front costs +47 to +160ms before anything appears.
        await HTMLContentText.warmReaderAttributedCache(
            html: html, baseURL: baseURL, typography: .current(), maxBlocks: 14
        )
        // The rest is warmed straight after, and this is the fix for the article
        // moving under the reader as they scroll.
        //
        // A block that has not imported its styled text yet is laid out from a plain
        // placeholder, and the placeholder is not the same height as the real thing.
        // So every block past the fourteenth changed height the moment it scrolled
        // into view: measured across those same fourteen articles, twelve of them
        // moved, 125 blocks in total, 10,650pt of accumulated shift — one block alone
        // was 1,590pt out where WebKit's importer turns an inline chart into a
        // paragraph per axis label. That is what makes scrolling down and back up the
        // way to see it: the heights above the reader settle after they have been
        // passed, and the document they are in has already moved.
        //
        // With the whole document warm, none of the fourteen changes height at all
        // (+0.0pt). It runs after `.ready` rather than before, so the article appears
        // exactly as promptly as it did; `warmReaderAttributedCache` yields between
        // blocks, and switching articles cancels it.
        warmRemainderTask?.cancel()
        warmRemainderTask = Task { @MainActor in
            await HTMLContentText.warmReaderAttributedCache(
                html: html, baseURL: baseURL, typography: .current(), maxBlocks: nil)
        }
    }

    /// The whole-document styled-text warm that follows `.ready`. One at a time:
    /// opening another article makes the previous one's remainder work nobody is
    /// going to look at.
    private var warmRemainderTask: Task<Void, Never>?

    /// Parses reader HTML into native blocks off the main actor and stores them in
    /// the shared block cache, so `HTMLContentView` renders from a synchronous
    /// cache hit instead of parsing on the render/transition frame.
    private func warmReaderBlocks(html: String, baseURL: URL?) async {
        await Task.detached(priority: .userInitiated) {
            if HTMLBlockCache.shared.blocks(html: html, baseURL: baseURL) == nil {
                HTMLBlockCache.shared.store(
                    HTMLContentParser.parseWithAnchors(html, baseURL: baseURL),
                    html: html, baseURL: baseURL
                )
            }
        }.value
    }

    /// Serializes every batched fetch through the single `allFeedsRefreshTask`
    /// slot so no two ever mutate the shared batch state (`isBatchRefreshing`, the
    /// merge-flush task, `refreshingFeedIDs`) at once. A new request cancels the
    /// in-flight batch and waits for it to fully unwind before running `work`, so
    /// batches replace each other (no pile-up) and never overlap (no reentry).
    /// Every batched entry point — Refresh All, activation/periodic sync,
    /// pull-to-refresh, background refresh, and OPML import's content fetch —
    /// starts here. Callers that need to propagate their own cancellation into the
    /// batch (pull-to-refresh, background) wrap the returned task's `.value` in a
    /// `withTaskCancellationHandler` that calls `.cancel()`.
    @discardableResult
    private func startBatchedFetch(_ work: @escaping (ReaderStore) async -> Void) -> Task<Void, Never> {
        let predecessor = allFeedsRefreshTask
        predecessor?.cancel()
        let task = Task { [weak self] in
            // Let the cancelled batch drain its in-flight fetches and run its defer
            // (which clears isBatchRefreshing and flushes the merge buffer) before
            // we enter the critical section, so the two never overlap.
            _ = await predecessor?.value
            guard let self, !Task.isCancelled, !self.isPreparingLocalReset else { return }
            await work(self)
        }
        allFeedsRefreshTask = task
        return task
    }

    /// Starts (or restarts) a full refresh, replacing any in-flight one.
    private func startAllFeedsRefresh() {
        guard !isPreparingLocalReset else { return }
        startBatchedFetch { await $0.refreshAllFeeds() }
    }

    /// Shortest gap between activation-triggered syncs. Prevents rapidly
    /// switching focus back to Nook from refetching every feed on each focus
    /// change; the periodic auto-refresh still keeps content current.
    private static let activationRefreshThrottle: TimeInterval = 300

    private var activationRefreshInFlight = false

    /// Syncs all feeds in response to the app launching or returning to the
    /// foreground. `honorThrottle` skips the sync when the last refresh was very
    /// recent, so refocusing Nook repeatedly doesn't refetch every feed each
    /// time. Launch passes `false` so opening the app always fetches.
    ///
    /// `activationRefreshInFlight` is set synchronously before the async work
    /// starts so the launch sync and the initial `didBecomeActive` (which both
    /// fire at startup) coalesce into a single refresh instead of two.
    public func refreshOnActivation(honorThrottle: Bool) {
        guard !isPreparingLocalReset,
              isStorageConfigured, !feeds.isEmpty, !isRefreshing, !activationRefreshInFlight else { return }

        if honorThrottle, let lastRefreshedAt,
           Date.now.timeIntervalSince(lastRefreshedAt) < Self.activationRefreshThrottle {
            return
        }

        activationRefreshInFlight = true
        // Automatic focus-driven sync: stay quiet and light so returning to Nook
        // doesn't jolt the UI while content trickles in.
        let task = startBatchedFetch { store in
            await store.refreshAllFeeds(mode: .ambient)
            // Re-opening after a long background can hit a network that isn't
            // ready yet, failing some feeds transiently. Retry just those once,
            // quietly, after a short delay — so a long-suspended launch still ends
            // up refreshed without any user action or alert.
            await store.retryFailedFeedsOnce()
        }
        // Clear the coalescing flag once this activation batch settles — whether it
        // ran or was replaced by a later refresh — so activation syncs never wedge.
        Task { [weak self] in
            _ = await task.value
            self?.activationRefreshInFlight = false
        }
    }

    private var isRetryingFailedFeeds = false

    /// One quiet retry of the feeds that failed the last refresh (marked
    /// unhealthy), a few seconds later. Recovers transient post-background
    /// failures; a persistently-broken feed just re-flags itself (no alert).
    private func retryFailedFeedsOnce() async {
        guard !isPreparingLocalReset, !isRetryingFailedFeeds else { return }
        let failed = feeds.filter { $0.healthScore <= 0 }.map(\.id)
        guard !failed.isEmpty else { return }
        isRetryingFailedFeeds = true
        defer { isRetryingFailedFeeds = false }
        try? await Task.sleep(for: .seconds(4))
        guard !Task.isCancelled, !isPreparingLocalReset else { return }
        for feed in failed.compactMap(feed(for:)) {
            if Task.isCancelled { return }
            await refreshFeed(feed)
        }
    }

    func refresh(feedID: Feed.ID) {
        guard !isPreparingLocalReset, feed(for: feedID) != nil else { return }
        feedSelection = [feedID]

        Task {
            // Sync first so the save can't drop a peer-added feed; re-resolve the
            // feed after the merge in case its stored URL changed.
            await reloadMerged()
            if let feed = feed(for: feedID) { await refreshFeed(feed) }
        }
    }

    public func refreshFeeds(ids: [Feed.ID]) {
        guard !isPreparingLocalReset,
              ids.contains(where: { feed(for: $0) != nil }) else { return }
        Task {
            await reloadMerged()
            for feed in ids.compactMap(feed(for:)) {
                await refreshFeed(feed)
            }
        }
    }

    /// Awaitable refresh of all feeds, for pull-to-refresh (the spinner stays
    /// until the fetch actually finishes).
    public func refreshAllAndWait() async {
        guard !feeds.isEmpty else { return }
        let task = startBatchedFetch { await $0.refreshAllFeeds() }
        // Forward this call's cancellation (e.g. the pull-to-refresh view going
        // away) into the serialized batch, so it stops rather than fetching on.
        await withTaskCancellationHandler {
            _ = await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Awaitable refresh of specific feeds, for pull-to-refresh in a single
    /// feed's article list.
    public func refreshFeedsAndWait(ids: [Feed.ID]) async {
        await reloadMerged()
        for feed in ids.compactMap(feed(for:)) {
            await refreshFeed(feed)
        }
    }

    public func markFeedsRead(ids: [Feed.ID]) {
        ids.forEach { markFeedRead(feedID: $0) }
    }

    public func removeFeeds(ids: [Feed.ID]) {
        ids.forEach { removeFeed(feedID: $0) }
    }

    /// Deletes a single article the user no longer wants — used when the original
    /// page is gone (404/410) but the local copy lingers. Records a tombstone in
    /// this device's shard so the deletion syncs and the baseline (which still
    /// carries the article) can't resurrect it at the next merge.
    public func deleteArticle(articleID: Article.ID) {
        guard articles.contains(where: { $0.id == articleID }) else { return }
        if selectedArticleID == articleID { selectedArticleID = nil }
        articles.removeAll { $0.id == articleID }
        readerContentStates[articleID] = nil
        readerContentEngines[articleID] = nil
        readerContentGenerations[articleID] = nil
        reparsingArticles[articleID] = nil
        readerDroppedEmbeds[articleID] = nil
        readerCommentThreads[articleID] = nil
        readerCommentsLoaded.remove(articleID)
        forgetComments(for: articleID)
        readerParserOverrides[articleID] = nil
        readerContentByEngine[articleID] = nil
        readerContentByEngineOrder.removeAll { $0 == articleID }
        readerParsersTried[articleID] = nil
        retainedArticleIDs.remove(articleID)
        recordArticleDeleted(articleID)
        // Guard the refresh merge immediately: the feed most likely still
        // serves this article, and without the local set it would re-insert on
        // the very next refresh (the tombstone only applies at materialize).
        deletedArticleIDs.insert(articleID)
        // Tombstones write through immediately — losing a delete on a kill is
        // worse than losing a read bit.
        scheduleShardSave(urgent: true)
    }

    public func markArticleOpened(articleID: Article.ID) {
        setRead(articleID: articleID, isRead: true)
    }

    /// Keeps an article visible in the current source even once it is read, so
    /// it does not vanish out from under the reader while it is being viewed.
    public func retainArticle(id: Article.ID) {
        guard !retainedArticleIDs.contains(id) else { return }
        retainedArticleIDs.insert(id)
        // Retention only widens visibility: when the article is already in the
        // displayed list the recompute is a guaranteed no-op, so skip the
        // debounced full filter that would otherwise land mid push-animation.
        if !displayedArticles.contains(where: { $0.id == id }) {
            scheduleArticleFilter(debounced: true)
        }
    }

    /// Drops the retained set so the list recomputes fresh; called when the
    /// selected source changes.
    public func clearRetainedArticles() {
        guard !retainedArticleIDs.isEmpty else { return }
        retainedArticleIDs.removeAll()
        scheduleArticleFilter(debounced: true)
    }

    /// Opens an article by ID (used by the widget deep link): makes it visible
    /// and selects it so the reader displays it. The reader then marks it read.
    func openArticle(id: Article.ID) {
        guard articles.contains(where: { $0.id == id }) else { return }
        smartSelection = .all
        feedSelection = []
        searchText = ""
        searchDebounceTask?.cancel()
        activeSearchQuery = ""
        selectedArticleID = id
    }

    public func setRead(articleID: Article.ID, isRead: Bool) {
        guard let index = articles.firstIndex(where: { $0.id == articleID }),
              articles[index].isRead != isRead else { return }

        // Incremental path: one element changes one bit — skip the didSet's
        // O(n) reclassification/count pass (this runs mid push-animation on
        // every article open).
        suppressArticlesDidSet = true
        articles[index].isRead = isRead
        suppressArticlesDidSet = false
        // Counts by O(1) delta, mirroring recomputeCounts (filtered articles
        // never count).
        if !filteredArticleIDs.contains(articleID) {
            bumpUnreadCounts(
                feedID: articles[index].feedID,
                categories: articles[index].categories,
                by: isRead ? -1 : 1
            )
            updateUnreadBadge()
        }
        // Keep the visible row in sync without a full recompute; membership
        // changes (an Unread list dropping a read article, a hidden article
        // resurfacing as unread) still go through the debounced filter unless
        // retention already pins it.
        let isDisplayed = updateDisplayedArticleInPlace(articleID) { $0.isRead = isRead }
        if isDisplayed {
            if isRead && !retainedArticleIDs.contains(articleID) {
                scheduleArticleFilter(debounced: true)
            }
        } else if !isRead {
            scheduleArticleFilter(debounced: true)
        }
        recordRead(articleID, isRead)
        // Read state is user state: it lives in this device's shard and is
        // overlaid on the baseline at materialize, so there's no need to rewrite
        // content shards for a read toggle.
        scheduleShardSave()
    }

    /// O(1) unread-count delta for a single article's read flip, replacing the
    /// full `recomputeCounts` pass. Zero entries are removed so the dictionaries
    /// stay canonical with what a full recompute would build.
    private func bumpUnreadCounts(feedID: Feed.ID, categories: [String], by delta: Int) {
        let feedCount = (unreadByFeed[feedID] ?? 0) + delta
        unreadByFeed[feedID] = feedCount <= 0 ? nil : feedCount
        totalUnread = max(0, totalUnread + delta)
        for categoryID in categories {
            let count = (unreadByCategory[categoryID] ?? 0) + delta
            unreadByCategory[categoryID] = count <= 0 ? nil : count
        }
    }

    /// Mutates the displayed copy of an article in place (rows render from
    /// `displayedArticles`, not `articles`). Returns whether the article is
    /// currently displayed. One property republish; no O(n) refilter.
    @discardableResult
    private func updateDisplayedArticleInPlace(_ id: Article.ID, _ mutate: (inout Article) -> Void) -> Bool {
        guard let index = displayedArticles.firstIndex(where: { $0.id == id }) else { return false }
        mutate(&displayedArticles[index])
        return true
    }

    public func markSelectedRead() {
        guard let selectedArticleID else { return }
        setRead(articleID: selectedArticleID, isRead: true)
    }

    func removeFeed(feedID: Feed.ID) {
        // The managed Saved Links feed cannot be deleted; its articles can.
        guard !Self.isManagedFeed(feedID) else { return }
        // A refresh may have this feed's fetch result buffered; applied after
        // the delete it would resurrect the feed and out-clock the tombstone.
        discardPendingBatchMerges(forFeedID: feedID)
        feeds.removeAll { $0.id == feedID }
        articles.removeAll { $0.feedID == feedID }
        feedIcons[feedID] = nil
        endFeedFetch(feedID)
        feedUpdateTokens[feedID] = nil

        feedSelection.remove(feedID)

        recordFeedDeleted(feedID)
        // Tombstone: write through immediately (see deleteArticle).
        scheduleShardSave(urgent: true)
        pruneSelectionIfHidden()
        saveAfterMutation()
    }

    func markFeedRead(feedID: Feed.ID) {
        // Build the mutated array locally and assign once: per-element writes on
        // the stored property would fire the didSet's O(n) recompute chain once
        // per article in the feed.
        var updated = articles
        var didChange = false
        for index in updated.indices where updated[index].feedID == feedID {
            if !updated[index].isRead {
                updated[index].isRead = true
                recordRead(updated[index].id, true)
                didChange = true
            }
        }

        if didChange {
            articles = updated
            // Per-article read state is shard-backed; no baseline rewrite needed.
            scheduleShardSave()
        }
    }

    public func toggleSelectedStarred() {
        guard let selectedArticleID else { return }
        toggleStarred(articleID: selectedArticleID)
    }

    public func toggleStarred(articleID: Article.ID) {
        guard let article = articles.first(where: { $0.id == articleID }) else { return }
        setStarred(articleID: articleID, isStarred: !article.isStarred)
    }

    public func setStarred(articleID: Article.ID, isStarred: Bool) {
        guard let index = articles.firstIndex(where: { $0.id == articleID }),
              articles[index].isStarred != isStarred else { return }

        // Same incremental path as `setRead`: one bit, O(1) count delta, no
        // whole-library reclassification.
        suppressArticlesDidSet = true
        articles[index].isStarred = isStarred
        suppressArticlesDidSet = false
        if !filteredArticleIDs.contains(articleID) {
            starredCount = max(0, starredCount + (isStarred ? 1 : -1))
        }
        updateDisplayedArticleInPlace(articleID) { $0.isStarred = isStarred }
        // Star toggles can change Starred-source membership; they're rare (never
        // on the article-open hot path), so always let the debounced filter run.
        scheduleArticleFilter(debounced: true)
        recordStarred(articleID, isStarred)
        // Starred state is user state (shard-backed, overlaid at materialize);
        // no baseline rewrite needed.
        scheduleShardSave()
    }

    /// Clears the article selection if it is no longer in the visible list.
    ///
    /// It deliberately does NOT auto-select the first article. Launching the app
    /// (or changing source/filter) should show the list with the reader empty
    /// until the user picks an article — otherwise an article opens on its own
    /// and gets marked read via `markReadOnOpen` every time the app starts.
    public func pruneSelectionIfHidden() {
        guard let selectedArticleID else { return }
        if !visibleArticles.contains(where: { $0.id == selectedArticleID }) {
            self.selectedArticleID = nil
        }
    }

    public func selectNextArticle() {
        moveSelection(offset: 1)
        syncBrowserModeToSelection()
    }

    /// When the in-app browser is open, advancing to another article must
    /// re-resolve the reading mode for the new article's feed; otherwise it keeps
    /// the previous article's mode instead of following the feed/global setting.
    private func syncBrowserModeToSelection() {
        guard isBrowserPresented, let article = selectedArticle else { return }
        browserMode = resolvedBrowserMode(for: article)
    }

    /// The live article for an ID from the full set (not the filtered visible
    /// list), so a reader driven by a captured snapshot can re-resolve fresh
    /// read/starred state even after the article leaves the current scope.
    public func article(withID id: Article.ID) -> Article? {
        articles.first { $0.id == id }
    }

    /// The article at a page URL, searched across every feed rather than the
    /// visible scope. Lets something that knows a URL but not an id — a writer who
    /// has just published — open that exact page in the reader.
    public func article(atPageURL url: URL) -> Article? {
        let key = url.feedIdentityKey
        return articles.first { $0.url.feedIdentityKey == key }
    }

    /// The followed feed at this URL, matched the way `addFeed` matches, so a
    /// trailing slash or a different spelling of the same URL still finds it.
    public func followedFeed(at url: URL) -> Feed? {
        let key = url.feedIdentityKey
        return feeds.first { $0.feedURL.feedIdentityKey == key || $0.siteURL.feedIdentityKey == key }
    }

    /// The article shown right after `id` in the current visible list, or nil if
    /// `id` is the last one. Lets the UI preview what "next" would open.
    public func article(after id: Article.ID) -> Article? {
        let visible = visibleArticles
        guard let index = visible.firstIndex(where: { $0.id == id }), index + 1 < visible.count else {
            return nil
        }
        return visible[index + 1]
    }

    /// The article shown right before `id` in the current visible list, or nil if
    /// `id` is the first one. Lets the native reader preview "previous".
    public func article(before id: Article.ID) -> Article? {
        let visible = visibleArticles
        guard let index = visible.firstIndex(where: { $0.id == id }), index > 0 else {
            return nil
        }
        return visible[index - 1]
    }

    public func selectPreviousArticle() {
        moveSelection(offset: -1)
        syncBrowserModeToSelection()
    }

    public func readBinding(articleID: Article.ID) -> Binding<Bool> {
        Binding {
            self.articles.first { $0.id == articleID }?.isRead ?? false
        } set: { isRead in
            self.setRead(articleID: articleID, isRead: isRead)
        }
    }

    public func starredBinding(articleID: Article.ID) -> Binding<Bool> {
        Binding {
            self.articles.first { $0.id == articleID }?.isStarred ?? false
        } set: { isStarred in
            self.setStarred(articleID: articleID, isStarred: isStarred)
        }
    }

    /// UserDefaults sentinel for the iOS "local library" mode: the library
    /// lives in the app's own Documents container, recorded as a flag rather
    /// than a bookmark because container paths change with every app update
    /// (a bookmark would resolve stale and alert the user for no reason).
    public static let usesLocalLibraryKey = "usesLocalLibrary"

    /// Whether the library currently lives in app-local storage (no sync
    /// folder chosen yet). Drives the "move to iCloud" promotion surfaces.
    public var usesLocalLibrary: Bool {
        UserDefaults.standard.bool(forKey: Self.usesLocalLibraryKey)
    }

    /// The app-local library directory for the local-first mode.
    private nonisolated static func localLibraryURL() -> URL? {
        guard let documents = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let directory = documents.appendingPathComponent("Nook", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// iOS-only first-run path (the iOS app calls this right after bootstrap;
    /// macOS keeps its explicit iCloud-folder product policy): brings a local
    /// library online so nothing — adding sites, reading, starring — is gated
    /// on the folder picker. Guarded so an EXISTING user whose bookmark failed
    /// to resolve never gets an empty local library shadowing their real one:
    /// any prior folder record (display path) disqualifies the fresh-install
    /// path.
    public func configureLocalStorageIfNeeded() async {
        guard storage == nil, let localURL = Self.localLibraryURL() else { return }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.usesLocalLibraryKey) {
            guard defaults.string(forKey: ReaderStorage.displayPathDefaultsKey) == nil else { return }
            defaults.set(true, forKey: Self.usesLocalLibraryKey)
        }
        let storage = ReaderStorage(directoryURL: localURL)
        self.storage = storage
        do {
            try await bringSyncFolderOnline(storage: storage, directoryURL: localURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restoreStorageIfPossible() async {
        do {
            guard let directoryURL = try ReaderStorage.resolveBookmarkedDirectory() else {
                // Returning local-library user (iOS): reconstruct storage from
                // the CURRENT container path — never from a stored bookmark.
                if UserDefaults.standard.bool(forKey: Self.usesLocalLibraryKey),
                   let localURL = Self.localLibraryURL() {
                    let storage = ReaderStorage(directoryURL: localURL)
                    self.storage = storage
                    try await bringSyncFolderOnline(storage: storage, directoryURL: localURL)
                    return
                }
                syncFolderDisplayPath = UserDefaults.standard.string(forKey: ReaderStorage.displayPathDefaultsKey)
                return
            }

            startAccessing(directoryURL)
            let storage = ReaderStorage(directoryURL: directoryURL)
            self.storage = storage
            syncFolderDisplayPath = directoryURL.path(percentEncoded: false)

            try await bringSyncFolderOnline(storage: storage, directoryURL: directoryURL)
        } catch {
            errorMessage = error.localizedDescription
            syncFolderDisplayPath = UserDefaults.standard.string(forKey: ReaderStorage.displayPathDefaultsKey)
        }
    }

    /// Everything heavy required to bring a sync folder online, computed off the
    /// main actor in one hop: own-shard coordinated read, ReplicaStore
    /// construction (SQLite open + pragmas + DDL), reconcile + publish, peer
    /// shard loads, the O(all registers) HLC fold, the CRDT materialize, and the
    /// initial filter classification/counts. The main actor only installs it.
    private struct SyncFolderLoad: Sendable {
        var ownShard: DeviceStateDocument
        var replica: ReplicaStore
        var snapshot: ReplicaSnapshot
        var foldedPeerHLC: HLC
        var merged: ReaderLibrary
        var precomputed: PrecomputedFilterState
        var deletedArticleIDs: Set<Article.ID>
        var hasLegacySeed: Bool
        var libraryModDate: Date?
        var stateModDate: Date?
        var contentModDate: Date?
        var bodiesModDate: Date?
    }

    nonisolated private static func loadSyncFolder(
        storage: ReaderStorage, directoryURL: URL, deviceID: String,
        onPhase: @escaping @Sendable (BootstrapPhase) -> Void = { _ in }
    ) throws -> SyncFolderLoad {
        let own: DeviceStateDocument
        if let fromDisk = storage.loadOwnShard(deviceID: deviceID) {
            own = fromDisk
        } else {
            // First run in this folder: seed and persist the empty shard so
            // peers can see this device (mirrors the old restoreOwnShard).
            own = DeviceStateDocument(deviceID: deviceID)
            try? storage.saveShard(own)
        }
        onPhase(.readingLibrary)
        let replica = try ReplicaStore(syncDirectory: directoryURL, deviceID: deviceID)
        let snapshot = try replica.reconcile(storage: storage)
        try replica.publishIfNeeded(to: storage)
        // The one-time v1→v2 user-state seed is rare; the main actor runs the
        // full legacy path when this flags true.
        let hasLegacySeed = (try? replica.pendingLegacyStateSeed(from: storage)) != nil
        onPhase(.mergingDevices)
        let peers = ((try? storage.loadShards()) ?? []).filter { $0.deviceID != deviceID }
        var folded = HLC.zero
        for shard in peers { folded = folded.witnessed(shard.maxObservedHLC) }
        let merged = DeviceStateDocument.materialize(base: snapshot.library, shards: peers + [own])
        let precomputed = precomputeFilterState(
            articles: merged.articles, filters: merged.filters, categories: merged.categories
        )
        return SyncFolderLoad(
            ownShard: own, replica: replica, snapshot: snapshot, foldedPeerHLC: folded,
            merged: merged, precomputed: precomputed,
            deletedArticleIDs: tombstonedArticleIDs(in: peers + [own]),
            hasLegacySeed: hasLegacySeed,
            libraryModDate: storage.libraryModificationDate,
            stateModDate: storage.stateDirectoryModificationDate,
            contentModDate: storage.contentDirectoryModificationDate,
            bodiesModDate: storage.bodiesDirectoryModificationDate
        )
    }

    /// Shared by launch (`restoreStorageIfPossible`) and folder configuration:
    /// runs `loadSyncFolder` off-main, then installs the results. Falls back to
    /// the fully synchronous legacy sequence when a local mutation raced the
    /// off-main load (pathological — the UI is barely interactive at these
    /// moments) or when the one-time legacy state seed is pending.
    private func bringSyncFolderOnline(storage: ReaderStorage, directoryURL: URL) async throws {
        let deviceID = deviceID
        let generationBefore = ownShard.generation
        bootstrapPhase = .connectingFolder
        defer { bootstrapPhase = nil }
        let load = try await Task.detached(priority: .userInitiated) { [weak self] in
            try Self.loadSyncFolder(storage: storage, directoryURL: directoryURL, deviceID: deviceID) { phase in
                Task { @MainActor in self?.bootstrapPhase = phase }
            }
        }.value

        if load.hasLegacySeed || ownShard.generation != generationBefore {
            // Rare paths keep the old, unconditionally-correct synchronous
            // sequence: the legacy seed mutates the shard mid-merge, and a raced
            // local edit must not be clobbered by the pre-race disk shard.
            restoreOwnShard(storage: storage)
            replicaStore = load.replica
            try migrateLegacyUserStateIfNeeded(replica: load.replica, storage: storage)
            applyReplicaSnapshot(load.snapshot, storage: storage)
        } else {
            ownShard = load.ownShard
            lastHLC = load.ownShard.clock.witnessed(load.foldedPeerHLC)
            ownShard.clock = lastHLC
            replicaStore = load.replica
            deletedArticleIDs = load.deletedArticleIDs
            if load.snapshot.revision >= appliedReplicaRevision {
                if !load.snapshot.bodies.isEmpty { bodyCache.merge(load.snapshot.bodies) { _, new in new } }
                apply(load.merged, precomputed: load.precomputed)
                appliedReplicaRevision = load.snapshot.revision
            }
        }

        errorMessage = nil
        lastKnownLibraryModDate = load.libraryModDate
        lastKnownStateModDate = load.stateModDate
        lastKnownContentModDate = load.contentModDate
        lastKnownBodiesModDate = load.bodiesModDate
        startObservingLibrary()
        // The list is up from the light baseline; pull the (heavier) article
        // bodies in from the sidecar in the background so it never blocks.
        Task { await loadBodyCacheIfNeeded() }
        let readerStore = ReaderContentStore(storage: storage, deviceID: deviceID)
        readerContentStore = readerStore
        Task { await readerStore.reload() }
    }

    private func startAccessing(_ directoryURL: URL) {
        if isAccessingSecurityScopedResource {
            securityScopedDirectoryURL?.stopAccessingSecurityScopedResource()
        }

        securityScopedDirectoryURL = directoryURL
        isAccessingSecurityScopedResource = directoryURL.startAccessingSecurityScopedResource()
    }

    /// Imports OPML feeds in two phases so a large import (issue #3: ~92 feeds)
    /// never stalls the UI and never loses its folders.
    ///
    /// Phase 1 (synchronous, no network): every feed and its folder is added to
    /// the in-memory model in ONE assignment and recorded into this device's shard
    /// right away — the same durable path `moveFeed` uses. So the whole library,
    /// folders included, appears at once, and the folder membership is CRDT state
    /// before any refresh runs. The old path set the folder in memory only, so the
    /// next materialize dropped every folder (the reported bug).
    ///
    /// Phase 2 (bounded concurrency, batched merge): the placeholder feeds' real
    /// titles and articles stream in through the same engine a full refresh uses —
    /// up to `maxConcurrentFetches` at a time, merged once per ~400ms — so the rows
    /// fill in smoothly instead of trickling one blocking fetch at a time. `merge`
    /// preserves the category set in Phase 1, so folders survive the refresh.
    private func importSelectedFeeds(_ opmlFeeds: [OPMLFeed]) async {
        guard !opmlFeeds.isEmpty, !isPreparingLocalReset else { return }

        // ── Phase 1: structure now, no network. ──
        var updatedFeeds = feeds
        var pendingFolders: [String] = []
        var targets: [(id: Feed.ID, url: URL)] = []

        func noteFolder(_ name: String) {
            guard !name.isEmpty, !folders.contains(name), !pendingFolders.contains(name) else { return }
            pendingFolders.append(name)
        }

        for opmlFeed in opmlFeeds {
            var category = (opmlFeed.category ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // "Feeds" is the reserved top-level sentinel (Feed.folderName maps it to
            // ""), so an OPML folder literally named "Feeds" cannot be represented
            // as a folder. Treat it as top-level instead of recording a phantom
            // empty "Feeds" folder row that no feed can appear inside.
            if category == "Feeds" { category = "" }
            let existingIndex = updatedFeeds.firstIndex { existing in
                existing.feedURL.feedIdentityKey == opmlFeed.feedURL.feedIdentityKey
                    || existing.id == opmlFeed.feedURL.absoluteString
                    || (opmlFeed.siteURL.map { existing.siteURL.feedIdentityKey == $0.feedIdentityKey } ?? false)
            }
            if let index = existingIndex {
                // Already present (in the library, or earlier in this same OPML):
                // don't duplicate the row. Adopt the OPML folder only when the feed
                // has none yet, so an import can't yank a feed out of a folder the
                // user already chose.
                let feedID = updatedFeeds[index].id
                if !category.isEmpty, updatedFeeds[index].folderName.isEmpty {
                    updatedFeeds[index].category = category
                    recordCategory(feedID, category)
                    noteFolder(category)
                }
                if !targets.contains(where: { $0.id == feedID }) {
                    targets.append((id: feedID, url: updatedFeeds[index].feedURL))
                }
                continue
            }

            // A brand-new feed: create a placeholder row so it shows immediately.
            // Its id is the feed URL (the app's convention, matching OPMLFeed.id);
            // Phase 2 re-keys the fetched feed onto this id, so article ids stay
            // stable.
            let feedID = opmlFeed.feedURL.absoluteString
            let title = opmlFeed.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let placeholder = Feed(
                id: feedID,
                title: title.isEmpty ? (opmlFeed.siteURL?.host ?? opmlFeed.feedURL.host ?? feedID) : title,
                siteDescription: "",
                category: category.isEmpty ? "Feeds" : category,
                systemImage: "dot.radiowaves.left.and.right",
                feedURL: opmlFeed.feedURL,
                siteURL: opmlFeed.siteURL ?? opmlFeed.feedURL,
                healthScore: 1
            )
            updatedFeeds.append(placeholder)
            // Durable identity + folder, recorded BEFORE any fetch (mirrors both
            // `merge`'s new-feed recording and `moveFeed`'s folder recording), so a
            // materialize racing the import cannot drop either.
            recordFeedRestored(feedID)
            recordFeedSeed(placeholder)
            if !category.isEmpty {
                recordCategory(feedID, category)
                noteFolder(category)
            }
            targets.append((id: feedID, url: opmlFeed.feedURL))
        }

        // One assignment → one observable republish for the whole import, not 92.
        if updatedFeeds != feeds { feeds = updatedFeeds }
        for folder in pendingFolders where !folders.contains(folder) {
            folders.append(folder)
            recordFolder(folder, present: true)
        }
        scheduleShardSave()
        scheduleSave()

        guard !targets.isEmpty, !isPreparingLocalReset else { return }

        // ── Phase 2: fetch content, bounded + batched, with progress. ──
        // Runs through the shared batch slot so it serializes with Refresh All /
        // activation sync instead of reentering the shared batch state. A refresh
        // (or an Add Feed) started meanwhile cancels this task and fetches the
        // imported feeds itself, so their content still arrives.
        importProgress = (0, targets.count)
        defer { importProgress = nil }
        await startBatchedFetch { store in
            await store.runBatchedFetch(targets: targets, mode: .interactive) { completed, total in
                store.importProgress = (completed, total)
            }
        }.value
    }

    private func refreshAllFeeds(syncFirst: Bool = true, mode: RefreshMode = .interactive) async {
        guard !isPreparingLocalReset else { return }
        // Pull the latest content + state shards before fetching, so the save at
        // the end can't clobber a feed another device just added but that hasn't
        // reached this device's in-memory list yet. (Callers that already synced
        // — e.g. the background reporter — pass false to avoid a redundant read.)
        if syncFirst { await reloadMerged() }
        guard !isPreparingLocalReset else { return }
        // Managed pseudo-feeds have no fetchable URL — refreshing one would just
        // flag it unhealthy.
        let targets = feeds.filter { !Self.isManagedFeed($0.id) }.map { (id: $0.id, url: $0.feedURL) }
        await runBatchedFetch(targets: targets, mode: mode)
    }

    /// Fetches a set of feeds concurrently (bounded) and merges the results in
    /// batches, holding per-feed saves until the end. This is the shared engine
    /// behind both "Refresh All" and OPML import: the network is the slow part and
    /// `RSSFeedService` is a `Sendable` value, so fetches run off the main actor in
    /// parallel while each result is merged back here serially and buffered, which
    /// bounds the whole-library didSet chain and the row-invalidating republish to
    /// once per flush window instead of once per feed. A sequential fetch would
    /// serialize every feed's up-to-15s timeout (the old OPML import did exactly
    /// that). `onProgress` (completed, total) is called on the main actor as each
    /// fetch finishes, for the import's determinate progress indicator.
    private func runBatchedFetch(
        targets: [(id: Feed.ID, url: URL)],
        mode: RefreshMode,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async {
        guard !targets.isEmpty, !isPreparingLocalReset else { return }
        // Hold per-feed writes and flush once at the end, so a fetch of many feeds
        // doesn't rewrite the whole library repeatedly. `defer` guarantees the flag
        // clears and the final state is saved even on early exit.
        isBatchRefreshing = true
        defer {
            // Safety net: no bucket may outlive the fetch, whatever the exit path
            // (idempotent — the explicit end flush below already handled the normal
            // path). Must run before scheduleSave so the last bucket is included in
            // the persisted snapshot.
            flushBatchMerges()
            batchMergeFlushTask?.cancel()
            batchMergeFlushTask = nil
            isBatchRefreshing = false
            // One immediate (non-debounced) filter now that the whole batch has
            // merged, so the list settles at once instead of after the debounce.
            // Counts/badge already stayed live via the `articles` didSet.
            scheduleArticleFilter()
            scheduleSave()
        }

        let service = feedService
        // Stamp `lastRefreshedAt` (an observable property) once per batch, not
        // once per completed feed.
        var anyFeedMerged = false
        let total = targets.count
        var completed = 0
        // `Error` isn't `Sendable`, so a child task returns the parsed feed or an
        // error message string across the actor boundary, never the error itself.
        await withTaskGroup(of: (Feed.ID, ParsedFeed?, String?).self) { group in
            // Only the network fetch runs off the main actor; touching
            // `refreshingFeedIDs` stays in the main-isolated group body below.
            func launch(_ target: (id: Feed.ID, url: URL)) {
                group.addTask(priority: mode.fetchPriority) {
                    do {
                        var parsed = try await service.fetch(url: target.url)
                        // Re-key the parsed feed AND its articles onto the caller's
                        // id. For a full refresh this is a no-op — the feed's id
                        // already equals the parsed id. For OPML import the target
                        // id is the OPML feed URL, which differs from the parsed id
                        // whenever the feed had to be discovered from an HTML page;
                        // re-keying only the feed would leave every article pointing
                        // at the discovered id (article ids are "\(feed.id)#\(seed)")
                        // — an orphaned, empty-looking feed. Mirrors the re-key in
                        // `fetch(url:existingFeedID:)`.
                        if parsed.feed.id != target.id {
                            let oldPrefix = parsed.feed.id + "#"
                            parsed.feed.id = target.id
                            parsed.articles = parsed.articles.map { article in
                                var article = article
                                let seed = article.id.hasPrefix(oldPrefix) ? String(article.id.dropFirst(oldPrefix.count)) : article.id
                                article.feedID = target.id
                                article.id = "\(target.id)#\(seed)"
                                return article
                            }
                        }
                        return (target.id, parsed, nil)
                    } catch {
                        return (target.id, nil, error.localizedDescription)
                    }
                }
            }
            var next = 0
            let limit = min(mode.maxConcurrentFetches, targets.count)
            while next < limit {
                // Mark in-flight so `isRefreshing` tracks the concurrent fetch; the
                // per-feed spinner shows only for user-initiated refreshes.
                beginFeedFetch(targets[next].id, spinner: mode.showsSpinner)
                launch(targets[next])
                next += 1
            }
            while let (feedID, parsed, _) = await group.next() {
                endFeedFetch(feedID)
                completed += 1
                onProgress?(completed, total)
                // Cancelled (e.g. the user tapped "Add Feed"): stop launching more
                // fetches and drain the in-flight ones without touching state, so
                // a cancel yields promptly and doesn't mark feeds unhealthy on the
                // way out. The interrupted fetch re-runs on the next turn.
                // Results that arrived before the cancel still merge (they did
                // before batching too) — flush them now, then drain untouched.
                if Task.isCancelled || isPreparingLocalReset {
                    flushBatchMerges()
                    continue
                }
                if let parsed {
                    // Buffered, not merged immediately: the flush window bounds
                    // the whole-library didSet chain and the row-invalidating
                    // republish to once per ~400ms instead of once per feed.
                    enqueueBatchMerge(parsed, animated: mode.animatesInsertion)
                    ensureFavicon(for: parsed.feed)
                    anyFeedMerged = true
                } else {
                    // A fetch failure (offline, HTTP host down, parse error) must
                    // never interrupt the user: don't surface a global alert. Just
                    // flag the feed unhealthy so the list can show a quiet
                    // sync-failed indicator; the flag clears on the next successful
                    // refresh (merge resets healthScore).
                    markFeedUnhealthy(feedID: feedID)
                }
                if next < targets.count {
                    beginFeedFetch(targets[next].id, spinner: mode.showsSpinner)
                    launch(targets[next])
                    next += 1
                }
            }
        }

        // Explicit end flush — deliberately here and not only in the defer:
        // everything below (and callers resuming after this await, like the
        // background notifier reading articles/unread counts) must see the fully
        // merged state, and the defer runs after them.
        flushBatchMerges()

        if anyFeedMerged { lastRefreshedAt = Date.now }

        // Recover real dates for any dateless items just merged — but not on the
        // iOS background task, whose tight time budget is for fetching + notifying.
        if mode != .background { resolveMissingDates() }
    }

    @discardableResult
    private func fetch(url: URL, existingFeedID: Feed.ID?) async throws -> ParsedFeed {
        guard !isPreparingLocalReset else { throw CancellationError() }
        let refreshID = existingFeedID ?? url.absoluteString
        // Single-feed fetches are always user-initiated (add feed, refresh this
        // feed), so the spinner is expected feedback.
        beginFeedFetch(refreshID, spinner: true)
        defer {
            endFeedFetch(refreshID)
        }

        var parsedFeed = try await feedService.fetch(url: url)
        guard !isPreparingLocalReset else { throw CancellationError() }
        if let existingFeedID, existingFeedID != parsedFeed.feed.id {
            // Re-key onto the existing feed's id atomically: the article ids are
            // built as "\(feed.id)#\(seed)", so re-keying only the feed would leave
            // every article pointing at the old (now absent) feed id — an orphan
            // ("Unknown Feed"). Re-key the feed AND every article's feedID/id.
            let oldID = parsedFeed.feed.id
            let oldPrefix = oldID + "#"
            parsedFeed.feed.id = existingFeedID
            parsedFeed.articles = parsedFeed.articles.map { article in
                var article = article
                let seed = article.id.hasPrefix(oldPrefix) ? String(article.id.dropFirst(oldPrefix.count)) : article.id
                article.feedID = existingFeedID
                article.id = "\(existingFeedID)#\(seed)"
                return article
            }
        }

        merge(parsedFeed)
        ensureFavicon(for: parsedFeed.feed)
        lastRefreshedAt = Date.now
        scheduleSave()
        pruneSelectionIfHidden()
        return parsedFeed
    }

    private func refreshFeed(_ feed: Feed) async {
        guard !Self.isManagedFeed(feed.id) else { return }
        guard !isPreparingLocalReset else { return }
        do {
            _ = try await fetch(url: feed.feedURL, existingFeedID: feed.id)
        } catch {
            // A refresh failure stays quiet (no global alert) — just flag the feed
            // so the list shows a sync-failed indicator; it clears on next success.
            markFeedUnhealthy(feedID: feed.id)
        }
    }

    /// For feed items that shipped no date, fetch each article page once (bounded,
    /// low priority) and read a real publish date from it. Fills in the article's
    /// timestamp when found; every page is fetched at most once (attempts are
    /// recorded), and network failures stay unrecorded so a later pass retries.
    private func resolveMissingDates() {
        guard resolvesMissingDates, let replicaStore, isStorageConfigured else { return }
        let candidates = Array(datelessArticleIDs)
        guard !candidates.isEmpty else { return }
        dateResolutionTask?.cancel()
        dateResolutionTask = Task { [weak self] in
            await self?.performDateResolution(candidates: candidates, replicaStore: replicaStore)
        }
    }

    private func performDateResolution(candidates: [Article.ID], replicaStore: ReplicaStore) async {
        let pending = (try? replicaStore.articleIDsNeedingDateResolution(candidates)) ?? []
        guard !pending.isEmpty else { return }
        let urlByID = Dictionary(articles.map { ($0.id, $0.url) }, uniquingKeysWith: { first, _ in first })
        let targets = pending.compactMap { id in urlByID[id].map { (id: id, url: $0) } }
        guard !targets.isEmpty else { return }

        let session = URLSession.shared
        var resolved: [Article.ID: Date] = [:]
        var attempted: [Article.ID] = []
        // Bool = the page actually loaded (mark attempted); a network failure
        // leaves it unmarked so a later pass retries.
        await withTaskGroup(of: (Article.ID, Date?, Bool).self) { group in
            func launch(_ target: (id: Article.ID, url: URL)) {
                group.addTask(priority: .utility) {
                    do {
                        let date = try await ArticleDateResolver.publishedDate(for: target.url, session: session)
                        return (target.id, date, true)
                    } catch {
                        return (target.id, nil, false)
                    }
                }
            }
            var next = 0
            let limit = min(Self.maxConcurrentDateResolutions, targets.count)
            while next < limit { launch(targets[next]); next += 1 }
            while let (id, date, loaded) = await group.next() {
                if Task.isCancelled { break }
                if loaded {
                    attempted.append(id)
                    if let date { resolved[id] = date }
                }
                if next < targets.count { launch(targets[next]); next += 1 }
            }
        }

        guard !Task.isCancelled else { return }
        if !resolved.isEmpty {
            articles = articles.map { article in
                guard let date = resolved[article.id] else { return article }
                var updated = article
                updated.publishedAt = date
                updated.hasExplicitPublishDate = true
                return updated
            }
            scheduleSave()
        }
        if !attempted.isEmpty {
            try? replicaStore.markDateResolutionAttempted(attempted)
            for id in attempted { datelessArticleIDs.remove(id) }
        }
    }

    /// Test-only factory (the app uses `shared`): lets regression tests drive
    /// store flows on an isolated instance without touching global state.
    static func _makeForTesting() -> ReaderStore { ReaderStore() }

    /// Test-only entry into the refresh merge path (`merge` stays private so
    /// production callers can't bypass the batching buffer by accident).
    func _mergeForTesting(_ parsedFeed: ParsedFeed) {
        merge(parsedFeed, animated: false)
    }

    /// Single-feed merge — a batch of one. Kept as the entry point for every
    /// single-feed path (add feed, refresh one feed, OPML import) so those stay
    /// immediate and never ride the refresh batching buffer.
    private func merge(_ parsedFeed: ParsedFeed, animated: Bool = true) {
        // An older snapshot of this same feed may be sitting in the refresh
        // bucket (a full refresh fetched it moments ago). This immediate merge
        // is newer — drop the stale entry so the later flush can't revert it.
        pendingBatchMerges.removeAll { $0.parsed.feed.id == parsedFeed.feed.id }
        merge(batch: [parsedFeed], animated: animated)
    }

    /// Merges a batch of fetched feeds in ONE synchronous main-actor pass.
    ///
    /// This is the only merge code path (the single-feed overload wraps it), so
    /// the batch semantics can never drift from the sequential ones. Batching
    /// exists because a full refresh used to run this once per feed: the
    /// all-articles dictionary rebuild, the `articles` didSet (full refilter +
    /// recount), and the @Observable republish each fired per changed feed.
    /// One pass bounds all of that to once per flush bucket.
    ///
    /// Deliberately synchronous with no suspension points: user mutations
    /// (setRead/setStarred/delete) also run on the main actor, so reading
    /// `articles` and assigning the merged result within one synchronous span
    /// makes a stale-apply clobber structurally impossible — the batch buffer
    /// only ever holds network snapshots, never store state.
    private func merge(batch: [ParsedFeed], animated: Bool) {
        guard !batch.isEmpty else { return }

        // Which feeds already had articles BEFORE this batch. A brand-new feed's
        // first batch shouldn't flash (nothing "arrived" for the user yet); the
        // set is computed up front so an earlier feed in the same batch can't
        // change a later feed's verdict.
        let feedIDsWithArticles = Set(articles.map(\.feedID))

        // Feed rows: mutate a local copy and assign once — each in-place element
        // write would republish the whole `feeds` array.
        var updatedFeeds = feeds
        var feedsChanged = false
        // Last-writer-wins on a duplicate ID rather than trapping — a dupe slipping
        // through the baseline/shard merge must degrade, not crash the next refresh.
        var existingArticlesByID = Dictionary(articles.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        let knownIDs = Set(existingArticlesByID.keys)
        var hasNewArticles = false
        // Whether any existing article's merged value actually differs — when a
        // refresh changes nothing, `articles` must not be reassigned (its didSet
        // re-filters and re-counts the whole library).
        var hasChangedArticles = false
        // Genuinely-new article ids to hand to the background AI categorizer.
        var newlyArrivedIDs: [Article.ID] = []
        // Feeds that gained new articles and existed before the batch — flashed
        // in the sidebar after the merge lands.
        var flashTargets: [Feed.ID] = []

        for parsedFeed in batch {
            if let feedIndex = updatedFeeds.firstIndex(where: { $0.id == parsedFeed.feed.id }) {
                var updated = parsedFeed.feed
                // Preserve the user's per-feed settings across refreshes; a freshly
                // parsed feed always has an empty category and no view preference.
                updated.category = updatedFeeds[feedIndex].category
                updated.preferredViewMode = updatedFeeds[feedIndex].preferredViewMode
                updated.customTitle = updatedFeeds[feedIndex].customTitle
                // Skip the write when nothing but the fetch stamp changed:
                // `lastFetchedAt` is rendered nowhere, so it's equalized for the
                // comparison (and intentionally not persisted on a no-op) — an
                // unchanged ambient refresh must stay observation-silent.
                var comparable = updated
                comparable.lastFetchedAt = updatedFeeds[feedIndex].lastFetchedAt
                if comparable != updatedFeeds[feedIndex] {
                    updatedFeeds[feedIndex] = updated
                    feedsChanged = true
                }
                // Keep the shard's seed current so every known feed's membership is
                // CRDT-protected (deduplicated, so an unchanged refresh is a no-op).
                recordFeedSeed(updated)
            } else {
                updatedFeeds.append(parsedFeed.feed)
                feedsChanged = true
                // A feed appearing for the first time in memory clears any stale
                // deletion tombstone for the same URL (feed ids are the URL), so
                // re-adding a previously removed feed isn't suppressed at materialize
                // by the old delete. The fresh HLC also beats a peer's older delete.
                recordFeedRestored(parsedFeed.feed.id)
                recordFeedSeed(parsedFeed.feed)
                scheduleShardSave()
            }

            var feedGainedNewArticles = false
            for newArticle in parsedFeed.articles {
                // A deleted article's entry usually survives in the feed's
                // response for days; re-inserting it here would resurrect it
                // until the next materialize re-applies the tombstone — over
                // and over, once per refresh. Deletions win.
                if deletedArticleIDs.contains(newArticle.id) { continue }
                var article = newArticle
                if let existing = existingArticlesByID[article.id] {
                    article.isRead = existing.isRead
                    article.isStarred = existing.isStarred
                    // A freshly parsed article has no categories; keep the ones already
                    // assigned (keyword/AI/manual) so a refresh never wipes them.
                    article.categories = existing.categories
                    // Only pin the timestamp when the feed gave no real date (we
                    // stamped a synthetic first-seen time): re-stamping it each
                    // refresh would jump the article to "now" and reshuffle the list.
                    // When the feed DOES supply a date, keep the freshly parsed one —
                    // it's authoritative and stable, and self-corrects a value that a
                    // past parse got wrong.
                    if !article.hasExplicitPublishDate {
                        article.publishedAt = existing.publishedAt
                    }
                } else {
                    hasNewArticles = true
                    feedGainedNewArticles = true
                    // Auto-classify new articles: keyword rules apply immediately
                    // (cheap, priority); AI runs later in the background queue.
                    article.categories = keywordAutoCategories(for: article)
                    newlyArrivedIDs.append(article.id)
                }
                // Track feed items that shipped no date so a background pass can try
                // to recover the real one from the article page.
                if !article.hasExplicitPublishDate {
                    datelessArticleIDs.insert(article.id)
                }
                if !hasChangedArticles, existingArticlesByID[article.id] != article {
                    hasChangedArticles = true
                }
                existingArticlesByID[article.id] = article
            }

            // Flashing is the only visual signal for automatic refreshes (they
            // show no spinner), so an unchanged feed stays completely silent.
            if feedGainedNewArticles, feedIDsWithArticles.contains(parsedFeed.feed.id) {
                flashTargets.append(parsedFeed.feed.id)
            }
        }

        // Feeds before articles, matching `apply`'s ordering convention.
        if feedsChanged { feeds = updatedFeeds }

        // Only republish when the merge actually changed something; an unchanged
        // refresh (the common ambient case) must stay observation-silent.
        if hasNewArticles || hasChangedArticles {
            let merged = Array(existingArticlesByID.values)
            // Animate the list only for interactive refreshes that bring in new
            // stories, so rows slide/fade in like Apple Mail. Automatic (ambient/
            // background) refreshes pass `animated: false` so new rows appear quietly
            // instead of sliding under the user mid-scroll.
            if animated && hasNewArticles && !knownIDs.isEmpty {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    articles = merged
                }
            } else {
                articles = merged
            }
        }

        // Persist the keyword categories just assigned to new articles (so they
        // sync), and queue those articles for background AI categorization (a
        // no-op unless AI is enabled).
        if !newlyArrivedIDs.isEmpty {
            var wroteCategories = false
            for id in newlyArrivedIDs {
                if let cats = existingArticlesByID[id]?.categories, !cats.isEmpty {
                    recordArticleCategories(id, from: [], to: cats)
                    wroteCategories = true
                }
                enqueueAICategorization(id)
            }
            if wroteCategories { scheduleShardSave() }
        }

        // Flash the feeds that actually brought in new articles.
        for feedID in flashTargets {
            flashFeedUpdate(feedID)
        }

        // Keep the body cache current with freshly fetched content, so a later
        // re-merge (which reloads the list-light baseline) restores these bodies
        // rather than blanking them until the next refresh.
        for parsedFeed in batch {
            for article in parsedFeed.articles
            where article.hasBody && !deletedArticleIDs.contains(article.id) {
                bodyCache[article.id] = article.body
            }
        }
    }

    // MARK: - Refresh merge batching

    /// Fetched feeds waiting to be merged — network snapshots only, never store
    /// state, so a flush can never apply anything stale over a user mutation.
    /// The animation mode rides along per entry: overlapping refresh runs with
    /// different modes (pull-to-refresh over an in-flight ambient refresh) can
    /// share the bucket without cross-contaminating each other's animation.
    private var pendingBatchMerges: [(parsed: ParsedFeed, animated: Bool)] = []
    /// The open flush window. A fixed trailing window (not a resetting debounce,
    /// which a slow trickle of feeds could starve): the first arrival opens it,
    /// later arrivals just join the bucket, and one merge lands when it closes.
    private var batchMergeFlushTask: Task<Void, Never>?
    private static let batchMergeFlushInterval: Duration = .milliseconds(400)

    /// Buffers a fetched feed for the next merge flush. Bounds the didSet chain
    /// and the observable republish to once per window instead of once per feed,
    /// while keeping progressive display (a slow refresh still shows articles
    /// every ~400ms, on par with the 300ms list-filter debounce).
    private func enqueueBatchMerge(_ parsed: ParsedFeed, animated: Bool) {
        guard !isPreparingLocalReset else { return }
        pendingBatchMerges.append((parsed, animated))
        guard batchMergeFlushTask == nil else { return }
        batchMergeFlushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.batchMergeFlushInterval)
            guard let self, !Task.isCancelled else { return }
            self.batchMergeFlushTask = nil
            self.flushBatchMerges()
        }
    }

    /// Drops a feed's buffered fetch results. Called when the user deletes a
    /// feed: a buffered result applied after the delete would re-append the
    /// feed and stamp a fresher restore over the deletion tombstone — undoing
    /// the delete on every synced device.
    func discardPendingBatchMerges(forFeedID feedID: Feed.ID) {
        pendingBatchMerges.removeAll { $0.parsed.feed.id == feedID }
    }

    /// Applies the pending bucket in one synchronous pass (split by animation
    /// mode, arrival order preserved within each). Idempotent and safe to call
    /// from anywhere (timer, cancellation, end-of-refresh, defer): an empty
    /// bucket is a no-op, and the merge reads `articles` at flush time so it
    /// always composes over the latest state.
    private func flushBatchMerges() {
        if isPreparingLocalReset {
            pendingBatchMerges.removeAll()
            batchMergeFlushTask?.cancel()
            batchMergeFlushTask = nil
            return
        }
        guard !pendingBatchMerges.isEmpty else { return }
        let bucket = pendingBatchMerges
        pendingBatchMerges = []
        batchMergeFlushTask?.cancel()
        batchMergeFlushTask = nil
        let quiet = bucket.filter { !$0.animated }.map(\.parsed)
        let animated = bucket.filter(\.animated).map(\.parsed)
        if !quiet.isEmpty { merge(batch: quiet, animated: false) }
        if !animated.isEmpty { merge(batch: animated, animated: true) }
        pruneSelectionIfHidden()
    }

    private func markFeedUnhealthy(feedID: Feed.ID) {
        guard let index = feeds.firstIndex(where: { $0.id == feedID }),
              feeds[index].healthScore != 0 else { return }
        feeds[index].healthScore = 0
        // No immediate full-library save: the flag is a transient indicator
        // (cleared by the next successful refresh) and every failed fetch was
        // re-encoding and coordinated-writing the whole library. Any later
        // scheduled save persists it incidentally.
    }

    private func moveSelection(offset: Int) {
        let visible = visibleArticles
        guard !visible.isEmpty else {
            selectedArticleID = nil
            return
        }

        guard let selectedArticleID,
              let currentIndex = visible.firstIndex(where: { $0.id == selectedArticleID }) else {
            self.selectedArticleID = visible.first?.id
            return
        }

        let nextIndex = min(max(currentIndex + offset, visible.startIndex), visible.index(before: visible.endIndex))
        self.selectedArticleID = visible[nextIndex].id
    }

    /// Debounces search input: an empty query clears instantly for a snappy
    /// reset, otherwise the filter waits until the user pauses typing. Setting
    /// `activeSearchQuery` triggers the (possibly background) refilter.
    public func debounceSearch() {
        searchDebounceTask?.cancel()

        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchDebounceTask = nil
            activeSearchQuery = ""
            return
        }

        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.activeSearchQuery = self.searchText
        }
    }

    /// Installs a merged library. When the caller ran the merge off the main
    /// actor it passes the matching `precomputed` filter/count state (built from
    /// the same articles), and the whole-library didSet recompute is skipped in
    /// favor of installing those values directly — the launch-path fix for the
    /// cold-start classification storm.
    private func apply(_ library: ReaderLibrary, precomputed: PrecomputedFilterState? = nil) {
        // Repair any feeds whose stored URLs have a doubled scheme (from an
        // earlier bug) so they fetch correctly instead of flooding failed
        // requests. `id` is left untouched so existing articles stay linked.
        var repairedFeeds = library.feeds
        var didRepair = false
        for index in repairedFeeds.indices {
            let fixedFeed = RSSFeedService.repairedWebURL(repairedFeeds[index].feedURL)
            let fixedSite = RSSFeedService.repairedWebURL(repairedFeeds[index].siteURL)
            if fixedFeed != repairedFeeds[index].feedURL { repairedFeeds[index].feedURL = fixedFeed; didRepair = true }
            if fixedSite != repairedFeeds[index].siteURL { repairedFeeds[index].siteURL = fixedSite; didRepair = true }
        }

        feeds = repairedFeeds
        // Set filters (and rebuild the compiled engine) BEFORE articles: assigning
        // `articles` triggers its didSet, which re-classifies filtered ids using
        // the engine — so the merged filters must already be compiled in place (a
        // peer's filter edit reclassifies).
        filters = library.filters
        // Categories drive both the badge display and (hidden ones) the filtered
        // set, so set them before `articles` for the didSet recompute.
        categories = library.categories
        rebuildFilterEngine()
        if let precomputed {
            // The classification/counts were computed off-main from these same
            // articles; install both sides without re-deriving anything. The
            // assignment still publishes (observation is untouched by the
            // suppress flag), and the debounced filter recompute still runs so
            // `displayedArticles` follows.
            suppressArticlesDidSet = true
            articles = library.articles
            suppressArticlesDidSet = false
            textFilteredArticleIDs = precomputed.textFilteredIDs
            filterClassifyCache = precomputed.classifyCache
            filteredArticleIDs = precomputed.filteredIDs
            if unreadByFeed != precomputed.unreadByFeed { unreadByFeed = precomputed.unreadByFeed }
            if unreadByCategory != precomputed.unreadByCategory { unreadByCategory = precomputed.unreadByCategory }
            if totalUnread != precomputed.totalUnread { totalUnread = precomputed.totalUnread }
            if todayCount != precomputed.todayCount { todayCount = precomputed.todayCount }
            if starredCount != precomputed.starredCount { starredCount = precomputed.starredCount }
            updateUnreadBadge()
            scheduleArticleFilter(debounced: true)
        } else {
            articles = library.articles
        }
        lastRefreshedAt = library.lastRefreshedAt
        // Merge explicit folders with any folders implied by feed categories.
        let feedFolderNames = feeds.map(\.folderName).filter { !$0.isEmpty }
        folders = Array(Set(library.folders + feedFolderNames))
        loadCachedFavicons()

        if didRepair { scheduleSave() }

        // Articles that arrived through this merge (fetched by another device)
        // may still be untagged — pick them up now that they're in the library.
        scheduleClassificationSweep()
    }

    private func loadCachedFavicons() {
        guard let storage else { return }
        // Only feeds without an in-memory icon need any disk work. Re-reading
        // every favicon on each merge (apply runs on every sync) needlessly
        // thrashed iCloud — and did the reads synchronously on the main actor,
        // which blocked (a spinning cursor) whenever a file had been evicted.
        let missing = feeds.filter { feedIcons[$0.id] == nil }
        guard !missing.isEmpty else { return }
        let items = missing.map { (id: $0.id, key: faviconKey(for: $0)) }

        Task { [weak self] in
            // Read the cached bytes (and the TTL check) off the main actor; the
            // small PNG decode then happens back on the main actor (Data is
            // Sendable, the platform image type isn't).
            let outcome = await Task.detached(priority: .userInitiated) { () -> [(id: Feed.ID, key: String, data: Data?, needsFetch: Bool)] in
                items.map { item in
                    let data = storage.cachedFaviconData(forKey: item.key)
                    let needsFetch = data == nil && storage.faviconNeedsRefresh(forKey: item.key)
                    return (item.id, item.key, data, needsFetch)
                }
            }.value
            guard let self else { return }

            for entry in outcome {
                if let data = entry.data, let image = makePlatformImage(data: data) {
                    self.feedIcons[entry.id] = image
                }
            }
            // Fetch over the network only when there's no cached icon at all and
            // the TTL allows a retry — a cached icon is used as-is, never
            // re-downloaded just because the app synced again.
            for entry in outcome where entry.needsFetch && !self.faviconAttemptedKeys.contains(entry.key) {
                guard let feed = self.feed(for: entry.id) else { continue }
                self.faviconAttemptedKeys.insert(entry.key)
                self.faviconQueue.append(feed)
            }
            self.pumpFaviconQueue()
        }
    }

    /// Shows any cached favicon immediately, then queues a background refresh
    /// when it is missing or older than the 1-day TTL. Refreshes are keyed by
    /// host, deduplicated, and rate-limited so opening a large library doesn't
    /// fire hundreds of concurrent (and often duplicate) network requests.
    private func ensureFavicon(for feed: Feed) {
        guard let storage else { return }
        let key = faviconKey(for: feed)

        if feedIcons[feed.id] == nil,
           let data = storage.cachedFaviconData(forKey: key),
           let image = makePlatformImage(data: data) {
            feedIcons[feed.id] = image
        }

        // One attempt per host per session: many feeds can share a host, and a
        // host that failed shouldn't be retried repeatedly.
        guard storage.faviconNeedsRefresh(forKey: key), !faviconAttemptedKeys.contains(key) else {
            return
        }
        faviconAttemptedKeys.insert(key)
        faviconQueue.append(feed)
        pumpFaviconQueue()
    }

    /// Starts queued favicon fetches up to the concurrency cap.
    private func pumpFaviconQueue() {
        while activeFaviconFetches < Self.maxConcurrentFaviconFetches, !faviconQueue.isEmpty {
            let feed = faviconQueue.removeFirst()
            activeFaviconFetches += 1
            Task { [weak self] in
                await self?.refreshFavicon(for: feed)
                guard let self else { return }
                self.activeFaviconFetches -= 1
                self.pumpFaviconQueue()
            }
        }
    }

    private func refreshFavicon(for feed: Feed) async {
        let key = faviconKey(for: feed)
        guard let data = await faviconService.fetchFavicon(for: feed.siteURL),
              let image = makePlatformImage(data: data) else {
            // Remember the failure so we don't re-hammer this host next launch.
            storage?.recordFaviconMiss(forKey: key)
            return
        }

        let pngData = image.pngData() ?? data
        try? storage?.writeFaviconData(pngData, forKey: key)
        let finalImage = makePlatformImage(data: pngData) ?? image
        // Apply to every feed that shares this host, so we fetch each icon once.
        for sibling in feeds where faviconKey(for: sibling) == key {
            feedIcons[sibling.id] = finalImage
        }
    }

    private func faviconKey(for feed: Feed) -> String {
        let base = feed.siteURL.host(percentEncoded: false) ?? feed.id
        let sanitized = base.map { character -> Character in
            character.isLetter || character.isNumber || character == "." || character == "-" ? character : "_"
        }
        return String(sanitized)
    }

    private func snapshotLibrary() -> ReaderLibrary {
        ReaderLibrary(
            feeds: feeds,
            articles: articles,
            lastRefreshedAt: lastRefreshedAt,
            folders: folders
        )
    }

    private func saveAfterMutation() {
        scheduleSave()
    }

    /// Schedules a background write of the latest library snapshot. Encoding
    /// and the coordinated file write happen off the main actor, and rapid
    /// mutations (e.g. during a full refresh) are coalesced so only the most
    /// recent state is written — keeping the UI lag-free while syncing.
    private func scheduleSave() {
        guard !isPreparingLocalReset, let storage else { return }
        // Always capture the latest snapshot (cheap: arrays are copy-on-write)...
        pendingSave = snapshotLibrary()
        // ...but hold the actual write until a batch refresh flushes it once.
        guard !isBatchRefreshing else { return }
        guard !isDrainingSaves else { return }
        isDrainingSaves = true
        saveDrainTask = Task { await drainSaves(storage: storage) }
    }

    private func drainSaves(storage: ReaderStorage) async {
        // Pause if a batch refresh starts mid-drain; the held snapshot stays in
        // `pendingSave` and is flushed once when the batch finishes.
        while !isBatchRefreshing, let library = pendingSave {
            pendingSave = nil
            guard let replicaStore else { continue }
            let outcome = await Task.detached(priority: .utility) { () -> (ReplicaSnapshot?, Date?) in
                let snapshot = try? replicaStore.recordLocal(
                    library,
                    retainBodies: ReaderStore.recentArticleIDs(from: library.articles)
                )
                try? replicaStore.publishIfNeeded(to: storage)
                return (snapshot, storage.contentDirectoryModificationDate)
            }.value
            if let revision = outcome.0?.revision { appliedReplicaRevision = max(appliedReplicaRevision, revision) }
            lastKnownContentModDate = outcome.1
            // Observable property the root alert binding reads — don't republish
            // nil-to-nil on every drained save.
            if errorMessage != nil { errorMessage = nil }
        }
        isDrainingSaves = false
        saveDrainTask = nil
    }

    /// Writes the library immediately on the calling actor. Used only for the
    /// initial file creation when configuring a folder, where later code
    /// depends on the file already existing.
    private func persistReplica() throws {
        guard !isPreparingLocalReset, let storage, let replicaStore else {
            throw ReaderStorageError.noDirectorySelected
        }
        let snapshot = try replicaStore.recordLocal(
            snapshotLibrary(),
            retainBodies: Self.recentArticleIDs(from: articles)
        )
        try replicaStore.publishIfNeeded(to: storage)
        appliedReplicaRevision = max(appliedReplicaRevision, snapshot.revision)
        lastKnownContentModDate = storage.contentDirectoryModificationDate
    }

    // MARK: - Recording user-state changes into this device's shard

    /// Issues the next monotonic HLC for a local write, always strictly greater
    /// than anything this device has issued or observed.
    private func nextHLC() -> HLC {
        lastHLC = HLC.next(after: lastHLC, node: deviceID)
        ownShard.clock = lastHLC
        return lastHLC
    }

    private func recordRead(_ id: Article.ID, _ value: Bool) {
        ownShard.setArticleRead(id, value, hlc: nextHLC())
    }

    private func recordStarred(_ id: Article.ID, _ value: Bool) {
        ownShard.setArticleStarred(id, value, hlc: nextHLC())
    }

    private func recordArticleDeleted(_ id: Article.ID) {
        ownShard.setArticleTombstone(id, true, hlc: nextHLC())
    }

    private func recordCategory(_ id: Feed.ID, _ value: String) {
        ownShard.setFeedCategory(id, value, hlc: nextHLC())
    }

    private func recordViewMode(_ id: Feed.ID, _ value: ReaderViewMode?) {
        ownShard.setFeedViewMode(id, value, hlc: nextHLC())
    }

    private func recordCustomTitle(_ id: Feed.ID, _ value: String?) {
        ownShard.setFeedTitle(id, value, hlc: nextHLC())
    }

    private func recordFeedDeleted(_ id: Feed.ID) {
        ownShard.setFeedTombstone(id, true, hlc: nextHLC())
    }

    /// Records that a feed is present again (tombstone cleared), so a re-add
    /// beats any earlier deletion of the same URL under last-writer-wins.
    private func recordFeedRestored(_ id: Feed.ID) {
        ownShard.setFeedTombstone(id, false, hlc: nextHLC())
    }

    /// Seeds a feed's identity into this device's shard so its membership is CRDT
    /// state, immune to a baseline-file overwrite by another device. Deduplicated
    /// so a refresh that changes nothing doesn't churn the shard.
    private func recordFeedSeed(_ feed: Feed) {
        let seed = FeedSeed(from: feed)
        guard ownShard.feedState[feed.id]?.seed?.value != seed else { return }
        ownShard.setFeedSeed(feed.id, seed, hlc: nextHLC())
        scheduleShardSave()
    }

    private func recordFolder(_ name: String, present: Bool) {
        ownShard.setFolderPresent(name, present, hlc: nextHLC())
    }

    /// Stamps one filter into this device's shard (per-item, so a concurrent edit
    /// to a different filter on another device is not clobbered). The caller
    /// schedules the save.
    private func recordFilter(_ filter: ArticleFilter) {
        ownShard.setFilter(filter.id, filter, hlc: nextHLC())
    }

    /// Records a filter deletion as a tombstone so it syncs and converges.
    private func recordFilterRemoval(_ id: ArticleFilter.ID) {
        ownShard.setFilterTombstone(id, true, hlc: nextHLC())
    }

    /// Stamps a category-assignment change into this device's shard. The truth
    /// for merging is the per-category membership registers — only the ids that
    /// actually changed get a register, so two devices tagging the same article
    /// concurrently union instead of clobbering, and a removal still syncs. The
    /// whole-list register is written too, as the base for shards from builds
    /// that predate membership registers.
    private func recordArticleCategories(_ id: Article.ID, from previous: [String], to next: [String]) {
        ownShard.setArticleCategories(id, next, hlc: nextHLC())
        for added in next where !previous.contains(added) {
            ownShard.setArticleCategoryMembership(id, category: added, present: true, hlc: nextHLC())
        }
        for removed in previous where !next.contains(removed) {
            ownShard.setArticleCategoryMembership(id, category: removed, present: false, hlc: nextHLC())
        }
    }

    private func recordCategoryDefinition(_ category: ArticleCategory) {
        ownShard.setCategory(category.id, category, hlc: nextHLC())
    }

    private func recordCategoryRemoval(_ id: String) {
        ownShard.setCategoryTombstone(id, true, hlc: nextHLC())
    }

    /// Schedules a coalesced background write of this device's shard. Runs off
    /// the main actor and, like the baseline save, only ever writes the latest
    /// snapshot. The shard is a separate file from `NookLibrary.json`, so the two
    /// writers never contend.
    ///
    /// Writes trail the mutation by a short window so a reading session (one
    /// mark-read per article open) coalesces into one grow-only-file write +
    /// iCloud upload per burst instead of one per article. `urgent` skips the
    /// window — used for tombstones (losing a delete is worse than losing a
    /// read bit) — and `flushPendingShardSave` drains on backgrounding /
    /// termination so no state is lost.
    private func scheduleShardSave(urgent: Bool = false) {
        guard !isPreparingLocalReset, let storage else { return }
        ownShard.updatedAt = Date()
        ownShard.generation &+= 1
        pendingShard = ownShard
        if urgent {
            shardSaveDebounceTask?.cancel()
            shardSaveDebounceTask = nil
            startShardSaveDrain(storage: storage)
            return
        }
        // Fixed trailing window (not a resetting debounce, which continuous
        // reading could starve): the first mutation opens it, later ones just
        // refresh `pendingShard`, and one write lands when it closes.
        guard shardSaveDebounceTask == nil else { return }
        shardSaveDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, !Task.isCancelled else { return }
            self.shardSaveDebounceTask = nil
            guard let storage = self.storage else { return }
            self.startShardSaveDrain(storage: storage)
        }
    }

    /// Drains any pending shard write immediately. Platform apps call this when
    /// leaving the foreground (and the macOS app on termination) so the trailing
    /// save window can't drop state.
    public func flushPendingShardSave() {
        guard !isPreparingLocalReset else { return }
        shardSaveDebounceTask?.cancel()
        shardSaveDebounceTask = nil
        guard let storage, pendingShard != nil else { return }
        startShardSaveDrain(storage: storage)
    }

    private func startShardSaveDrain(storage: ReaderStorage) {
        guard !isPreparingLocalReset, !isDrainingShardSaves else { return }
        isDrainingShardSaves = true
        shardSaveDrainTask = Task { await drainShardSaves(storage: storage) }
    }

    private func drainShardSaves(storage: ReaderStorage) async {
        while let shard = pendingShard {
            pendingShard = nil
            let modDate = await Task.detached(priority: .utility) { () -> Date? in
                try? storage.saveShard(shard)
                return storage.stateDirectoryModificationDate
            }.value
            // Record our own write so the directory observer doesn't treat it as
            // an external (another-device) change and re-merge it back.
            lastKnownStateModDate = modDate
        }
        isDrainingShardSaves = false
        shardSaveDrainTask = nil
    }
}
