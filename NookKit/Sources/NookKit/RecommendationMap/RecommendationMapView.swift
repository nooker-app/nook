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
    @State private var showSetup = false
    @State private var showInfo = false

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
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    MagazineHeadline(String(localized: "Follow your curiosity.", bundle: .module), size: 29)
                    Text("Start with a story. Discover the ideas around it.", bundle: .module)
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showInfo.toggle() } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel(Text("About the map", bundle: .module))
                    .buttonStyle(MagazineGlassButtonStyle())
                    .popover(isPresented: $showInfo) { mapInfo }
            }.padding(.horizontal, 30).padding(.top, 22).padding(.bottom, 22)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        filters
                        RecommendationMapCanvas(model: model)
                    }
                    Rectangle().fill(NookTheme.hairline).frame(width: 1)
                    inspector.frame(width: min(326, max(245, geometry.size.width * 0.29)))
                }
            }
            footer
        }
        .background(NookTheme.canvas)
        .task { await setup.check() }
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
                TextField(String(localized: "Find a story", bundle: .module), text: $search)
                    .textFieldStyle(.plain)
                    .onChange(of: search) { _, value in showSearch = !value.trimmingCharacters(in: .whitespaces).isEmpty }
            }
            .font(.system(size: 11)).padding(.horizontal, 12).frame(width: 180, height: 32)
            .glassEffect(.regular, in: .capsule)
            .popover(isPresented: $showSearch, arrowEdge: .bottom) {
                let matches = model.graph.nodes.filter { $0.article.title.localizedCaseInsensitiveContains(search) }.prefix(8)
                VStack(alignment: .leading, spacing: 4) {
                    if matches.isEmpty { Text("No matching stories", bundle: .module).padding(12).foregroundStyle(.secondary) }
                    ForEach(Array(matches)) { node in
                        Button {
                            model.select(node.id)
                            model.focusRequest += 1
                            showSearch = false
                            search = ""
                        } label: {
                            HStack(alignment: .top) {
                                Image(systemName: node.article.isRead ? "checkmark.circle" : "circle.fill")
                                    .foregroundStyle(recommendationTopicColor(node.topic)).font(.system(size: 10))
                                Text(node.article.title).lineLimit(2).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(MagazinePlainButtonStyle())
                    }
                }.font(.system(size: 12)).padding(8).frame(width: 340)
            }
        }.padding(.horizontal, 24).padding(.bottom, 12)
    }

    private func topicButton(_ topic: String?) -> some View {
        Button { model.topic = model.topic == topic ? nil : topic } label: {
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
            if let progress = model.indexingProgress {
                ProgressView().controlSize(.mini)
                Text("Connecting stories: \(progress.0) / \(progress.1)", bundle: .module)
            } else {
                Image(systemName: "externaldrive").foregroundStyle(NookTheme.accent)
                Text("\(model.graph.nodes.filter { !$0.article.isRead }.count) unread · \(model.graph.nodes.filter { $0.article.isRead }.count) read", bundle: .module)
            }
            Spacer(minLength: 8)
            if let error = model.error { Text(error).lineLimit(1).help(error) }
            if !setup.ready {
                Button { showSetup.toggle() } label: {
                    Label(String(localized: "Enable deeper connections", bundle: .module), systemImage: "arrow.down.circle")
                }
                .buttonStyle(MagazinePlainButtonStyle(capsule: true))
                .popover(isPresented: $showSetup) { RecommendationModelSettings().buttonStyle(MagazineGlassButtonStyle()).padding(24).frame(width: 390) }
            }
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 26).frame(height: 42)
    }

    private var mapInfo: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("About the map", bundle: .module).font(.headline)
            Text("Numbers show unread recommendation ranks. Dimmed points with a checkmark are stories you have read. Colors show categories; connections compare the actual titles and content, even across categories.", bundle: .module)
            Text("Cached original articles are included. Otherwise, Nook uses the content provided by the feed. Connections help you explore related ideas; they do not explain why a story was recommended.", bundle: .module)
            Text("Select a point to preview, double-click to read. Scroll to pan, pinch or use the wheel to zoom, and drag a point to explore its neighborhood. Search also finds stories you have read.", bundle: .module)
            RecommendationModelSettings()
        }.font(.callout).lineSpacing(4).padding(24).frame(width: 390).buttonStyle(MagazineGlassButtonStyle())
    }
}

private struct RecommendationMapCanvas: View {
    @Bindable var model: RecommendationMapController
    @State private var control = RecommendationCanvasControl()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RecommendationCanvasHost(model: model, control: control, reduceMotion: reduceMotion)
            .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            .onChange(of: model.focusRequest) { _, _ in control.view?.updateSelection(model.selectedID); control.focus() }
            .overlay(alignment: .topLeading) {
                Text("Scroll to pan · Pinch to zoom · Drag to explore", bundle: .module)
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(20).allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                HStack(spacing: 12) {
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
            .overlay {
                if model.loading && model.graph.nodes.isEmpty {
                    ProgressView(String(localized: "Building your map…", bundle: .module)).padding(25).glassEffect(.regular, in: .rect(cornerRadius: 20))
                } else if model.graph.nodes.isEmpty {
                    ContentUnavailableView(String(localized: "No stories to connect", bundle: .module), systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text("Your articles will appear here as your library grows.", bundle: .module))
                }
            }
    }
}
#endif
