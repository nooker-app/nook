import Foundation
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

    // MARK: - Validation

    /// The rules mirror the service's, so anything accepted here is accepted there.
    /// A mismatch shows up as a rejected publish after the writing is done.
    @Test("validation matches what the service accepts")
    func validation() {
        #expect(PlusSlug.problem(with: "my-post") == nil)
        #expect(PlusSlug.problem(with: "2026-07-30") == nil)
        #expect(PlusSlug.problem(with: "a") == nil)
        #expect(PlusSlug.problem(with: "") == .empty)
        #expect(PlusSlug.problem(with: "   ") == .empty)
        #expect(PlusSlug.problem(with: "-leading") == .hyphenAtEdge)
        #expect(PlusSlug.problem(with: "trailing-") == .hyphenAtEdge)
        #expect(PlusSlug.problem(with: String(repeating: "a", count: 61)) == .tooLong)
    }

    /// The case the writer reported: typing Korean into the address field said
    /// nothing at all, and publishing failed later with no explanation.
    @Test("an address in another script is refused with a reason")
    func otherScriptsAreRefused() {
        for slug in ["반가워요", "テスト", "测试", "café", "my post", "My-Post", "under_score"] {
            #expect(
                PlusSlug.problem(with: slug) == .unsupportedCharacters,
                "\(slug) should be refused")
        }
    }

    @Test("every reason has something to show")
    func messages() {
        for problem: PlusSlug.Problem in [.empty, .tooLong, .unsupportedCharacters, .hyphenAtEdge] {
            #expect(problem.message.isEmpty == false)
        }
    }

    // MARK: - The dated default

    /// What a title with no ASCII falls back to.
    @Test("a date makes a readable address")
    func datedDefault() {
        let date = DateComponents(calendar: .current, year: 2026, month: 7, day: 30).date!
        #expect(PlusSlug.dated(date, avoiding: []) == "2026-07-30")
        #expect(PlusSlug.isUsable(PlusSlug.dated(date, avoiding: [])))
    }

    /// A second post on the same day counts up, so somebody reading the URL can make
    /// sense of it. A random suffix would be unique and meaningless.
    @Test("a second post on the same day counts up")
    func datedAvoidsCollisions() {
        let date = DateComponents(calendar: .current, year: 2026, month: 7, day: 30).date!
        #expect(PlusSlug.dated(date, avoiding: ["2026-07-30"]) == "2026-07-30-2")
        #expect(PlusSlug.dated(date, avoiding: ["2026-07-30", "2026-07-30-2"]) == "2026-07-30-3")
    }
}
