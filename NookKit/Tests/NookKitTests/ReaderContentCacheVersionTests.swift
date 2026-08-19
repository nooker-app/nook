import Foundation
import Testing

@testable import NookKit

/// A cached failure has to expire when the extractor changes.
///
/// Written because it did not. The extractor refused any page whose article text
/// was under eighty characters, which rejected every short post. Fixing that
/// reached nobody who had already opened one: the failure was cached and synced
/// between devices, and a cache hit never re-extracts, so the reader kept saying
/// the original could not be read after the cause had been removed.
@Suite("Reader content cache versioning")
struct ReaderContentCacheVersionTests {
    @Test("a failure from an older extractor is not trusted")
    func staleFailure() {
        let old = ReaderContentValue(
            status: .failed, html: nil, extractorVersion: 1, engine: .readability)
        #expect(old.isCurrent(for: .readability) == false)
    }

    /// Records written before the version was tracked decode with no version, and
    /// must be treated as older than any current extractor.
    @Test("a failure with no recorded version is not trusted")
    func versionlessFailure() {
        let ancient = ReaderContentValue(status: .failed, html: nil, extractorVersion: nil)
        #expect(ancient.isCurrent(for: .readability) == false)
    }

    @Test("a failure from the current extractor is trusted")
    func currentFailure() {
        let fresh = ReaderContentValue(status: .failed, html: nil, engine: .readability)
        #expect(fresh.extractorVersion == ReaderContentValue.currentExtractorVersion)
        #expect(fresh.isCurrent(for: .readability))
    }

    /// Success is kept whatever produced it. Extracted content does not become
    /// wrong because the extractor improved, and re-fetching every page after an
    /// update would cost far more than it returns.
    @Test("success is trusted regardless of the extractor that produced it")
    func successIsKept() {
        for version in [nil, 1, ReaderContentValue.currentExtractorVersion] {
            let value = ReaderContentValue(status: .success, html: "<p>Body.</p>", extractorVersion: version)
            #expect(value.isCurrent(for: .readability), "success recorded by version \(String(describing: version)) should be kept")
        }
    }

    /// The version travels with the record, including through the sync shard.
    @Test("the version survives a round trip")
    func roundTrip() throws {
        let value = ReaderContentValue(status: .failed, html: nil, engine: .readability)
        let decoded = try JSONDecoder().decode(
            ReaderContentValue.self, from: try JSONEncoder().encode(value))
        #expect(decoded.extractorVersion == ReaderContentValue.currentExtractorVersion)
        #expect(decoded.isCurrent(for: .readability))
    }

    /// A record encoded before the field existed still decodes, rather than
    /// failing and taking a device's whole shard with it.
    @Test("a record without the field still decodes")
    func decodesLegacyRecord() throws {
        let json = Data(#"{"s":"failed"}"#.utf8)
        let decoded = try JSONDecoder().decode(ReaderContentValue.self, from: json)
        #expect(decoded.status == .failed)
        #expect(decoded.extractorVersion == nil)
        #expect(decoded.isCurrent(for: .readability) == false)
    }

    // MARK: - Which parser produced it

    /// Every record on disk before two parsers existed came from Readability.js, so
    /// an absent engine is that one and not "unknown".
    @Test("a record with no engine is a Readability record")
    func absentEngineIsReadability() throws {
        let decoded = try JSONDecoder().decode(
            ReaderContentValue.self, from: Data(#"{"s":"success","h":"<p>Body.</p>"}"#.utf8))
        #expect(decoded.engine == nil)
        #expect(decoded.recordedEngine == .readability)
    }

    @Test("the engine survives a round trip")
    func engineRoundTrip() throws {
        let value = ReaderContentValue(status: .success, html: "<p>Body.</p>", engine: .legibility)
        let encoded = try JSONEncoder().encode(value)
        #expect(String(data: encoded, encoding: .utf8)?.contains("\"e\":\"legibility\"") == true)
        let decoded = try JSONDecoder().decode(ReaderContentValue.self, from: encoded)
        #expect(decoded.recordedEngine == .legibility)
    }

    /// The rule that keeps two devices from destroying each other's work.
    ///
    /// The cache is synced. If a body extracted by one parser were invalidated on a
    /// device that prefers the other, a Mac on legibility and a phone on Readability
    /// would take turns re-loading every article and rewriting a multi-megabyte
    /// shard into iCloud Drive, forever, converging on nothing.
    @Test("a success from the other parser is still served")
    func successFromTheOtherParserIsKept() {
        let byReadability = ReaderContentValue(
            status: .success, html: "<p>Body.</p>", engine: .readability)
        #expect(byReadability.isCurrent(for: .legibility))

        let byLegibility = ReaderContentValue(
            status: .success, html: "<p>Body.</p>", engine: .legibility)
        #expect(byLegibility.isCurrent(for: .readability))
    }

    /// A failure is the case where the parsers genuinely disagree: legibility reads
    /// short posts and link posts that Readability rejects outright, so "Readability
    /// found nothing" says nothing about what legibility would find.
    @Test("a failure from the other parser is reconsidered")
    func failureFromTheOtherParserIsRetried() {
        let readabilityGaveUp = ReaderContentValue(
            status: .failed, html: nil, engine: .readability)
        #expect(readabilityGaveUp.isCurrent(for: .readability))
        #expect(readabilityGaveUp.isCurrent(for: .legibility) == false)
    }

    /// The convergence that keeps two devices from re-loading a page neither parser
    /// can read, once each, forever.
    ///
    /// Recording only the last parser to give up is not enough: each device sees the
    /// other's stamp, concludes its own parser has not been tried, re-loads the page,
    /// and rewrites the whole shard into the sync folder. Accumulating the verdicts
    /// ends it.
    @Test("a failure accumulates every parser that has given up")
    func failuresAccumulate() {
        let first = ReaderContentValue.failure(
            engine: .legibility, previous: nil, sourceFingerprint: nil)
        #expect(first.recordedFailures == [.legibility])
        #expect(first.isCurrent(for: .legibility))
        #expect(first.isCurrent(for: .readability) == false)

        let second = ReaderContentValue.failure(
            engine: .readability, previous: first, sourceFingerprint: nil)
        #expect(Set(second.recordedFailures) == [.legibility, .readability])
        // Each verdict carries the version its own parser was at. One shared field
        // could not say whether legibility's verdict was stale once its rules moved,
        // because the two engines number their rules independently.
        #expect(
            second.failedVersions["legibility"]
                == ReaderContentValue.currentExtractorVersion(for: .legibility))
        #expect(
            second.failedVersions["readability"]
                == ReaderContentValue.currentExtractorVersion(for: .readability))
        #expect(second.isCurrent(for: .legibility), "the earlier verdict must survive")
        #expect(second.isCurrent(for: .readability))

        // Idempotent, so a device repeating itself does not grow the list.
        let third = ReaderContentValue.failure(
            engine: .readability, previous: second, sourceFingerprint: nil)
        #expect(third.recordedFailures.count == 2)
    }

    /// A success replaced by a later failure starts the list over: the page changed,
    /// and the old verdicts were about different markup.
    @Test("a failure after a success does not inherit anything")
    func failureAfterSuccess() {
        let success = ReaderContentValue(status: .success, html: "<p>Body.</p>", engine: .legibility)
        let failure = ReaderContentValue.failure(
            engine: .readability, previous: success, sourceFingerprint: nil)
        #expect(failure.recordedFailures == [.readability])
    }

    @Test("the accumulated list survives a round trip, and its absence is read as one entry")
    func failureListRoundTrip() throws {
        let value = ReaderContentValue.failure(
            engine: .readability,
            previous: ReaderContentValue.failure(engine: .legibility, previous: nil, sourceFingerprint: nil),
            sourceFingerprint: nil)
        let decoded = try JSONDecoder().decode(
            ReaderContentValue.self, from: try JSONEncoder().encode(value))
        #expect(Set(decoded.recordedFailures) == [.legibility, .readability])

        let legacy = try JSONDecoder().decode(
            ReaderContentValue.self, from: Data(#"{"s":"failed","v":2,"e":"readability"}"#.utf8))
        #expect(legacy.recordedFailures == [.readability])
        #expect(legacy.isCurrent(for: .readability))
        #expect(legacy.isCurrent(for: .legibility) == false)
    }

    /// One counter for two parsers would mean that improving legibility's rules
    /// expired every failure Readability had recorded, re-loading a page for each.
    @Test("each parser has its own extractor version")
    func versionsAreIndependent() {
        let legibilityFailure = ReaderContentValue(
            status: .failed, html: nil,
            extractorVersion: ReaderContentValue.currentExtractorVersion(for: .legibility),
            engine: .legibility)
        #expect(legibilityFailure.isCurrent(for: .legibility))

        // Readability's counter is at 2 and legibility's at 1, so a legibility
        // failure stamped 1 must not be read as "older than version 2".
        #expect(
            ReaderContentValue.currentExtractorVersion(for: .legibility)
                != ReaderContentValue.currentExtractorVersion(for: .readability),
            "this test is only meaningful while the two counters differ")
    }
}
