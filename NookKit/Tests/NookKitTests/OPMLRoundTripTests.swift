import Foundation
import Testing

@testable import NookKit

/// OPML export used to emit a flat list, so re-importing a file Nook exported
/// dropped every folder. Export now wraps each folder in a container outline,
/// which the import parser reads back as the feed's category — this pins that
/// round-trip so it can't silently regress.
@Suite("OPML folder round-trip")
struct OPMLRoundTripTests {
    private func feed(_ url: String, category: String) -> Feed {
        Feed(
            id: url, title: url, siteDescription: "", category: category,
            systemImage: "dot.radiowaves.left.and.right",
            feedURL: URL(string: url)!, siteURL: URL(string: url)!, healthScore: 1
        )
    }

    @Test("exported folders survive re-import")
    func roundTrip() throws {
        let feeds = [
            feed("https://a.example/feed", category: "Tech"),
            feed("https://b.example/feed", category: "Tech"),
            feed("https://c.example/feed", category: "News"),
            feed("https://d.example/feed", category: "Feeds"), // reserved sentinel → top level
            feed("https://e.example/feed", category: ""),      // top level
        ]

        let data = OPMLService().exportData(for: feeds)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".opml")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let imported = try OPMLService().importFeeds(from: url)
        let byURL = Dictionary(uniqueKeysWithValues: imported.map { ($0.feedURL.absoluteString, $0) })

        #expect(imported.count == 5)
        for u in feeds.map(\.feedURL.absoluteString) {
            #expect(byURL[u] != nil)
        }
        #expect(byURL["https://a.example/feed"]?.category == "Tech")
        #expect(byURL["https://b.example/feed"]?.category == "Tech")
        #expect(byURL["https://c.example/feed"]?.category == "News")
        // The reserved "Feeds" sentinel and an empty category both export at the
        // top level, so they come back with no folder.
        #expect(byURL["https://d.example/feed"]?.category == nil)
        #expect(byURL["https://e.example/feed"]?.category == nil)
    }
}
