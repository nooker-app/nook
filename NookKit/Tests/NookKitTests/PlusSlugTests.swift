import Testing

@testable import NookKit

/// The address is derived rather than typed, so nobody proofreads it. A wrong
/// one becomes a permanent public link, which is why these are pinned.
@Suite("Nook Plus address derivation")
struct PlusSlugTests {
    @Test("a title becomes a readable address")
    func ordinaryTitles() {
        #expect(PlusSlug.derive(from: "My First Post") == "my-first-post")
        #expect(PlusSlug.derive(from: "Hello") == "hello")
        #expect(PlusSlug.derive(from: "Reading in 2026") == "reading-in-2026")
    }

    @Test("punctuation becomes a word break, never a character")
    func punctuation() {
        #expect(PlusSlug.derive(from: "What's next?") == "what-s-next")
        #expect(PlusSlug.derive(from: "Notes: part one") == "notes-part-one")
        #expect(PlusSlug.derive(from: "a/b\\c") == "a-b-c")
        #expect(PlusSlug.derive(from: "one  two   three") == "one-two-three")
    }

    /// No hyphen may lead, trail, or double up: the service rejects all three, and
    /// a derived address that cannot be submitted is worse than none.
    @Test("hyphens never lead, trail, or double")
    func hyphens() {
        for title in ["  Spaced  ", "...Dots...", "-- Dashes --", "!!!", "a -- b"] {
            let slug = PlusSlug.derive(from: title)
            #expect(!slug.hasPrefix("-"), "\(title) produced \(slug)")
            #expect(!slug.hasSuffix("-"), "\(title) produced \(slug)")
            #expect(!slug.contains("--"), "\(title) produced \(slug)")
        }
    }

    /// A title in another script yields nothing rather than a guess. Romanising
    /// would put a machine's reading of someone's words in their permanent URL.
    @Test("other scripts yield an empty address rather than a transliteration")
    func otherScripts() {
        #expect(PlusSlug.derive(from: "안녕하세요") == "")
        #expect(PlusSlug.derive(from: "テスト") == "")
        #expect(PlusSlug.derive(from: "Hello 안녕") == "hello")
    }

    @Test("the result stays within the length the service accepts")
    func length() {
        let long = String(repeating: "word ", count: 40)
        let slug = PlusSlug.derive(from: long)
        #expect(slug.utf8.count <= PlusSlug.maximumLength)
        #expect(!slug.hasSuffix("-"))
    }

    @Test("an empty title yields an empty address")
    func empty() {
        #expect(PlusSlug.derive(from: "") == "")
        #expect(PlusSlug.derive(from: "   ") == "")
    }
}
