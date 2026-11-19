import Testing
@testable import NookKit

@Suite("Contextual article empty states")
struct ArticleEmptyStateTests {
    @Test("Saved links and each smart collection explain their own empty state")
    func collectionStates() {
        #expect(resolve(feeds: [ReaderStore.savedLinksFeedID]) == .saved)
        let cases: [(SmartSource, ArticleEmptyState)] = [(.unread, .unread), (.today, .today),
            (.starred, .starred), (.recent, .recent), (.filtered, .filtered), (.offline, .offline), (.all, .all)]
        for (source, expected) in cases { #expect(resolve(smart: source) == expected) }
        #expect(resolve(category: "category") == .category)
        #expect(resolve(feeds: ["feed"]) == .feed)
        #expect(resolve(smart: .all, subscribed: false) == .subscriptions)
        #expect(resolve(smart: .starred, subscribed: false) == .starred)
        #expect(resolve(smart: .recent, subscribed: false) == .recent)
    }

    @Test("Search and an explicitly empty folder take precedence over stale collection selection")
    func precedence() {
        #expect(resolve(query: "missing", feeds: [ReaderStore.savedLinksFeedID]) == .search)
        #expect(resolve(query: "missing", subscribed: false) == .search)
        #expect(ArticleEmptyState.resolve(query: "", feedIDs: [], categoryID: nil,
                                         smart: .all, hasSubscriptions: true, emptyFolder: true) == .folder)
    }

    private func resolve(query: String = "", feeds: Set<String> = [], category: String? = nil,
                         smart: SmartSource? = .all, subscribed: Bool = true) -> ArticleEmptyState {
        .resolve(query: query, feedIDs: feeds, categoryID: category, smart: smart, hasSubscriptions: subscribed)
    }
}
