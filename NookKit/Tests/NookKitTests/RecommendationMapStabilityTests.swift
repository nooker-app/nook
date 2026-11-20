#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import NookKit

@Suite("Map incremental update stability")
struct RecommendationMapStabilityTests {
    private func stories(_ count: Int = 8) -> [Article] {
        (0..<count).map { i in
            var article = Fixture.article("story-\(i)", feedID: "feed")
            article.title = "Space mission \(i)"
            article.bodyParagraphs = ["Spacecraft telemetry antenna mission propulsion communication \(i)"]
            return article
        }
    }

    private actor Updates {
        var begins = 0
        func receive(_ update: RecommendationMapIndexUpdate) { if update.beginsFormation { begins += 1 } }
    }

    @Test("Only initial indexing unfolds the map; content arrivals and relaunch preserve geometry")
    func quietIndexing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let encode: @Sendable ([String]) async throws -> [[Float]] = { texts in
            texts.map { _ in [1] + Array(repeating: Float(0.01), count: 1023) }
        }
        let engine = RecommendationGraphEngine(scope: "test", cacheRoot: root, embed: encode)
        let updates = Updates()
        func snapshot(_ rows: [Article]) -> RecommendationLibrarySnapshot {
            .init(scope: "test", library: Fixture.library(feeds: [], articles: rows), readerHTML: [:])
        }
        var rows = stories()
        let first = try await engine.graph(articles: rows, ranks: [:], snapshot: snapshot(rows), semantic: true,
            progress: { _, _ in }, formation: { await updates.receive($0) })
        #expect(await updates.begins == 1)
        rows[0].isRead = true
        rows[0].bodyParagraphs.append("Newly cached original article with additional content.")
        rows.append(stories(9)[8])
        let updated = try await engine.graph(articles: Array(rows.reversed()), ranks: ["story-3": 1], snapshot: snapshot(rows),
            semantic: true, progress: { _, _ in }, formation: { await updates.receive($0) })
        #expect(await updates.begins == 1)
        let lookup = Dictionary(uniqueKeysWithValues: updated.nodes.map { ($0.id, $0.position) })
        #expect(first.nodes.allSatisfy { lookup[$0.id] == $0.position })
        let relaunched = RecommendationGraphEngine(scope: "test", cacheRoot: root, embed: encode)
        rows[1].bodyParagraphs.append("Another cached original.")
        let restored = try await relaunched.graph(articles: rows, ranks: [:], snapshot: snapshot(rows), semantic: true,
            progress: { _, _ in }, formation: { await updates.receive($0) })
        #expect(await updates.begins == 1)
        #expect(restored.nodes.allSatisfy { lookup[$0.id] == $0.position })
    }

    @Test("Read changes retain refined links; changed content invalidates them")
    func refinedLinks() {
        var rows = stories()
        let library = Fixture.library(feeds: [], articles: rows)
        var graph = RecommendationGraphBuilder.build(articles: rows, ranks: [:], library: library)
        let edge = RecommendationMapEdge(a: rows[0].id, b: rows[1].id, strength: 0.8, terms: ["mission"])
        graph.overrides[rows[0].id] = [edge]
        rows[0].isRead = true
        let read = graph.refreshed(articles: Array(rows.reversed()), ranks: [:], library: library)
        #expect(read.overrides[rows[0].id]?.first?.id == edge.id)
        rows[1].bodyParagraphs = ["An unrelated cooking story"]
        let changed = read.refreshed(articles: rows, ranks: [:], library: library)
        #expect(changed.overrides[rows[0].id] == nil)
    }

    @Test("Actual canvas preserves pan, zoom and positions across read, removal and arrival")
    @MainActor func canvas() {
        let rows = stories()
        let graph = RecommendationGraphBuilder.build(articles: rows, ranks: [:], library: Fixture.library(feeds: [], articles: rows))
        let view = RecommendationCanvasView(frame: CGRect(x: 0, y: 0, width: 900, height: 650))
        view.reduceMotion = true
        view.install(graph, revision: 1, layoutRevision: 1)
        view.updateSelection(rows[0].id)
        view.zoomBy(1.4, anchor: CGPoint(x: 150, y: 100), animated: false)
        let before = view.inspection
        var next = graph
        next.nodes.removeFirst()
        next.nodes.reverse()
        view.install(next, revision: 2, layoutRevision: 1)
        view.updateSelection(rows[1].id)
        let after = view.inspection
        #expect(after.pan == before.pan)
        #expect(after.zoom == before.zoom)
        #expect(after.positions.allSatisfy { before.positions[$0.key] == $0.value })
        #expect(!after.forming)
        print("Map canvas read/removal: camera delta=\(hypot(after.pan.x-before.pan.x, after.pan.y-before.pan.y)), zoom delta=\(after.zoom-before.zoom), moved nodes=\(after.positions.filter { before.positions[$0.key] != $0.value }.count)")
    }
}
#endif
