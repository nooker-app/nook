#if os(macOS)
import Foundation
import Observation
import os

@MainActor @Observable public final class RecommendationMapController {
    var graph = RecommendationGraph()
    var graphRevision = 0
    var layoutRevision = 0
    var selectedID: String?
    var topic: String?
    var focus = false
    var focusRequest = 0
    var isInteractive = true
    var loading = true
    var indexingProgress: (Int, Int)?
    var refiningID: String?
    var error: String?
    var scope = ""
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refinementGeneration = 0
    @ObservationIgnored private var engine: RecommendationGraphEngine?
    @ObservationIgnored private var refinementTask: Task<Void, Never>?
    @ObservationIgnored private var baseEdges: [RecommendationMapEdge] = []
    @ObservationIgnored private var canRefine = false
    @ObservationIgnored var onOpen: ((String) -> Void)?
    private static let log = Logger(subsystem: "com.tim.nook", category: "recommendation-map")

    public init() {}
    var selected: RecommendationMapNode? { graph.nodes.first { $0.id == selectedID } }
    var related: [(RecommendationMapNode, RecommendationMapEdge)] { selectedID.map { graph.related(to: $0, limit: 3) } ?? [] }
    public var readerArticleIDs: [String] { graph.nodes.filter { !$0.article.isRead }.map(\.id) }

    func select(_ id: String) {
        guard graph.nodes.contains(where: { $0.id == id }) else { return }
        selectedID = id
        topic = nil
        refineSelection()
    }

    func openSelected() { if let selectedID { onOpen?(selectedID) } }

    func exclude(_ id: String) {
        refinementTask?.cancel()
        refinementGeneration &+= 1
        refiningID = nil
        graph.nodes.removeAll { $0.id == id }
        graph.edges.removeAll { $0.a == id || $0.b == id }
        graph.overrides.removeAll()
        if selectedID == id { selectedID = graph.nodes.first?.id }
        graphRevision &+= 1
    }

    func pause() {
        generation &+= 1
        refinementGeneration &+= 1
        refinementTask?.cancel()
        refiningID = nil
        indexingProgress = nil
    }

    func refresh(store: ReaderStore, feedback: MagazineRecommendationController,
                 personalized: Bool, modelsReady: Bool) async {
        generation &+= 1
        let expected = generation
        Self.log.debug("refresh begin generation=\(expected)")
        refinementTask?.cancel()
        refiningID = nil
        error = nil
        let nextScope = store.syncFolderURL?.standardizedFileURL.path ?? "local"
        if scope != nextScope {
            scope = nextScope
            graph = RecommendationGraph()
            graphRevision &+= 1
            layoutRevision &+= 1
            canRefine = false
            selectedID = nil
            topic = nil
            engine = RecommendationGraphEngine(scope: nextScope)
        }
        loading = graph.nodes.isEmpty
        let snapshot = await store.recommendationMapSnapshot()
        Self.log.debug("snapshot generation=\(expected) current=\(self.generation) cancelled=\(Task.isCancelled) matchingScope=\(snapshot.scope == self.scope) engine=\(self.engine != nil) articles=\(snapshot.library.articles.count)")
        guard !Task.isCancelled, generation == expected, snapshot.scope == scope, let engine else { return }
        feedback.selectLibrary(scope)
        let ranked = await feedback.rankedRecommendations(candidates: snapshot.library.articles.filter { !$0.isRead },
            library: snapshot.library.articles, personalized: personalized)
        Self.log.debug("ranked generation=\(expected) current=\(self.generation) cancelled=\(Task.isCancelled) articles=\(ranked.count)")
        guard !Task.isCancelled, generation == expected else { return }
        let lookup = Dictionary(uniqueKeysWithValues: snapshot.library.articles.map { ($0.id, $0) })
        let unread = ranked.compactMap { lookup[$0.articleID] }
        let read = snapshot.library.articles.filter { $0.isRead && !feedback.isNotInterested($0.id) }
            .sorted { $0.publishedAt == $1.publishedAt ? $0.id < $1.id : $0.publishedAt > $1.publishedAt }
        let articles = unread + read
        let ranks = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($0.element.articleID, $0.offset + 1) })
        if !graph.nodes.isEmpty {
            // Read flags and feedback must be visible on return even while
            // first-time semantic indexing is still running in the background.
            graph = graph.refreshed(articles: articles, ranks: ranks, library: snapshot.library)
            let ids = Set(graph.nodes.map(\.id))
            baseEdges = baseEdges.filter { ids.contains($0.a) && ids.contains($0.b) }
            if !ids.contains(selectedID ?? "") { selectedID = graph.nodes.first?.id }
            graphRevision &+= 1
        }
        do {
            if graph.nodes.isEmpty || !modelsReady {
                let quick = try await engine.graph(articles: articles, ranks: ranks, snapshot: snapshot,
                    semantic: false, progress: { _, _ in })
                Self.log.debug("graph generation=\(expected) current=\(self.generation) cancelled=\(Task.isCancelled) nodes=\(quick.nodes.count)")
                guard !Task.isCancelled, generation == expected else { return }
                install(quick, refined: false)
            }
            if modelsReady {
                let enriched = try await engine.graph(articles: articles, ranks: ranks, snapshot: snapshot, semantic: true) { [weak self] done, total in
                    Task { @MainActor in
                        guard let self, self.generation == expected else { return }
                        self.indexingProgress = (done, total)
                    }
                }
                guard !Task.isCancelled, generation == expected else { return }
                install(enriched, refined: true)
            }
            loading = false
            indexingProgress = nil
        } catch {
            guard !Task.isCancelled, generation == expected else { return }
            loading = false
            indexingProgress = nil
            self.error = String(localized: "The map is available. Detailed connections could not be updated.", bundle: .module)
        }
    }

    private func install(_ fresh: RecommendationGraph, refined: Bool) {
        var next = fresh
        // The first semantic graph replaces the provisional lexical layout.
        // Later read/rank updates keep the user's exploration in place.
        let changesLayout = refined != canRefine
        if changesLayout { layoutRevision &+= 1 }
        let previous = Dictionary(uniqueKeysWithValues: (changesLayout ? [] : graph.nodes).map { ($0.id, $0) })
        for index in next.nodes.indices {
            if let old = previous[next.nodes[index].id] {
                next.nodes[index].position = old.position
                next.nodes[index].clusterID = old.clusterID
                next.nodes[index].clusterLabel = old.clusterLabel
            }
        }
        if !next.nodes.contains(where: { $0.id == selectedID }) { selectedID = next.nodes.first?.id }
        baseEdges = next.edges
        graph = next
        graphRevision &+= 1
        canRefine = refined
        loading = false
        refineSelection()
    }

    private func refineSelection() {
        refinementTask?.cancel()
        refinementGeneration &+= 1
        refiningID = nil
        guard canRefine, let selected, graph.overrides[selected.id] == nil, let engine else { return }
        let id = selected.id, revision = refinementGeneration, expected = generation
        let lookup = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let candidates = (graph.candidates[id] ?? []).filter { $0.score >= 0.28 && lookup[$0.id] != nil }
        guard !candidates.isEmpty else { return }
        refiningID = id
        refinementTask = Task {
            do {
                let scores = try await engine.refine(selected.article, candidates: candidates.compactMap { lookup[$0.id]?.article })
                guard !Task.isCancelled, selectedID == id, generation == expected, refinementGeneration == revision else { return }
                let valid: [(RecommendationCandidate, Double)] = zip(candidates, scores).filter { $0.1.isFinite && $0.1 >= -4 }
                let sorted = valid.sorted { left, right in
                    let lhs = left.1 + left.0.score * 0.01
                    let rhs = right.1 + right.0.score * 0.01
                    return lhs == rhs ? left.0.id < right.0.id : lhs > rhs
                }
                var seen = Set([RecommendationContentText.duplicateKey(selected.article)])
                let picked = sorted.filter { seen.insert(RecommendationContentText.duplicateKey(lookup[$0.0.id]!.article)).inserted }.prefix(3)
                let old = graph.related(to: id)
                let edges: [RecommendationMapEdge] = picked.map { candidate, score in
                    let strength = 1.0 / (1.0 + Foundation.exp(-score))
                    let terms = old.first(where: { $0.0.id == candidate.id })?.1.terms
                        ?? [String(localized: "Related subject and context", bundle: .module)]
                    return RecommendationMapEdge(a: id, b: candidate.id, strength: strength, terms: terms)
                }
                graph.overrides[id] = edges
                graph.edges = Self.mergedEdges(baseEdges, overrides: graph.overrides)
                graphRevision &+= 1
                refiningID = nil
            } catch {
                guard !Task.isCancelled, selectedID == id, refinementGeneration == revision else { return }
                refiningID = nil
                self.error = String(localized: "The map is available. Detailed connections could not be updated.", bundle: .module)
            }
        }
    }

    static func mergedEdges(_ base: [RecommendationMapEdge], overrides: [String: [RecommendationMapEdge]]) -> [RecommendationMapEdge] {
        var result: [String: RecommendationMapEdge] = [:]
        for edge in base where overrides[edge.a] == nil && overrides[edge.b] == nil { result[edge.id] = edge }
        for edges in overrides.values {
            for edge in edges where edge.strength > (result[edge.id]?.strength ?? -.infinity) { result[edge.id] = edge }
        }
        return result.values.sorted { $0.strength == $1.strength ? $0.id < $1.id : $0.strength > $1.strength }
    }
}
#endif
