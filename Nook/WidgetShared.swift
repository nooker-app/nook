import Foundation

// MARK: - Shared article model

/// A lightweight article snapshot written by the app into the shared App Group
/// and read by the widget extension. Defined here so both the Nook target and
/// the NookWidget extension target can use it without depending on NookKit.
public struct TodayNewsItem: Codable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var url: URL
    public var feedTitle: String
    public var publishedAt: Date

    public init(id: String, title: String, url: URL, feedTitle: String, publishedAt: Date) {
        self.id = id
        self.title = title
        self.url = url
        self.feedTitle = feedTitle
        self.publishedAt = publishedAt
    }
}

// MARK: - Shared constants and helpers

/// Shared between the app and the widget extension (add this file to both
/// targets' membership).
enum WidgetShared {
    static let urlScheme = "nook"
    static let widgetKind = "NookWidget"

    // MARK: App Group

    /// The App Group container shared between the Nook app and NookWidget extension.
    /// Must match the `com.apple.security.application-groups` entitlement in both targets.
    static let appGroupID = "group.com.tim.nook"

    /// UserDefaults key for the cached today-news article list.
    static let todayNewsKey = "widgetTodayNews"

    /// The WidgetKit kind string for the Today News widget.
    static let todayNewsWidgetKind = "NookTodayNewsWidget"

    /// The shared App Group `UserDefaults` suite, or `nil` when the entitlement
    /// isn't active (e.g., unsigned debug builds — reads return an empty list
    /// and writes are silently dropped).
    static var appGroupDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// Encodes `items` and stores them in the shared App Group defaults so the
    /// widget extension can read them. A no-op when the App Group isn't available.
    static func writeTodayNews(_ items: [TodayNewsItem]) {
        guard let defaults = appGroupDefaults,
              let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: todayNewsKey)
    }

    /// 读取缓存的今日新闻列表。App Group 不可用或尚未写入时返回空数组。
    static func readTodayNews() -> [TodayNewsItem] {
        guard let defaults = appGroupDefaults,
              let data = defaults.data(forKey: todayNewsKey),
              let items = try? JSONDecoder().decode([TodayNewsItem].self, from: data) else {
            return []
        }
        return items
    }

    /// Opens the app without changing the view.
    static var openAppURL: URL {
        URL(string: "\(urlScheme)://open")!
    }

    /// Opens the app focused on a smart source (Unread, Today, …).
    static func sourceURL(_ source: WidgetSource) -> URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "source"
        components.queryItems = [URLQueryItem(name: "smart", value: source.rawValue)]
        return components.url ?? openAppURL
    }

    /// The `smart` value from a `nook://source?smart=…` deep link.
    static func smartSourceRaw(from url: URL) -> String? {
        guard url.scheme == urlScheme, url.host == "source",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == "smart" })?.value
    }
}

/// The smart sources the widget can jump to. Raw values match the app's
/// `SmartSource` so the app can map them back.
enum WidgetSource: String, CaseIterable, Identifiable {
    case unread
    case today
    case starred
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unread: "Unread"
        case .today: "Today"
        case .starred: "Starred"
        case .all: "All Articles"
        }
    }

    var systemImage: String {
        switch self {
        case .unread: "largecircle.fill.circle"
        case .today: "calendar"
        case .starred: "star"
        case .all: "tray.full"
        }
    }
}
