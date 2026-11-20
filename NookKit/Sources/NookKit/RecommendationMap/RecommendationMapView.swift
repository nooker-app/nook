#if os(macOS)
import SwiftUI

func recommendationTopicColor(_ topic: String) -> Color {
    switch topic.lowercased() {
    case "ai": NookTheme.accent
    case "it", "개발": Color(red: 0.49, green: 0.68, blue: 0.77)
    case "보안": Color(red: 0.72, green: 0.59, blue: 0.80)
    case "사회", "경제": Color(red: 0.76, green: 0.54, blue: 0.47)
    default: Color(red: 0.48, green: 0.66, blue: 0.55)
    }
}

public struct RecommendationMapView: View {
    @Bindable private var model: RecommendationMapController
    private let store: ReaderStore
    private let feedback: MagazineRecommendationController
    private let personalized: Bool
    private let active: Bool
    private let onOpen: (String) -> Void
    private let onDislike: (Article) -> Void
    @State private var setup = RecommendationModelSetup.shared
    @State private var search = ""
    @State private var showSearch = false
    @State private var searchIDs: [String] = []
    @State private var searchSelection = ArticleSearchSelection()
    @State private var resultsQuery = ""
    @State private var searching = false
    @State private var searchUsesMeaning = false
    @State private var showSetup = false
    @State private var showInfo = false
    @State private var showSearchSetup = false
    @AppStorage("recommendationMapIntroductionVersion") private var introductionVersion = 0

    public init(model: RecommendationMapController, store: ReaderStore,
                feedback: MagazineRecommendationController, personalized: Bool,
                active: Bool, onOpen: @escaping (String) -> Void,
                onDislike: @escaping (Article) -> Void) {
        self.model = model
        self.store = store
        self.feedback = feedback
        self.personalized = personalized
        self.active = active
        self.onOpen = onOpen
        self.onDislike = onDislike
    }

    private var refreshID: String {
        "\(store.magazineContentRevision)|\(store.syncFolderURL?.path ?? "local")|\(feedback.revision)|\(personalized)|\(setup.ready)|\(active)"
    }

    public var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        filters.zIndex(1)
                        RecommendationMapCanvas(model: model)
                            .overlay(alignment: .topLeading) {
                                if active && setup.checked && !setup.ready && !setup.downloading
                                    && RecommendationModelSetup.supported && introductionVersion < 1 && !model.graph.nodes.isEmpty {
                                    RecommendationMapIntroduction {
                                        introductionVersion = 1
                                        showSetup = true
                                    } onLater: { introductionVersion = 1 }
                                    .padding(20).frame(maxWidth: 400)
                                }
                            }
                    }
                    Rectangle().fill(NookTheme.hairline).frame(width: 1)
                    inspector.frame(width: min(326, max(245, geometry.size.width * 0.29)))
                }
            }
            footer
        }
        .background(NookTheme.canvas)
        .task { await setup.check() }
        .onChange(of: store.smartSelection, initial: true) { _, source in
            model.setCollection(source ?? .all, recentlyOpened: store.recentlyRead.opened)
        }
        .onChange(of: store.recentlyRead.opened) { _, opened in
            model.setCollection(store.smartSelection ?? .all, recentlyOpened: opened)
        }
        .task(id: "\(search)|\(model.graphRevision)|\(setup.ready)|\(active)") {
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            guard active, !query.isEmpty else { searching = false; searchIDs = []; return }
            if resultsQuery != query { searchIDs = []; searchSelection.id = nil }
            resultsQuery = query
            searching = true
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await store.searchArticles(query: query, candidates: model.graph.nodes.map(\.article)) { update in
                guard !Task.isCancelled, search.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                searchIDs = Array(update.ids.prefix(20))
                searchSelection.reconcile(searchIDs)
                searching = update.isSearching
                searchUsesMeaning = update.usesMeaning
            }
        }
        .task(id: refreshID) {
            model.isInteractive = active
            model.onOpen = onOpen
            setup.retainModels(active)
            guard active else { model.pause(); return }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            await model.refresh(store: store, feedback: feedback, personalized: personalized, modelsReady: setup.ready)
        }
        .onDisappear { model.pause(); model.isInteractive = false; model.onOpen = nil; setup.retainModels(false) }
    }

    private var filters: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    topicButton(nil)
                    ForEach(model.graph.topics, id: \.self) { topicButton($0) }
                }
            }.scrollIndicators(.never)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                ArticleSearchField(text: $search, move: moveSearchSelection, submit: selectSearchResult, escape: dismissSearch)
                    .frame(height: 20)
                    .onChange(of: search) { _, value in
                        showSearch = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        if value.trimmingCharacters(in: .whitespacesAndNewlines) != resultsQuery {
                            searchIDs = []; searchSelection.id = nil
                        }
                    }
                if searching { ProgressView().controlSize(.mini) }
            }
            .font(.system(size: 11)).padding(.horizontal, 12).frame(width: 230, height: 32)
            .glassEffect(.regular, in: .capsule)
            .overlay(alignment: .topTrailing) {
                if showSearch {
                    searchResults
                        .glassEffect(.regular, in: .rect(cornerRadius: 14))
                        .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
                        .offset(y: 40)
                }
            }
            Button { showInfo.toggle() } label: { Image(systemName: "info.circle") }
                .accessibilityLabel(Text("About the map", bundle: .module))
                .buttonStyle(MagazineGlassButtonStyle())
                .popover(isPresented: $showInfo) { mapInfo }
        }.padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)
    }

    private var searchResults: some View {
        let lookup = Dictionary(uniqueKeysWithValues: model.graph.nodes.map { ($0.id, $0) })
        let matches = searchIDs.compactMap { lookup[$0] }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(searching ? "Searching your articles…" : searchUsesMeaning ? "Results by relevance" : "Keyword results", bundle: .module)
                Spacer()
                Text(verbatim: "↑ ↓  ·  ↩")
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 10)
            if matches.isEmpty && !searching { Text("No matching stories", bundle: .module).padding(12).foregroundStyle(.secondary) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(matches) { node in
                            Button { searchSelection.id = node.id; _ = selectSearchResult() } label: {
                                HStack(alignment: .top, spacing: 9) {
                                    Image(systemName: node.article.isRead ? "checkmark.circle" : "circle.fill")
                                        .foregroundStyle(recommendationTopicColor(node.topic)).font(.system(size: 10))
                                    Text(node.article.title).lineLimit(2).multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(searchSelection.id == node.id ? NookTheme.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(MagazinePlainButtonStyle()).id(node.id)
                            .accessibilityAddTraits(searchSelection.id == node.id ? .isSelected : [])
                        }
                    }
                }.frame(height: min(370, CGFloat(max(1, matches.count)) * 56))
                    .onChange(of: searchSelection.id) { _, id in if let id { proxy.scrollTo(id) } }
            }
            if !searching && !searchUsesMeaning {
                Button(String(localized: "Enable natural-language search", bundle: .module)) { showSearchSetup = true }
                    .buttonStyle(MagazinePlainButtonStyle()).padding(.horizontal, 10)
                    .popover(isPresented: $showSearchSetup) { RecommendationModelSettings().padding(24).frame(width: 390) }
            }
        }.font(.system(size: 12)).padding(10).frame(width: 380)
    }

    private func moveSearchSelection(_ delta: Int) -> Bool {
        guard !search.isEmpty else { return false }
        showSearch = true
        searchSelection.move(delta, in: searchIDs)
        return true
    }

    @discardableResult private func selectSearchResult() -> Bool {
        guard resultsQuery == search.trimmingCharacters(in: .whitespacesAndNewlines),
              let id = searchSelection.id, searchIDs.contains(id), model.graph.nodes.contains(where: { $0.id == id }) else { return false }
        model.select(id)
        model.focusRequest += 1
        showSearch = false
        search = ""
        return true
    }

    private func dismissSearch() -> Bool {
        if showSearch { showSearch = false; return true }
        guard !search.isEmpty else { return false }
        search = ""
        return true
    }

    private func topicButton(_ topic: String?) -> some View {
        Button { showSearch = false; model.topic = model.topic == topic ? nil : topic } label: {
            HStack(spacing: 5) {
                if let topic { Circle().fill(recommendationTopicColor(topic)).frame(width: 5, height: 5) }
                Text(topic ?? String(localized: "All", bundle: .module))
            }
            .font(.system(size: 11, weight: .medium)).padding(.horizontal, 11).frame(height: 30)
            .foregroundStyle(model.topic == topic ? NookTheme.accent : .secondary)
            .background(model.topic == topic ? NookTheme.accent.opacity(0.12) : .clear, in: Capsule())
        }
        .buttonStyle(MagazinePlainButtonStyle(capsule: true))
        .accessibilityAddTraits(model.topic == topic ? .isSelected : [])
    }

    private var inspector: some View {
        ScrollView {
            if let selected = model.selected {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Selected story", bundle: .module).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        if selected.article.isRead {
                            Image(systemName: "checkmark.circle").font(.system(size: 25, weight: .light)).foregroundStyle(.secondary)
                                .accessibilityLabel(Text("Read", bundle: .module))
                        } else {
                            Text(selected.rank, format: .number).font(.system(size: 25, weight: .light, design: .rounded)).foregroundStyle(NookTheme.accent)
                        }
                    }.padding(.bottom, 28)
                    HStack(spacing: 7) {
                        Circle().fill(recommendationTopicColor(selected.topic)).frame(width: 6, height: 6)
                        Text(selected.topic).foregroundStyle(recommendationTopicColor(selected.topic))
                        Spacer()
                        if selected.article.isRead { Text("Read", bundle: .module).foregroundStyle(.secondary) }
                    }.font(.system(size: 11)).padding(.bottom, 14)
                    MagazineHeadline(selected.article.title, size: 23)
                        .textSelection(.enabled).padding(.bottom, 16)
                    Text(selected.source).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(2).padding(.bottom, 6)
                    Text(selected.article.publishedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10)).foregroundStyle(.secondary).padding(.bottom, 20)
                    Text(selected.article.summary).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(5).lineLimit(7).padding(.bottom, 23)
                    HStack(spacing: 9) {
                        Button { onOpen(selected.id) } label: { Label(String(localized: "Read story", bundle: .module), systemImage: "arrow.up.right") }
                            .buttonStyle(MagazineGlassButtonStyle(prominent: true))
                        Button { onDislike(selected.article); model.exclude(selected.id) } label: { Image(systemName: "hand.thumbsdown") }
                            .buttonStyle(MagazineGlassButtonStyle())
                            .help(Text("Not interested", bundle: .module))
                            .accessibilityLabel(Text("Not interested", bundle: .module))
                    }
                    Divider().padding(.vertical, 26)
                    HStack {
                        Text("Continue exploring", bundle: .module).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if model.refiningID == selected.id { ProgressView().controlSize(.mini) }
                    }.padding(.bottom, 16)
                    if model.refiningID == selected.id {
                        Text("Looking more closely at these connections…", bundle: .module)
                            .font(.system(size: 10)).foregroundStyle(.secondary).padding(.bottom, 8)
                    }
                    if model.related.isEmpty {
                        Text("No close connections yet. Choose another point to keep exploring.", bundle: .module)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(model.related, id: \.0.id) { node, edge in
                        Button { model.select(node.id); model.focusRequest += 1 } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Circle().fill(recommendationTopicColor(node.topic)).frame(width: 6, height: 6).padding(.top, 5)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(node.article.title).font(.system(size: 12, weight: .medium)).lineSpacing(3).lineLimit(3)
                                    if node.article.isRead {
                                        Label(String(localized: "Read", bundle: .module), systemImage: "checkmark").font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Text(edge.terms.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(NookTheme.accent).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 3)
                            }.multilineTextAlignment(.leading).padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(MagazinePlainButtonStyle())
                    }
                }.padding(24)
            }
        }.background(NookTheme.card.opacity(0.3))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.preparation.isWorking {
                ProgressView().controlSize(.mini)
                if model.preparation.phase == .analyzing {
                    Text("Understanding stories: \(model.preparation.completed) / \(model.preparation.total)", bundle: .module)
                    Text(model.preparation.fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                } else if model.preparation.phase == .connecting {
                    Text("Arranging meaningful connections…", bundle: .module)
                } else {
                    Text("Preparing on-device analysis…", bundle: .module)
                }
            } else {
                Image(systemName: model.usesMeaning ? "point.3.connected.trianglepath.dotted" : "text.word.spacing")
                    .foregroundStyle(NookTheme.accent)
                Text(model.usesMeaning ? String(localized: "Meaning-based connections", bundle: .module)
                     : String(localized: "Word-based connections", bundle: .module))
                Text("\(model.graph.nodes.filter { !$0.article.isRead }.count) unread · \(model.graph.nodes.filter { $0.article.isRead }.count) read", bundle: .module)
            }
            Spacer(minLength: 8)
            if let error = model.error { Text(error).lineLimit(1).help(error) }
            if !setup.ready {
                Button { showSetup.toggle() } label: {
                    if setup.downloading {
                        Label {
                            Text("Downloading models", bundle: .module)
                            Text(setup.progress, format: .percent.precision(.fractionLength(0)))
                        } icon: { Image(systemName: "arrow.down.circle") }
                    } else {
                        Label(String(localized: "Enable deeper connections", bundle: .module), systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(MagazinePlainButtonStyle(capsule: true))
                .popover(isPresented: $showSetup) { RecommendationModelSettings().buttonStyle(MagazineGlassButtonStyle()).padding(24).frame(width: 390) }
            }
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 26).frame(height: 42)
    }

    private var mapInfo: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Text("About the map", bundle: .module).font(.headline)
            Text("Numbers show unread recommendation ranks. Dimmed points with a checkmark are stories you have read. Colors show categories; connections compare the actual titles and content, even across categories.", bundle: .module)
            Text("Cached original articles are included. Otherwise, Nook uses the content provided by the feed. Connections help you explore related ideas; they do not explain why a story was recommended.", bundle: .module)
            Text("Select a point to preview, double-click to read. In 3D, drag to rotate and Shift-drag to pan. Scroll to pan, pinch or use the wheel to zoom. Switch to 2D to drag individual points. Search also finds stories you have read.", bundle: .module)
            RecommendationModelSettings()
        }.font(.callout).lineSpacing(4).padding(24)
        }.frame(width: 390, height: 620).buttonStyle(MagazineGlassButtonStyle())
    }
}

private struct RecommendationMapCanvas: View {
    @Bindable var model: RecommendationMapController
    @State private var control = RecommendationCanvasControl()
    @AppStorage("recommendationMapSpatial") private var spatial = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RecommendationCanvasHost(model: model, control: control, reduceMotion: reduceMotion, spatial: spatial)
            .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            .onChange(of: model.focusRequest) { _, _ in control.view?.updateSelection(model.selectedID); control.focus() }
            .overlay(alignment: .bottom) {
                HStack(spacing: 12) {
                    Button { spatial.toggle() } label: {
                        Text(verbatim: spatial ? "3D" : "2D").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(spatial ? NookTheme.accent : .secondary)
                    }
                    .accessibilityValue(Text(verbatim: spatial ? "3D" : "2D"))
                    .help(Text("Switch between 2D and 3D", bundle: .module))
                    .accessibilityLabel(Text("Switch between 2D and 3D", bundle: .module))
                    Divider().frame(height: 14)
                    Button { control.fit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .help(Text("Fit map", bundle: .module)).accessibilityLabel(Text("Fit map", bundle: .module))
                    Divider().frame(height: 14)
                    Button { control.zoom(0.77) } label: { Image(systemName: "minus") }
                        .accessibilityLabel(Text("Zoom out", bundle: .module))
                    Text(control.zoomText).font(.system(size: 10, design: .monospaced)).frame(width: 35).foregroundStyle(.secondary)
                    Button { control.zoom(1.3) } label: { Image(systemName: "plus") }
                        .accessibilityLabel(Text("Zoom in", bundle: .module))
                    Divider().frame(height: 14)
                    Button { control.focus() } label: { Image(systemName: "location") }
                        .help(Text("Focus selected story", bundle: .module)).accessibilityLabel(Text("Focus selected story", bundle: .module))
                    Button { model.focus.toggle() } label: { Image(systemName: "scope").foregroundStyle(model.focus ? NookTheme.accent : .secondary) }
                        .help(Text("Focus on connections", bundle: .module)).accessibilityLabel(Text("Focus on connections", bundle: .module))
                        .accessibilityAddTraits(model.focus ? .isSelected : [])
                }
                .font(.system(size: 12)).buttonStyle(MagazinePlainButtonStyle(capsule: true))
                .padding(.horizontal, 18).padding(.vertical, 13).glassEffect(.regular, in: .capsule).padding(.bottom, 20)
            }
            .overlay(alignment: .topLeading) {
                if spatial && !model.graph.nodes.isEmpty {
                    Text("Drag to rotate · Scroll to pan · Pinch to zoom", bundle: .module)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(NookTheme.canvas.opacity(0.8), in: Capsule())
                        .padding(14).allowsHitTesting(false)
                }
            }
            .overlay {
                if model.loading && model.graph.nodes.isEmpty {
                    ProgressView(String(localized: "Building your map…", bundle: .module)).padding(25).glassEffect(.regular, in: .rect(cornerRadius: 20))
                } else if model.graph.nodes.isEmpty {
                    let empty = ArticleEmptyState.resolve(query: "", feedIDs: [], categoryID: nil,
                        smart: model.collection, hasSubscriptions: true)
                    ContentUnavailableView(empty.title, systemImage: empty.symbol, description: Text(empty.message))
                }
            }
    }
}
#endif
