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
    @State private var isTransitioning = false
    @State private var initialLoadFinished = false
    @State private var collectionBarVisible = true
    @State private var addingFeed = false
    @State private var importing = false
    @State private var exporting = false
    @State private var importRequest: MagazineOPMLImportRequest?
    @State private var imagePresenter = ArticleImagePresenter()
    @State private var draftSession: BetaDraftSession?
    @State private var browserOffset: CGFloat = 0
    @Namespace private var navigationSelection
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    @AppStorage("showUnreadBadge") private var showUnreadBadge = true
    @AppStorage("autoRefreshEnabled") private var autoRefresh = true
    @Namespace private var hero
    @FocusState private var focusedArticle: String?
    @FocusState private var searchFocused: Bool

    enum MagazineTab: String, CaseIterable {
        case magazine = "Magazine", library = "Library", studio = "Studio"
        var icon: String {
            switch self {
            case .magazine: "newspaper"
            case .library: "books.vertical"
            case .studio: "square.and.pencil"
            }
        }
    }

    var body: some View {
        ZStack {
            workspace
                .allowsHitTesting(opened == nil)
                .accessibilityHidden(opened != nil)
            if let opened {
                MagazineReaderDetail(store: store, articleID: opened, heroNamespace: hero,
                                     nextTitle: adjacentRow(forward: true)?.title,
                                     previousTitle: adjacentRow(forward: false)?.title,
                                     gesturesEnabled: !isTransitioning,
                                     onClose: closeArticle, onNavigate: navigate)
                    .background {
                        NookTheme.canvas
                            .matchedGeometryEffect(id: "surface-\(opened)", in: hero)
                    }
                    .safeAreaInset(edge: .top) { readerControls }
                    .zIndex(2)
                    .transition(reduceMotion ? .opacity : .identity)
            }
        }
        .background(NookTheme.canvas)
        .articleImageOverlay(imagePresenter)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 3) {
                    ForEach(MagazineTab.allCases, id: \.self) { item in
                        Button {
                            guard draftSession?.flush() != false, !isTransitioning else { return }
                            if opened != nil { closeArticle() }
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
                        .buttonStyle(.plain)
                        .help(Text(LocalizedStringKey(item.rawValue)))
                        .accessibilityLabel(Text(LocalizedStringKey(item.rawValue)))
                    }
                }
                .padding(3)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Refresh All", systemImage: "arrow.clockwise") { store.refreshAll() }
                    .disabled(store.isRefreshing || store.feeds.isEmpty)
                Button("Settings", systemImage: "gearshape") { openSettings() }
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
        .sheet(isPresented: $store.isBrowserPresented) {
            if let article = store.selectedArticle {
                MagazineBrowserPanel(store: store, article: article, style: ReaderStyle(),
                                     linkOpensInApp: true, dragOffset: $browserOffset) { store.isBrowserPresented = false }
                    .frame(minWidth: 800, minHeight: 600)
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
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
            LayoutSelectionCoordinator.shared.prepareToLeave = { draftSession?.flush() ?? true }
        }
        .onDisappear { LayoutSelectionCoordinator.shared.prepareToLeave = nil }
        .onOpenURL { handleLayoutURL($0) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.syncFromDisk()
            if autoRefresh { store.refreshOnActivation(honorThrottle: true) }
        }
        .onChange(of: showUnreadBadge) { _, value in store.showsUnreadBadge = value }
        .onChange(of: store.searchText, initial: true) { _, _ in
            store.debounceSearch()
        }
        .onChange(of: store.activeSearchQuery) { _, _ in
            scrollPosition.scrollTo(edge: .top)
        }
        .focusedSceneValue(\.readerCommandActions, commands)
    }

    @ViewBuilder private var workspace: some View {
        switch tab {
        case .magazine: magazine
        case .library: library
        case .studio: BetaStudioView(store: plus, session: $draftSession)
        }
    }

    private var magazine: some View {
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
                    } else if rows.isEmpty && !store.activeSearchQuery.isEmpty {
                        ContentUnavailableView {
                            Label("No search results", systemImage: "magnifyingglass")
                        } description: {
                            Text("No article matches the current search.")
                        } actions: {
                            Button("Clear Search") {
                                store.searchText = ""
                                searchFocused = true
                            }.buttonStyle(MagazineGlassButtonStyle())
                        }
                        .frame(maxWidth: .infinity, minHeight: 320)
                    } else if rows.isEmpty {
                        ContentUnavailableView {
                            Label("Room for your next story.", systemImage: "newspaper")
                        } description: {
                            Text("Add a feed or choose another collection to start reading.")
                        } actions: {
                            Button("Add Feed") { addingFeed = true }.buttonStyle(MagazineGlassButtonStyle())
                        }
                        .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        if let lead = rows.first { card(lead, lead: true) }
                        HStack {
                            Text(store.activeSearchQuery.isEmpty ? "From your subscriptions" : "Search results")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Rectangle().fill(.primary.opacity(0.09)).frame(height: 1)
                        }
                        let columns = min(3, max(1, Int((geometry.size.width - 96) / 300)))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 22, alignment: .top), count: columns),
                                  alignment: .leading, spacing: 22) {
                            ForEach(rows.dropFirst()) { row in card(row, lead: false) }
                        }
                    }
                }
                .padding(.horizontal, 48).padding(.top, 34).padding(.bottom, 96)
                .frame(maxWidth: 1280)
                .frame(maxWidth: .infinity)
            }
            .scrollPosition($scrollPosition)
            .overlay(alignment: .bottom) {
                if !collectionBarVisible && opened == nil {
                    collectionTabs
                        .padding(7)
                        .glassEffect(.regular.tint(NookTheme.accent.opacity(0.07)), in: Capsule())
                        .shadow(color: .black.opacity(0.16), radius: 20, y: 6)
                        .padding(.bottom, 20)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.36, bounce: 0.12), value: collectionBarVisible)
        }
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
                MagazineHeadline(store.selectedSourceTitle, size: 40)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                MagazineTrendTicker(articles: store.libraryArticles,
                                    sourceID: rows.first?.id ?? "empty",
                                    active: opened == nil && tab == .magazine)
                Group {
                    if store.activeSearchQuery.isEmpty {
                        Text("\(store.listWindow.totalCount) stories")
                    } else {
                        Text("\(store.listWindow.totalCount) results")
                    }
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var collectionBar: some View {
        HStack(spacing: 16) {
            collectionTabs
            .padding(4).glassEffect(.regular.tint(NookTheme.accent.opacity(0.07)), in: Capsule())
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(searchFocused ? NookTheme.accent : .secondary)
                TextField("Search Articles", text: $store.searchText).textFieldStyle(.plain)
                    .focused($searchFocused)
                if !store.searchText.isEmpty {
                    Button {
                        store.searchText = ""
                        searchFocused = true
                    } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
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
        .padding(.bottom, 4)
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
                .buttonStyle(.plain)
                .accessibilityLabel(Text(source.title))
                .accessibilityAddTraits(store.smartSelection == source ? .isSelected : [])
            }
        }
    }

    private var rows: [ArticleRowModel] { frozenRows ?? store.listWindow.rows }

    @ViewBuilder private func card(_ row: ArticleRowModel, lead: Bool) -> some View {
        if let article = store.listedArticle(withID: row.id) {
            Button { openArticle(article.id) } label: {
                VStack(alignment: .leading, spacing: lead ? 20 : 18) {
                    MagazineArticleHeading(article: article, feedTitle: row.feedDisplayTitle ?? "",
                                           namespace: hero, expanded: false, lead: lead, matched: opened != row.id)
                    Text(article.summary)
                        .font(.system(size: lead ? 15 : 13))
                        .foregroundStyle(.secondary).lineSpacing(5).lineLimit(3)
                        .frame(maxWidth: lead ? 900 : .infinity, alignment: .leading)
                    Spacer(minLength: lead ? 8 : 0)
                    HStack(spacing: 8) {
                        if !article.isRead { Circle().fill(NookTheme.accent).frame(width: 5, height: 5) }
                        Text(article.publishedAt, style: .date)
                        Text("·")
                        Text("\(article.estimatedReadMinutes) min read")
                        Spacer()
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
            .magazineReveal(paused: opened != nil)
            .focused($focusedArticle, equals: row.id)
            .id(row.id)
            .contextMenu { ArticleRowMenu(store: store, id: article.id) }
            .onAppear { if opened == nil { store.listWindow.rowAppeared(id: row.id) } }
        }
    }

    private var readerControls: some View {
        HStack {
            Button("Back to Magazine", systemImage: "arrow.left", action: closeArticle)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Previous Article", systemImage: "chevron.left") { navigate(false) }
                .disabled(adjacentRow(forward: false) == nil)
            Button("Next Article", systemImage: "chevron.right") { navigate(true) }
                .disabled(adjacentRow(forward: true) == nil)
        }
        .buttonStyle(MagazineGlassButtonStyle()).padding(.horizontal, 32).padding(.vertical, 14)
    }

    private func openArticle(_ id: Article.ID) {
        guard !isTransitioning, opened == nil else { return }
        frozenRows = store.listWindow.rows
        store.selectedArticleID = id
        store.retainArticle(id: id)
        isTransitioning = true
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0.08), completionCriteria: .logicallyComplete) {
            opened = id
        } completion: { isTransitioning = false }
    }

    private func closeArticle() {
        guard let id = opened, !isTransitioning else { return }
        isTransitioning = true
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0.08), completionCriteria: .logicallyComplete) {
            opened = nil
        } completion: {
            frozenRows = nil
            focusedArticle = id
            isTransitioning = false
        }
    }

    private func navigate(_ forward: Bool) {
        guard !isTransitioning, let row = adjacentRow(forward: forward) else { return }
        opened = row.id
        store.selectedArticleID = row.id
        store.retainArticle(id: row.id)
    }

    private func adjacentRow(forward: Bool) -> ArticleRowModel? {
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
                    Button("Add Feed", systemImage: "plus") { addingFeed = true }.buttonStyle(.glassProminent)
                    MagazineGlassMenu {
                        Button("Choose Sync Folder", action: chooseSyncFolder)
                        Button("Import OPML…") { importing = true }
                        Button("Export OPML…") { exporting = true }
                    } label: { Label("Manage", systemImage: "ellipsis") }
                }
                HStack {
                    ForEach(SmartSource.allCases) { source in
                        Button {
                            store.selectSmartSource(source); tab = .magazine
                        } label: {
                            Label(source.title, systemImage: source.systemImage)
                        }.buttonStyle(MagazineGlassButtonStyle())
                    }
                }
                Divider()
                ForEach([""] + store.feedFolders, id: \.self) { folder in
                    VStack(alignment: .leading, spacing: 12) {
                        if !folder.isEmpty {
                            Button(folder, systemImage: "folder") { store.selectFolder(folder); tab = .magazine }
                                .buttonStyle(.plain).font(.title2)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 18)], alignment: .leading, spacing: 18) {
                            ForEach(store.feeds(inFolder: folder)) { feed in
                                Button {
                                    store.selectFeed(feed.id); tab = .magazine
                                } label: {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Label(feed.displayTitle, systemImage: feed.systemImage).font(.headline)
                                        Text(feed.siteDescription).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                        Text("\(store.unreadCount(feedID: feed.id)) unread").font(.caption).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                                    .padding(20).background(NookTheme.card, in: RoundedRectangle(cornerRadius: 16))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }.padding(36).frame(maxWidth: 1320).frame(maxWidth: .infinity)
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
    @State private var coverURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(String(feedTitle.prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 23, height: 23)
                    .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                Text(feedTitle).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            MagazineHeadline(article.title, size: expanded ? 36 : (lead ? 30 : 23), lines: expanded ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(MagazineMatch(id: "title-\(article.id)", namespace: namespace, enabled: matched, properties: .position))
                .transition(.opacity)
            if let coverURL {
                AsyncImage(url: coverURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                            .frame(maxWidth: .infinity).frame(height: expanded ? 240 : (lead ? 180 : 130))
                            .clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                            .modifier(MagazineMatch(id: "image-\(article.id)", namespace: namespace, enabled: matched))
                    }
                }
            }

        }
        .task(id: article.id) {
            let html = article.contentHTML
            let base = article.url
            let url = await Task.detached {
                guard let html,
                      let regex = try? NSRegularExpression(pattern: #"<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive),
                      let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                      let range = Range(match.range(at: 1), in: html),
                      let url = URL(string: String(html[range]).replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)?.absoluteURL,
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return URL?.none }
                return url
            }.value
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            if !Task.isCancelled { coverURL = url }
        }
    }
}
