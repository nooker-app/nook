#if os(macOS)
import Foundation
import Testing
@testable import NookKit

@Suite("Recommendation preparation")
struct RecommendationPreparationTests {
    @Test("Download disclosure uses the installation manifest")
    func manifest() {
        let models = RecommendationModelManifest.bundled
        #expect(models.count == 2)
        #expect(RecommendationModelManifest.totalBytes == 2_918_648_939)
        #expect(models.allSatisfy { $0.sourceURL.host == "huggingface.co" && $0.sourceURL.path.hasSuffix($0.revision) })
    }

    @Test("Completed analysis is separate from layout and ignores late progress")
    func stages() {
        var state = RecommendationMapPreparation()
        state.begin()
        state.update(completed: 16, total: 40)
        state.update(completed: 8, total: 40)
        #expect(state.fraction == 0.4)
        state.update(completed: 40, total: 40)
        #expect(state.phase == .connecting)
        state.finish()
        state.update(completed: 32, total: 40)
        #expect(state.phase == .ready)
        state.reset()
        state.update(completed: 40, total: 40)
        #expect(state.phase == .idle)
    }

    @Test("Live edges require actual compatible vectors, exclude duplicates and bridge batches")
    func incrementalNeighbors() {
        let articles = (0..<5).map { i in
            var a = Fixture.article("\(i)", feedID: "feed")
            a.title = "Story \(i)";a.url = URL(string: "https://example.org/\(i)")!
            return a
        }
        func vector(_ values: [Float], model: String = "Qwen/test") -> RecommendationVector {
            RecommendationVector(model: model, values: values)
        }
        var live = RecommendationLiveConnections()
        #expect(live.append([articles[0]], vectors: [vector([1,0,0])]).isEmpty)
        let edges = live.append([articles[1], articles[2]], vectors: [vector([0.9,0.1,0]), vector([0,0,1])])
        #expect(edges.count == 1)
        #expect(edges.first?.a == "0" && edges.first?.b == "1")
        #expect(live.append([articles[3]], vectors: [vector([1,0,0], model: "other")]).isEmpty)
        #expect(live.append([articles[4]], vectors: [vector([.nan,0,0])]).isEmpty)
        var duplicate = articles[0];duplicate.id = "duplicate"
        let duplicateEdges = live.append([duplicate], vectors: [vector([1,0,0])])
        #expect(!duplicateEdges.contains { $0.a == "0" || $0.b == "0" })
    }

    @Test("A resumed run restores analyzed identities and deduplicates live edges")
    func formationState() {
        var state = RecommendationMapFormation()
        let positions = RecommendationMapFormation.spreadPositions(for: ["b", "a", "c"])
        let edge = RecommendationMapEdge(a: "a", b: "b", strength: 0.8, terms: [])
        state.receive(.init(completed: 1, total: 3, analyzedIDs: ["a"], beginsFormation: true, positions: positions))
        state.receive(.init(completed: 2, total: 3, analyzedIDs: ["b"], connections: [edge, edge]))
        #expect(state.edges.count == 1 && state.analyzed == ["a", "b"])
        #expect(state.positions == RecommendationMapFormation.spreadPositions(for: ["c", "b", "a"]))
        state.receive(.init(completed: 0, total: 1, beginsFormation: true))
        #expect(state.edges.isEmpty && state.analyzed.isEmpty)
    }

    @Test("Live layout draws connected stories closer without moving unrelated articles")
    func incrementalLayout() {
        let positions = ["a": CGPoint(x: -2000, y: 0), "b": CGPoint(x: 2000, y: 0), "c": CGPoint(x: 0, y: 3000)]
        var layout = RecommendationFormationLayout(positions: positions)
        layout.add([.init(a: "a", b: "b", strength: 0.9, terms: [])], activated: ["a", "b", "c"])
        let changed = layout.relax()
        #expect(changed["c"] == nil)
        #expect(changed["a"]!.x > -2000 && changed["b"]!.x < 2000)
        #expect(changed.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        #expect(layout.relax().isEmpty)
    }

    @Test("Isolated completed articles cannot starve later layout work")
    func isolatedLayout() {
        let ids = (0..<600).map { String(format: "%04d", $0) }
        let positions = RecommendationMapFormation.spreadPositions(for: ids)
        var layout = RecommendationFormationLayout(positions: positions)
        layout.add([], activated: Array(ids.prefix(300)))
        #expect(layout.relax().isEmpty)
        layout.add([.init(a: ids[500], b: ids[501], strength: 0.9, terms: [])], activated: [ids[500], ids[501]])
        #expect(!layout.relax().isEmpty)
    }
}
#endif
