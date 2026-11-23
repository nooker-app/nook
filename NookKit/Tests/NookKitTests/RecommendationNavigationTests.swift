#if os(macOS)
import AppKit
import Testing
@testable import NookKit

@Suite("Spatial map navigation")
@MainActor
struct RecommendationNavigationTests {
    private func graph() -> RecommendationGraph {
        let nodes = (0..<120).map { i in
            let angle = Double(i)*2.399, radius = sqrt(Double(i))*160
            return RecommendationMapNode(article: Fixture.article("story-\(i)", feedID: "feed"),
                rank: i+1, topic: "", source: "Feed", position: CGPoint(x: cos(angle)*radius, y: sin(angle)*radius),
                clusterID: "cluster-\(i/16)")
        }
        return RecommendationGraph(nodes: nodes, edges: [RecommendationMapEdge(a: "story-0", b: "story-1", strength: 0.8, terms: [])])
    }
    private func canvas() -> RecommendationCanvasView {
        let view = RecommendationCanvasView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        view.reduceMotion = true;view.setSpatial(true)
        view.install(graph(), revision: 1, layoutRevision: 1)
        view.updateSelection("story-0")
        return view
    }

    @Test("Overscroll, overview navigation and extreme zoom always retain a visible story")
    func bounds() throws {
        let view = canvas()
        #expect(view.navigationInspection.overview.percent == 100)
        for _ in 0..<12 { view.navigateZoom(10) }
        #expect(view.inspection.zoom == view.navigationInspection.maximumZoom)
        for p in [CGPoint.zero, CGPoint(x: 1,y: 0), CGPoint(x: 0,y: 1), CGPoint(x: 1,y: 1), CGPoint(x: 0.5,y: 0.5)] {
            view.navigateOverview(to: p, remember: true)
            #expect(view.navigationInspection.visible > 0)
        }
        for delta: Int32 in [-50_000,50_000] {
            let raw = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: delta, wheel2: delta, wheel3: 0))
            let event = try #require(NSEvent(cgEvent: raw))
            view.scrollWheel(with: event)
            #expect(view.navigationInspection.visible > 0)
        }
        for _ in 0..<12 { view.navigateZoom(0.01) }
        #expect(view.inspection.zoom == view.navigationInspection.minimumZoom)
        #expect(view.navigationInspection.visible > 0)
        #expect(view.navigationInspection.history <= 20)
        view.setFrameSize(CGSize(width: 600,height: 400));view.layout()
        #expect(view.navigationInspection.visible > 0)
    }

    @Test("Back restores the full camera; routine article changes preserve it and its history")
    func history() {
        let view = canvas()
        _ = view.inspectOrbit(x: 0.4, y: 0.2)
        view.navigateZoom(2)
        let camera = view.inspection, orbit = view.inspectOrbit()
        view.focusSelection()
        view.navigateBack()
        #expect(view.inspection.pan == camera.pan)
        #expect(view.inspection.zoom == camera.zoom)
        #expect(view.inspectOrbit().yaw == orbit.yaw && view.inspectOrbit().pitch == orbit.pitch)
        let history = view.navigationInspection.history
        var updated = graph()
        let node = updated.nodes[0]
        var read = node.article
        read.isRead = true
        updated.nodes[0] = RecommendationMapNode(article: read, rank: node.rank, topic: node.topic,
            source: node.source, position: node.position, clusterID: node.clusterID)
        updated.nodes.reverse()
        view.install(updated, revision: 2, layoutRevision: 1)
        #expect(view.inspection.pan == camera.pan && view.inspection.zoom == camera.zoom)
        #expect(view.navigationInspection.history == history)
        view.install(updated, revision: 3, layoutRevision: 2)
        #expect(!view.navigationInspection.overview.canGoBack)
    }

    @Test("Reader input lock freezes toolbar, overview, camera shortcuts and gestures")
    func inputLock() throws {
        let view = canvas()
        view.navigateZoom(2)
        let before = view.inspection, orbit = view.inspectOrbit(), history = view.navigationInspection.history
        view.interactionEnabled = false
        view.navigateToFit();view.focusSelection();view.navigateZoom(1.5)
        view.navigateOverview(to: .zero, remember: true);view.resetDirection();view.navigateBack()
        for key: UInt16 in [3,29,51,53,123] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key))
            view.keyDown(with: event)
        }
        #expect(view.inspection.pan == before.pan && view.inspection.zoom == before.zoom)
        #expect(view.inspectOrbit().yaw == orbit.yaw && view.inspectOrbit().pitch == orbit.pitch)
        #expect(view.navigationInspection.history == history)
        view.interactionEnabled = true;view.navigateBack()
        #expect(view.inspection.zoom != before.zoom)
    }

    @Test("Materials follow real edges across updates, independently of categories")
    func connections() {
        let view = canvas()
        #expect(view.materialForStory("story-0") == .lightHalo)
        #expect(view.materialForStory("story-1") == .lightHalo)
        #expect(view.materialForStory("story-2") == .amberLens)
        var updated = graph()
        updated.edges = [RecommendationMapEdge(a: "story-1", b: "story-2", strength: 0.8, terms: [])]
        view.install(updated, revision: 2, layoutRevision: 1)
        #expect(view.materialForStory("story-0") == .amberLens)
        #expect(view.materialForStory("story-2") == .lightHalo)
    }

    @Test("Empty collections and 2D mode cannot reuse stale minimap or camera history")
    func collections() {
        let view = canvas()
        view.navigateZoom(2);view.setSpatial(false)
        #expect(view.navigationInspection.overview.points.isEmpty)
        #expect(!view.navigationInspection.overview.canGoBack)
        let before = view.inspection
        view.navigateOverview(to: .zero, remember: true)
        #expect(view.inspection.pan == before.pan && view.inspection.zoom == before.zoom)
        view.setSpatial(true);view.navigateZoom(2)
        view.install(RecommendationGraph(), revision: 2, layoutRevision: 2)
        #expect(view.navigationInspection.overview.points.isEmpty)
        #expect(!view.navigationInspection.overview.canGoBack)
        view.navigateBack();view.navigateToFit();view.navigateOverview(to: .zero, remember: true)
        view.install(graph(), revision: 3, layoutRevision: 3)
        #expect(view.navigationInspection.overview.percent == 100)
        #expect(view.navigationInspection.visible > 0)
    }
}
#endif
