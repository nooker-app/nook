import AppKit
import NookKit
import SwiftUI
import UniformTypeIdentifiers

struct MagazineView: View {
    @State private var store = ReaderStore.shared
    @State private var plus = PlusStore()
    @State private var tab: MagazineTab = .magazine
    @State private var opened: Article.ID?
    @State private var frozenRows: [ArticleRowModel]?
    @State private var recommendations = MagazineRecommendationController()
    @State private var recommendationMap = RecommendationMapController()
    @State private var recommendation: MagazineRecommendation?
    @State private var recommendationLoaded = false
    @State private var rankedRecommendations: [MagazineRecommendation] = []
    @State private var rankedScope: String?
    @State private var recommendationWindow = 120
    @AppStorage("magazineUnreadRecommendationOrder") private var prefersRecommendationOrder = true
    @State private var pendingRecommendation: MagazineRecommendationController.Dismissal?
    @State private var pendingDisinterest: [MagazineRecommendationController.DisinterestUndo] = []
    @State private var libraryScope: String?
    @State private var libraryFolder: String?
    @State private var libraryPosition = ScrollPosition(edge: .top)
    @State private var frozenLead: ArticleRowModel?
    @State private var dismissedArticle: Article.ID?
    @State private var initialLoadFinished = false
    @State private var collectionBarVisible = true
    @State private var addingFeed = false
    @State private var importing = false
    @State private var exporting = false
    @State private var importRequest: MagazineOPMLImportRequest?
    @State private var imagePresenter = ArticleImagePresenter()
    @State private var draftSession: BetaDraftSession?
    @Namespace private var navigationSelection
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showUnreadBadge") private var showUnreadBadge = true
    @AppStorage("autoRefreshEnabled") private var autoRefresh = true
    @AppStorage(MagazineRecommendationController.enabledKey) private var recommendationsEnabled = true
    @AppStorage(MagazineRecommendationController.resetKey) private var recommendationReset = 0
    @AppStorage(ReaderStore.translateListTitlesKey) private var translateListTitles = false
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system
    @AppStorage(TranslationSettings.titleProviderKey) private var titleProvider = TranslationProvider.appleIntelligence.rawValue
    @AppStorage(TranslationSettings.geminiKeyConfiguredKey) private var geminiKeyConfigured = false
    private let titleTranslator = ListTitleTranslator.shared
    @Namespace private var hero
    @FocusState private var focusedArticle: String?
    @FocusState private var searchFocused: Bool
    @State private var searchSetup = false

    enum MagazineTab: String, CaseIterable {
        case magazine = "Magazine", map = "Map", library = "Library", studio = "Studio"
        var icon: String {
            switch self {
            case .magazine: "newspaper"
            case .map: "point.3.connected.trianglepath.dotted"
            case .library: "books.vertical"
            case .studio: "square.and.pencil"
            }
        }
    }

    private var presentedWorkspace: some View {
        ZStack {
            workspace
                .allowsHitTesting(opened == nil && !store.isBrowserPresented)
                .disabled(store.isBrowserPresented)
                .accessibilityHidden(opened != nil || store.isBrowserPresented)
            if let opened {
                MagazineReaderDetail(store: store, recommendations: recommendations,
                                     articleID: opened, heroNamespace: hero,
                                     nextTitle: adjacentRow(forward: true)?.title,
                                     previousTitle: adjacentRow(forward: false)?.title,
                                     backToCollection: libraryScope != nil,
                                     backToMap: isRecommendationMap,
                                     onClose: closeArticle, onNavigate: navigate)
                    .background {
                        NookTheme.canvas
                            .matchedGeometryEffect(id: "surface-\(opened)", in: hero)
                    }
                    .allowsHitTesting(!store.isBrowserPresented)
                    .disabled(store.isBrowserPresented)
                    .accessibilityHidden(store.isBrowserPresented)
                    .zIndex(2)
                    .transition(reduceMotion ? .opacity : .identity)
            }
            if store.isBrowserPresented, let article = store.selectedArticle {
                MagazineBrowserPanel(store: store, article: article,
                    previousTitle: adjacentRow(forward: false)?.title,
                    nextTitle: adjacentRow(forward: true)?.title,
                    onNavigate: navigate, onClose: closeBrowser)
                    .zIndex(3)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.32, bounce: 0.04), value: store.isBrowserPresented)
        .background(NookTheme.canvas)
        .containerBackground(NookTheme.canvas, for: .window)
        .toolbarBackground(NookTheme.canvas, for: .windowToolbar)
        .toolbarBackgroundVisibility(isRecommendationMap ? .visible : .automatic, for: .windowToolbar)
        .articleImageOverlay(imagePresenter)
        .toolbar {
            if store.isBrowserPresented {
                ToolbarItem(placement: .principal) {
                    Label(store.browserMode == .reader ? LocalizedStringKey("Reader Mode") : LocalizedStringKey("Original Page"),
                          systemImage: store.browserMode == .reader ? "book" : "globe")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 3) {
                    ForEach(MagazineTab.allCases, id: \.self) { item in
                        Button {
                            guard draftSession?.flush() != false else { return }
                            if opened != nil { closeArticle() }
                            pendingRecommendation = nil
                            if item == .library { libraryScope = nil }
                            if (item == .magazine || item == .map) && (tab == .library || libraryScope != nil) {
                                libraryScope = nil
                                store.selectSmartSource(.all)
                                store.searchText = ""
                            }
                            if item == .map { store.searchText = "" }
                            tab = item
                        } label: {
                            Label(LocalizedStringKey(item.rawValue), systemImage: item.icon)
                                .labelStyle(.titleAndIcon)
                                .font(.system(size: 13, weight: tab == item ? .semibold : .medium))
                                .foregroundStyle(tab == item ? NookTheme.accent : .secondary)
                                .padding(.horizontal, 15).frame(height: 30)
                                .background {
                                    if tab == item {
                                        Capsule().fill(NookTheme.accent.opacity(0.16))
                                            .matchedGeometryEffect(id: "navigation", in: navigationSelection)
                                    }
                                }
                        }
                        .buttonStyle(MagazinePlainButtonStyle(capsule: true))
                        .help(Text(LocalizedStringKey(item.rawValue)))
                        .accessibilityLabel(Text(LocalizedStringKey(item.rawValue)))
                    }
                }
                .padding(3)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Refresh All", systemImage: "arrow.clockwise") { store.refreshAll() }
                    .disabled(store.isRefreshing || store.feeds.isEmpty)
                    .pointerStyle(store.isRefreshing || store.feeds.isEmpty ? .default : .link)
                Button("Settings", systemImage: "gearshape") { openWindow(id: "settings") }
                    .pointerStyle(.link)
            }
            }
        }
        .sheet(isPresented: $addingFeed) {
            MagazineAddFeedSheet(folders: store.feedFolders) { url, folder in
                try await store.addFeed(urlString: url, toFolder: folder)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.opml, .xml]) { result in
            if case .success(let url) = result {
                let candidates = store.parseOPML(at: url)
                if candidates.isEmpty { store.errorMessage = String(localized: "No feeds found in the OPML file.") }
                else { importRequest = MagazineOPMLImportRequest(feeds: candidates) }
            }
        }
        .sheet(item: $importRequest) { request in
            MagazineOPMLImportView(feeds: request.feeds,
                existingKeys: Set(store.feeds.flatMap { [$0.feedURL.feedIdentityKey, $0.siteURL.feedIdentityKey] })) {
                store.importFeeds($0)
            }
        }
        .fileExporter(isPresented: $exporting, document: OPMLDocument(feeds: store.exportableFeeds),
                      contentType: .opml, defaultFilename: "NookSubscriptions.opml") { store.handleOPMLExport($0) }
        .alert("Something went wrong", isPresented: Binding(get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    var body: some View {
        presentedWorkspace
        .task {
            plus.syncFolder = { ReaderStore.shared.syncFolderURL }
            plus.loadDrafts()
            store.onUnreadBadgeChange = { NSApp.dockTile.badgeLabel = $0 > 0 ? String($0) : nil }
            store.showsUnreadBadge = showUnreadBadge
            await store.bootstrap()
            initialLoadFinished = true
            if plus.isSignedIn { await plus.prepareToCompose() }
            if autoRefresh { store.refreshOnActivation(honorThrottle: true) }
        }
        .onAppear {
            configureTitleTranslator()
            LayoutSelectionCoordinator.shared.prepareToLeave = { draftSession?.flush() ?? true }
        }
        .onDisappear {
            LayoutSelectionCoordinator.shared.prepareToLeave = nil
            titleTranslator.setScrolling(false)
        }
        .onChange(of: titleTranslationConfiguration) { _, _ in configureTitleTranslator() }
        .onChange(of: LayoutSelectionCoordinator.shared.collectionRequest, initial: true) { _, source in
            guard source != nil else { return }
            LayoutSelectionCoordinator.shared.collectionRequest = nil
            tab = .magazine
            libraryScope = nil
            libraryFolder = nil
            closeArticle()
        }
        .onChange(of: LayoutSelectionCoordinator.shared.readerRequest?.id, initial: true) { _, _ in
            guard let request = LayoutSelectionCoordinator.shared.readerRequest else { return }
            LayoutSelectionCoordinator.shared.readerRequest = nil
            store.isBrowserPresented = false
            if opened == request.articleID { return }
            opened = nil
            if tab == .studio || tab == .library {
                tab = .magazine
                libraryScope = nil
                libraryFolder = nil
            }
            openArticle(request.articleID, fromRecommendation: request.recommendation)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.syncFromDisk()
            if autoRefresh { store.refreshOnActivation(honorThrottle: true) }
        }
        .onChange(of: showUnreadBadge) { _, value in store.showsUnreadBadge = value }
        .onChange(of: store.searchText, initial: true) { _, _ in
            store.debounceSearch()
        }
        .onChange(of: recommendationScope) { _, _ in
            scrollPosition.scrollTo(edge: .top)
        }
        .onChange(of: store.syncFolderURL?.path) { _, _ in pendingDisinterest = [] }
        .onChange(of: recommendationReset) { _, _ in
            pendingDisinterest = []
            pendingRecommendation = nil
            recommendations.reloadAfterReset()
        }
        .onChange(of: store.selectedArticleID) { _, id in
            if id == nil {
                closeBrowser()
                closeArticle()
            }
        }
        .task(id: opened) {
            guard opened == nil, let dismissedArticle else { return }
            // Keep the source cards in place during dismissal. This task is
            // cancelled on reopening: an old dismissal must not clear the new
            // reader's snapshot or steal its focus. Animation completion is not
            // an input lock; async reader content can outlive the hero animation.
            do { try await Task.sleep(for: .milliseconds(reduceMotion ? 150 : 400)) } catch { return }
            guard !Task.isCancelled, opened == nil, self.dismissedArticle == dismissedArticle else { return }
            frozenRows = nil
            frozenLead = nil
            focusedArticle = dismissedArticle
            self.dismissedArticle = nil
        }
        .task(id: recommendationTaskID) {
            guard opened == nil, initialLoadFinished, isBrowsingMagazine, !libraryFolderIsEmpty, !isRecommendationMap, store.activeSearchQuery.isEmpty else { return }
            recommendations.selectLibrary(store.syncFolderURL?.standardizedFileURL.path ?? "local")
            let pending = pendingRecommendation
            let scope = recommendationScope
            let showsList = isRecommendationList
            if pending == nil { recommendationLoaded = false }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            let result: MagazineRecommendation?
            let ranked: [MagazineRecommendation]
            if showsList {
                ranked = await recommendations.rankedRecommendations(candidates: store.visibleArticles,
                    library: store.libraryArticles, personalized: recommendationsEnabled)
                result = nil
            } else if store.smartSelection == .recent {
                ranked = []
                result = nil
            } else {
                ranked = []
                result = await recommendations.recommend(candidates: store.visibleArticles,
                    library: store.libraryArticles, personalized: recommendationsEnabled)
            }
            if let pending {
                let remaining = pending.deadline.timeIntervalSinceNow
                if remaining > 0 {
                    do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                }
            }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                recommendation = result
                if showsList {
                    if rankedScope != scope { recommendationWindow = 120 }
                    rankedRecommendations = ranked
                    rankedScope = scope
                }
                recommendationLoaded = true
                pendingRecommendation = nil
            }
        }
        .task(id: pendingDisinterest.last?.id) {
            await expireDisinterestUndo()
        }
        .task(id: readingTaskID) {
            guard recommendationsEnabled, store.isForegroundActive, let id = opened else { return }
            // ForegroundEngagementPolicy accounts for reader-window focus,
            // minimization, screen lock and idle time. Settings is not reading.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                recommendations.recordReading(articleID: id, seconds: 10)
            }
        }
        .focusedSceneValue(\.readerCommandActions, commands)
    }

    private func expireDisinterestUndo() async {
        guard let last = pendingDisinterest.last else { return }
        do { try await Task.sleep(for: .seconds(max(0, last.deadline.timeIntervalSinceNow))) } catch { return }
        guard !Task.isCancelled, pendingDisinterest.last?.id == last.id else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { pendingDisinterest = [] }
    }

    private var recommendationTaskID: String {
        "\(recommendationScope)|\(prefersRecommendationOrder)|\(isRecommendationMap)|\(store.magazineContentRevision)|\(initialLoadFinished)|\(isBrowsingMagazine)|\(libraryScope ?? "")|\(opened == nil)|\(recommendationsEnabled)|\(recommendationReset)|\(recommendations.revision)|\(store.syncFolderURL?.path ?? "local")"
    }

    private var recommendationScope: String {
        "\(store.smartSelection?.rawValue ?? "")|\(store.feedSelection.sorted())|\(store.categorySelection ?? "")|\(store.activeSearchQuery)|\(store.syncFolderURL?.path ?? "local")"
    }

    private var isUnreadCollection: Bool {
        store.smartSelection == .unread && store.feedSelection.isEmpty && store.categorySelection == nil
    }

    private var isRecommendationList: Bool { isUnreadCollection && prefersRecommendationOrder && store.activeSearchQuery.isEmpty }
    private var isRecommendationMap: Bool { tab == .map }
    private var showsFeaturedStory: Bool { !isUnreadCollection && store.smartSelection != .recent }
    private var collectionIsEmpty: Bool {
        if libraryFolderIsEmpty { return true }
        // Reader retention can leave the final, now-read story in the store's
        // unread scope until navigation. It is no longer a recommendation.
        if isRecommendationList && frozenRows == nil {
            return !store.visibleArticles.contains { !$0.isRead }
        }
        return store.visibleArticles.isEmpty
    }

    private func configureTitleTranslator() {
        let locale = appLanguage == .system ? Locale.current : appLanguage.locale
        let code = locale.language.languageCode?.identifier ?? "en"
        let name: String
        switch locale.language.script?.identifier {
        case "Hans": name = "Simplified Chinese"
        case "Hant": name = "Traditional Chinese"
        default: name = Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code
        }
        titleTranslator.configure(enabled: translateListTitles, targetLanguageName: name, targetLanguageCode: code)
    }

    private var titleTranslationConfiguration: String {
        "\(translateListTitles)|\(appLanguage.rawValue)|\(titleProvider)|\(geminiKeyConfigured)"
    }

    private var isBrowsingMagazine: Bool { tab == .magazine || (tab == .library && libraryScope != nil) }

    private var readingTaskID: String {
        "\(opened ?? "")|\(store.isForegroundActive)|\(recommendationsEnabled)|\(recommendationReset)"
    }

    @ViewBuilder private var workspace: some View {
        switch tab {
        case .magazine, .map: magazine
        case .library:
            if libraryScope != nil {
                magazine.safeAreaInset(edge: .top, spacing: 0) { libraryBreadcrumb }
            } else { library }
        case .studio:
            BetaStudioView(store: plus, session: $draftSession) { openWindow(id: "settings") }
        }
    }

    @ViewBuilder private var magazine: some View {
        if isRecommendationMap && store.isStorageConfigured && initialLoadFinished {
            VStack(spacing: 0) {
                HStack {
                    collectionTabs
                    Spacer(minLength: 12)
                }.padding(.horizontal, 30).padding(.top, 18)
                RecommendationMapView(model: recommendationMap, store: store, feedback: recommendations,
                    personalized: recommendationsEnabled, active: opened == nil && !store.isBrowserPresented,
                    onOpen: { openArticle($0, fromRecommendation: true) }, onDislike: { markNotInterested($0.id) })
            }
            .overlay(alignment: .bottom) {
                if !pendingDisinterest.isEmpty && opened == nil {
                    disinterestUndoNotice.padding(.bottom, 55)
                }
            }
        } else { magazineCards }
    }

    private var magazineCards: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    editionHeader
                        .magazineReveal(paused: opened != nil)
                    collectionBar
                        .onScrollVisibilityChange(threshold: 0.01) { collectionBarVisible = $0 }
                    if !initialLoadFinished && rows.isEmpty {
                        magazineLoading
                    } else if !store.isStorageConfigured {
                        ContentUnavailableView {
                            Label("Your reading life, in one place.", systemImage: "books.vertical")
                        } description: {
                            Text("Choose your sync folder, then add the publications you love.")
                        } actions: {
                            Button("Choose Sync Folder", action: chooseSyncFolder).buttonStyle(MagazineGlassButtonStyle())
                        }
                        .frame(maxWidth: .infinity, minHeight: 320)
                    } else if collectionIsEmpty {
                        if store.isSearching { magazineLoading }
                        else { emptyCollection }
                    } else {
                        if isRecommendationList && rankedScope != recommendationScope {
                            magazineLoading
                        }
                        if showsFeaturedStory && store.activeSearchQuery.isEmpty {
                            if let lead = leadRow { card(lead, lead: true) }
                            else if !recommendationLoaded { magazineLoading }
                            else {
                                HStack {
                                    Text("You're all caught up on recommendations.").foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Show recommendations again") { recommendations.restoreRecommendations() }
                                        .buttonStyle(MagazineGlassButtonStyle())
                                }.padding(24).background(NookTheme.card, in: RoundedRectangle(cornerRadius: 18))
                            }
                        }
                        HStack {
                            Text(sectionTitle)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Rectangle().fill(.primary.opacity(0.09)).frame(height: 1)
                            if store.activeSearchQuery.isEmpty {
                                if isUnreadCollection { readingOrderPicker }
                            } else if !store.isSearching && !store.searchUsesMeaning {
                                Button("Enable natural-language search") { searchSetup = true }
                                    .buttonStyle(MagazinePlainButtonStyle())
                                    .popover(isPresented: $searchSetup) { RecommendationModelSettings(onReady: store.refreshArticleSearch).padding(24).frame(width: 390) }
                            } else {
                                Text("Results by relevance").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if isRecommendationList {
                            Text(recommendationsEnabled
                                 ? "Every unread story, ranked for you. Your choices and reading shape the next picks."
                                 : "All unread stories are included. Turn on personalization in Settings to rank them by your interests.")
                                .font(.callout).foregroundStyle(.secondary)
                            if rankedScope == recommendationScope && rankedRecommendations.isEmpty {
                                Button("Show recommendations again") { recommendations.restoreRecommendations() }
                                    .buttonStyle(MagazineGlassButtonStyle())
                            }
                        }
                        let columns = min(3, max(1, Int((geometry.size.width - 96) / 300)))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 22, alignment: .top), count: columns),
                                  alignment: .leading, spacing: 22) {
                            ForEach(rows.filter { $0.id != leadRow?.id }) { row in card(row, lead: false) }
                        }
                    }
                }
                .padding(.horizontal, 48).padding(.top, 34).padding(.bottom, 140)
                .frame(maxWidth: 1280)
                .frame(maxWidth: .infinity)
            }
            .scrollPosition($scrollPosition)
            .onScrollPhaseChange { _, phase in titleTranslator.setScrolling(phase != .idle) }
            .onDisappear { titleTranslator.setScrolling(false) }
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    if !pendingDisinterest.isEmpty && opened == nil {
                        disinterestUndoNotice
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                    if !collectionBarVisible && opened == nil && libraryScope == nil {
                        collectionTabs
                            .padding(7)
                            .glassEffect(.regular.tint(NookTheme.accent.opacity(0.07)), in: Capsule())
                            .shadow(color: .black.opacity(0.16), radius: 20, y: 6)
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.36, bounce: 0.12), value: collectionBarVisible)
        }
    }

    private var emptyCollection: some View {
        let state = libraryFolderIsEmpty && store.activeSearchQuery.isEmpty ? ArticleEmptyState.folder : store.articleEmptyState
        return ContentUnavailableView {
            Label(state.title, systemImage: state.symbol)
        } description: {
            Text(state.message)
        } actions: {
            switch state {
            case .search:
                if !store.searchUsesMeaning {
                    Button("Enable natural-language search") { searchSetup = true }
                        .popover(isPresented: $searchSetup) {
                            RecommendationModelSettings(onReady: store.refreshArticleSearch).padding(24).frame(width: 390)
                        }
                }
                Button("Clear Search") { store.searchText = ""; searchFocused = true }
            case .subscriptions:
                Button("Add Feed") { addingFeed = true }
            case .feed, .today, .all:
                Button("Refresh") {
                    if store.feedSelection.isEmpty { store.refreshAll() }
                    else { store.refreshFeeds(ids: store.selectedFeedIDs) }
                }.disabled(store.isRefreshing)
                Button("View All Articles", action: showAllArticles)
            case .folder:
                Button("Back to Library") { libraryScope = nil; tab = .library }
            default:
                Button("View All Articles", action: showAllArticles)
            }
        }
        .buttonStyle(MagazineGlassButtonStyle())
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private func showAllArticles() {
        libraryScope = nil
        pendingRecommendation = nil
        store.searchText = ""
        store.selectSmartSource(.all)
        tab = .magazine
    }

    private var magazineLoading: some View {
        VStack(alignment: .leading, spacing: 20) {
            ProgressView().controlSize(.small)
            Text(store.bootstrapPhase?.label ?? String(localized: "Loading your articles…"))
                .font(.callout).foregroundStyle(.secondary)
            ForEach(0..<3) { index in
                RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.05))
                    .frame(maxWidth: index == 0 ? 700 : 500, minHeight: index == 0 ? 24 : 12)
            }
        }
        .padding(32).frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 18))
    }

    private var editionHeader: some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "sun.max").font(.system(size: 12, weight: .medium))
                    Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                MagazineHeadline(libraryScope ?? store.selectedSourceTitle, size: 40)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                MagazineTrendTicker(articles: store.visibleArticles,
                                    sourceID: String(store.magazineContentRevision),
                                    active: opened == nil && isBrowsingMagazine,
                                    openArticle: { openArticle($0) })
                Group {
                    if store.activeSearchQuery.isEmpty {
                        Text("\(libraryFolderIsEmpty ? 0 : store.listWindow.totalCount) stories")
                    } else {
                        Text("\(store.listWindow.totalCount) results")
                    }
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var collectionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                collectionScope.fixedSize()
                Spacer(minLength: 0)
                collectionSearch
            }
            VStack(alignment: .leading, spacing: 14) {
                collectionScope
                collectionSearch
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder private var collectionScope: some View {
        if libraryScope == nil {
            collectionTabs
                .padding(4).glassEffect(.regular.tint(NookTheme.accent.opacity(0.07)), in: Capsule())
        } else {
            Label("Stories in this collection", systemImage: "rectangle.stack")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var collectionSearch: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(searchFocused ? NookTheme.accent : .secondary)
            TextField("Search by keyword or meaning", text: $store.searchText).textFieldStyle(.plain)
                .focused($searchFocused)
            if store.isSearching { ProgressView().controlSize(.mini) }
            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                    searchFocused = true
                } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(MagazinePlainButtonStyle()).foregroundStyle(.secondary)
                    .accessibilityLabel("Clear Search")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 13).frame(width: searchFocused ? 290 : 230, height: 36)
        .glassEffect(.regular.tint(NookTheme.accent.opacity(0.07)), in: Capsule())
        .overlay {
            Capsule().strokeBorder(NookTheme.accent.opacity(searchFocused ? 0.5 : 0), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: searchFocused)
    }

    private var sectionTitle: LocalizedStringKey {
        if !store.activeSearchQuery.isEmpty { return "Search results" }
        if store.smartSelection == .recent { return "Recently opened" }
        return isRecommendationList ? "Recommended for you" : "From your subscriptions"
    }

    private var readingOrderPicker: some View {
        HStack(spacing: 2) {
            readingOrderButton("Recommended", recommended: true)
            readingOrderButton("Newest", recommended: false)

        }
        .padding(3)
        .glassEffect(.regular.tint(NookTheme.accent.opacity(0.07)), in: Capsule())
    }

    private func readingOrderButton(_ title: LocalizedStringKey, recommended: Bool) -> some View {
        Button {
            prefersRecommendationOrder = recommended
            if !recommended && store.sortOrder(for: .unread) != .newest { store.toggleSortOrder(for: .unread) }
        } label: {
            Text(title).font(.system(size: 11, weight: .medium))
                .foregroundStyle(prefersRecommendationOrder == recommended ? NookTheme.accent : .secondary)
                .padding(.horizontal, 12).frame(height: 28)
                .background(prefersRecommendationOrder == recommended ? NookTheme.accent.opacity(0.14) : .clear, in: Capsule())
        }
        .buttonStyle(MagazinePlainButtonStyle(capsule: true))
        .accessibilityAddTraits(prefersRecommendationOrder == recommended ? .isSelected : [])
    }

    private var collectionTabs: some View {
        HStack(spacing: 4) {
            ForEach(SmartSource.library) { source in
                Button { store.selectSmartSource(source) } label: {
                    Label(source.title, systemImage: source.systemImage)
                        .font(.system(size: 12, weight: .medium)).labelStyle(.titleAndIcon)
                        .foregroundStyle(store.smartSelection == source ? NookTheme.accent : .secondary)
                        .padding(.horizontal, 13).frame(height: 32)
                        .background(store.smartSelection == source ? NookTheme.accent.opacity(0.17) : .clear, in: Capsule())
                }
                .buttonStyle(MagazinePlainButtonStyle(capsule: true))
                .accessibilityLabel(Text(source.title))
                .accessibilityAddTraits(store.smartSelection == source ? .isSelected : [])
            }
        }
    }

    private var rows: [ArticleRowModel] {
        if let frozenRows { return frozenRows }
        guard isRecommendationList else { return store.listWindow.rows }
        guard rankedScope == recommendationScope else { return [] }
        return rankedRecommendations.prefix(recommendationWindow).compactMap { pick in
            guard !recommendations.isNotInterested(pick.articleID), store.listWindow.contains(pick.articleID),
                  let article = store.listedArticle(withID: pick.articleID), !article.isRead else { return nil }
            return ArticleRowModel(article, feedDisplayTitle: store.feed(for: article.feedID)?.displayTitle,
                                   isSavedOffline: store.isOfflineSaved(article.id))
        }
    }

    private var leadRow: ArticleRowModel? {
        if let frozenLead { return frozenLead }
        guard showsFeaturedStory, store.activeSearchQuery.isEmpty, let recommendation,
              store.listWindow.contains(recommendation.articleID),
              let article = store.listedArticle(withID: recommendation.articleID) else { return nil }
        return ArticleRowModel(article, feedDisplayTitle: store.feed(for: article.feedID)?.displayTitle, isSavedOffline: false)
    }

    private var readingOrder: [ArticleRowModel] {
        if let frozenRows { return frozenRows }
        if isRecommendationMap {
            return recommendationMap.readerArticleIDs.compactMap { id in
                guard let article = store.listedArticle(withID: id) else { return nil }
                return ArticleRowModel(article, feedDisplayTitle: store.feed(for: article.feedID)?.displayTitle,
                    isSavedOffline: store.isOfflineSaved(id))
            }
        }
        guard let lead = leadRow else { return rows }
        return [lead] + rows.filter { $0.id != lead.id }
    }

    @ViewBuilder private func card(_ row: ArticleRowModel, lead: Bool) -> some View {
        if let article = store.listedArticle(withID: row.id) {
            Button { openArticle(article.id, fromRecommendation: isRecommendationList || lead) } label: {
                VStack(alignment: .leading, spacing: lead ? 20 : 18) {
                    if lead {
                        Label(recommendation?.personalized == true ? "Picked for you" : "Fresh from your subscriptions",
                              systemImage: recommendation?.personalized == true ? "bookmark" : "sun.max")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(NookTheme.accent)
                            .padding(.trailing, 210)
                            .help(recommendation?.personalized == true
                                ? Text("Based on your reading time, starred stories, and interests. Ranked on this Mac.")
                                : Text("Read and star stories to make future picks more personal."))
                    }
                    MagazineArticleHeading(article: article, feedTitle: row.feedDisplayTitle ?? "",
                                           namespace: hero, expanded: false, lead: lead, matched: opened != row.id,
                                           trailingControlSpace: isRecommendationList && !lead ? 38 : 0)
                    MagazineCategoryLabels(store.categories(forArticle: article))
                    MagazineTranslatedSummary(id: article.id, summary: article.summary, size: lead ? 15 : 13)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: lead ? 900 : .infinity, alignment: .leading)
                    Spacer(minLength: lead ? 8 : 0)
                    HStack(spacing: 8) {
                        if !article.isRead { Circle().fill(NookTheme.accent).frame(width: 5, height: 5) }
                        if store.smartSelection == .recent, let date = store.recentlyRead.opened[article.id] {
                            Image(systemName: "clock")
                            Text(date, format: .relative(presentation: .named))
                        } else {
                            Text(article.publishedAt, style: .date)
                        }
                        Text("·")
                        ArticleReadingTimeLabel(article: article, viewportBound: true)
                        Spacer()
                        if recommendations.isNotInterested(article.id) {
                            Image(systemName: "hand.thumbsdown").help("Excluded from recommendations")
                        }
                        if article.isStarred { Image(systemName: "star.fill").foregroundStyle(.orange) }
                        Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .medium))
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(lead ? 32 : 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(minHeight: lead ? 300 : 310, maxHeight: .infinity, alignment: .topLeading)
                .background {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(NookTheme.card)
                        .modifier(MagazineMatch(id: "surface-\(row.id)", namespace: hero, enabled: opened != row.id))
                }
                .opacity(opened == row.id ? 0 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(MagazineCardStyle())
            .overlay(alignment: .topTrailing) {
                if lead && opened == nil {
                    recommendationAction(row.id)
                        .padding(22)
                } else if isRecommendationList && opened == nil {
                    Button { markNotInterested(row.id) } label: {
                        Image(systemName: "hand.thumbsdown")
                    }
                    .buttonStyle(MagazineGlassButtonStyle())
                    .accessibilityLabel("Not interested")
                    .help("Remove this recommendation without marking it read. Similar topics will be recommended less.")
                    .padding(24)
                }
            }
            .magazineReveal(paused: opened != nil)
            .magazinePreviewDemand(active: opened == nil && store.isForegroundActive)
            .focused($focusedArticle, equals: row.id)
            .id(row.id)
            .contextMenu {
                if recommendations.isNotInterested(article.id) {
                    Button("Include in recommendations again", systemImage: "arrow.uturn.backward") {
                        recommendations.restoreRecommendation(article.id)
                    }
                    Divider()
                } else if isRecommendationList {
                    Button("Not interested", systemImage: "hand.thumbsdown") { markNotInterested(article.id) }
                    Divider()
                }
                ArticleRowMenu(store: store, id: article.id)
            }
            .task {
                guard opened == nil else { return }
                if isRecommendationList {
                    let scope = recommendationScope
                    let window = recommendationWindow
                    guard let index = rankedRecommendations.firstIndex(where: { $0.articleID == row.id }),
                          index >= window - 30, window < rankedRecommendations.count else { return }
                    await Task.yield()
                    guard !Task.isCancelled, opened == nil, scope == recommendationScope,
                          recommendationWindow == window else { return }
                    recommendationWindow += 120
                } else {
                    store.listWindow.rowAppeared(id: row.id)
                }
            }
        }
    }

    private func openArticle(_ id: Article.ID, fromRecommendation: Bool = false) {
        guard opened == nil, let article = store.listedArticle(withID: id) else { return }
        // A new click may interrupt a dismissal; use the current collection.
        dismissedArticle = nil
        frozenRows = nil
        frozenLead = nil
        let order = readingOrder
        frozenLead = leadRow
        frozenRows = order.contains(where: { $0.id == id }) ? order : [
            ArticleRowModel(article, feedDisplayTitle: store.feed(for: article.feedID)?.displayTitle, isSavedOffline: false)
        ] + order
        if fromRecommendation && recommendationsEnabled {
            recommendations.selectLibrary(store.syncFolderURL?.standardizedFileURL.path ?? "local")
            recommendations.recordSelection(articleID: id)
        }
        store.selectedArticleID = id
        store.retainArticle(id: id)
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0.08)) {
            opened = id
        }
    }

    private func closeArticle() {
        guard let id = opened else { return }
        // Deletion clears the store selection, but `opened` owns the Beta
        // overlay and its input lock. There is no source card to morph back to.
        // Drop the frozen snapshot too, so it cannot retain a deleted target.
        if store.article(withID: id) == nil && !store.isOfflineSaved(id) {
            opened = nil
            dismissedArticle = nil
            frozenRows = nil
            frozenLead = nil
            focusedArticle = nil
            return
        }
        dismissedArticle = id
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0.08)) {
            opened = nil
        }
    }

    private func closeBrowser() {
        store.isBrowserPresented = false
    }

    private func navigate(_ forward: Bool) {
        guard let row = adjacentRow(forward: forward) else { return }
        opened = row.id
        store.selectedArticleID = row.id
        store.retainArticle(id: row.id)
        if store.isBrowserPresented, let article = store.selectedArticle {
            store.browserMode = store.resolvedBrowserMode(for: article)
        }
    }

    private func adjacentRow(forward: Bool) -> ArticleRowModel? {
        let rows = readingOrder
        guard let opened, let index = rows.firstIndex(where: { $0.id == opened }) else { return nil }
        let next = index + (forward ? 1 : -1)
        return rows.indices.contains(next) ? rows[next] : nil
    }

    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    MagazineHeadline(String(localized: "Your library"), size: 40)
                    Spacer()
                    Button("Add Feed", systemImage: "plus") { addingFeed = true }.buttonStyle(MagazineGlassButtonStyle(prominent: true))
                    MagazineGlassMenu {
                        Button("Choose Sync Folder", action: chooseSyncFolder)
                        Button("Import OPML…") { importing = true }
                        Button("Export OPML…") { exporting = true }
                    } label: { Label("Manage", systemImage: "ellipsis") }
                }
                HStack {
                    ForEach(SmartSource.allCases) { source in
                        Button {
                            enterLibraryCollection(source.title) { store.selectSmartSource(source) }
                        } label: {
                            Label(source.title, systemImage: source.systemImage)
                        }.buttonStyle(MagazineGlassButtonStyle())
                    }
                }
                Divider()
                ForEach([""] + store.feedFolders, id: \.self) { folder in
                    VStack(alignment: .leading, spacing: 12) {
                        if !folder.isEmpty {
                            Button(folder, systemImage: "folder") { enterLibraryCollection(folder, folder: folder) { store.selectFolder(folder) } }
                                .buttonStyle(MagazinePlainButtonStyle()).font(.title2)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 18)], alignment: .leading, spacing: 18) {
                            ForEach(store.feeds(inFolder: folder)) { feed in
                                Button {
                                    enterLibraryCollection(feed.displayTitle) { store.selectFeed(feed.id) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Label(feed.displayTitle, systemImage: feed.systemImage).font(.headline)
                                        Text(feed.siteDescription).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                        Text("\(store.unreadCount(feedID: feed.id)) unread").font(.caption).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                                    .padding(20).background(NookTheme.card, in: RoundedRectangle(cornerRadius: 18))
                                }.buttonStyle(MagazineCardStyle())
                            }
                        }
                    }
                }
            }.padding(36).frame(maxWidth: 1320).frame(maxWidth: .infinity)
        }
        .scrollPosition($libraryPosition)
    }

    private var libraryBreadcrumb: some View {
        HStack(spacing: 14) {
            Button("Back to Library", systemImage: "arrow.left") {
                libraryScope = nil
                pendingRecommendation = nil
                store.searchText = ""
            }
            .buttonStyle(MagazineGlassButtonStyle())
            .keyboardShortcut("[", modifiers: .command)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            Text(libraryScope ?? "").font(.callout.weight(.medium)).lineLimit(1)
            Spacer()
            Button("All subscriptions", systemImage: "newspaper") {
                libraryScope = nil
                pendingRecommendation = nil
                store.searchText = ""
                store.selectSmartSource(.all)
                tab = .magazine
            }.buttonStyle(MagazineGlassButtonStyle())
        }
        .padding(.horizontal, 36).padding(.vertical, 12)
        .background(NookTheme.canvas)
    }

    private var libraryFolderIsEmpty: Bool {
        guard libraryScope != nil, let libraryFolder else { return false }
        return store.feeds(inFolder: libraryFolder).isEmpty
    }

    private func enterLibraryCollection(_ title: String, folder: String? = nil, select: () -> Void) {
        libraryFolder = folder
        store.searchText = ""
        pendingRecommendation = nil
        recommendation = nil
        recommendationLoaded = false
        select()
        libraryScope = title
        scrollPosition.scrollTo(edge: .top)
    }

    private func markNotInterested(_ articleID: Article.ID) {
        guard opened == nil else { return }
        recommendations.selectLibrary(store.syncFolderURL?.standardizedFileURL.path ?? "local")
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            pendingDisinterest.append(recommendations.markNotInterested(articleID))
        }
    }

    private var disinterestUndoNotice: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(pendingDisinterest.count) recommendations excluded")
                    .font(.system(size: 12, weight: .medium))
                if pendingDisinterest.contains(where: { store.listedArticle(withID: $0.articleID)?.isRead == true }) {
                    Text("Reading status is unchanged. You can find them in All Articles.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("Still unread. You can find them in Newest.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                    for undo in pendingDisinterest.reversed() { recommendations.undoDisinterest(undo) }
                    pendingDisinterest = []
                }
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(MagazineGlassButtonStyle())
            .help("Undo this recommendation change")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassEffect(.regular.tint(NookTheme.accent.opacity(0.07)), in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.16), radius: 16, y: 5)
    }

    @ViewBuilder private func recommendationAction(_ articleID: Article.ID) -> some View {
        if let pending = pendingRecommendation, pending.articleID == articleID {
            Button {
                recommendations.undoDismissal(pending)
                pendingRecommendation = nil
            } label: {
                HStack(spacing: 8) {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("\(max(0, Int(ceil(pending.deadline.timeIntervalSince(context.date)))))")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(MagazineGlassButtonStyle(prominent: true))
            .help("Undo this recommendation change")
        } else {
            Button("Show another story", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") {
                pendingRecommendation = recommendations.dismissRecommendation(articleID)
            }
            .buttonStyle(MagazineGlassButtonStyle())
            .help("A new recommendation in 3 seconds. You can undo until then.")
        }
    }

    private func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose iCloud Sync Folder")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: cloud.path) { panel.directoryURL = cloud }
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { store.configureSyncFolder(url) }
        }
        NSApp.activate()
        if let window = LayoutSelectionCoordinator.shared.readerWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private var commands: ReaderCommandActions? {
        guard tab != .studio else { return nil }
        return ReaderCommandActions(refreshAll: store.refreshAll, markSelectedRead: store.markSelectedRead,
                                    toggleSelectedStarred: store.toggleSelectedStarred,
                                    selectNextArticle: { navigate(true) }, selectPreviousArticle: { navigate(false) },
                                    toggleReaderMode: store.toggleBrowserMode)
    }
}

struct MagazineMatch: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    var enabled = true
    var properties: MatchedGeometryProperties = .frame
    func body(content: Content) -> some View {
        if enabled { content.matchedGeometryEffect(id: id, in: namespace, properties: properties, anchor: .topLeading) }
        else { content }
    }
}

struct MagazineArticleHeading: View {
    let article: Article
    let feedTitle: String
    let namespace: Namespace.ID
    var expanded = false
    var lead = false
    var matched = true
    var translatedTitle: String?
    var titleTranslating = false
    var openInApp: (() -> Void)?
    var trailingControlSpace: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(String(feedTitle.prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 23, height: 23)
                    .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 4) {
                    Text(feedTitle).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary).lineLimit(1)
                    MagazineAuthorLine(authors: article.authors, expanded: expanded)
                }
            }
            .padding(.trailing, trailingControlSpace)
            Group {
                if expanded {
                    ReaderArticleLink(url: article.url, openInApp: openInApp) { _ in
                        ReaderTranslatedTitle(original: article.title, translated: translatedTitle,
                                              translating: titleTranslating, size: 36)
                            .id(article.id)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(ReaderTitleButtonStyle())
                    .help("Open in Reader — ⌘-click to open in browser")
                } else {
                    MagazineTranslatedHeadline(id: article.id, title: article.title, size: lead ? 30 : 23)
                        .id("\(article.id)|\(article.title)")
                }
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(MagazineMatch(id: "title-\(article.id)", namespace: namespace, enabled: matched, properties: .position))
                .transition(.opacity)
            if expanded {
                MagazinePublicationDate(date: article.publishedAt)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            MagazineArticleThumbnail(article: article, height: expanded ? 240 : (lead ? 180 : 130), expanded: expanded, lead: lead)
                .id("\(article.id)|\(article.url)")
                .modifier(MagazineMatch(id: "image-\(article.id)", namespace: namespace, enabled: matched))

        }
    }
}
