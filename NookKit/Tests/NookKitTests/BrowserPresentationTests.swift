import Foundation
import Testing
@testable import NookKit

@Suite("Browser presentation respects reading preferences")
@MainActor
struct BrowserPresentationTests {
    @Test(arguments: ReaderViewMode.allCases, [nil, ReaderViewMode.reader, .original])
    func feedOverrideWins(global: ReaderViewMode, override: ReaderViewMode?) throws {
        let suite = "BrowserPresentation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(global.rawValue, forKey: "readerViewMode")
        let store = ReaderStore._makeForTesting()
        var feed = Fixture.feed("feed")
        feed.preferredViewMode = override
        let article = Fixture.article("article", feedID: feed.id)
        store.feeds = [feed]
        store.articles = [article]

        store.presentBrowser(for: article, defaults: defaults)

        #expect(store.isBrowserPresented)
        #expect(store.selectedArticleID == article.id)
        #expect(store.browserMode == (override ?? global))
    }

    @Test("Reopening the same article reads changed settings and discards a temporary toggle")
    func reopenAfterSettingsChange() throws {
        let suite = "BrowserPresentation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReaderStore._makeForTesting()
        store.feeds = [Fixture.feed("feed")]
        let article = Fixture.article("article", feedID: "feed")
        store.articles = [article]
        defaults.set("reader", forKey: "readerViewMode")
        store.presentBrowser(for: article, defaults: defaults)
        store.isBrowserPresented = false

        defaults.set("original", forKey: "readerViewMode")
        store.presentBrowser(for: article, defaults: defaults)
        #expect(store.browserMode == .original)
        store.toggleBrowserMode()
        #expect(store.browserMode == .reader)
        #expect(defaults.string(forKey: "readerViewMode") == "original")
        store.isBrowserPresented = false
        store.presentBrowser(for: article, defaults: defaults)
        #expect(store.browserMode == .original)

        store.feeds[0].preferredViewMode = .reader
        store.presentBrowser(for: article, defaults: defaults)
        #expect(store.browserMode == .reader)
        store.feeds[0].preferredViewMode = nil
        store.presentBrowser(for: article, defaults: defaults)
        #expect(store.browserMode == .original)
    }

    @Test("Missing feeds and invalid defaults have a predictable fallback")
    func missingFeedAndInvalidDefault() throws {
        let suite = "BrowserPresentation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReaderStore._makeForTesting()
        let article = Fixture.article("article", feedID: "missing")
        #expect(store.resolvedBrowserMode(for: article, defaults: defaults) == .reader)
        defaults.set("unknown", forKey: "readerViewMode")
        #expect(store.resolvedBrowserMode(for: article, defaults: defaults) == .reader)
        defaults.set("original", forKey: "readerViewMode")
        #expect(store.resolvedBrowserMode(for: article, defaults: defaults) == .original)
    }
}
