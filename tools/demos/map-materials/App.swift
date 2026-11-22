import AppKit
import SwiftUI

@MainActor @Observable final class Study {
    var material = DemoMaterial.lens
    var dark = true
    var selectedID: String?
    let control = RecommendationCanvasControl()
    let snapshot: DemoSnapshot
    let graph: RecommendationGraph

    init() {
        let url = Bundle.main.url(forResource: "graph", withExtension: "json")!
        snapshot = try! JSONDecoder().decode(DemoSnapshot.self, from: Data(contentsOf: url))
        graph = RecommendationGraph(nodes: snapshot.nodes.enumerated().map { i, story in
            RecommendationMapNode(article: Article(id: story.id, title: story.title), rank: i + 1,
                position: CGPoint(x: story.x, y: story.y), clusterID: story.cluster)
        }, edges: snapshot.edges)
        selectedID = nil
    }
    var selected: DemoStory? { snapshot.nodes.first { $0.id == selectedID } }
    var related: [DemoStory] {
        guard let selectedID else { return [] }
        let ids = Set(snapshot.edges.compactMap { edge in
            edge.a == selectedID ? edge.b : edge.b == selectedID ? edge.a : nil
        })
        return Array(snapshot.nodes.filter { ids.contains($0.id) }.prefix(3))
    }
    func select(_ id: String) { selectedID = id; control.view?.updateSelection(id) }
}

struct MapSurface: NSViewRepresentable {
    var study: Study
    func makeNSView(context: Context) -> RecommendationCanvasView {
        let view = RecommendationCanvasView()
        study.control.view = view
        view.demoMaterial = study.material
        view.setSpatial(true)
        view.install(study.graph, revision: 1, layoutRevision: 1)
        view.onSelect = { study.select($0) }
        view.onZoom = { text in if study.control.zoomText != text { study.control.zoomText = text } }
        return view
    }
    func updateNSView(_ view: RecommendationCanvasView, context: Context) {
        view.demoMaterial = study.material
        let appearance = NSAppearance(named: study.dark ? .darkAqua : .aqua)
        if view.appearance?.name != appearance?.name { view.appearance = appearance }
        view.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

struct MaterialSample: View {
    var material: DemoMaterial
    var dark: Bool
    private static let glass = DemoGlassAtlas()
    private static let original = RecommendationSphereAtlas()
    var body: some View {
        let sprite = material == .original
            ? Self.original.palette([NSColor(srgbRed: 0.43, green: 0.65, blue: 0.54, alpha: 1)], dark: dark)[0][0]
            : Self.glass.images(material: material, dark: dark, sample: true)[0]
        ZStack {
            Canvas { context, size in
                var line = Path()
                line.move(to: CGPoint(x: 0, y: size.height * 0.85))
                line.addLine(to: CGPoint(x: size.width, y: size.height * 0.10))
                context.stroke(line, with: .color(NookTheme.accent.opacity(0.20)), lineWidth: 0.7)
                var second = Path()
                second.move(to: CGPoint(x: size.width * 0.15, y: 0))
                second.addLine(to: CGPoint(x: size.width * 0.85, y: size.height))
                context.stroke(second, with: .color(NookTheme.accent.opacity(0.12)), lineWidth: 0.7)
            }
            Image(decorative: sprite, scale: 1).resizable().interpolation(.high)
                .frame(width: 194, height: 194)
        }
        .frame(height: 132).clipped()
        .accessibilityLabel(material.title + " 확대 미리보기")
    }
}

struct StudyView: View {
    @State private var study = Study()
    @Namespace private var selection
    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(NookTheme.hairline.opacity(0.35)).frame(height: 0.5)
            HStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    MapSurface(study: study)
                    VStack {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Your reading, connected.")
                                    .font(.system(size: 23, weight: .medium, design: .serif))
                                Text("\(study.graph.nodes.count)개의 글 · 같은 연결, 다른 질감")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 30).padding(.top, 25)
                        Spacer()
                    }.allowsHitTesting(false)
                    cameraControls.padding(.bottom, 24)
                }
                Rectangle().fill(NookTheme.hairline.opacity(0.45)).frame(width: 0.5)
                sidebar.frame(width: 294)
            }
            Rectangle().fill(NookTheme.hairline.opacity(0.35)).frame(height: 0.5)
            HStack {
                Label("드래그로 회전", systemImage: "rotate.3d")
                Text("·")
                Text("스크롤로 이동 · 핀치로 확대 · 글을 눌러 미리보기")
                Spacer()
                Text("별도 데모 · 원본 데이터는 변경되지 않습니다")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 24).padding(.vertical, 13)
        }
        .background(NookTheme.canvas)
        .tint(NookTheme.accent)
        .preferredColorScheme(study.dark ? .dark : .light)
        .frame(minWidth: 1080, minHeight: 740)
        .onChange(of: study.dark) { _, dark in
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        }
    }
    private var header: some View {
        HStack(spacing: 16) {
            Text("Nook").font(.system(size: 27, weight: .bold, design: .serif))
            Text("MATERIAL STUDY").font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
            Spacer()
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 5) {
                    ForEach(DemoMaterial.allCases) { material in
                        Button {
                            withAnimation(.smooth(duration: 0.24)) { study.material = material }
                        } label: {
                            Label(material.title, systemImage: material.symbol)
                                .font(.system(size: 12, weight: study.material == material ? .semibold : .regular))
                                .foregroundStyle(study.material == material ? NookTheme.accent : .secondary)
                                .padding(.horizontal, 14).frame(height: 35)
                                .background {
                                    if study.material == material {
                                        Capsule().fill(NookTheme.accent.opacity(0.12))
                                            .matchedGeometryEffect(id: "selected", in: selection)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(study.material == material ? .isSelected : [])
                    }
                }
                .padding(5).glassEffect(.regular, in: .capsule)
            }
            Spacer()
            Button { study.dark.toggle() } label: {
                Image(systemName: study.dark ? "sun.max" : "moon")
                    .frame(width: 23, height: 26)
            }.buttonStyle(.glass(.clear)).tint(.clear).help("밝은 화면 / 어두운 화면")
        }
        .padding(.leading, 92).padding(.trailing, 23).frame(height: 73)
    }
    private var cameraControls: some View {
        HStack(spacing: 12) {
            Text("3D").font(.system(size: 11, weight: .semibold)).foregroundStyle(NookTheme.accent)
            Divider().frame(height: 14)
            Button { study.control.fit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("전체 지도").accessibilityLabel("전체 지도")
            Button { study.control.zoom(0.75) } label: { Image(systemName: "minus") }.help("축소").accessibilityLabel("축소")
            Text(study.control.zoomText).font(.system(size: 11, design: .monospaced)).frame(width: 36)
            Button { study.control.zoom(1.3) } label: { Image(systemName: "plus") }.help("확대").accessibilityLabel("확대")
        }
        .buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 18).padding(.vertical, 13)
        .glassEffect(.regular, in: .capsule)
    }
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("질감 살펴보기").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Text(study.material == .original ? "BEFORE" : "CONCEPT \(study.material == .lens ? "A" : "B")")
                        .font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(NookTheme.accent)
                }
                MaterialSample(material: study.material, dark: study.dark)
                    .background(NookTheme.card.opacity(0.4), in: .rect(cornerRadius: 18))
                Text(study.material.title).font(.system(size: 24, weight: .semibold, design: .serif))
                Text(study.material.caption).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
                Rectangle().fill(NookTheme.hairline.opacity(0.5)).frame(height: 0.5).padding(.vertical, 6)
                if let story = study.selected {
                    Text(story.source).font(.system(size: 10, weight: .medium)).foregroundStyle(NookTheme.accent)
                    Text(story.title).font(.system(size: 21, weight: .semibold, design: .serif)).fixedSize(horizontal: false, vertical: true)
                    Text(story.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5).lineLimit(5)
                    if let url = URL(string: story.url), ["https", "http"].contains(url.scheme ?? "") {
                        Link(destination: url) { Label("원문 보기", systemImage: "arrow.up.right") }
                            .buttonStyle(.glass).font(.system(size: 12))
                    }
                    if !study.related.isEmpty {
                        Text("이 글에서 이어 읽기").font(.system(size: 11, weight: .medium)).padding(.top, 8)
                        ForEach(study.related) { related in
                            Button { study.select(related.id) } label: {
                                HStack(alignment: .top, spacing: 9) {
                                    Circle().fill(NookTheme.accent.opacity(0.65)).frame(width: 4, height: 4).padding(.top, 5)
                                    Text(related.title).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                } else {
                    Label("지도에서 글을 골라 보세요", systemImage: "cursorarrow.click")
                        .font(.system(size: 13, weight: .medium))
                    Text("선택한 글과 연결은 앰버로 강조됩니다.\n재질을 바꿔도 보고 있던 위치는 유지됩니다.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
                }
            }.padding(24)
        }
        .scrollIndicators(.hidden)
        .background(NookTheme.card.opacity(0.28))
    }
}

@main struct DemoApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = DemoDelegate()
        app.delegate = delegate
        app.run()
    }
}
@MainActor final class DemoDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Nook · Glass Study"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: StudyView().ignoresSafeArea())
        window.minSize = NSSize(width: 1080, height: 740)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
