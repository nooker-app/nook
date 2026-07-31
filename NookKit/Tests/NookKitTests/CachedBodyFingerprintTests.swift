import Foundation
import Testing

@testable import NookKit

/// That the fingerprint survives being written down.
///
/// Both caches are on disk and one is synced between devices, so the whole
/// refresh depends on a value making the round trip. A mistyped coding key would
/// disable it silently: every cached body would read back with no fingerprint,
/// which for a Nook post means one needless re-extraction and for everything else
/// means nothing at all — no crash, no error, and no refresh either.
@Suite("Cached body fingerprint")
struct CachedBodyFingerprintTests {
    @Test("an extracted body keeps its fingerprint through the shard")
    func readerContentRoundTrip() throws {
        let value = ReaderContentValue(
            status: .success, html: "<p>Body.</p>", sourceFingerprint: "abc123")

        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ReaderContentValue.self, from: data)

        #expect(decoded.sourceFingerprint == "abc123")
        #expect(decoded == value)
    }

    /// The key as it appears on disk, pinned against a literal.
    ///
    /// A round trip cannot catch this: encoding and decoding share the same
    /// `CodingKeys`, so renaming the key keeps every round trip passing while
    /// silently failing to read anything another device or an earlier build wrote.
    /// The shard is synced, so that is data loss in the only place it matters.
    @Test("the on-disk key for the fingerprint is pinned")
    func readerContentKeyIsPinned() throws {
        let onDisk = Data(#"{"s":"success","h":"<p>Body.</p>","v":2,"f":"fp-pinned"}"#.utf8)
        let decoded = try JSONDecoder().decode(ReaderContentValue.self, from: onDisk)
        #expect(decoded.sourceFingerprint == "fp-pinned")

        // And the same name comes back out, so a peer on an older build can read it.
        let encoded = try JSONEncoder().encode(decoded)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains(#""f":"fp-pinned""#), "encoded as: \(text)")
    }

    /// A record written by an older build has no fingerprint and must still decode.
    @Test("an extracted body written before fingerprints existed still decodes")
    func readerContentDecodesWithoutFingerprint() throws {
        let legacy = Data(#"{"s":"success","h":"<p>Body.</p>","v":2}"#.utf8)
        let decoded = try JSONDecoder().decode(ReaderContentValue.self, from: legacy)

        #expect(decoded.sourceFingerprint == nil)
        #expect(decoded.status == .success)
        #expect(decoded.html == "<p>Body.</p>")
    }

    /// A whole shard document, which is the form that actually reaches disk and
    /// peers.
    @Test("a reader shard carries fingerprints for its entries")
    func shardRoundTrip() throws {
        var document = ReaderContentShardDocument(deviceID: "device-1")
        let clock = HLC.next(after: .zero, node: "device-1")
        document.clock = clock
        document.entries["f#at://did:plc:abc/app.nooker.article/3kkk"] = LWWRegister(
            value: ReaderContentValue(
                status: .success, html: "<p>Body.</p>", sourceFingerprint: "fp-1"),
            hlc: clock)

        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(ReaderContentShardDocument.self, from: data)

        #expect(
            decoded.entries["f#at://did:plc:abc/app.nooker.article/3kkk"]?.value
                .sourceFingerprint == "fp-1")
    }

    @Test("an offline copy keeps its fingerprint through its index")
    func offlineInfoRoundTrip() throws {
        let info = OfflineArticleInfo(
            id: "f#at://did:plc:abc/app.nooker.article/3kkk", title: "Title",
            url: URL(string: "https://nooker.app/@tim/post")!, feedTitle: "tim",
            savedAt: Date(timeIntervalSince1970: 1_700_000_000), byteCount: 12,
            sourceFingerprint: "fp-2")

        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(OfflineArticleInfo.self, from: data)

        #expect(decoded.sourceFingerprint == "fp-2")
        #expect(decoded == info)
    }

    /// The offline index's key, pinned the same way and for the same reason.
    @Test("the on-disk key for an offline copy's fingerprint is pinned")
    func offlineKeyIsPinned() throws {
        let onDisk = Data(
            """
            {"id":"f#1","title":"T","url":"https://example.com/p","feedTitle":"f",
             "savedAt":751000000,"byteCount":12,"sourceFingerprint":"fp-pinned"}
            """.utf8)
        let decoded = try JSONDecoder().decode(OfflineArticleInfo.self, from: onDisk)
        #expect(decoded.sourceFingerprint == "fp-pinned")
    }

    /// An index written by an older build has no fingerprint. Those copies must
    /// still load — a saved article that stopped opening would be a far worse
    /// outcome than one that refreshes once.
    @Test("an offline copy saved before fingerprints existed still decodes")
    func offlineInfoDecodesWithoutFingerprint() throws {
        let legacy = Data(
            """
            {"id":"f#1","title":"T","url":"https://example.com/p","feedTitle":"f",
             "savedAt":751000000,"byteCount":12}
            """.utf8)
        let decoded = try JSONDecoder().decode(OfflineArticleInfo.self, from: legacy)

        #expect(decoded.sourceFingerprint == nil)
        #expect(decoded.id == "f#1")
    }
}
