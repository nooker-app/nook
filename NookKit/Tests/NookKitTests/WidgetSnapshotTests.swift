import Foundation
import Testing
@testable import NookKit

@Suite("Widget snapshot and reader links")
struct WidgetSnapshotTests {
    @Test("Reader links round-trip hostile URL characters without revealing paths")
    func links() throws {
        let library = NookReaderLink.token("/Users/test/iCloud/내 라이브러리")
        let article = "https://example.org/feed#한글?x=1&library=wrong/fragment"
        let url = NookReaderLink.url(libraryID: library, articleID: article, recommendation: true)
        let destination = try #require(NookReaderLink.destination(from: url))
        #expect(destination.libraryID == library)
        #expect(destination.articleToken == NookReaderLink.token(article))
        #expect(destination.recommendation)
        #expect(!url.absoluteString.contains("Users"))
        #expect(!url.absoluteString.contains("example.org"))
        #expect(NookReaderLink.destination(from: URL(string: url.absoluteString + "&library=" + library)!) == nil)
        #expect(NookReaderLink.destination(from: URL(string: "https://reader/" + destination.articleToken + "?library=" + library)!) == nil)
        #expect(NookReaderLink.destination(from: URL(string: "nook://reader/../../vault?library=" + library)!) == nil)
        #expect(NookReaderLink.destination(from: URL(string: "nook://source?smart=unread")!) == nil)
    }

    @Test("Snapshots stay bounded and preserve independent collection ordering")
    func collections() {
        let rows = (0..<20).map {
            NookWidgetStory(id: String($0), title: String(repeating: "가", count: 800),
                source: "feed", publishedAt: Date(timeIntervalSince1970: Double($0)), isUnread: true)
        }
        let snapshot = NookWidgetSnapshot(unreadCount: 20, latest: rows,
            recommended: Array(rows.reversed()), recent: [rows[8], rows[4]])
        #expect(snapshot.latest.count == 6)
        #expect(snapshot.recommended.count == 6)
        #expect(snapshot.stories(for: .recent).map(\.id) == ["8", "4"])
        #expect(snapshot.stories(for: .recommended).first?.id == "19")
        #expect(snapshot.latest.first?.title.count == 500)
    }

    @Test("Atomic snapshots skip unchanged data, clear old libraries and reject incompatible data")
    func persistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ReadingSnapshot.json")
        let first = NookWidgetSnapshot(libraryID: "one", unreadCount: 12)
        #expect(try NookWidgetStorage.write(first, to: url))
        var later = first
        later.generatedAt = .now.addingTimeInterval(60)
        #expect(try !NookWidgetStorage.write(later, to: url))
        #expect(NookWidgetStorage.read(from: url) == first)
        #expect(try NookWidgetStorage.write(NookWidgetSnapshot(), to: url))
        #expect(NookWidgetStorage.read(from: url)?.libraryID == nil)
        var newer = first
        newer.version = 99
        try JSONEncoder().encode(newer).write(to: url)
        #expect(NookWidgetStorage.read(from: url) == nil)
        try Data(repeating: 0, count: 256_001).write(to: url)
        #expect(NookWidgetStorage.read(from: url) == nil)
    }
}
