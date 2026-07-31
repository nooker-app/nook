import CryptoKit
import Foundation

/// Which articles are Nook posts, and whether one has changed since its body was
/// last fetched.
///
/// Both questions exist for the same reason. A Nook post has an owner who can edit
/// it, and a reader who already opened it keeps seeing the old text: the extracted
/// body is cached per article and a cache hit never re-extracts. That is right for
/// the open web — a page changes for reasons that have nothing to do with its
/// author, and re-fetching every article on every open would be slow and would
/// overwrite what a reader chose to keep. It is wrong for a post whose author just
/// corrected it.
///
/// So the refresh applies to Nook posts only, and everything else keeps exactly the
/// data it fetched. Deletion is untouched either way: a post that disappears is
/// still the reader's to remove, never Nook's.
enum NookPostOrigin {
    /// The AT Protocol collection holding Nook articles.
    ///
    /// Matching on this rather than on a hostname is what makes the rule survive a
    /// custom publication domain: the record type is part of the public contract,
    /// and the domain a publication is served from is a presentation attribute the
    /// writer may change.
    static let articleCollection = "/app.nooker.article/"

    /// Article ids are the feed id and the item's guid, joined by "#". For a Nook
    /// feed the guid is the article's AT URI, which the contract fixes.
    private static let guidSeparator = "#at://"

    /// Whether an article came from a Nook publication.
    ///
    /// Read from the id, which already carries the guid, so nothing has to be
    /// stored alongside the article and articles fetched by older builds are
    /// classified correctly too.
    static func isNookPost(articleID: Article.ID) -> Bool {
        guard let separator = articleID.range(of: guidSeparator) else { return false }
        return articleID[separator.lowerBound...].contains(articleCollection)
    }

    /// A fingerprint of the article as the feed most recently served it.
    ///
    /// Over the fields an edit changes and that the feed carries in full: for a Nook
    /// post the feed holds the whole rendered body, so any edit moves this value.
    /// Lengths are included so no rearrangement across fields collides.
    ///
    /// Not a checksum of the extracted body. The point is to compare what the feed
    /// says now against what it said when the body was extracted, and the extracted
    /// form is a different document — it would differ for reasons the author never
    /// caused.
    static func fingerprint(of article: Article) -> String {
        let body = article.contentHTML ?? article.bodyParagraphs.joined(separator: "\n")
        let canonical = [article.title, article.summary, body]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Whether a body cached for `article` is still the right body to show.
    ///
    /// The three answers matter separately:
    ///
    /// - not a Nook post → always current. Other sources keep what they fetched.
    /// - no fingerprint recorded → **not** current, once. Cached before this
    ///   existed, so there is nothing to compare and one re-fetch settles it. Only
    ///   for Nook posts, so nobody else's cache is invalidated by the upgrade.
    /// - fingerprint recorded → current when it matches what the feed serves now.
    static func cachedBodyIsCurrent(_ recorded: String?, for article: Article) -> Bool {
        guard isNookPost(articleID: article.id) else { return true }
        guard let recorded else { return false }
        return recorded == fingerprint(of: article)
    }
}
