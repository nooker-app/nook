import CryptoKit
import Foundation
import NaturalLanguage
import Observation

/// Device-local positive feedback. Read flags deliberately are NOT feedback:
/// importing a library or marking a feed read says nothing about interest.
struct MagazineReadingHistory: Codable, Sendable {
    struct Entry: Codable, Sendable {
        var seconds: Double
        var lastRead: Date
    }
    var entries: [Article.ID: Entry] = [:]

    mutating func record(_ id: Article.ID, seconds: Double, now: Date) {
        guard seconds.isFinite, seconds > 0 else { return }
        let previous = entries[id]?.seconds ?? 0
        entries[id] = Entry(seconds: min(600, previous + min(seconds, 30)), lastRead: now)
        entries = entries.filter { now.timeIntervalSince($0.value.lastRead) < 90 * 86400 }
        if entries.count > 500 {
            entries = Dictionary(uniqueKeysWithValues: entries.sorted {
                $0.value.lastRead > $1.value.lastRead
            }.prefix(500).map { ($0.key, $0.value) })
        }
    }

    func weight(for article: Article, now: Date) -> Double {
        let reading = entries[article.id].map { entry in
            entry.seconds >= 10
                ? min(2, entry.seconds / 45) * exp(-max(0, now.timeIntervalSince(entry.lastRead)) / (30 * 86400))
                : 0
        } ?? 0
        return (article.isStarred ? 3 : 0) + reading
    }
}

public struct MagazineRecommendation: Sendable {
    public let articleID: Article.ID
    public let personalized: Bool
}

/// TF–IDF content affinity + bounded source/category affinity + freshness.
/// New RSS items have no collaborative history, so a fixed item-item model is
/// a poor fit. Native contextual embeddings only rerank a small shortlist when
/// their assets already exist; the complete base ranker works without downloads.
actor MagazineRecommendationRanker {
    struct Scored: Sendable {
        let article: Article
        var score: Double
    }
    private var tokenCache: [String: Set<String>] = [:]
    private var vectorCache: [String: SemanticVector] = [:]
    private struct SemanticVector {
        let model: String
        let values: [Double]
    }

    func rank(candidates: [Article], library: [Article], history: MagazineReadingHistory,
              now: Date, useSemantics: Bool = true) -> MagazineRecommendation? {
        // Membership comes from ReaderStore's complete filtered result, not its
        // first rendering window. Prefer unread articles within that scope.
        let unread = candidates.filter { !$0.isRead }
        let pool = Array((unread.isEmpty ? candidates : unread).sorted(by: newer).prefix(600))
        guard !pool.isEmpty, !Task.isCancelled else { return nil }
        let evidence = library.compactMap { article -> (Article, Double)? in
            let weight = history.weight(for: article, now: now)
            return weight > 0 ? (article, weight) : nil
        }.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? newer(lhs.0, rhs.0) : lhs.1 > rhs.1
        }.prefix(120)
        guard !evidence.isEmpty else {
            return MagazineRecommendation(articleID: pool[0].id, personalized: false)
        }

        let documents = pool + evidence.map(\.0)
        var frequency: [String: Double] = [:]
        var terms: [Article.ID: Set<String>] = [:]
        for article in documents {
            if Task.isCancelled { return nil }
            guard terms[article.id] == nil else { continue }
            let words = tokens(article)
            terms[article.id] = words
            for word in words { frequency[word, default: 0] += 1 }
        }
        let count = Double(terms.count)
        let idf = frequency.mapValues { log((1 + count) / (1 + $0)) + 1 }
        func vector(_ article: Article) -> [String: Double] {
            let raw = Dictionary(uniqueKeysWithValues: (terms[article.id] ?? []).map { ($0, idf[$0] ?? 1) })
            let norm = sqrt(raw.values.reduce(0) { $0 + $1 * $1 })
            return norm > 0 ? raw.mapValues { $0 / norm } : [:]
        }
        var profile: [String: Double] = [:]
        var feeds: [Feed.ID: Double] = [:]
        var categories: [String: Double] = [:]
        var total = 0.0
        for (article, weight) in evidence {
            total += weight
            for (term, value) in vector(article) { profile[term, default: 0] += value * weight }
            feeds[article.feedID, default: 0] += weight
            for category in article.categories { categories[category, default: 0] += weight }
        }
        let norm = sqrt(profile.values.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { profile = profile.mapValues { $0 / norm } }
        var ranked = pool.map { article in
            let affinity = vector(article).reduce(0) { $0 + $1.value * (profile[$1.key] ?? 0) }
            let source = (feeds[article.feedID] ?? 0) / total
            let category = article.categories.map { (categories[$0] ?? 0) / total }.max() ?? 0
            let freshness = exp(-max(0, now.timeIntervalSince(article.publishedAt)) / (7 * 86400))
            // A small novelty bonus gives unfamiliar publications a way in.
            let discovery = source == 0 ? 0.04 : 0
            let seen = history.entries[article.id].map {
                $0.seconds >= 10 ? 0.28 * exp(-max(0, now.timeIntervalSince($0.lastRead)) / 86400) : 0
            } ?? 0
            return Scored(article: article, score: 0.48 * affinity + 0.16 * source
                + 0.10 * category + 0.26 * freshness + discovery - seen)
        }.sorted(by: higher)

        if useSemantics {
            // Bound cold inference as well as memory. Never request model assets,
            // contact a provider, or compare vectors from different model spaces.
            let deadline = ContinuousClock.now + .seconds(1)
            var models: [NLLanguage: NLContextualEmbedding] = [:]
            defer { for model in models.values { model.unload() } }
            var references: [(SemanticVector, Double)] = []
            for (article, weight) in evidence.prefix(6) {
                guard !Task.isCancelled, ContinuousClock.now < deadline,
                      let vector = semantic(article.title, models: &models) else { continue }
                references.append((vector, weight))
            }
            if !references.isEmpty {
                for index in ranked.indices.prefix(12) {
                    guard !Task.isCancelled, ContinuousClock.now < deadline else { break }
                    guard let value = semantic(ranked[index].article.title, models: &models) else { continue }
                    let matches = references.filter { $0.0.model == value.model }
                    let weight = matches.reduce(0) { $0 + $1.1 }
                    guard weight > 0 else { continue }
                    let similarity = matches.reduce(0) { sum, reference in
                        sum + zip(value.values, reference.0.values).reduce(0) { $0 + $1.0 * $1.1 } * reference.1
                    } / weight
                    ranked[index].score += 0.12 * max(0, similarity)
                }
                ranked.sort(by: higher)
            }
        }
        if tokenCache.count > 1500 { tokenCache.removeAll(keepingCapacity: true) }
        if vectorCache.count > 512 { vectorCache.removeAll(keepingCapacity: true) }
        guard !Task.isCancelled, let first = ranked.first else { return nil }
        return MagazineRecommendation(articleID: first.article.id, personalized: true)
    }

    private func newer(_ lhs: Article, _ rhs: Article) -> Bool {
        lhs.publishedAt == rhs.publishedAt ? lhs.id < rhs.id : lhs.publishedAt > rhs.publishedAt
    }

    private func higher(_ lhs: Scored, _ rhs: Scored) -> Bool {
        lhs.score == rhs.score ? newer(lhs.article, rhs.article) : lhs.score > rhs.score
    }

    private func tokens(_ article: Article) -> Set<String> {
        let text = String(article.title.prefix(300)) + " " + String(article.summary.prefix(400))
        if let cached = tokenCache[text] { return cached }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text.lowercased()
        let normalized = tokenizer.string!
        let stop: Set<String> = ["the", "and", "for", "with", "from", "this", "that", "are", "was", "has",
                                "have", "your", "you", "its", "how", "what", "대한", "위한", "있는", "하는"]
        var result = Set<String>()
        tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { range, _ in
            let word = String(normalized[range])
            if word.count > 1, !stop.contains(word), word.unicodeScalars.contains(where: CharacterSet.letters.contains) {
                result.insert(word)
            }
            return true
        }
        tokenCache[text] = result
        return result
    }

    private func semantic(_ title: String, models: inout [NLLanguage: NLContextualEmbedding]) -> SemanticVector? {
        let text = String(title.prefix(180))
        if let cached = vectorCache[text] { return cached }
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else { return nil }
        let model: NLContextualEmbedding
        if let existing = models[language] { model = existing }
        else {
            guard let available = NLContextualEmbedding(language: language), available.hasAvailableAssets else { return nil }
            models[language] = available
            model = available
        }
        guard let result = try? model.embeddingResult(for: text, language: language) else { return nil }
        var pooled = [Double](repeating: 0, count: model.dimension)
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { values, _ in
            for index in pooled.indices { pooled[index] += values[index] }
            return true
        }
        let norm = sqrt(pooled.reduce(0) { $0 + $1 * $1 })
        guard norm > 0, norm.isFinite else { return nil }
        let value = SemanticVector(model: model.modelIdentifier, values: pooled.map { $0 / norm })
        vectorCache[text] = value
        return value
    }
}

@MainActor @Observable
public final class MagazineRecommendationController {
    public static let enabledKey = "magazineRecommendationsEnabled"
    public static let resetKey = "magazineRecommendationsReset"
    public private(set) var revision = 0
    private var history = MagazineReadingHistory()
    private var scope = ""
    private let defaults: UserDefaults
    private let ranker = MagazineRecommendationRanker()
    private var storageKey: String { "magazineReadingHistory.v1." + scope }

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func selectLibrary(_ identifier: String) {
        let key = SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
        guard key != scope else { return }
        scope = key
        history = defaults.data(forKey: storageKey).flatMap {
            try? JSONDecoder().decode(MagazineReadingHistory.self, from: $0)
        } ?? MagazineReadingHistory()
        revision &+= 1
    }

    public func recordReading(articleID: Article.ID, seconds: Double, now: Date = .now) {
        guard !scope.isEmpty else { return }
        history.record(articleID, seconds: seconds, now: now)
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: storageKey) }
        revision &+= 1
    }

    public func reloadAfterReset() {
        history = MagazineReadingHistory()
        revision &+= 1
    }

    public static func reset(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("magazineReadingHistory.v1.") {
            defaults.removeObject(forKey: key)
        }
        defaults.set(defaults.integer(forKey: resetKey) + 1, forKey: resetKey)
    }

    public func recommend(candidates: [Article], library: [Article], personalized: Bool) async -> MagazineRecommendation? {
        await ranker.rank(candidates: candidates, library: personalized ? library : [],
                          history: personalized ? history : MagazineReadingHistory(), now: .now)
    }
}
