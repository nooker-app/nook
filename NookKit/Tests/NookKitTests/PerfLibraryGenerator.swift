import Foundation
import Testing
@testable import NookKit

@Suite("Deterministic performance library generator")
struct PerfLibraryGenerator {
    private static let deviceID = "nook-perf-device"
    private static let referenceDate = Date(timeIntervalSince1970: 1_759_276_800) // 2026-10-01T00:00:00Z
    private static let feedCount = 300

    @Test(
        "generate performance library",
        .enabled(if: ProcessInfo.processInfo.environment["NOOK_GEN_PERF_LIB"] != nil,
                 "Set NOOK_GEN_PERF_LIB to generate a golden library")
    )
    func generate() throws {
        let environment = ProcessInfo.processInfo.environment
        let output = try #require(environment["NOOK_GEN_PERF_LIB"])
        let articleCount = Int(environment["NOOK_GEN_N"] ?? "10000") ?? 10_000
        guard [5_000, 10_000, 20_000].contains(articleCount) else {
            throw GeneratorError.invalidArticleCount(articleCount)
        }

        let outputURL = URL(filePath: output, directoryHint: .isDirectory)
        guard outputURL.deletingLastPathComponent().lastPathComponent == "golden",
              ["lib-5k", "lib-10k", "lib-20k"].contains(outputURL.lastPathComponent) else {
            throw GeneratorError.unsafeOutput(outputURL.path)
        }
        // A generator run is a full replacement, not ReaderStorage's normal
        // additive user-data save. This target is explicitly supplied by the
        // caller and never points at the app's selected library.
        if FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: outputURL)
        }
        // Feed XML is per library: lib-20k's feed-big must not leak into a
        // lib-10k refresh. run.sh serves feeds/<lib>/<variant>.
        let feedsRoot = outputURL.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "feeds", directoryHint: .isDirectory)
            .appending(path: outputURL.lastPathComponent, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: feedsRoot.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: feedsRoot)
        }
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        var rng = SplitMix64(seed: 42)
        let fixture = try Self.makeFixture(articleCount: articleCount, rng: &rng)
        let (feeds, folders, articles, byFeed) = (fixture.feeds, fixture.folders, fixture.articles, fixture.byFeed)
        #expect(articles.count == articleCount)
        #expect(byFeed[Self.feedCount - 2].count == 30)
        #expect(byFeed[Self.feedCount - 1].count == Self.articleCounts(total: articleCount).max())

        let storage = ReaderStorage(directoryURL: outputURL)
        let library = ReaderLibrary(
            feeds: feeds,
            articles: articles,
            lastRefreshedAt: Self.referenceDate,
            folders: folders
        )
        try storage.save(library)

        let categories = Self.categories
        let shard = Self.makeStateShard(feeds: feeds, folders: folders, articles: articles, categories: categories)
        try storage.saveShard(shard)

        let bodies = Self.retainedBodies(articles: articles)
        try storage.saveContent(bodies, retain: Set(bodies.keys))

        // Every feed shares the localhost host key, matching ReaderStore.faviconKey(for:).
        try storage.writeFaviconData(Self.onePixelPNG, forKey: "127.0.0.1")
        try Self.writeFeedVariants(feeds: feeds, current: byFeed, at: feedsRoot)
        try Self.canonicalizeJSONFiles(in: outputURL)

        let unread = articles.indices.count(where: { $0 % 5 < 3 })
        let starred = articles.indices.count(where: { $0 % 50 == 0 })
        print("perf.library articles=\(articles.count) unread=\(unread) starred=\(starred) feeds=\(feeds.count)")
    }

    private struct Fixture {
        let feeds: [Feed]
        let folders: [String]
        let articles: [Article]
        let byFeed: [[Article]]
    }

    private static func makeFixture(articleCount: Int, rng: inout SplitMix64) throws -> Fixture {
        let folders = (1...12).map { String(format: "Folder %02d", $0) }
        let counts = articleCounts(total: articleCount)
        let feeds = (0..<feedCount).map { index in
            Feed(
                id: feedID(index),
                title: "Perf Feed \(String(format: "%03d", index + 1)) 성능 뉴스",
                siteDescription: "Deterministic performance feed \(index + 1)",
                category: folders[index % folders.count],
                systemImage: "dot.radiowaves.left.and.right",
                feedURL: URL(string: "http://127.0.0.1:8765/f/\(index).xml")!,
                siteURL: URL(string: "http://127.0.0.1:8765/site/\(index)")!,
                healthScore: 1,
                lastFetchedAt: referenceDate
            )
        }

        var articles: [Article] = []
        articles.reserveCapacity(articleCount)
        var byFeed = Array(repeating: [Article](), count: feedCount)
        var globalIndex = 0
        for feedIndex in 0..<feedCount {
            byFeed[feedIndex].reserveCapacity(counts[feedIndex])
            for localIndex in 0..<counts[feedIndex] {
                // RSSFeedService builds "<feed.id>#<guid>" (RSSFeedService.swift:463)
                // and ReaderStore re-keys it onto the library feed id, so the
                // fixture must use the same shape or every refresh looks new.
                let id = articleID(feedID: feeds[feedIndex].id, guid: "perf-item-\(feedIndex)-\(localIndex)")
                let category = "perf-cat-\((globalIndex % 8) + 1)"
                let title = makeTitle(index: globalIndex, rng: &rng)
                let summary = makeSummary(index: globalIndex, keyword: category, rng: &rng)
                let article = Article(
                    id: id,
                    feedID: feeds[feedIndex].id,
                    title: title,
                    summary: summary,
                    bodyParagraphs: [],
                    publishedAt: referenceDate.addingTimeInterval(TimeInterval(-globalIndex * 113)),
                    url: URL(string: "http://127.0.0.1:8765/article/\(feedIndex)/\(localIndex)")!,
                    estimatedReadMinutes: 1 + Int(rng.next() % 12),
                    isRead: false,
                    isStarred: false
                )
                articles.append(article)
                byFeed[feedIndex].append(article)
                globalIndex += 1
            }
        }
        // The newest window is exactly what refresh serves. Build those stored
        // values with the production parser, then re-key them exactly as
        // ReaderStore does. This keeps every field used by Article equality —
        // including bodyParagraphs/contentHTML/read time — identical on B1.
        for feedIndex in feeds.indices {
            let parsed = try parsedFeed(
                feed: feeds[feedIndex],
                index: feedIndex,
                current: byFeed[feedIndex],
                variant: "none"
            )
            let parsedByID = Dictionary(uniqueKeysWithValues: parsed.articles.map { ($0.id, $0) })
            byFeed[feedIndex] = byFeed[feedIndex].map { parsedByID[$0.id] ?? $0 }
        }
        articles = byFeed.flatMap { $0 }
        return Fixture(feeds: feeds, folders: folders, articles: articles, byFeed: byFeed)
    }

    /// The content sidecar a real library holds in steady state: bodies only
    /// for the ids `ReaderStore.recentArticleIDs(from:)` keeps (the newest 600
    /// by `Article.isOrderedBefore`, ReaderStore.bodyRetentionLimit), which is
    /// what every replica save retains. Feed-window articles outside that set
    /// load without a body, exactly as after a real relaunch. Retained articles
    /// that no feed window gave a body get a deterministic two-paragraph one.
    private static func retainedBodies(articles: [Article]) -> [Article.ID: ArticleBody] {
        let retained = ReaderStore.recentArticleIDs(from: articles)
        var bodies: [Article.ID: ArticleBody] = [:]
        for article in articles where retained.contains(article.id) {
            if article.hasBody {
                bodies[article.id] = article.body
                continue
            }
            let paragraphs = [
                "\(article.title) 본문 첫 문단입니다. Performance fixture body paragraph one.",
                "스크롤과 리더 로딩을 재현하는 결정적 본문입니다. Deterministic body paragraph two.",
            ]
            bodies[article.id] = ArticleBody(
                bodyParagraphs: paragraphs,
                contentHTML: "<p>\(xmlEscape(paragraphs.joined(separator: "</p><p>")))</p>"
            )
        }
        return bodies
    }

    private static func articleID(feedID: String, guid: String) -> String {
        "\(feedID)#\(guid)"
    }

    /// B1 must stay observation-silent after loading a list-light baseline:
    /// fetched bodies beyond the retained 600 are hydration, not content edits.
    @Test("none XML merge adds zero articles and changes no existing articles")
    @MainActor
    func noneRefreshMergeIsNoop() throws {
        var rng = SplitMix64(seed: 42)
        let fixture = try Self.makeFixture(articleCount: 5_000, rng: &rng)
        let categories = Self.categories
        let shard = Self.makeStateShard(
            feeds: fixture.feeds,
            folders: fixture.folders,
            articles: fixture.articles,
            categories: categories
        )
        let base = ReaderLibrary(
            feeds: fixture.feeds,
            articles: fixture.articles,
            lastRefreshedAt: Self.referenceDate,
            folders: fixture.folders
        )
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "nook-perf-merge-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = ReaderStorage(directoryURL: directory)
        try storage.save(base)
        try storage.saveShard(shard)
        let bodies = Self.retainedBodies(articles: fixture.articles)
        try storage.saveContent(bodies, retain: Set(bodies.keys))
        #expect(bodies.count == 600)

        var storedBase = try #require(try storage.load())
        let storedBodies = storage.loadContent()
        #expect(storedBodies.count == 600)
        storedBase.articles = storedBase.articles.map { article in
            guard let body = storedBodies[article.id] else { return article }
            var article = article
            article.bodyParagraphs = body.bodyParagraphs
            article.contentHTML = body.contentHTML
            return article
        }
        let materialized = DeviceStateDocument.materialize(
            base: storedBase,
            shards: try storage.loadShards()
        )
        let store = ReaderStore._makeForTesting()
        store.feeds = materialized.feeds
        store.articles = materialized.articles

        var newArticles = 0
        var changedArticles = 0
        var republishedFeeds = 0
        for index in fixture.feeds.indices {
            let feed = fixture.feeds[index]
            let parsed = try Self.parsedFeed(
                feed: feed, index: index, current: fixture.byFeed[index], variant: "none"
            )
            let before = store.articles
            let existingByID = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
            for var article in parsed.articles {
                guard let existing = existingByID[article.id] else {
                    newArticles += 1
                    continue
                }
                article.isRead = existing.isRead
                article.isStarred = existing.isStarred
                article.categories = existing.categories
                if !article.hasExplicitPublishDate { article.publishedAt = existing.publishedAt }
                if ReaderStore.MergeProjection.changed(from: existing, to: article) {
                    changedArticles += 1
                }
            }
            store._mergeForTesting(parsed)
            if store.articles != before { republishedFeeds += 1 }
        }
        print("perf.none.merge new=\(newArticles) changed=\(changedArticles) republishedFeeds=\(republishedFeeds)")
        #expect(newArticles == 0)
        #expect(changedArticles == 0)
        #expect(republishedFeeds == 0)

        let libraryIDs = Set(materialized.articles.map(\.id))
        for index in [0, 29, 30, Self.feedCount - 2, Self.feedCount - 1] {
            let feed = fixture.feeds[index]
            let trickle = try Self.parsedFeed(
                feed: feed, index: index, current: fixture.byFeed[index], variant: "trickle"
            )
            #expect(trickle.articles.count { !libraryIDs.contains($0.id) } == (index < 30 ? 1 : 0))
            let big1 = try Self.parsedFeed(
                feed: feed, index: index, current: fixture.byFeed[index], variant: "big1"
            )
            #expect(big1.articles.count { !libraryIDs.contains($0.id) } == (feed.id == "perf-feed-big" ? 3 : 0))
        }
    }

    private static var categories: [ArticleCategory] {
        (1...8).map { index in
            ArticleCategory(
                id: "perf-cat-\(index)",
                name: "Perf Category \(index)",
                colorHex: ArticleCategory.defaultPalette[(index - 1) % ArticleCategory.defaultPalette.count],
                order: index - 1,
                keywords: ["perf-cat-\(index)"]
            )
        }
    }

    private static func makeStateShard(
        feeds: [Feed], folders: [String], articles: [Article], categories: [ArticleCategory]
    ) -> DeviceStateDocument {
        var shard = DeviceStateDocument(deviceID: deviceID, clock: .zero, updatedAt: referenceDate)
        var clock = HLC(physicalMillis: 1_759_276_800_000, counter: 0, node: deviceID)
        func tick() -> HLC { clock.counter &+= 1; return clock }
        for folder in folders { shard.setFolderPresent(folder, true, hlc: tick()) }
        for category in categories { shard.setCategory(category.id, category, hlc: tick()) }
        for feed in feeds {
            shard.setFeedCategory(feed.id, feed.category, hlc: tick())
            shard.setFeedSeed(feed.id, FeedSeed(from: feed), hlc: tick())
        }
        for (index, article) in articles.enumerated() {
            shard.setArticleRead(article.id, index % 5 >= 3, hlc: tick())
            shard.setArticleStarred(article.id, index % 50 == 0, hlc: tick())
            shard.setArticleCategories(article.id, ["perf-cat-\((index % 8) + 1)"], hlc: tick())
        }
        shard.clock = clock
        shard.generation = 1
        return shard
    }

    private static func parsedFeed(
        feed: Feed, index: Int, current: [Article], variant: String
    ) throws -> ParsedFeed {
        let xml = feedXML(feed: feed, index: index, current: current, variant: variant)
        var parsed = try FeedXMLParser(feedURL: feed.feedURL).parse(data: Data(xml.utf8))
        let oldPrefix = parsed.feed.id + "#"
        parsed.feed.id = feed.id
        parsed.articles = parsed.articles.map { article in
            var article = article
            let seed = article.id.hasPrefix(oldPrefix)
                ? String(article.id.dropFirst(oldPrefix.count)) : article.id
            article.id = articleID(feedID: feed.id, guid: seed)
            article.feedID = feed.id
            return article
        }
        return parsed
    }

    private static func feedID(_ index: Int) -> String {
        if index == feedCount - 2 { return "perf-feed-small" }
        if index == feedCount - 1 { return "perf-feed-big" }
        return "perf-feed-\(index)"
    }

    private static func articleCounts(total: Int) -> [Int] {
        // Rank 1 is reserved for feed-big. Exponent 0.775 puts roughly 30% in
        // the top ten while retaining a long Zipf tail. feed-small stays exact.
        let rankedIndices = [feedCount - 1] + Array(0..<(feedCount - 2))
        let available = total - 30
        let weights = rankedIndices.indices.map { 1.0 / pow(Double($0 + 1), 0.775) }
        let sum = weights.reduce(0, +)
        let raw = weights.map { Double(available) * $0 / sum }
        var allocated = raw.map { Int(floor($0)) }
        var remainder = available - allocated.reduce(0, +)
        let order = raw.indices.sorted {
            let left = raw[$0] - Double(allocated[$0])
            let right = raw[$1] - Double(allocated[$1])
            return left == right ? $0 < $1 : left > right
        }
        for rank in order where remainder > 0 {
            allocated[rank] += 1
            remainder -= 1
        }
        var result = Array(repeating: 0, count: feedCount)
        result[feedCount - 2] = 30
        for (rank, feedIndex) in rankedIndices.enumerated() { result[feedIndex] = allocated[rank] }
        return result
    }

    private static func makeTitle(index: Int, rng: inout SplitMix64) -> String {
        let chunks = ["대규모 목록 성능", "native reader", "스크롤 지연 분석", "background refresh", "새로운 피드 소식", "SwiftUI rendering"]
        var value = "\(index + 1) · "
        while value.count < 48 + Int(rng.next() % 35) {
            value += chunks[Int(rng.next() % UInt64(chunks.count))] + " "
        }
        return String(value.prefix(90)).trimmingCharacters(in: .whitespaces)
    }

    private static func makeSummary(index: Int, keyword: String, rng: inout SplitMix64) -> String {
        let chunks = ["결정적인 성능 측정을 위한 한국어 요약입니다.", "This English sentence keeps the fixture representative.", "목록 전환과 새로고침의 실제 비용을 관찰합니다.", "Rendering remains native and reproducible across runs."]
        var value = "\(keyword) article \(index + 1). "
        while value.count < 200 { value += chunks[Int(rng.next() % UInt64(chunks.count))] + " " }
        return String(value.prefix(220)).trimmingCharacters(in: .whitespaces)
    }

    private static let feedVariants = ["none", "trickle", "burst", "big1"]
    /// Real feeds publish a rolling window, not their whole history; serving
    /// feed-big's ~1000 items would inflate B merge cost.
    private static let feedWindow = 30

    private static func writeFeedVariants(feeds: [Feed], current: [[Article]], at root: URL) throws {
        for variant in feedVariants {
            let directory = root.appending(path: variant).appending(path: "f")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for index in feeds.indices {
                let xml = feedXML(feed: feeds[index], index: index, current: current[index], variant: variant)
                try Data(xml.utf8).write(to: directory.appending(path: "\(index).xml"), options: [.atomic])
            }
        }
    }

    private static func feedXML(feed: Feed, index: Int, current: [Article], variant: String) -> String {
        // `current` is newest-first, so the prefix is the feed's latest window.
        var items = Array(current.prefix(feedWindow))
        let additions: Int
        switch variant {
        case "trickle": additions = index < 30 ? 1 : 0
        case "burst": additions = 5
        case "big1": additions = feed.id == "perf-feed-big" ? 3 : 0
        default: additions = 0
        }
        for extra in 0..<additions {
            items.insert(Article(
                id: articleID(feedID: feed.id, guid: "perf-new-\(index)-\(extra)"), feedID: feed.id,
                title: "New performance item \(extra + 1) 새 글", summary: "Deterministic refresh item",
                bodyParagraphs: [], publishedAt: referenceDate.addingTimeInterval(TimeInterval(60 + extra)),
                url: URL(string: "http://127.0.0.1:8765/new/\(index)/\(extra)")!,
                estimatedReadMinutes: 2, isRead: false, isStarred: false
            ), at: 0)
        }
        return rss(feed: feed, articles: items)
    }

    /// ReaderStorage's compact shard encoder intentionally skips sorted keys for
    /// interactive write speed. Golden fixtures trade write speed for stable
    /// bytes, so canonicalize the API-produced JSON without constructing schema.
    private static func canonicalizeJSONFiles(in root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return }
        for case let url as URL in enumerator where url.pathExtension == "json" {
            let data = try Data(contentsOf: url)
            let object = try JSONSerialization.jsonObject(with: data)
            let canonical = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            try canonical.write(to: url, options: [.atomic])
        }
    }

    private static func rss(feed: Feed, articles: [Article]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let items = articles.map { article in
            let guid = article.id.hasPrefix(feed.id + "#") ? String(article.id.dropFirst(feed.id.count + 1)) : article.id
            return "<item><guid isPermaLink=\"false\">\(xmlEscape(guid))</guid><title>\(xmlEscape(article.title))</title><link>\(xmlEscape(article.url.absoluteString))</link><description>\(xmlEscape(article.summary))</description><pubDate>\(formatter.string(from: article.publishedAt))</pubDate></item>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><rss version=\"2.0\"><channel><title>\(xmlEscape(feed.title))</title><link>\(xmlEscape(feed.siteURL.absoluteString))</link><description>\(xmlEscape(feed.siteDescription))</description>\(items)</channel></rss>"
    }

    private static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
}

private enum GeneratorError: Error {
    case invalidArticleCount(Int)
    case unsafeOutput(String)
}

private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
