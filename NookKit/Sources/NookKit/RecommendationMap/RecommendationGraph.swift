import Foundation
import NaturalLanguage

struct RecommendationMapNode: Identifiable, Sendable {
    let article: Article
    let rank: Int
    let topic: String
    let source: String
    var position: CGPoint
    var clusterID = ""
    var clusterLabel = ""
    var id: String { article.id }
}
struct RecommendationMapEdge: Identifiable, Sendable, Codable {
    let a: String
    let b: String
    let strength: Double
    let terms: [String]
    init(a:String,b:String,strength:Double,terms:[String]) {
        self.a=min(a,b);self.b=max(a,b);self.strength=strength;self.terms=terms
    }
    var id: String { a + "\u{0}" + b }
    func other(_ id: String) -> String? { a == id ? b : (b == id ? a : nil) }
}
struct RecommendationGraph: Sendable {
    var nodes: [RecommendationMapNode] = []
    var edges: [RecommendationMapEdge] = []
    var candidates:[String:[RecommendationCandidate]]=[:]
    var overrides:[String:[RecommendationMapEdge]]=[:]
    func related(to id:String,limit:Int=8) -> [(RecommendationMapNode,RecommendationMapEdge)] {
        let lookup=Dictionary(uniqueKeysWithValues:nodes.map {($0.id,$0)})
        let sorted=(overrides[id] ?? edges).compactMap {edge -> (RecommendationMapNode,RecommendationMapEdge)? in
            guard let other=edge.other(id),let node=lookup[other] else{return nil}
            return (node,edge)
        }.sorted {$0.1.strength==$1.1.strength ? $0.0.id<$1.0.id:$0.1.strength>$1.1.strength}
        var seen=Set<String>()
        if let original=lookup[id] {seen.insert(RecommendationContentText.duplicateKey(original.article))}
        return Array(sorted.filter {seen.insert(RecommendationContentText.duplicateKey($0.0.article)).inserted}.prefix(limit))
    }
    var topics: [String] { Array(Set(nodes.map(\.topic))).sorted() }

    /// Project a cached library graph without rerunning embeddings or layout.
    /// Keeping positions makes switching collections spatially predictable.
    func collection(_ source: SmartSource, recentlyOpened: [String: Date]) -> Self {
        var result = self
        result.nodes = nodes.filter { node in
            source == .recent ? recentlyOpened[node.id] != nil : node.article.matches(.smart(source))
        }
        if source == .recent {
            result.nodes.sort { (recentlyOpened[$0.id] ?? .distantPast) > (recentlyOpened[$1.id] ?? .distantPast) }
        }
        let ids = Set(result.nodes.map(\.id))
        result.edges = edges.filter { ids.contains($0.a) && ids.contains($0.b) }
        result.candidates = candidates.filter { ids.contains($0.key) }.mapValues { $0.filter { ids.contains($0.id) } }
        result.overrides = overrides.filter { ids.contains($0.key) }.mapValues { $0.filter { ids.contains($0.a) && ids.contains($0.b) } }
        return result
    }

    func refreshed(articles: [Article], ranks: [String: Int], library: ReaderLibrary) -> Self {
        let lookup = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let names = Dictionary(uniqueKeysWithValues: library.categories.map { ($0.id, $0.name) })
        let sources = Dictionary(uniqueKeysWithValues: library.feeds.map { ($0.id, $0.displayTitle) })
        var result = self
        result.nodes = articles.compactMap { article in
            guard let old = lookup[article.id] else { return nil }
            var node = RecommendationMapNode(article: article, rank: article.isRead ? Int.max : (ranks[article.id] ?? Int.max),
                topic: article.categories.compactMap { names[$0] }.first ?? String(localized: "Uncategorized", bundle: .module),
                source: sources[article.feedID] ?? article.url.host() ?? "RSS", position: old.position)
            node.clusterID = old.clusterID
            node.clusterLabel = old.clusterLabel
            return node
        }
        let ids = Set(result.nodes.map(\.id))
        result.edges = edges.filter { ids.contains($0.a) && ids.contains($0.b) }
        result.candidates = candidates.filter { ids.contains($0.key) }.mapValues { $0.filter { ids.contains($0.id) } }
        result.overrides = overrides.filter { ids.contains($0.key) }.mapValues { $0.filter { ids.contains($0.a) && ids.contains($0.b) } }
        return result
    }
}

struct RecommendationCandidate:Sendable, Codable {
    let id:String
    let score:Double
}
