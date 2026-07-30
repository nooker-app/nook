import Foundation

/// The writer's own publication, seen from the reader side.
///
/// Publishing used to end at a link that opened Safari, which left the one reader
/// in the app unable to show the writer their own post. A publication is a feed
/// like any other, so following it makes every reader feature work on their own
/// writing for free: offline, reader mode, starring, search.
///
/// The publication URL is mirrored into UserDefaults rather than passed down the
/// view tree, because the Feeds screen has no other reason to hold a `PlusStore`,
/// and reading a defaults key is far cheaper than building one on every launch.
/// This follows `PlusCredential.configuredKey`, which exists for the same reason.
public enum PlusOwnFeed {
    /// The last known publication URL, or empty when signed out.
    public static let publicationURLKey = "nookPlusPublicationURL"

    /// Records the publication URL, or clears it when passed nothing. Called
    /// wherever the publication becomes known or stops being ours.
    public static func remember(publicationURL: String?) {
        let defaults = UserDefaults.standard
        guard let publicationURL, !publicationURL.isEmpty else {
            defaults.removeObject(forKey: publicationURLKey)
            return
        }
        defaults.set(publicationURL, forKey: publicationURLKey)
    }

    /// The remembered publication URL.
    public static var publicationURL: URL? {
        guard let stored = UserDefaults.standard.string(forKey: publicationURLKey),
            !stored.isEmpty
        else { return nil }
        return URL(string: stored)
    }

    /// The RSS feed for a publication page.
    ///
    /// `appending(path:)` rather than string concatenation, matching the fix on the
    /// service side: a slug is user data, and building URLs by hand is what emitted
    /// an unencoded path into a feed.
    public static func feedURL(for publicationURL: URL) -> URL {
        publicationURL.appending(path: "feed.xml")
    }

    /// The feed to follow, when a publication is known.
    public static var feedURL: URL? {
        publicationURL.map(feedURL(for:))
    }

    /// Whether two URLs address the same page.
    ///
    /// Used to find the reader's copy of a post the writer just published. The
    /// reader's own key does the work, so the two cannot drift: a page found here
    /// and a feed deduplicated there agree on what "the same URL" means.
    public static func isSamePage(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.feedIdentityKey == rhs.feedIdentityKey
    }
}
