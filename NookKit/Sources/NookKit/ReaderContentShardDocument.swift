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

    /// Per-engine, because two engines cannot share one counter: bumping
    /// legibility's rules must not expire every failure Readability recorded, and
    /// the reverse. Readability keeps the number the field already holds on disk.
    public static func currentExtractorVersion(for engine: ReaderParserEngine) -> Int {
        switch engine {
        case .readability: currentExtractorVersion
        // Deliberately a hand-bumped integer and not the wasm build stamp: the
        // asset is regenerated whenever the pin moves, and expiring every cached
        // failure on every rebuild would be a re-extraction storm for no reason.
        case .legibility: 1
        }
    }

    public var status: Status
    /// The extracted reader HTML for `.success`; `nil` for `.failed`.
    public var html: String?
    /// The extractor that produced this. Absent in records written before this
    /// was tracked, which are treated as older than any current version.
    public var extractorVersion: Int?

    /// Which parser produced this. Absent in every record written before two
    /// engines existed, and those all came from Readability.js — so absence means
    /// `.readability` rather than "unknown".
    public var engine: ReaderParserEngine?

    /// For a failure: every parser that has come up empty on this page, and the
    /// extractor version each was at when it did.
    ///
    /// Accumulated rather than overwritten, because otherwise two devices on
    /// different parsers ping-pong forever on any page neither can read — each sees
    /// the other's stamp, decides its own parser has not been tried, re-loads the
    /// page, and rewrites the whole shard into iCloud Drive. Keyed by
    /// `ReaderParserEngine.rawValue`, with a version per entry: the two engines
    /// number their rules independently, so one `extractorVersion` field cannot say
    /// whether *this* parser's verdict is stale. Additive — an older peer ignores the
    /// key.
    public var failedEngines: [String: Int]?

    /// The article as the feed served it when this body was extracted, as a
    /// fingerprint. Absent in records written before this was tracked.
    ///
    /// Only consulted for Nook posts, and only to notice that the author edited
    /// one — see ``NookPostOrigin``. Other sources keep the body they fetched, so
    /// for them this is recorded and never read.
    public var sourceFingerprint: String?

    public init(
        status: Status, html: String?, extractorVersion: Int? = currentExtractorVersion,
        sourceFingerprint: String? = nil,
        engine: ReaderParserEngine? = nil,
        failedEngines: [String: Int]? = nil
    ) {
        self.status = status
        self.html = html
        self.extractorVersion = extractorVersion
        self.sourceFingerprint = sourceFingerprint
        self.engine = engine
        self.failedEngines = failedEngines
    }

    /// A failure record for `engine`, carrying forward whatever `previous` already
    /// knew — so a page that neither parser can read ends up saying so once, rather
    /// than each device overwriting the other's verdict with its own.
    public static func failure(
        engine: ReaderParserEngine,
        previous: ReaderContentValue?,
        sourceFingerprint: String?
    ) -> ReaderContentValue {
        // Only a previous *failure* carries anything forward. Verdicts about a page
        // that used to extract were about different markup.
        var failed = previous?.status == .failed ? previous?.failedVersions ?? [:] : [:]
        failed[engine.rawValue] = currentExtractorVersion(for: engine)
        return ReaderContentValue(
            status: .failed, html: nil,
            extractorVersion: currentExtractorVersion(for: engine),
            sourceFingerprint: sourceFingerprint,
            engine: engine,
            failedEngines: failed)
    }

    /// The parser this record came from, reading an absent field as the only one
    /// that existed when it was written.
    public var recordedEngine: ReaderParserEngine { engine ?? .readability }

    /// The parsers a failure record has ruled out, and the version each was at.
    /// Records written before the list existed name exactly one, at whatever the
    /// single `extractorVersion` field said.
    public var failedVersions: [String: Int] {
        if let failedEngines, !failedEngines.isEmpty { return failedEngines }
        return [recordedEngine.rawValue: extractorVersion ?? 0]
    }

    /// The parsers a failure record has ruled out.
    public var recordedFailures: [ReaderParserEngine] {
        failedVersions.keys.compactMap(ReaderParserEngine.init(rawValue:))
    }

    /// Whether this result still reflects what `engine` would do now.
    ///
    /// Success is always trusted, **including a success from the other parser**.
    /// Extracted content does not become wrong because a different extractor is
    /// now preferred, and the alternative is worse than it looks: the cache is
    /// synced, so a device set to legibility and a device set to Readability would
    /// each keep invalidating the other's body, re-loading the page and rewriting
    /// a multi-megabyte shard into iCloud Drive, forever. The engine preference
    /// decides which parser runs when there is nothing cached; it is not a reason
    /// to re-fetch what is.
    ///
    /// A **failure** is different, and is the case worth reconsidering: legibility
    /// reads short posts and link posts that Readability rejects outright, so a
    /// failure it recorded says nothing about what the other engine would find.
    public func isCurrent(for engine: ReaderParserEngine) -> Bool {
        if status == .success { return true }
        guard let recorded = failedVersions[engine.rawValue] else { return false }
        return recorded >= Self.currentExtractorVersion(for: engine)
    }

    enum CodingKeys: String, CodingKey {
        case status = "s"
        case html = "h"
        case extractorVersion = "v"
        case sourceFingerprint = "f"
        case engine = "e"
        case failedEngines = "g"
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
