import Foundation
import Testing

@testable import NookKit

/// Drafts are the only copy of writing that has not been published, so these pin the
/// properties that keep one from being lost.
@Suite("Nook Plus drafts")
struct PlusDraftTests {
    /// A fresh directory per test, removed afterwards.
    private func makeStore() throws -> (PlusDraftStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "nook-draft-tests-\(UUID().uuidString)")
        return (try PlusDraftStore(directory: directory), directory)
    }

    @Test("a draft survives a round trip")
    func roundTrip() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let draft = PlusDraft(
            title: "반가워요", slug: "hello", summary: "A note", markdown: "# 제목\n\n본문 **굵게**")
        try store.save(draft)

        let loaded = try #require(store.all().first)
        #expect(loaded.id == draft.id)
        #expect(loaded.title == "반가워요")
        #expect(loaded.slug == "hello")
        #expect(loaded.summary == "A note")
        #expect(loaded.markdown == "# 제목\n\n본문 **굵게**")
    }

    @Test("saving again replaces rather than duplicates")
    func saveReplaces() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        var draft = PlusDraft(title: "First", markdown: "one")
        try store.save(draft)
        draft.title = "Second"
        draft.markdown = "two"
        try store.save(draft)

        #expect(store.all().count == 1)
        #expect(store.all().first?.title == "Second")
    }

    @Test("drafts are listed newest first")
    func ordering() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.save(PlusDraft(title: "older", markdown: "x"))
        // `save` stamps the time itself, so the two need separable stamps.
        Thread.sleep(forTimeInterval: 0.01)
        try store.save(PlusDraft(title: "newer", markdown: "y"))

        #expect(store.all().map(\.title) == ["newer", "older"])
    }

    @Test("deleting removes only that draft")
    func delete() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let keep = PlusDraft(title: "keep", markdown: "x")
        let drop = PlusDraft(title: "drop", markdown: "y")
        try store.save(keep)
        try store.save(drop)

        store.delete(drop.id)
        #expect(store.all().map(\.title) == ["keep"])

        // Deleting something already gone is not an error.
        store.delete(drop.id)
        #expect(store.all().count == 1)
    }

    /// One unreadable file must not make the rest of someone's writing unreachable.
    @Test("an unreadable file costs one draft, not all of them")
    func corruptFileIsSkipped() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.save(PlusDraft(title: "good", markdown: "x"))
        try Data("this is not json".utf8)
            .write(to: directory.appending(path: "\(UUID().uuidString).json"))
        // Something that is not a draft at all, in the same directory.
        try Data("{}".utf8).write(to: directory.appending(path: "notes.txt"))

        #expect(store.all().map(\.title) == ["good"])
    }

    @Test("a store can be opened twice on the same directory")
    func reopen() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.save(PlusDraft(title: "kept", markdown: "x"))
        let reopened = try PlusDraftStore(directory: directory)
        #expect(reopened.all().map(\.title) == ["kept"])
    }

    // MARK: - What a draft is called in a list

    /// A draft usually has no title yet, and a list of "Untitled" cannot be read.
    @Test("a draft with no title is named from its first line")
    func displayTitleFallsBackToBody() {
        #expect(PlusDraft(title: "Given", markdown: "# Heading").displayTitle == "Given")
        #expect(PlusDraft(markdown: "# Heading\n\nBody").displayTitle == "Heading")
        #expect(PlusDraft(markdown: "- a list item").displayTitle == "a list item")
        #expect(PlusDraft(markdown: "> quoted opening").displayTitle == "quoted opening")
        #expect(PlusDraft(markdown: "\n\n  \nAfter blank lines").displayTitle == "After blank lines")
        #expect(PlusDraft(markdown: "반가워요 여기").displayTitle == "반가워요 여기")
    }

    @Test("a draft with nothing in it has no name and is not worth keeping")
    func emptyDraft() {
        let empty = PlusDraft()
        #expect(empty.displayTitle == "")
        #expect(empty.isEmpty)

        #expect(PlusDraft(markdown: "   \n\n ").isEmpty)
        #expect(!PlusDraft(markdown: "something").isEmpty)
        #expect(!PlusDraft(title: "something").isEmpty)
        // A summary alone is still writing worth keeping.
        #expect(!PlusDraft(summary: "a note to self").isEmpty)
    }

    /// A first line long enough to be a paragraph would push the row's own controls
    /// off the screen.
    @Test("a long first line is cut to a row's worth")
    func longFirstLine() {
        let draft = PlusDraft(markdown: String(repeating: "word ", count: 40))
        #expect(draft.displayTitle.count <= 60)
    }
}
