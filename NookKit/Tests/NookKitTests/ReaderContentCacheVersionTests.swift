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
        let old = ReaderContentValue(status: .failed, html: nil, extractorVersion: 1)
        #expect(old.isCurrent == false)
    }

    /// Records written before the version was tracked decode with no version, and
    /// must be treated as older than any current extractor.
    @Test("a failure with no recorded version is not trusted")
    func versionlessFailure() {
        let ancient = ReaderContentValue(status: .failed, html: nil, extractorVersion: nil)
        #expect(ancient.isCurrent == false)
    }

    @Test("a failure from the current extractor is trusted")
    func currentFailure() {
        let fresh = ReaderContentValue(status: .failed, html: nil)
        #expect(fresh.extractorVersion == ReaderContentValue.currentExtractorVersion)
        #expect(fresh.isCurrent)
    }

    /// Success is kept whatever produced it. Extracted content does not become
    /// wrong because the extractor improved, and re-fetching every page after an
    /// update would cost far more than it returns.
    @Test("success is trusted regardless of the extractor that produced it")
    func successIsKept() {
        for version in [nil, 1, ReaderContentValue.currentExtractorVersion] {
            let value = ReaderContentValue(status: .success, html: "<p>Body.</p>", extractorVersion: version)
            #expect(value.isCurrent, "success recorded by version \(String(describing: version)) should be kept")
        }
    }

    /// The version travels with the record, including through the sync shard.
    @Test("the version survives a round trip")
    func roundTrip() throws {
        let value = ReaderContentValue(status: .failed, html: nil)
        let decoded = try JSONDecoder().decode(
            ReaderContentValue.self, from: try JSONEncoder().encode(value))
        #expect(decoded.extractorVersion == ReaderContentValue.currentExtractorVersion)
        #expect(decoded.isCurrent)
    }

    /// A record encoded before the field existed still decodes, rather than
    /// failing and taking a device's whole shard with it.
    @Test("a record without the field still decodes")
    func decodesLegacyRecord() throws {
        let json = Data(#"{"s":"failed"}"#.utf8)
        let decoded = try JSONDecoder().decode(ReaderContentValue.self, from: json)
        #expect(decoded.status == .failed)
        #expect(decoded.extractorVersion == nil)
        #expect(decoded.isCurrent == false)
    }
}
