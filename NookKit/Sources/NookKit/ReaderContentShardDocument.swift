import Foundation

/// One article's reader-mode extraction result, synced across devices.
/// Regenerable content, so a `.failed` marker is kept too — it stops every
/// device from re-fetching a page that has no extractable article.
public struct ReaderContentValue: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case success
        case failed
    }

    /// What the extractor could do at the time. Bump it whenever the extraction
    /// rules change, so a failure recorded under the old rules is retried instead
    /// of being served forever.
    ///
    /// This is why it exists: the extractor used to refuse a page whose article
    /// text was under eighty characters, which rejected any short post. Fixing
    /// that reached no article that had already failed, because the failure was
    /// cached and synced, and a cache hit never re-extracts. A reader could
    /// install the fix and still be told the original could not be read.
    ///
    /// 2: an explicit `<article>` or `[itemprop="articleBody"]` is trusted
    /// whatever its length.
    public static let currentExtractorVersion = 2

    public var status: Status
    /// The extracted reader HTML for `.success`; `nil` for `.failed`.
    public var html: String?
    /// The extractor that produced this. Absent in records written before this
    /// was tracked, which are treated as older than any current version.
    public var extractorVersion: Int?

    /// The article as the feed served it when this body was extracted, as a
    /// fingerprint. Absent in records written before this was tracked.
    ///
    /// Only consulted for Nook posts, and only to notice that the author edited
    /// one — see ``NookPostOrigin``. Other sources keep the body they fetched, so
    /// for them this is recorded and never read.
    public var sourceFingerprint: String?

    public init(
        status: Status, html: String?, extractorVersion: Int? = currentExtractorVersion,
        sourceFingerprint: String? = nil
    ) {
        self.status = status
        self.html = html
        self.extractorVersion = extractorVersion
        self.sourceFingerprint = sourceFingerprint
    }

    /// Whether this result still reflects what the extractor would do now.
    ///
    /// Success is always trusted: extracted content does not become wrong because
    /// the extractor improved, and re-fetching every page after an update would
    /// be a poor trade. Only a failure is worth reconsidering.
    public var isCurrent: Bool {
        status == .success || (extractorVersion ?? 0) >= Self.currentExtractorVersion
    }

    enum CodingKeys: String, CodingKey {
        case status = "s"
        case html = "h"
        case extractorVersion = "v"
        case sourceFingerprint = "f"
    }
}

/// A state-based CRDT shard for reader-mode-extracted content, mirroring
/// `ContentShardDocument`/`BodyShardDocument`: each device writes only its own
/// `.nook/reader/<deviceID>.json`, and loads merge every shard with last-writer-
/// wins per article (by `HLC`). This keeps macOS and iOS conflict-free — the two
/// devices never write the same file, and concurrent extractions of the same
/// article converge deterministically (their content is equivalent anyway).
///
/// Deliberately separate from the library/state/body sync: it is additive and
/// never modifies the existing shards.
public struct ReaderContentShardDocument: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public var schema: Int
    public var deviceID: String
    public var clock: HLC
    public var entries: [Article.ID: LWWRegister<ReaderContentValue>]

    public init(
        deviceID: String,
        clock: HLC = .zero,
        entries: [Article.ID: LWWRegister<ReaderContentValue>] = [:]
    ) {
        schema = Self.currentSchema
        self.deviceID = deviceID
        self.clock = clock
        self.entries = entries
    }

    enum CodingKeys: String, CodingKey { case schema, deviceID, clock, entries }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? Self.currentSchema
        deviceID = try c.decode(String.self, forKey: .deviceID)
        clock = try c.decodeIfPresent(HLC.self, forKey: .clock) ?? .zero
        entries = try c.decodeIfPresent([Article.ID: LWWRegister<ReaderContentValue>].self, forKey: .entries) ?? [:]
    }
}
