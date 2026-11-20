import CryptoKit
import Foundation

/// Compiled by NookKit and the widget target. Contains no app/model dependencies:
/// widgets read a small local snapshot, never the vault or embedding models.
public struct NookWidgetStory: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let source: String
    public let publishedAt: Date
    public let isUnread: Bool

    public init(id: String, title: String, source: String, publishedAt: Date, isUnread: Bool) {
        self.id = id
        self.title = String(title.prefix(500))
        self.source = String(source.prefix(120))
        self.publishedAt = publishedAt
        self.isUnread = isUnread
    }
}

public enum NookWidgetCollection: String, CaseIterable, Sendable {
    case latest, recommended, recent

    public var kind: String {
        switch self {
        case .latest: "NookLatestWidget"
        case .recommended: "NookRecommendedWidget"
        case .recent: "NookRecentlyReadWidget"
        }
    }
}

public struct NookWidgetSnapshot: Codable, Equatable, Sendable {
    public var version = 1
    public var generatedAt: Date
    public var libraryID: String?
    public var unreadCount: Int
    public var latest: [NookWidgetStory]
    public var recommended: [NookWidgetStory]
    public var recent: [NookWidgetStory]

    public init(generatedAt: Date = .now, libraryID: String? = nil, unreadCount: Int = 0,
                latest: [NookWidgetStory] = [], recommended: [NookWidgetStory] = [], recent: [NookWidgetStory] = []) {
        self.generatedAt = generatedAt
        self.libraryID = libraryID
        self.unreadCount = max(0, unreadCount)
        self.latest = Array(latest.prefix(6))
        self.recommended = Array(recommended.prefix(6))
        self.recent = Array(recent.prefix(6))
    }

    public func stories(for collection: NookWidgetCollection) -> [NookWidgetStory] {
        switch collection {
        case .latest: latest
        case .recommended: recommended
        case .recent: recent
        }
    }

    public func hasSameContent(as other: Self) -> Bool {
        version == other.version && libraryID == other.libraryID && unreadCount == other.unreadCount
            && latest == other.latest && recommended == other.recommended && recent == other.recent
    }
}

public enum NookReaderLink {
    public struct Destination: Equatable, Sendable {
        public let libraryID: String
        public let articleToken: String
        public let recommendation: Bool
    }

    public static func token(_ value: String) -> String {
        let hex = Array("0123456789abcdef".utf8)
        return String(decoding: SHA256.hash(data: Data(value.utf8)).flatMap {
            [hex[Int($0 >> 4)], hex[Int($0 & 15)]]
        }, as: UTF8.self)
    }

    public static func url(libraryID: String, articleID: String, recommendation: Bool = false) -> URL {
        var url = URLComponents()
        url.scheme = "nook"
        url.host = "reader"
        url.path = "/" + token(articleID)
        url.queryItems = [URLQueryItem(name: "library", value: libraryID)]
        if recommendation { url.queryItems?.append(URLQueryItem(name: "recommendation", value: "1")) }
        return url.url!
    }

    public static func destination(from url: URL) -> Destination? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "nook", parts.host == "reader", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil else { return nil }
        let items = parts.queryItems ?? []
        let libraries = items.filter { $0.name == "library" }
        let article = String(parts.path.dropFirst())
        func validToken(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard libraries.count == 1, let library = libraries.first?.value,
              validToken(library), validToken(article) else { return nil }
        return Destination(libraryID: library, articleToken: article,
                           recommendation: items.contains { $0.name == "recommendation" && $0.value == "1" })
    }
}

public enum NookWidgetStorage {
    // Team-prefixed macOS App Groups also work with Developer ID distribution.
    public static let groupID = "F7WUT95TT6.com.tim.nook.widgets"
    public static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("ReadingSnapshot.json")
    }

    public static func read(from url: URL?) -> NookWidgetSnapshot? {
        guard let url, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 256_000, let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(NookWidgetSnapshot.self, from: data),
              snapshot.version == 1 else { return nil }
        return snapshot
    }

    /// Atomic replacement prevents WidgetKit reading a half-written document.
    @discardableResult public static func write(_ snapshot: NookWidgetSnapshot, to url: URL) throws -> Bool {
        if let old = read(from: url), snapshot.hasSameContent(as: old) { return false }
        let data = try JSONEncoder().encode(snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return true
    }
}
