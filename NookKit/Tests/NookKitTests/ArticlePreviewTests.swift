import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import NookKit

@Suite("Magazine preview budgets")
struct ArticlePreviewBudgetTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func feedAndSharedHostLimits() {
        var budget = ArticlePreviewBudget()
        var policy = ArticlePreviewPolicy()
        policy.interval = 3
        policy.requestsPerMinute = 2
        budget.started(feed: "a", host: "publisher.test", policy: policy, now: now)
        #expect(budget.delay(feed: "a", host: "cdn.test", policy: policy, now: now) == 3)
        #expect(budget.delay(feed: "b", host: "publisher.test", policy: policy, now: now) == 3)
        #expect(budget.delay(feed: "b", host: "other.test", policy: policy, now: now) == 0)
        budget.started(feed: "a", host: "publisher.test", policy: policy, now: now.addingTimeInterval(3))
        #expect(budget.delay(feed: "a", host: "publisher.test", policy: policy, now: now.addingTimeInterval(4)) == 56)
        #expect(budget.delay(feed: "a", host: "publisher.test", policy: policy, now: now.addingTimeInterval(60)) == 0)
    }

    @Test func retryAfterSurvivesRestartAndBeatsUserLimits() throws {
        var budget = ArticlePreviewBudget()
        let policy = ArticlePreviewPolicy()
        budget.started(feed: "a", host: "server.test", policy: policy, now: now)
        budget.finished(feed: "a", host: "server.test", status: 429, retryAfter: "120", now: now)
        let restored = try JSONDecoder().decode(ArticlePreviewBudget.self, from: JSONEncoder().encode(budget))
        #expect(restored.delay(feed: "b", host: "server.test", policy: policy, now: now.addingTimeInterval(10)) == 110)
        #expect(restored.delay(feed: "a", host: "cdn.test", policy: policy, now: now.addingTimeInterval(10)) == 110)
        budget.finished(feed: "a", host: "server.test", status: 503, retryAfter: nil, now: now.addingTimeInterval(130))
        #expect(budget.delay(feed: "a", host: "server.test", policy: policy, now: now.addingTimeInterval(130)) == 30)
    }

    @Test func retryAfterDateAndInvalidValues() {
        let date = ArticlePreviewBudget.retryDate("Wed, 21 Oct 2015 07:28:00 GMT", now: .distantPast)
        #expect(date == Date(timeIntervalSince1970: 1_445_412_480))
        #expect(ArticlePreviewBudget.retryDate("NaN", now: now) == nil)
        #expect(ArticlePreviewBudget.retryDate("-2", now: now) == nil)
        #expect(ArticlePreviewBudget.retryDate("nonsense", now: now) == nil)
    }

    @Test @MainActor func preferencesRoundTripAndGlobalPause() throws {
        let suite = "MagazinePreview.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ArticlePreviewPreferences(defaults: defaults)
        var custom = ArticlePreviewPolicy()
        custom.interval = 17
        custom.requestsPerMinute = 4
        preferences.setOverride(custom, for: "a")
        var standard = ArticlePreviewPolicy()
        standard.enabled = false
        preferences.setStandard(standard)
        let restored = ArticlePreviewPreferences(defaults: defaults)
        #expect(restored.override(for: "a") == custom)
        #expect(restored.policy(for: "a").enabled == false)
        #expect(restored.policy(for: "a").interval == 17)
        restored.setOverride(nil, for: "a")
        #expect(restored.policy(for: "a").interval == 3)
    }
}

@Suite("Magazine cover discovery")
struct ArticlePreviewHTMLTests {
    @Test func metadataRelativeLazyImagesAndTrackingPixels() {
        let html = #"""
        <img src='/tracker.gif' width='1' height='1'>
        <img src='data:image/gif;base64,AAA' data-src='../body.jpg'>
        <meta content="//cdn.test/cover.jpg?a=1&amp;b=2" property="og:image">
        <meta name='twitter:image' content='javascript:alert(1)'>
        <img srcset='/small.jpg 320w, /large.jpg 1200w'>
        """#
        let result = ArticlePreviewHTML.images(in: html, baseURL: URL(string: "https://example.test/posts/one")!)
        #expect(result.map(\.absoluteString) == ["https://cdn.test/cover.jpg?a=1&b=2", "https://example.test/body.jpg", "https://example.test/large.jpg"])
    }

    @Test func noImageIsAValidResult() {
        #expect(ArticlePreviewHTML.images(in: "<article><p>Just words.</p></article>", baseURL: URL(string: "https://example.test")!).isEmpty)
    }
}

@Suite("Magazine cache and cancellation", .serialized)
struct ArticlePreviewCacheTests {
    final class HeldRequest: URLProtocol, @unchecked Sendable {
        static let lock = NSLock()
        nonisolated(unsafe) static var starts = 0
        nonisolated(unsafe) static var stops = 0
        static func reset() { lock.withLock { starts = 0; stops = 0 } }
        static var counts: (Int, Int) { lock.withLock { (starts, stops) } }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { Self.lock.withLock { Self.starts += 1 } }
        override func stopLoading() { Self.lock.withLock { Self.stops += 1 } }
    }

    final class Stub: URLProtocol, @unchecked Sendable {
        struct Reply: Sendable {
            var data: Data
            var status = 200
            var headers = ["Content-Type": "text/html"]
        }
        static let lock = NSLock()
        nonisolated(unsafe) static var replies: [String: Reply] = [:]
        nonisolated(unsafe) static var requests: [String] = []
        static func reset(_ values: [String: Reply]) { lock.withLock { replies = values; requests = [] } }
        static func count(_ path: String) -> Int { lock.withLock { requests.filter { $0 == path }.count } }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}
        override func startLoading() {
            let path = request.url!.path
            let reply = Self.lock.withLock {
                Self.requests.append(path)
                return Self.replies[path] ?? Reply(data: Data(), status: 404)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return URLSession(configuration: config)
    }
    private func folder() -> URL { URL.temporaryDirectory.appending(path: "nook-preview-test-\(UUID())") }
    private func article(_ path: String) -> Article {
        var article = Fixture.article(path, feedID: "feed")
        article.url = URL(string: "https://publisher.test/\(path)")!
        return article
    }

    @Test func concurrentCardsAndDiskReuseFetchOnce() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        Stub.reset(["/one": .init(data: Data("<article>Text without images.</article>".utf8))])
        let cache = ArticlePreviewCache(directory: folder, session: session())
        async let first = cache.prepare(article("one"), policy: ArticlePreviewPolicy())
        async let second = cache.prepare(article("one"), policy: ArticlePreviewPolicy())
        _ = try await (first, second)
        #expect(Stub.count("/one") == 1)
        let restored = ArticlePreviewCache(directory: folder, session: session())
        _ = try await restored.prepare(article("one"), policy: ArticlePreviewPolicy())
        #expect(Stub.count("/one") == 1)
        #expect(await restored.cachedPage(for: article("one"))?.html?.contains("Text without") == true)
    }

    @Test func disabledPreviewAndNoStoreResponsesDoNotPersist() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        Stub.reset(["/one": .init(data: Data("<p>Private response</p>".utf8), headers: ["Content-Type": "text/html", "Cache-Control": "no-store"])])
        let cache = ArticlePreviewCache(directory: folder, session: session())
        var policy = ArticlePreviewPolicy()
        policy.enabled = false
        _ = try await cache.prepare(article("one"), policy: policy)
        #expect(Stub.count("/one") == 0)
        policy.enabled = true
        _ = try await cache.prepare(article("one"), policy: policy)
        #expect(Stub.count("/one") == 1)
        #expect(await cache.cachedPage(for: article("one")) == nil)
        let restored = ArticlePreviewCache(directory: folder, session: session())
        #expect(await restored.cachedPage(for: article("one")) == nil)
    }

    @Test func offscreenCardCancelsQueuedRequest() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        Stub.reset(["/one": .init(data: Data("<p>One</p>".utf8))])
        let cache = ArticlePreviewCache(directory: folder, session: session())
        _ = try await cache.prepare(article("one"), policy: ArticlePreviewPolicy())
        let task = Task { try await cache.prepare(article("two"), policy: ArticlePreviewPolicy()) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        _ = try? await task.value
        #expect(Stub.count("/two") == 0)
    }

    @Test(arguments: [true, false])
    func globalAndPerFeedConcurrency(sharedFeed: Bool) async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        HeldRequest.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldRequest.self]
        let cache = ArticlePreviewCache(directory: folder, session: URLSession(configuration: config))
        let tasks = (0..<5).map { index in
            var item = article("\(index)")
            item.url = URL(string: "https://server\(index).test/story")!
            item.feedID = sharedFeed ? "same" : "feed-\(index)"
            let input = item
            return Task { try await cache.prepare(input, policy: ArticlePreviewPolicy()) }
        }
        try await Task.sleep(for: .milliseconds(350))
        #expect(HeldRequest.counts.0 == (sharedFeed ? 1 : 2))
        for task in tasks { task.cancel() }
        for task in tasks { _ = try? await task.value }
        await waitForTransportCancellation()
        #expect(HeldRequest.counts.1 == HeldRequest.counts.0)
    }

    @Test func sharedRequestIsCancelledOnlyAfterLastVisibleCardLeaves() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        HeldRequest.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldRequest.self]
        let cache = ArticlePreviewCache(directory: folder, session: URLSession(configuration: config))
        let first = Task { try await cache.prepare(article("one"), policy: ArticlePreviewPolicy()) }
        let second = Task { try await cache.prepare(article("one"), policy: ArticlePreviewPolicy()) }
        try await Task.sleep(for: .milliseconds(150))
        first.cancel()
        try await Task.sleep(for: .milliseconds(150))
        #expect(HeldRequest.counts.0 == 1)
        #expect(HeldRequest.counts.1 == 0)
        second.cancel()
        _ = try? await first.value
        _ = try? await second.value
        await waitForTransportCancellation()
        #expect(HeldRequest.counts.1 == 1)
    }

    private func waitForTransportCancellation() async {
        // URLSession acknowledges Task cancellation before its delegate queue
        // delivers stopLoading. Wait for that actual transport acknowledgement.
        for _ in 0..<100 {
            if HeldRequest.counts.0 == HeldRequest.counts.1 { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func throttledServerDoesNotCacheFailureOrRetryOnAnotherFeed() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        Stub.reset(["/one": .init(data: Data(), status: 429, headers: ["Retry-After": "120"])])
        let cache = ArticlePreviewCache(directory: folder, session: session())
        _ = try? await cache.prepare(article("one"), policy: ArticlePreviewPolicy())
        #expect(await cache.cachedPage(for: article("one")) == nil)
        let restored = ArticlePreviewCache(directory: folder, session: session())
        var another = article("two")
        another.feedID = "another-feed"
        let next = another
        let task = Task { try await restored.prepare(next, policy: ArticlePreviewPolicy()) }
        try await Task.sleep(for: .milliseconds(250))
        task.cancel()
        _ = try? await task.value
        #expect(Stub.count("/two") == 0)
    }

    @Test func thumbnailDecodedAndCachedAcrossLaunches() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = try #require(CGContext(data: nil, width: 400, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let pixels = try #require(context.makeImage())
        let bytes = NSMutableData()
        let output = try #require(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, pixels, nil)
        #expect(CGImageDestinationFinalize(output))
        Stub.reset([
            "/one": .init(data: Data(#"<meta property='og:image' content='/cover.png'>"#.utf8)),
            "/cover.png": .init(data: bytes as Data, headers: ["Content-Type": "image/png"]),
        ])
        let cache = ArticlePreviewCache(directory: folder, session: session())
        let image = try await cache.prepare(article("one"), policy: ArticlePreviewPolicy())
        #expect(image?.width == 400)
        #expect(Stub.count("/cover.png") == 1)
        let restored = ArticlePreviewCache(directory: folder, session: session())
        #expect(await restored.cachedThumbnail(for: article("one"))?.width == 400)
        _ = try await restored.prepare(article("one"), policy: ArticlePreviewPolicy())
        #expect(Stub.count("/one") == 1)
        #expect(Stub.count("/cover.png") == 1)

        var supplied = article("rss-picture")
        supplied.contentHTML = "<img src='/cover.png'>"
        #expect(try await restored.prepareFeedThumbnail(supplied, policy: ArticlePreviewPolicy())?.width == 400)
        #expect(Stub.count("/rss-picture") == 0)
        #expect(Stub.count("/cover.png") == 1)
    }

    @Test @MainActor func cachedHTMLUsesBothParsersWithoutExecutingPageScripts() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = ArticlePreviewCache(directory: folder, session: session())
        let text = String(repeating: "This is the actual article body about reading and writing native Mac software. ", count: 30)
        let html = "<html><head><title>Cached story</title></head><body><article><h1>Cached story</h1><p>\(text)</p></article><script>document.body.textContent='PAGE SCRIPT RAN';</script></body></html>"
        await cache.seed(article("one"), html: html)
        let extractor = ReaderModeExtractor()
        for engine in ReaderParserEngine.allCases {
            let outcome = await extractor.extractCachedPage(for: article("one"), engine: engine, cache: cache)
            guard case .success(let extracted) = outcome else {
                Issue.record("Cached extraction failed for \(engine)")
                continue
            }
            #expect(extracted.html.contains("actual article body"))
            #expect(!extracted.html.contains("PAGE SCRIPT RAN"))
            #expect(extracted.engine == engine)
        }
    }
}
