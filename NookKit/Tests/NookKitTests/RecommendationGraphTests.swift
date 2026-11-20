#if os(macOS)
import Foundation
import Testing
@testable import NookKit

@Suite("Recommendation map")
struct RecommendationGraphTests {
    private func article(_ id: String, title: String, body: String, read: Bool = false) -> Article {
        var result = Fixture.article(id, feedID: "feed", isRead: read)
        result.title = title
        result.bodyParagraphs = [body]
        return result
    }

    private var stories: [Article] {
        [article("one", title: "A distant signal", body: "Voyager spacecraft telemetry antenna interstellar exploration mission propulsion communication"),
         article("two", title: "Keeping the mission alive", body: "Voyager spacecraft telemetry antenna interstellar exploration mission propulsion communication", read: true),
         article("three", title: "A new recipe", body: "Baking sourdough bread sourdough starter fermentation flour kitchen dough")]
    }

    @Test("Unlabeled stories connect through their bodies, including read stories")
    func contentConnections() {
        var rows = stories
        rows[1].categories = ["different"]
        let library = Fixture.library(feeds: [Fixture.feed("feed")], articles: rows)
        let graph = RecommendationGraphBuilder.build(articles: rows, ranks: ["one": 1, "three": 2], library: library)
        #expect(graph.related(to: "one").map(\.0.id).contains("two"))
        #expect(!graph.related(to: "one").map(\.0.id).contains("three"))
        #expect(graph.nodes.first { $0.id == "two" }?.rank == Int.max)
        rows[0].categories = ["different"]
        rows[1].categories = []
        let relabeled = RecommendationGraphBuilder.build(articles: rows, ranks: ["one": 1, "three": 2], library: library)
        #expect(graph.edges.map(\.id) == relabeled.edges.map(\.id))
        #expect(graph.nodes.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite })
    }

    @Test("Collections keep original positions and include only their stories and links")
    func collectionProjection() {
        var rows = stories
        rows[0].isStarred = true
        rows[0].publishedAt = .now
        rows[1].publishedAt = .distantPast
        rows[2].publishedAt = .distantPast
        let library = Fixture.library(feeds: [Fixture.feed("feed")], articles: rows)
        let graph = RecommendationGraphBuilder.build(articles: rows, ranks: ["one": 1, "three": 2], library: library)
        let unread = graph.collection(.unread, recentlyOpened: [:])
        #expect(Set(unread.nodes.map(\.id)) == ["one", "three"])
        #expect(unread.edges.allSatisfy { $0.a != "two" && $0.b != "two" })
        #expect(graph.collection(.today, recentlyOpened: [:]).nodes.map(\.id) == ["one"])
        #expect(graph.collection(.starred, recentlyOpened: [:]).nodes.map(\.id) == ["one"])
        let recent = graph.collection(.recent, recentlyOpened: ["one": Date(timeIntervalSince1970: 10), "two": Date(timeIntervalSince1970: 20)])
        #expect(recent.nodes.map(\.id) == ["two", "one"])
        #expect(graph.collection(.recent, recentlyOpened: [:]).nodes.isEmpty)
        #expect(graph.collection(.all, recentlyOpened: [:]).nodes.count == 3)
        for node in unread.nodes { #expect(node.position == graph.nodes.first { $0.id == node.id }?.position) }
        // Filtering is a projection: read neighbors are still available on All.
        #expect(graph.related(to: "one").contains { $0.0.id == "two" })
    }

    @Test("Exact blocked cosine matches an exhaustive oracle without mixing models or invalid vectors")
    func exactNeighbors() {
        var vectors: [RecommendationVector?] = (0..<130).map { i in
            RecommendationVector(model: "Qwen/test", values: (0..<16).map { j in Float(sin(Double(i * 13 + j * 7))) })
        }
        vectors += [nil, .init(model: "Qwen/test", values: [.nan, 1]), .init(model: "Qwen/test", values: [0, 0]),
                    .init(model: "other", values: vectors[0]!.values), .init(model: "Qwen/test", values: [1])]
        let actual = RecommendationSemanticIndex(vectors: vectors).neighbors(limit: 5)
        for i in 0..<130 {
            let a = vectors[i]!.values.map(Double.init)
            let normA = sqrt(a.reduce(0) { $0 + $1 * $1 })
            let expected = (0..<130).filter { $0 != i }.map { j -> (Int, Double) in
                let b = vectors[j]!.values.map(Double.init)
                let normB = sqrt(b.reduce(0) { $0 + $1 * $1 })
                return (j, zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } / (normA * normB))
            }.filter { $0.1 > 0.16 }.sorted { $0.1 > $1.1 }.prefix(5)
            #expect(Set(actual[i].keys) == Set(expected.map(\.0)))
            for (j, value) in expected { #expect(abs((actual[i][j] ?? 0) - value) < 0.00001) }
        }
        #expect(actual.suffix(5).allSatisfy { $0.isEmpty })
    }

    @Test("Original HTML supplies body evidence without scripts or navigation")
    func cachedBody() {
        let library = Fixture.library(feeds: [], articles: stories)
        let snapshot = RecommendationLibrarySnapshot(scope: "one", library: library,
            readerHTML: ["one": "<nav>Unrelated menu</nav><script>tracking()</script><p>Voyager &amp; space</p><p>Mission telemetry</p>"])
        #expect(snapshot.library.articles[0].bodyParagraphs == ["Voyager & space", "Mission telemetry"])
        #expect(snapshot.originalIDs == ["one"])
        #expect(library.articles[0].bodyParagraphs == stories[0].bodyParagraphs)
        #expect(snapshot.library.articles[1].bodyParagraphs == stories[1].bodyParagraphs)
    }

    @Test("Vector caches preserve float bits and migrate scalar arrays")
    func vectorCacheFormat() throws {
        let vector = RecommendationVector(model: "Qwen/test", values: [0, -0.0, 1.0 / 3, -.greatestFiniteMagnitude], fingerprint: "body")
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(vector)
        let result = try PropertyListDecoder().decode(RecommendationVector.self, from: data)
        #expect(result.values.map(\.bitPattern) == vector.values.map(\.bitPattern))
        #expect(result.model == vector.model)
        #expect(result.fingerprint == vector.fingerprint)
        let legacy = Data(#"{"model":"old","values":[1,0.25],"fingerprint":"same"}"#.utf8)
        let migrated = try JSONDecoder().decode(RecommendationVector.self, from: legacy)
        #expect(migrated.values == [1, 0.25])
        let corrupt = Data(#"{"model":"bad","float32":"AQ=="}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(RecommendationVector.self, from: corrupt) }
    }

    @Test("Thousands of disconnected stories have finite, separate positions")
    func disconnectedLayout() {
        let rows = (0..<3000).map { article("isolated-\($0)", title: String($0), body: "") }
        let started = ContinuousClock.now
        let graph = RecommendationGraphBuilder.build(articles: rows, ranks: [:], library: Fixture.library(feeds: [], articles: rows))
        print("Map layout, 3000 disconnected stories: \(started.duration(to: .now))")
        #expect(graph.nodes.count == rows.count)
        #expect(graph.edges.isEmpty)
        #expect(Set(graph.nodes.map { "\($0.position.x),\($0.position.y)" }).count == rows.count)
        #expect(graph.nodes.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite })
    }

    @Test("Duplicate stories do not consume related slots")
    func duplicates() {
        var copy = stories[0]
        copy.id = "copy"
        let rows = stories + [copy]
        let graph = RecommendationGraphBuilder.build(articles: rows, ranks: [:], library: Fixture.library(feeds: [], articles: rows))
        #expect(!graph.related(to: "one").contains { $0.0.id == "copy" })
        #expect(Set(graph.edges.map(\.id)).count == graph.edges.count)
        #expect(graph.edges.allSatisfy { $0.a < $0.b })
    }

    @Test("Graph cache preserves geometry, updates read/rank state, and invalidates changed content")
    func cacheUpdates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RecommendationGraphEngine(scope: "test", cacheRoot: root)
        var rows = stories
        func snapshot(_ values: [Article]) -> RecommendationLibrarySnapshot {
            .init(scope: "test", library: Fixture.library(feeds: [], articles: values), readerHTML: [:])
        }
        let first = try await engine.graph(articles: rows, ranks: ["one": 1, "three": 2], snapshot: snapshot(rows), semantic: false, progress: { _, _ in })
        rows[0].isRead = true
        let updated = try await engine.graph(articles: rows, ranks: ["three": 1], snapshot: snapshot(rows), semantic: false, progress: { _, _ in })
        #expect(updated.nodes[0].article.isRead)
        #expect(updated.nodes[0].rank == Int.max)
        #expect(updated.nodes[2].rank == 1)
        #expect(updated.nodes.map(\.position) == first.nodes.map(\.position))
        rows[0].bodyParagraphs = ["Baking sourdough bread sourdough starter fermentation flour kitchen dough"]
        let changed = try await engine.graph(articles: rows, ranks: [:], snapshot: snapshot(rows), semantic: false, progress: { _, _ in })
        #expect(changed.related(to: "one").first?.0.id == "three")
        let subset = Array(rows.dropFirst())
        let removed = try await engine.graph(articles: subset, ranks: [:], snapshot: snapshot(subset), semantic: false, progress: { _, _ in })
        #expect(removed.nodes.count == 2)
        #expect(!removed.edges.contains { $0.a == "one" || $0.b == "one" })
    }

    @Test("Refinement replaces obsolete incident edges and keeps canonical links")
    @MainActor func refinementEdges() {
        let old = RecommendationMapEdge(a: "a", b: "b", strength: 0.5, terms: [])
        let new = RecommendationMapEdge(a: "c", b: "a", strength: 0.8, terms: [])
        let merged = RecommendationMapController.mergedEdges([old], overrides: ["a": [new], "c": [new]])
        #expect(merged.map(\.id) == [new.id])
        #expect(RecommendationMapController.mergedEdges([old], overrides: ["a": []]).isEmpty)
    }

    @Test("Disk graph cache survives relaunch, updates metadata and restores excluded stories")
    func diskGraphCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Fixture.library(feeds: [], articles: stories)
        let snapshot = RecommendationLibrarySnapshot(scope: "test", library: library, readerHTML: [:])
        let first = try await RecommendationGraphEngine(scope: "test", cacheRoot: root)
            .graph(articles: stories, ranks: ["one": 1], snapshot: snapshot, semantic: false, progress: { _, _ in })
        let relaunched = RecommendationGraphEngine(scope: "test", cacheRoot: root)
        let subset = try await relaunched.graph(articles: Array(stories.dropFirst()), ranks: ["three": 1], snapshot: snapshot, semantic: false, progress: { _, _ in })
        #expect(subset.nodes.count == 2)
        #expect(subset.nodes.first { $0.id == "three" }?.rank == 1)
        let restored = try await relaunched.graph(articles: stories, ranks: ["one": 1], snapshot: snapshot, semantic: false, progress: { _, _ in })
        #expect(restored.nodes.map(\.id) == first.nodes.map(\.id))
        #expect(restored.nodes.map(\.position) == first.nodes.map(\.position))
        #expect(restored.edges.map(\.id) == first.edges.map(\.id))
    }

    @Test("Not interested immediately removes the selected node without waiting for inference")
    @MainActor func immediateExclusion() {
        let model = RecommendationMapController()
        model.graph = RecommendationGraphBuilder.build(articles: stories, ranks: [:], library: Fixture.library(feeds: [], articles: stories))
        model.select("one")
        model.exclude("one")
        #expect(model.selectedID != "one")
        #expect(!model.graph.nodes.contains { $0.id == "one" })
        #expect(!model.graph.edges.contains { $0.a == "one" || $0.b == "one" })
    }
}
#endif
