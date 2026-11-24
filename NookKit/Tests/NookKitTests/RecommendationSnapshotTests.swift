#if os(macOS)
import Foundation
import Testing
@testable import NookKit

@Suite("Cached recommendation content snapshots")
struct RecommendationSnapshotTests {
    @Test("Read state reuses content; changed/removed originals and library switches invalidate it")
    func invalidation() async throws {
        let builder = RecommendationSnapshotBuilder()
        var article = Fixture.article("one", feedID: "feed")
        article.bodyParagraphs = ["RSS fallback"]
        let original = [article.id: "<article><p>Original &amp; context</p></article>"]
        func library(_ article: Article) -> ReaderLibrary { Fixture.library(feeds: [], articles: [article]) }
        let first = try await builder.snapshot(scope: "a", library: library(article), readerHTML: original)
        #expect(first.library.articles[0].bodyParagraphs == ["Original & context"])
        article.isRead = true
        let read = try await builder.snapshot(scope: "a", library: library(article), readerHTML: original)
        #expect(read.library.articles[0].isRead)
        #expect(await builder.parsedDocuments == 1)
        let changed = try await builder.snapshot(scope: "a", library: library(article), readerHTML: [article.id: "<p>New original</p>"])
        #expect(changed.library.articles[0].bodyParagraphs == ["New original"])
        #expect(await builder.parsedDocuments == 2)
        let removed = try await builder.snapshot(scope: "a", library: library(article), readerHTML: [:])
        #expect(removed.originalIDs.isEmpty)
        #expect(removed.library.articles[0].bodyParagraphs == ["RSS fallback"])
        _ = try await builder.snapshot(scope: "b", library: library(article), readerHTML: original)
        #expect(await builder.parsedDocuments == 3)
    }

    @Test("Cancelled snapshot work does not poison the next request")
    func cancellation() async throws {
        let builder = RecommendationSnapshotBuilder()
        let library = Fixture.library(feeds: [], articles: [Fixture.article("one", feedID: "feed")])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await builder.snapshot(scope: "a", library: library, readerHTML: ["one": "<p>Cancelled</p>"])
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(await builder.parsedDocuments == 0)
        }
        let next = try await builder.snapshot(scope: "a", library: library, readerHTML: ["one": "<p>Current</p>"])
        #expect(next.library.articles[0].bodyParagraphs == ["Current"])
        #expect(await builder.parsedDocuments == 1)
    }

    @Test("Optional real-library profiling compares the same extraction output")
    func profileRealLibrary() async throws {
        guard let path = ProcessInfo.processInfo.environment["NOOK_PERF_READER_HTML"] else { return }
        let html = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let library = Fixture.library(feeds: [], articles: html.keys.sorted().map { Fixture.article($0, feedID: "feed") })
        let builder = RecommendationSnapshotBuilder()
        for pass in 0..<3 {
            var start = ContinuousClock.now
            let original = RecommendationLibrarySnapshot(scope: "profile", library: library, readerHTML: html)
            let uncached = start.duration(to: .now)
            start = .now
            let cached = try await builder.snapshot(scope: "profile", library: library, readerHTML: html)
            let elapsed = start.duration(to: .now)
            #expect(original.library.articles.map(\.bodyParagraphs) == cached.library.articles.map(\.bodyParagraphs))
            #expect(original.originalIDs == cached.originalIDs)
            print("snapshot.profile pass=\(pass) articles=\(html.count) uncached=\(uncached) cached=\(elapsed) parsed=\(await builder.parsedDocuments)")
        }
    }
}
#endif
