#if os(macOS)
import Accelerate
import Foundation

struct RecommendationMapIndexUpdate: Sendable {
    let completed: Int
    let total: Int
    var analyzedIDs: [String] = []
    var connections: [RecommendationMapEdge] = []
    var beginsFormation = false
    var positions: [String: CGPoint] = [:]
}

/// Provisional semantic neighbors among articles analyzed so far. The final
/// graph still applies the complete hybrid ranking and duplicate policy.
/// Append-only normalized storage avoids rebuilding an N × N index per batch.
struct RecommendationLiveConnections {
    private var ids: [String] = []
    private var keys: [String] = []
    private var matrix: [Float] = []
    private var dimension = 0
    private var model: String?

    mutating func append(_ articles: [Article], vectors: [RecommendationVector], connect: Bool = true) -> [RecommendationMapEdge] {
        let start = ids.count
        for (article, vector) in zip(articles, vectors) {
            guard !vector.values.isEmpty, vector.values.allSatisfy(\.isFinite),
                  dimension == 0 || (vector.values.count == dimension && vector.model == model) else { continue }
            var norm: Float = 0
            vDSP_svesq(vector.values, 1, &norm, vDSP_Length(vector.values.count))
            guard norm > 0 else { continue }
            dimension = vector.values.count
            model = vector.model
            let scale = 1 / sqrt(norm)
            matrix.append(contentsOf: vector.values.map { $0 * scale })
            ids.append(article.id)
            keys.append(RecommendationContentText.duplicateKey(article))
        }
        let count = ids.count - start, n = ids.count
        guard connect, count > 0, n > 1, !Task.isCancelled else { return [] }
        var scores = Array(repeating: Float(0), count: count * n)
        matrix.withUnsafeBufferPointer { m in
            scores.withUnsafeMutableBufferPointer { s in
                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(count), Int32(n), Int32(dimension),
                    1, m.baseAddress! + start * dimension, Int32(dimension), m.baseAddress!, Int32(dimension),
                    0, s.baseAddress!, Int32(n))
            }
        }
        var result: [RecommendationMapEdge] = []
        var seen = Set<String>()
        for row in 0..<count {
            let i = start + row
            var best: [(Int, Float)] = []
            for j in 0..<n where j != i && keys[i] != keys[j] {
                let score = scores[row * n + j]
                // Same raw-cosine floor as the final Qwen fast map.
                guard score >= 0.40 else { continue }
                let position = best.firstIndex { score > $0.1 || (score == $0.1 && ids[j] < ids[$0.0]) } ?? best.count
                if position < 3 {
                    best.insert((j, score), at: position)
                    if best.count > 3 { best.removeLast() }
                }
            }
            for (j, score) in best {
                let edge = RecommendationMapEdge(a: ids[i], b: ids[j], strength: Double(score),
                    terms: [String(localized: "Related subject and context", bundle: .module)])
                if seen.insert(edge.id).inserted { result.append(edge) }
            }
        }
        return result
    }
}

struct RecommendationMapFormation {
    var active = false
    var analyzed = Set<String>()
    var edges: [RecommendationMapEdge] = []
    var positions: [String: CGPoint] = [:]
    private var edgeIDs = Set<String>()
    var layoutRevision = 0

    mutating func receive(_ update: RecommendationMapIndexUpdate) {
        if update.beginsFormation { self = Self(); active = true; positions = update.positions }
        guard active else { return }
        analyzed.formUnion(update.analyzedIDs)
        if !update.positions.isEmpty {
            positions.merge(update.positions) { _, new in new }
            layoutRevision &+= 1
        }
        for edge in update.connections where edgeIDs.insert(edge.id).inserted { edges.append(edge) }
    }

    static func spreadPositions(for ids: [String]) -> [String: CGPoint] {
        Dictionary(uniqueKeysWithValues: ids.sorted().enumerated().map { offset, id in
            let angle = Double(offset) * 2.399963, radius = sqrt(Double(offset)) * 100
            return (id, CGPoint(x: cos(angle) * radius, y: sin(angle) * radius))
        })
    }
}
#endif
