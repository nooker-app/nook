import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A bounded, device-local cache for magazine previews. Automatic loads fetch
/// HTML, not a live page: no publisher scripts, ads or subresources execute.
public actor ArticlePreviewCache {
    public static let shared = ArticlePreviewCache()
    public static let didChange = Notification.Name("NookArticlePreviewDidChange")

    struct Page: Codable, Sendable {
        var url: URL
        var html: String?
        var expires: Date
        var imageURLs: [URL]
        var mayStore: Bool
        var sourceFingerprint: String?
        var readingMinutes: Int?
        var readingTimeChecked: Bool?
    }

    private struct Pending {
        var task: Task<Page, Error>
        var clients: Set<UUID>
    }

    private struct Ticket {
        var id: UUID
        var feed: String
        var host: String
        var policy: ArticlePreviewPolicy
        var image: Bool
    }

    private let directory: URL
    private let session: URLSession
    private var budget: ArticlePreviewBudget
    private var queue: [Ticket] = []
    private var active: [UUID: Ticket] = [:]
    private var pending: [URL: Pending] = [:]
    private var memoryPages: [URL: Page] = [:]
    private let images = NSCache<NSURL, CGImage>()

    init(directory: URL? = nil, session: URLSession? = nil) {
        #if DEBUG
        let perfDirectory = PerfLaunch.isActive ? PerfLaunch.value(for: "-NookPerfPreviewCache").map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } : nil
        #else
        let perfDirectory: URL? = nil
        #endif
        self.directory = directory ?? perfDirectory ?? URL.cachesDirectory.appending(path: "Nook/ArticlePreviews", directoryHint: .isDirectory)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        config.httpMaximumConnectionsPerHost = 1
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = session ?? URLSession(configuration: config)
        images.countLimit = 48
        images.totalCostLimit = 64 * 1024 * 1024
        budget = (try? Data(contentsOf: self.directory.appending(path: "budget.json")))
            .flatMap { try? JSONDecoder().decode(ArticlePreviewBudget.self, from: $0) } ?? ArticlePreviewBudget()
    }

    /// Called before the dwell delay, without network or a blank image slot.
    public func cachedThumbnail(for article: Article) -> CGImage? {
        let urls = (cachedPage(for: article)?.imageURLs ?? [])
            + ArticlePreviewHTML.images(in: article.contentHTML ?? "", baseURL: article.url)
        for url in urls {
            if let image = cachedImage(url) { return image }
        }
        return nil
    }

    /// Callers cancel when their card leaves the viewport. A shared page request
    /// survives while another visible card still needs it; the last client stops it.
    public func prepare(_ article: Article, policy: ArticlePreviewPolicy) async throws -> CGImage? {
        guard policy.enabled else { return cachedThumbnail(for: article) }
        let page = try await page(for: article, policy: policy.normalized)
        try Task.checkCancellation()
        let feedImages = ArticlePreviewHTML.images(in: article.contentHTML ?? "", baseURL: article.url)
        return try await thumbnail(from: page.imageURLs + feedImages, for: article, policy: policy, mayStore: page.mayStore)
    }

    /// Feed-provided pictures do not have to wait for the original document.
    public func prepareFeedThumbnail(_ article: Article, policy: ArticlePreviewPolicy) async throws -> CGImage? {
        guard policy.enabled else { return cachedThumbnail(for: article) }
        return try await thumbnail(from: ArticlePreviewHTML.images(in: article.contentHTML ?? "", baseURL: article.url),
                                   for: article, policy: policy, mayStore: true)
    }

    private func thumbnail(from candidates: [URL], for article: Article, policy: ArticlePreviewPolicy, mayStore: Bool) async throws -> CGImage? {
        var seen = Set<URL>()
        for url in candidates.filter({ seen.insert($0).inserted }).prefix(3) {
            if let image = cachedImage(url) { return image }
            if let data = try? Data(contentsOf: file(url, extension: "miss")),
               let until = try? JSONDecoder().decode(Date.self, from: data), until > Date() { continue }
            do {
                let response = try await request(url, feed: article.feedID, policy: policy, limit: 8 * 1024 * 1024, accept: "image/*")
                guard (200..<300).contains(response.http.statusCode),
                      let jpeg = Self.thumbnailData(response.data),
                      let image = Self.decode(jpeg) else {
                    if Self.mayStore(response.http), let data = try? JSONEncoder().encode(Date().addingTimeInterval(86400)) {
                        write(data, to: file(url, extension: "miss"))
                    }
                    continue
                }
                if mayStore && Self.mayStore(response.http) {
                    images.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
                    write(jpeg, to: file(url, extension: "jpg"))
                }
                return image
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                // One failure is enough for this visit. A 429 must never cause
                // an immediate attempt at a different image on the same page.
                return nil
            }
        }
        return nil
    }

    /// A full body already downloaded by the reader/offline feature is enough
    /// for a preview. Do not fetch the same article just to discover its image.
    func seed(_ article: Article, html: String) {
        guard !html.isEmpty else { return }
        let minutes = ArticleReadingTime.minutes(inReaderHTML: html)
        if var page = cachedPage(for: article) {
            guard let minutes, page.readingMinutes != minutes else { return }
            page.readingMinutes = minutes
            page.readingTimeChecked = true
            store(page, for: article.url)
            return
        }
        let page = Page(url: article.url, html: html, expires: Date().addingTimeInterval(7 * 86400),
                        imageURLs: ArticlePreviewHTML.images(in: html, baseURL: article.url),
                        mayStore: true, sourceFingerprint: NookPostOrigin.fingerprint(of: article),
                        readingMinutes: minutes, readingTimeChecked: true)
        store(page, for: article.url)
    }

    /// Parse only an already cached document. Legibility runs the markup as data
    /// in its isolated, network-disabled engine, excluding site chrome/comments.
    func readingMinutes(for article: Article) async -> Int? {
        guard let page = cachedPage(for: article) else { return nil }
        if let minutes = page.readingMinutes { return minutes }
        guard page.readingTimeChecked != true, let html = page.html, !Task.isCancelled else { return nil }
        let outcome = await LegibilityEngine.shared.extract(document: html)
        guard !Task.isCancelled,
              var current = cachedPage(for: article), current.expires == page.expires,
              current.html == html else { return nil }
        // A reader may have supplied a newer, fully rendered body while parsing.
        if let minutes = current.readingMinutes { return minutes }
        switch outcome {
        case .article(let extracted) where !extracted.isLinkOnly && !extracted.truncated:
            current.readingMinutes = ArticleReadingTime.minutes(inReaderHTML: extracted.html)
        case .unavailable:
            return nil
        default:
            break
        }
        current.readingTimeChecked = true
        store(current, for: article.url)
        return current.readingMinutes
    }

    private func store(_ page: Page, for url: URL) {
        guard page.mayStore else { return }
        remember(page, for: url)
        if let data = try? JSONEncoder().encode(page) { write(data, to: file(url, extension: "json")) }
        NotificationCenter.default.post(name: Self.didChange, object: url)
    }

    func cachedPage(for article: Article) -> Page? {
        guard let page = cachedPage(for: article.url) else { return nil }
        guard NookPostOrigin.cachedBodyIsCurrent(page.sourceFingerprint, for: article) else {
            invalidate(article.url)
            return nil
        }
        return page
    }

    func cachedPage(for url: URL) -> Page? {
        if let page = memoryPages[url], page.expires > Date() { return page }
        memoryPages[url] = nil
        guard let data = try? Data(contentsOf: file(url, extension: "json")),
              let page = try? JSONDecoder().decode(Page.self, from: data), page.expires > Date() else { return nil }
        remember(page, for: url)
        return page
    }

    func invalidate(_ url: URL) {
        pending[url]?.task.cancel()
        pending[url] = nil
        memoryPages[url] = nil
        try? FileManager.default.removeItem(at: file(url, extension: "json"))
        NotificationCenter.default.post(name: Self.didChange, object: url)
    }

    private func page(for article: Article, policy: ArticlePreviewPolicy) async throws -> Page {
        if let page = cachedPage(for: article) { return page }
        let url = article.url
        let client = UUID()
        if pending[url] == nil {
            pending[url] = Pending(task: Task { try await self.fetchPage(article, policy: policy) }, clients: [])
        }
        pending[url]?.clients.insert(client)
        let task = pending[url]!.task
        return try await withTaskCancellationHandler {
            defer { release(client, for: url) }
            let page = try await task.value
            try Task.checkCancellation()
            return page
        } onCancel: {
            Task { await self.release(client, for: url) }
        }
    }

    private func release(_ client: UUID, for url: URL) {
        guard pending[url]?.clients.remove(client) != nil else { return }
        if pending[url]?.clients.isEmpty == true {
            pending[url]?.task.cancel()
            pending[url] = nil
        }
    }

    private func fetchPage(_ article: Article, policy: ArticlePreviewPolicy) async throws -> Page {
        let response = try await request(article.url, feed: article.feedID, policy: policy, limit: 2 * 1024 * 1024, accept: "text/html, application/xhtml+xml")
        let status = response.http.statusCode
        let base = response.http.url ?? article.url
        let isHTML = ["text/html", "application/xhtml+xml"].contains(response.http.mimeType?.lowercased() ?? "text/html")
        let html = (200..<300).contains(status) && isHTML ? Self.html(response.data, response: response.http) : nil
        let page = Page(url: base, html: html,
                        expires: Date().addingTimeInterval(html == nil ? 86400 : 7 * 86400),
                        imageURLs: html.map { ArticlePreviewHTML.images(in: $0, baseURL: base) } ?? [],
                        mayStore: Self.mayStore(response.http),
                        sourceFingerprint: NookPostOrigin.fingerprint(of: article))
        try Task.checkCancellation()
        store(page, for: article.url)
        return page
    }

    private func remember(_ page: Page, for url: URL) {
        if memoryPages.count >= 32 { memoryPages.removeAll(keepingCapacity: true) }
        memoryPages[url] = page
    }

    private func cachedImage(_ url: URL) -> CGImage? {
        if let image = images.object(forKey: url as NSURL) { return image }
        let path = file(url, extension: "jpg")
        guard let date = try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              Date().timeIntervalSince(date) < 7 * 86400,
              let data = try? Data(contentsOf: path), let image = Self.decode(data) else { return nil }
        images.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        return image
    }

    private func request(_ url: URL, feed: String, policy: ArticlePreviewPolicy, limit: Int, accept: String) async throws -> (data: Data, http: HTTPURLResponse) {
        var target = url
        for _ in 0..<5 {
            guard let host = target.host?.lowercased(), ["https", "http"].contains(target.scheme?.lowercased() ?? ""),
                  target.user == nil, target.password == nil else { throw URLError(.unsupportedURL) }
            let ticket = Ticket(id: UUID(), feed: feed, host: host, policy: policy.normalized, image: accept == "image/*")
            try await acquire(ticket)
            defer { active[ticket.id] = nil }
            var request = URLRequest(url: target)
            request.setValue(accept, forHTTPHeaderField: "Accept")
            // Redirects are followed manually so each destination takes a permit.
            let result: (Data, HTTPURLResponse)
            do {
                let (bytes, response) = try await session.bytes(for: request, delegate: PreviewRedirectDelegate.shared)
                defer { bytes.task.cancel() }
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                budget.finished(feed: feed, host: host, status: http.statusCode,
                                retryAfter: http.value(forHTTPHeaderField: "Retry-After"), now: Date())
                saveBudget()
                if [403, 429, 503].contains(http.statusCode) || http.statusCode >= 500 { throw PreviewError.serverDeferred }
                if http.expectedContentLength > limit { throw PreviewError.tooLarge }
                var data = Data()
                for try await byte in bytes {
                    if data.count >= limit { throw PreviewError.tooLarge }
                    data.append(byte)
                }
                try Task.checkCancellation()
                result = (data, http)
            } catch {
                if !Task.isCancelled && !(error is PreviewError) {
                    budget.finished(feed: feed, host: host, status: 0, retryAfter: nil, now: Date())
                    saveBudget()
                }
                throw error
            }
            if (300..<400).contains(result.1.statusCode),
               let location = result.1.value(forHTTPHeaderField: "Location"),
               let redirected = ArticlePreviewHTML.resolve(location, baseURL: target) {
                target = redirected
                continue
            }
            return (result.0, result.1)
        }
        throw URLError(.httpTooManyRedirects)
    }

    private func acquire(_ ticket: Ticket) async throws {
        // Finish the visible card whose page arrived before starting another
        // page. Otherwise a screenful of HTML can starve every thumbnail.
        if ticket.image, let index = queue.firstIndex(where: { !$0.image }) { queue.insert(ticket, at: index) }
        else { queue.append(ticket) }
        defer { queue.removeAll { $0.id == ticket.id } }
        while true {
            try Task.checkCancellation()
            let now = Date()
            let next = queue.first { item in
                active.count < 2 && !active.values.contains { $0.feed == item.feed || $0.host == item.host }
                    && budget.delay(feed: item.feed, host: item.host, policy: item.policy, now: now) <= 0
            }
            if next?.id == ticket.id {
                active[ticket.id] = ticket
                budget.started(feed: ticket.feed, host: ticket.host, policy: ticket.policy, now: now)
                saveBudget()
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private enum PreviewError: Error { case serverDeferred, tooLarge }

    private func saveBudget() {
        guard let data = try? JSONEncoder().encode(budget) else { return }
        write(data, to: directory.appending(path: "budget.json"))
    }

    private func file(_ url: URL, extension suffix: String) -> URL {
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(key).\(suffix)")
    }

    private func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        if url.lastPathComponent != "budget.json" { prune() }
    }

    private func prune() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        let entries = files.filter { $0.lastPathComponent != "budget.json" }.compactMap { url -> (URL, Date, Int)? in
            guard let value = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, value.contentModificationDate ?? .distantPast, value.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var bytes = 0
        for (index, entry) in entries.enumerated() {
            bytes += entry.2
            if index >= 1000 || bytes > 250 * 1024 * 1024 || Date().timeIntervalSince(entry.1) > 7 * 86400 {
                try? FileManager.default.removeItem(at: entry.0)
            }
        }
    }

    private static func mayStore(_ response: HTTPURLResponse) -> Bool {
        !(response.value(forHTTPHeaderField: "Cache-Control")?.lowercased().contains("no-store") ?? false)
    }

    private static func html(_ data: Data, response: HTTPURLResponse) -> String? {
        if let name = response.textEncodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) { return text }
        }
        return String(data: data, encoding: .utf8)
    }

    private static func thumbnailData(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width >= 160, height >= 90, Double(width) / Double(height) < 5,
              Double(width) * Double(height) <= 100_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 960,
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

private final class PreviewRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = PreviewRedirectDelegate()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
