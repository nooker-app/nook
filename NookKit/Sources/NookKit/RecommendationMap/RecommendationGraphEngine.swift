#if os(macOS)
import CryptoKit
import Foundation

actor RecommendationGraphEngine {
    @MainActor private static var sharedEngines: [String: RecommendationGraphEngine] = [:]
    @MainActor static func shared(scope: String) -> RecommendationGraphEngine {
        if let engine = sharedEngines[scope] { return engine }
        let engine = RecommendationGraphEngine(scope: scope)
        if sharedEngines.count >= 3 { sharedEngines.removeAll() }
        sharedEngines[scope] = engine
        return engine
    }
    let folder: URL
    var vectors: [String: RecommendationVector] = [:]
    var searchQueries: [String: [Float]] = [:]
    var searchBodies: [String: (html: String, paragraphs: [String])] = [:]
    private var pairs: [String: Double] = [:]
    private var loaded = false
    private var checkedDiskGraphs = Set<Bool>()
    private var graphCache: [Bool: (graph: RecommendationGraph, fingerprints: [String: String])] = [:]

    init(scope: String, cacheRoot: URL? = nil) {
        let root = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nook/RecommendationMap", isDirectory: true)
        folder = root.appendingPathComponent(Self.hash(scope), isDirectory: true)
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        let decoder = PropertyListDecoder()
        vectors = (try? Data(contentsOf: folder.appendingPathComponent("vectors.plist")))
            .flatMap { try? decoder.decode([String: RecommendationVector].self, from: $0) } ?? [:]
        pairs = (try? Data(contentsOf: folder.appendingPathComponent("pairs.plist")))
            .flatMap { try? decoder.decode([String: Double].self, from: $0) } ?? [:]
    }

    func save<T: Encodable>(_ value: T, name: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(value) { try? data.write(to: folder.appendingPathComponent(name), options: .atomic) }
    }

    func graph(articles: [Article], ranks: [String: Int], snapshot: RecommendationLibrarySnapshot,
               semantic: Bool, progress: @Sendable @escaping (Int, Int) async -> Void,
               formation: @Sendable @escaping (RecommendationMapIndexUpdate) async -> Void = { _ in }) async throws -> RecommendationGraph {
        // Reading, ranking, and undo do not change content similarity. Reuse
        // geometry and edges when the corpus is unchanged or only loses rows.
        let fingerprints = Dictionary(uniqueKeysWithValues: articles.map { article in
            (article.id, Self.hash(article.title + "\n" + article.summary + "\n" + article.bodyParagraphs.joined(separator: "\n")
                + "\noriginal:\(snapshot.originalIDs.contains(article.id))"))
        })
        if checkedDiskGraphs.insert(semantic).inserted,
           let data = try? Data(contentsOf: folder.appendingPathComponent(graphFile(semantic))),
           let cached = try? PropertyListDecoder().decode(StoredRecommendationGraph.self, from: data) {
            let restored = cached.restore(articles: articles, ranks: ranks, library: snapshot.library)
            let ids = Set(restored.nodes.map(\.id))
            graphCache[semantic] = (restored, cached.fingerprints.filter { ids.contains($0.key) })
        }
        if let cached = graphCache[semantic], fingerprints.allSatisfy({ cached.fingerprints[$0.key] == $0.value }) {
            return cached.graph.refreshed(articles: articles, ranks: ranks, library: snapshot.library)
        }
        if semantic {
            load()
            let validIDs = Set(articles.map(\.id))
            vectors = vectors.filter { validIDs.contains($0.key) }
            let missing = articles.filter { article in
                let fingerprint = Self.hash(RecommendationContentText.embeddingInput(article))
                guard let vector = vectors[article.id] else { return true }
                return vector.model != RecommendationNativeModels.embeddingID || vector.fingerprint != fingerprint
                    || vector.values.count != 1024 || !vector.values.allSatisfy(\.isFinite)
            }
            await progress(articles.count - missing.count, articles.count)
            var live = RecommendationLiveConnections()
            let spread = RecommendationMapFormation.spreadPositions(for: articles.map(\.id))
            var liveLayout = RecommendationFormationLayout(positions: spread)
            var lastLayout = ContinuousClock.now
            if !missing.isEmpty {
                let missingIDs = Set(missing.map(\.id))
                let cached = articles.filter { !missingIDs.contains($0.id) }
                _ = live.append(cached, vectors: cached.compactMap { vectors[$0.id] }, connect: false)
                await formation(RecommendationMapIndexUpdate(completed: cached.count, total: articles.count,
                    analyzedIDs: cached.map(\.id), beginsFormation: true,
                    positions: spread))
            }
            for start in stride(from: 0, to: missing.count, by: 8) {
                try Task.checkCancellation()
                let batch = Array(missing[start..<min(start + 8, missing.count)])
                let texts = batch.map(RecommendationContentText.embeddingInput)
                let encoded = try await RecommendationNativeModels.shared.embed(texts)
                try Task.checkCancellation()
                guard encoded.count == batch.count else { throw RecommendationModelError.invalidVector }
                for (index, article) in batch.enumerated() {
                    let value = encoded[index]
                    guard value.count == 1024, value.allSatisfy(\.isFinite) else { throw RecommendationModelError.invalidVector }
                    vectors[article.id] = RecommendationVector(model: RecommendationNativeModels.embeddingID,
                        values: value, fingerprint: Self.hash(texts[index]))
                }
                if start % 128 == 0 { save(vectors, name: "vectors.plist") }
                await progress(articles.count - missing.count + start + batch.count, articles.count)
                let connections = live.append(batch, vectors: batch.compactMap { vectors[$0.id] })
                liveLayout.add(connections, activated: batch.map(\.id))
                var positions: [String: CGPoint] = [:]
                if lastLayout.duration(to: .now) >= .milliseconds(1500) || start + batch.count == missing.count {
                    let snapshot = liveLayout
                    let layoutTask = Task.detached(priority: .utility) {
                        var next = snapshot
                        let changed = next.relax()
                        return (next, changed)
                    }
                    let result = await withTaskCancellationHandler { await layoutTask.value } onCancel: { layoutTask.cancel() }
                    try Task.checkCancellation()
                    liveLayout = result.0;positions = result.1;lastLayout = .now
                }
                await formation(RecommendationMapIndexUpdate(completed: articles.count - missing.count + start + batch.count,
                    total: articles.count, analyzedIDs: batch.map(\.id), connections: connections, positions: positions))
            }
            save(vectors, name: "vectors.plist")
        }
        try Task.checkCancellation()
        // Layout/content analysis must not occupy the shared cache actor: a
        // foreground search should be able to retrieve vectors while it runs.
        let encoded = semantic ? articles.map { vectors[$0.id] } : nil
        let build = Task.detached(priority: .utility) {
            RecommendationGraphBuilder.build(articles: articles, ranks: ranks, library: snapshot.library,
                semantic: encoded.map { RecommendationSemanticIndex(vectors: $0) }, originalIDs: snapshot.originalIDs)
        }
        let result = await withTaskCancellationHandler {
            await build.value
        } onCancel: {
            build.cancel()
        }
        try Task.checkCancellation()
        graphCache[semantic] = (result, fingerprints)
        save(StoredRecommendationGraph(result, fingerprints: fingerprints), name: graphFile(semantic))
        return result
    }

    private func graphFile(_ semantic: Bool) -> String {
        // Change the version when retrieval, cleanup, or layout rules change.
        "graph-v1-\(semantic ? RecommendationNativeModels.embeddingID.replacingOccurrences(of: "/", with: "-") : "lexical").plist"
    }

    func refine(_ article: Article, candidates: [Article]) async throws -> [Double] {
        load()
        let query = RecommendationContentText.rerankingInput(article)
        let documents = candidates.map(RecommendationContentText.rerankingInput)
        let keys = documents.map { Self.hash(RecommendationNativeModels.rerankingID + "\n" + query + "\u{0}" + $0) }
        let missing = keys.indices.filter { pairs[keys[$0]] == nil }
        if !missing.isEmpty {
            let scores = try await RecommendationNativeModels.shared.rerank(query: query, documents: missing.map { documents[$0] })
            try Task.checkCancellation()
            for (index, score) in zip(missing, scores) where score.isFinite { pairs[keys[index]] = score }
            if pairs.count > 20_000 {
                let keep = Set(keys)
                pairs = pairs.filter { keep.contains($0.key) }
            }
            save(pairs, name: "pairs.plist")
        }
        return keys.map { pairs[$0] ?? -.infinity }
    }
}

/// Persist geometry and links, never duplicate the article bodies in this cache.
private struct StoredRecommendationGraph: Codable {
    struct Position: Codable {
        let point: CGPoint
        let clusterID: String
        let clusterLabel: String
    }
    let positions: [String: Position]
    let edges: [RecommendationMapEdge]
    let candidates: [String: [RecommendationCandidate]]
    let fingerprints: [String: String]

    init(_ graph: RecommendationGraph, fingerprints: [String: String]) {
        positions = Dictionary(uniqueKeysWithValues: graph.nodes.map {
            ($0.id, Position(point: $0.position, clusterID: $0.clusterID, clusterLabel: $0.clusterLabel))
        })
        edges = graph.edges
        candidates = graph.candidates
        self.fingerprints = fingerprints
    }

    func restore(articles: [Article], ranks: [String: Int], library: ReaderLibrary) -> RecommendationGraph {
        let nodes = articles.compactMap { article -> RecommendationMapNode? in
            guard let position = positions[article.id] else { return nil }
            var node = RecommendationMapNode(article: article, rank: Int.max, topic: "", source: "", position: position.point)
            node.clusterID = position.clusterID
            node.clusterLabel = position.clusterLabel
            return node
        }
        return RecommendationGraph(nodes: nodes, edges: edges, candidates: candidates)
            .refreshed(articles: articles, ranks: ranks, library: library)
    }
}
#endif
