import Foundation

/// The selected collection, not just an empty result, determines the next step.
public enum ArticleEmptyState: Equatable, Sendable {
    case search, saved, unread, today, starred, recent, filtered, offline, category, feed, folder, subscriptions, all

    public static func resolve(query: String, feedIDs: Set<Feed.ID>, categoryID: String?,
                               smart: SmartSource?, hasSubscriptions: Bool, emptyFolder: Bool = false) -> Self {
        if !query.isEmpty { return .search }
        if emptyFolder { return .folder }
        if feedIDs == [ReaderStore.savedLinksFeedID] { return .saved }
        if !feedIDs.isEmpty { return .feed }
        if categoryID != nil { return .category }
        switch smart {
        case .unread: return .unread
        case .today: return .today
        case .starred: return .starred
        case .recent: return .recent
        case .filtered: return .filtered
        case .offline: return .offline
        case .all, nil: return hasSubscriptions ? .all : .subscriptions
        }
    }

    public var title: String {
        switch self {
        case .search: String(localized: "No search results", bundle: .module)
        case .saved: String(localized: "No saved stories yet", bundle: .module)
        case .unread: String(localized: "You're All Caught Up", bundle: .module)
        case .today: String(localized: "Nothing new today", bundle: .module)
        case .starred: String(localized: "Your favorites start here", bundle: .module)
        case .recent: String(localized: "No recently opened stories", bundle: .module)
        case .filtered: String(localized: "No filtered stories", bundle: .module)
        case .offline: String(localized: "No downloaded stories", bundle: .module)
        case .category: String(localized: "No stories with this label yet", bundle: .module)
        case .feed: String(localized: "No stories in this feed", bundle: .module)
        case .folder: String(localized: "This folder is ready for feeds", bundle: .module)
        case .subscriptions: String(localized: "Your library starts here", bundle: .module)
        case .all: String(localized: "Waiting for the next story", bundle: .module)
        }
    }

    public var message: String {
        switch self {
        case .recent: String(localized: "Stories you open appear here, even when automatic read marking is off.", bundle: .module)
        case .search: String(localized: "Try another search or clear it to see this collection again.", bundle: .module)
        case .saved: String(localized: "Links you save to Nook appear here. You can keep reading from your subscriptions.", bundle: .module)
        case .unread: String(localized: "You've read everything in this collection. Revisit a story or check for new ones.", bundle: .module)
        case .today: String(localized: "No stories dated today yet. Earlier stories are still in your library.", bundle: .module)
        case .starred: String(localized: "Star a story you want to revisit. It will appear here.", bundle: .module)
        case .filtered: String(localized: "Stories hidden by your rules appear here. Your other stories remain in the magazine.", bundle: .module)
        case .offline: String(localized: "Download a story for offline reading and it will appear here.", bundle: .module)
        case .category: String(localized: "Stories appear here when this label is assigned, automatically or by you.", bundle: .module)
        case .feed: String(localized: "This feed has no visible stories. Refresh it, or review your filtering rules.", bundle: .module)
        case .folder: String(localized: "Add a feed to this folder or move one here from your library.", bundle: .module)
        case .subscriptions: String(localized: "Add a website or RSS feed to start your reading collection.", bundle: .module)
        case .all: String(localized: "Your subscriptions are here. Check for new stories or review your filtering rules.", bundle: .module)
        }
    }

    public var symbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .saved: "bookmark"
        case .unread: "checkmark.circle"
        case .today: "sun.max"
        case .starred: "star"
        case .recent: "clock.arrow.circlepath"
        case .filtered: "line.3.horizontal.decrease.circle"
        case .offline: "arrow.down.circle"
        case .category: "tag"
        case .feed, .all: "newspaper"
        case .folder: "folder"
        case .subscriptions: "books.vertical"
        }
    }
}

extension ReaderStore {
    public var articleEmptyState: ArticleEmptyState {
        ArticleEmptyState.resolve(query: activeSearchQuery, feedIDs: feedSelection,
                                  categoryID: categorySelection, smart: smartSelection,
                                  hasSubscriptions: feeds.contains { $0.id != Self.savedLinksFeedID })
    }
}
