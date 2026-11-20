#if os(macOS)
import Accelerate
import Foundation

struct ArticleSearchUpdate: Sendable {
    let ids: [Article.ID]
    let isSearching: Bool
    let usesMeaning: Bool
    var indexed = 0
    var total = 0
}

/// Shared retrieval rules for magazine results and map suggestions. Exact
/// phrases remain useful; natural-language queries also compare document meaning.
enum ArticleSearchRanking {
    private static let filler = Set("찾아 찾아줘 찾아주세요 알려줘 알려주세요 보여줘 보여주세요 추천 추천해줘 기사 글 글들 관련 관한 읽고 싶은 싶어 방법 내용 대한 있는 하는 어떤 어떻게 왜 무엇 무엇인가요 궁금해 주세요 싶어요 싶습니다 것 것들 대해서 하는지 the a an articles article stories story find show me about on how why what which please want read".split(separator: " ").map(String.init))

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func terms(_ query: String) -> [String] {
        let raw = normalized(query).components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Array(Set(raw.compactMap { word -> String? in
            guard !word.isEmpty, !filler.contains(word) else { return nil }
            var term = word
            if term.unicodeScalars.allSatisfy({ (0xAC00...0xD7A3).contains($0.value) }) {
                for ending in RecommendationContentFeatures.endings where term.hasSuffix(ending) && term.count - ending.count >= 2 {
                    term = String(term.dropLast(ending.count)); break
                }
            }
            return filler.contains(term) ? nil : term
        })).sorted()
    }

    static func lexical(query: String, articles: [Article], feedTitles: [String: String]) -> [String: Double] {
        let phrase = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !phrase.isEmpty else { return [:] }
        let terms = terms(query)
        var scores: [String: Double] = [:]
        for article in articles {
            if Task.isCancelled { break }
            let title = normalized(article.title)
            let summary = normalized(article.summary)
            let feed = normalized(feedTitles[article.feedID] ?? "")
            let body = normalized(article.bodyParagraphs.joined(separator: " "))
            var score = title.contains(phrase) ? 12.0 : (summary.contains(phrase) || feed.contains(phrase) ? 9 : body.contains(phrase) ? 7 : 0)
            var matched = 0
            for term in terms {
                if title.contains(term) { score += 3; matched += 1 }
                else if summary.contains(term) || feed.contains(term) { score += 1.6; matched += 1 }
                else if body.contains(term) { score += 0.8; matched += 1 }
            }
            if score >= 7 || matched > 0 && Double(matched) / Double(max(1, terms.count)) >= 0.5 {
                scores[article.id] = score / Double(max(1, terms.count))
            }
        }
        return scores
    }

    static func rank(query: String, articles: [Article], lexical: [String: Double], semantic: [String: Double]) -> [String] {
        let order = Dictionary(uniqueKeysWithValues: articles.enumerated().map { ($0.element.id, $0.offset) })
        let best = semantic.values.max() ?? 0
        let meaning = semantic.filter { $0.value >= max(0.42, best - 0.12) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(80)
        let lexicalIDs = lexical.keys.sorted { lexical[$0] == lexical[$1] ? (order[$0] ?? 0) < (order[$1] ?? 0) : lexical[$0]! > lexical[$1]! }
        var scores: [String: Double] = [:]
        for (rank, id) in lexicalIDs.enumerated() { scores[id, default: 0] += 1 / Double(20 + rank) }
        for (rank, item) in meaning.enumerated() { scores[item.key, default: 0] += 1.2 / Double(20 + rank) }
        let phrase = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        for article in articles where scores[article.id] != nil && normalized(article.title).contains(phrase) {
            scores[article.id, default: 0] += 0.1
        }
        return scores.keys.sorted { scores[$0] == scores[$1] ? (order[$0] ?? 0) < (order[$1] ?? 0) : scores[$0]! > scores[$1]! }
    }

    static func similarities(query: [Float], articles: [Article], vectors: [String: RecommendationVector]) -> [String: Double] {
        guard !query.isEmpty, query.allSatisfy(\.isFinite) else { return [:] }
        var queryNorm: Float = 0
        vDSP_svesq(query, 1, &queryNorm, vDSP_Length(query.count))
        guard queryNorm > 0 else { return [:] }
        var result: [String: Double] = [:]
        for article in articles {
            guard let vector = vectors[article.id], vector.model == RecommendationNativeModels.embeddingID,
                  vector.fingerprint == RecommendationGraphEngine.hash(RecommendationContentText.embeddingInput(article)),
                  vector.values.count == query.count, vector.values.allSatisfy(\.isFinite) else { continue }
            var dot: Float = 0, norm: Float = 0
            vDSP_dotpr(query, 1, vector.values, 1, &dot, vDSP_Length(query.count))
            vDSP_svesq(vector.values, 1, &norm, vDSP_Length(query.count))
            if norm > 0 { result[article.id] = Double(dot / sqrt(norm * queryNorm)) }
        }
        return result
    }
}

extension RecommendationGraphEngine {
    func search(query: String, articles: [Article], feedTitles: [String: String], html: [String: String],
                update: @MainActor @Sendable (ArticleSearchUpdate) async -> Void) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !articles.isEmpty else {
            await update(.init(ids: [], isSearching: false, usesMeaning: false))
            return
        }
        var enriched = articles
        for index in enriched.indices {
            let id = enriched[index].id
            guard let source = html[id] else { continue }
            let paragraphs: [String]
            if let cached = searchBodies[id], cached.html == source { paragraphs = cached.paragraphs }
            else {
                paragraphs = RecommendationLibrarySnapshot.paragraphs(source)
                searchBodies[id] = (source, paragraphs)
            }
            if !paragraphs.isEmpty { enriched[index].bodyParagraphs = paragraphs }
        }
        let documents = enriched
        let lexical = ArticleSearchRanking.lexical(query: query, articles: documents, feedTitles: feedTitles)
        #if arch(arm64)
        let ready = await RecommendationModelAssets.shared.isInstalled()
        #else
        let ready = false
        #endif
        guard !Task.isCancelled else { return }
        await update(.init(ids: ArticleSearchRanking.rank(query: query, articles: documents, lexical: lexical, semantic: [:]),
                           isSearching: ready, usesMeaning: ready))
        guard ready else { return }
        do {
            load()
            let embeddingQuery = "Instruct: Given a search query, retrieve relevant articles that answer the query.\nQuery: " + query
            let queryVector: [Float]
            if let cached = searchQueries[embeddingQuery] { queryVector = cached }
            else {
                queryVector = try await RecommendationNativeModels.shared.embed([embeddingQuery]).first ?? []
                try Task.checkCancellation()
                if searchQueries.count >= 32 { searchQueries.removeAll() }
                searchQueries[embeddingQuery] = queryVector
            }
            func publish(_ semantic: [String: Double], searching: Bool) async {
                guard !Task.isCancelled else { return }
                await update(.init(ids: ArticleSearchRanking.rank(query: query, articles: documents, lexical: lexical, semantic: semantic),
                                   isSearching: searching, usesMeaning: true, indexed: semantic.count, total: documents.count))
            }
            var similarities = ArticleSearchRanking.similarities(query: queryVector, articles: documents, vectors: vectors)
            let missing = documents.filter { similarities[$0.id] == nil }.sorted { (lexical[$0.id] ?? 0) > (lexical[$1.id] ?? 0) }
            await publish(similarities, searching: !missing.isEmpty)
            for start in stride(from: 0, to: missing.count, by: 8) {
                try Task.checkCancellation()
                // The map may have indexed this batch while the query was running.
                let batch = missing[start..<min(start + 8, missing.count)].filter {
                    vectors[$0.id]?.fingerprint != Self.hash(RecommendationContentText.embeddingInput($0))
                        || vectors[$0.id]?.model != RecommendationNativeModels.embeddingID
                        || vectors[$0.id]?.values.count != 1024
                        || vectors[$0.id]?.values.allSatisfy(\.isFinite) != true
                }
                if !batch.isEmpty {
                    let texts = batch.map(RecommendationContentText.embeddingInput)
                    let encoded = try await RecommendationNativeModels.shared.embed(texts)
                    try Task.checkCancellation()
                    guard encoded.count == batch.count else { throw RecommendationModelError.invalidVector }
                    for (index, article) in batch.enumerated() {
                        guard encoded[index].count == 1024, encoded[index].allSatisfy(\.isFinite) else { throw RecommendationModelError.invalidVector }
                        vectors[article.id] = .init(model: RecommendationNativeModels.embeddingID, values: encoded[index], fingerprint: Self.hash(texts[index]))
                    }
                }
                if start % 128 == 0 { save(vectors, name: "vectors.plist") }
                if start % 32 == 0 || start + 8 >= missing.count {
                    similarities = ArticleSearchRanking.similarities(query: queryVector, articles: documents, vectors: vectors)
                    await publish(similarities, searching: start + 8 < missing.count)
                }
            }
            if !missing.isEmpty { save(vectors, name: "vectors.plist") }
        } catch {
            guard !Task.isCancelled else { return }
            await update(.init(ids: ArticleSearchRanking.rank(query: query, articles: documents, lexical: lexical, semantic: [:]),
                               isSearching: false, usesMeaning: false))
        }
    }
}

/// Keep keyboard focus on a story ID when semantic results arrive or reorder.
struct ArticleSearchSelection {
    var id: String?
    mutating func reconcile(_ ids: [String]) { if !ids.contains(id ?? "") { id = ids.first } }
    mutating func move(_ delta: Int, in ids: [String]) {
        guard !ids.isEmpty else { id = nil; return }
        let current = id.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        id = ids[min(ids.count - 1, max(0, current + delta))]
    }
}
#endif
