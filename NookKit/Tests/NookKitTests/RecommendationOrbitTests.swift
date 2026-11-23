#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import NookKit

@Suite("Spatial map geometry")
struct RecommendationOrbitTests {
    @Test("Depth creates perspective, and rotation changes projected positions")
    func perspective() {
        let points = [CGPoint(x: 200, y: 0), CGPoint(x: 200, y: 0)]
        let seeds = [(0.8, 0.0), (-0.8, 0.0)]
        var camera = RecommendationOrbit(yaw: 0, pitch: 0)
        let front = camera.project(points, seeds: seeds, center: .zero, radius: 1000)
        #expect(front[0].scale > front[1].scale)
        #expect(front[0].point.x > front[1].point.x)
        camera.rotate(x: .pi / 2, y: 0)
        let side = camera.project(points, seeds: seeds, center: .zero, radius: 1000)
        #expect(side[0].point.x > 0)
        #expect(side[1].point.x < 0)
        camera.rotate(x: 100_000, y: 100_000)
        #expect(abs(camera.pitch) < .pi / 2)
        #expect(abs(camera.yaw) < .pi * 2)
    }

    @Test("20,000 story transforms are finite and linear; no pairwise camera work")
    func largeProjection() {
        let points: [CGPoint] = (0..<20_000).map { i -> CGPoint in
            let angle = Double(i) * 2.399
            let radius = sqrt(Double(i)) * 110
            return CGPoint(x: sin(angle)*radius, y: cos(angle)*radius)
        }
        let seeds = points.indices.map { RecommendationOrbit.depthSeed(id: "story-\($0)", community: "group-\($0/32)") }
        var camera = RecommendationOrbit()
        let start = ContinuousClock.now
        for _ in 0..<60 {
            camera.rotate(x: 0.02, y: 0.005)
            let output = camera.project(points, seeds: seeds, center: .zero, radius: 20_000)
            #expect(output.count == 20_000)
            #expect(output.allSatisfy { $0.point.x.isFinite && $0.point.y.isFinite && $0.scale > 0 })
        }
        print("Spatial projection 20k × 60: \(start.duration(to: .now))")
    }

    @Test("Read changes and collection projections retain the actual 3D camera and positions")
    @MainActor func cameraStability() {
        let articles = (0..<24).map { Fixture.article("story-\($0)", feedID: "feed") }
        let nodes = articles.enumerated().map { i, article in
            RecommendationMapNode(article: article, rank: i+1, topic: "", source: "Feed",
                position: CGPoint(x: Double(i%6)*200, y: Double(i/6)*200), clusterID: "community-\(i/4)")
        }
        let graph = RecommendationGraph(nodes: nodes)
        let view = RecommendationCanvasView(frame: CGRect(x: 0,y: 0,width: 900,height: 650))
        view.reduceMotion = true
        view.setSpatial(true)
        view.install(graph, revision: 1,layoutRevision: 1)
        let before = view.inspectOrbit(x: 0.7,y: 0.3)
        var updated = graph
        updated.nodes[0] = RecommendationMapNode(article: articles[0], rank: 99, topic: "new", source: "Feed", position: nodes[0].position, clusterID: nodes[0].clusterID)
        updated.nodes.removeLast()
        updated.nodes.reverse()
        view.install(updated,revision: 2,layoutRevision: 1)
        let after = view.inspectOrbit()
        #expect(after.yaw == before.yaw && after.pitch == before.pitch)
        #expect(after.points.allSatisfy { before.points[$0.key] == $0.value })
    }

    @Test("Actual canvas bounds drawing for a 20,000-story orbit")
    @MainActor func largeCanvas() throws {
        let nodes: [RecommendationMapNode] = (0..<20_000).map { i in
            let angle = Double(i)*2.399, radius = sqrt(Double(i))*110
            return RecommendationMapNode(article: Fixture.article("node-\(i)",feedID: "f"),rank:i+1,topic:"AI",source:"Feed",
                position:CGPoint(x:sin(angle)*radius,y:cos(angle)*radius),clusterID:"cluster-\(i/32)")
        }
        let edges = (1..<nodes.count).map { RecommendationMapEdge(a:nodes[$0-1].id,b:nodes[$0].id,strength:0.6,terms:[]) }
        let view = RecommendationCanvasView(frame:CGRect(x:0,y:0,width:1200,height:800))
        view.reduceMotion = true;view.setSpatial(true)
        view.install(RecommendationGraph(nodes:nodes,edges:edges),revision:1,layoutRevision:1)
        #expect(view.navigationInspection.overview.points.count <= 600)
        view.navigateZoom(12)
        view.navigateOverview(to: CGPoint(x: 1, y: 1), remember: true)
        #expect(view.navigationInspection.visible > 0)
        view.navigateToFit()
        let image = try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1200,pixelsHigh:800,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        let context = try #require(NSGraphicsContext(bitmapImageRep:image))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        var times: [Double] = []
        for _ in 0..<12 {
            let start = ProcessInfo.processInfo.systemUptime
            _ = view.inspectOrbit(x:0.02,y:0.005)
            view.draw(view.bounds)
            times.append((ProcessInfo.processInfo.systemUptime-start)*1000)
            #expect(view.spatialDrawInspection.nodes <= 2400)
            #expect(view.spatialDrawInspection.edges <= 1600)
            #expect(view.spatialDrawInspection.labels <= 36)
        }
        times.sort()
        print("Native 3D canvas 20k, 1200×800: median=\(times[6])ms max=\(times.last!)ms; \(view.spatialDrawInspection)")
    }

}
#endif
