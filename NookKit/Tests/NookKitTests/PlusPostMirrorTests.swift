import Foundation
import Testing

@testable import NookKit

/// The rules that decide whose files these are.
///
/// Pinned hard because the failure mode is deleting somebody else's writing. A sync
/// folder can be shared, so the mirror will meet directories belonging to accounts it
/// is not signed in as, and the wrong answer there is not a cosmetic bug.
@Suite("Nook Plus post mirror")
struct PlusPostMirrorTests {
    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "nook-mirror-tests-\(UUID().uuidString)")
    }

    private func makeAccountDirectory(owner: String?) throws -> URL {
        let folder = temporaryFolder()
        let directory = PlusPostMirror.directory(in: folder, handle: "tim.nooker.app")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let owner {
            try Data(owner.utf8).write(
                to: directory.appending(path: PlusPostMirror.ownerFileName))
        }
        return directory
    }

    // MARK: - Paths

    /// A writer opening their sync folder should recognise the directory, so it is
    /// named from the handle rather than from the DID.
    @Test("an account's directory is named from its handle")
    func directoryName() {
        let folder = URL(filePath: "/tmp/MySync")
        let directory = PlusPostMirror.directory(in: folder, handle: "tim.nooker.app")
        #expect(directory.path().hasSuffix("MySync/Posts/tim/"))
    }

    @Test("the domain is dropped and only the first label is used")
    func folderNameUsesTheFirstLabel() {
        #expect(PlusPostMirror.folderName(for: "tim.nooker.app") == "tim")
        #expect(PlusPostMirror.folderName(for: "tim.staging.nooker.app") == "tim")
        #expect(PlusPostMirror.folderName(for: "tim") == "tim")
    }

    /// A directory name assembled from an unexpected string is how a write escapes the
    /// folder it was meant for.
    @Test("a handle that could escape the folder is reduced to something that cannot")
    func folderNameCannotEscape() {
        for handle in ["../../etc", "..", ".", "/etc/passwd", "a/b", "", "///"] {
            let name = PlusPostMirror.folderName(for: handle)
            #expect(!name.contains("/"), "\(handle) produced \(name)")
            #expect(!name.contains("\\"), "\(handle) produced \(name)")
            #expect(name != "." && name != "..", "\(handle) produced \(name)")
            #expect(!name.isEmpty, "\(handle) produced an empty name")
        }
    }

    /// The file is named from the slug, which is what the public URL is built from, so
    /// the file a writer opens is recognisably the page a reader sees.
    @Test("a post's file is named from its slug")
    func fileName() throws {
        let directory = URL(filePath: "/tmp/MySync/Posts/tim")
        let file = try #require(PlusPostMirror.file(in: directory, slug: "hello-world"))
        #expect(file.lastPathComponent == "hello-world.md")
    }

    /// The Korean slug published before the service validated them is still a slug the
    /// mirror has to handle.
    @Test("a slug in another script still names a file")
    func multibyteSlug() throws {
        let directory = URL(filePath: "/tmp/MySync/Posts/tim")
        let file = try #require(PlusPostMirror.file(in: directory, slug: "하이"))
        #expect(file.lastPathComponent == "하이.md")
    }

    /// Refused, not repaired. Silently rewriting a traversal hides that a caller
    /// passed one at all.
    @Test("a slug that is not one safe component is refused")
    func unsafeSlugsAreRefused() {
        let directory = URL(filePath: "/tmp/MySync/Posts/tim")
        for slug in ["", ".", "..", "../secrets", "a/b", "a\\b", ".hidden", "with\0null"] {
            #expect(
                PlusPostMirror.file(in: directory, slug: slug) == nil,
                "\(slug.debugDescription) should be refused")
        }
    }

    // MARK: - Ownership

    @Test("an unowned directory may be claimed")
    func unownedIsClaimable() throws {
        let directory = try makeAccountDirectory(owner: nil)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(PlusPostMirror.owner(of: directory) == nil)
        #expect(PlusPostMirror.mayWrite(directory, as: "did:plc:me"))
    }

    @Test("a directory that does not exist yet may be claimed")
    func missingIsClaimable() {
        let directory = temporaryFolder().appending(path: "Posts/nobody")
        #expect(PlusPostMirror.mayWrite(directory, as: "did:plc:me"))
    }

    @Test("the owner may write to its own directory")
    func ownerMayWrite() throws {
        let directory = try makeAccountDirectory(owner: "did:plc:me")
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(PlusPostMirror.owner(of: directory) == "did:plc:me")
        #expect(PlusPostMirror.mayWrite(directory, as: "did:plc:me"))
    }

    /// The reason this file exists. A shared sync folder holds another account's
    /// posts, and a mirror that treated them as its own would delete them for not
    /// being in its repository.
    @Test("another account's directory must not be written to")
    func anotherAccountIsRefused() throws {
        let directory = try makeAccountDirectory(owner: "did:plc:someone-else")
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(!PlusPostMirror.mayWrite(directory, as: "did:plc:me"))
    }

    /// Two accounts can pick the same handle on different deployments, or one can be
    /// renamed to the other's old name. The folder name is therefore never the test.
    @Test("ownership follows the DID, not the folder name")
    func ownershipIgnoresTheFolderName() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // Two directories with the same handle-derived name cannot coexist, so this is
        // the case where a handle was reused: the name says "tim", the owner does not.
        let directory = PlusPostMirror.directory(in: folder, handle: "tim.nooker.app")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("did:plc:the-original-tim".utf8)
            .write(to: directory.appending(path: PlusPostMirror.ownerFileName))

        #expect(!PlusPostMirror.mayWrite(directory, as: "did:plc:a-different-tim"))
    }

    /// Written by hand, or synced by a service that adds a trailing newline.
    @Test("a recorded owner is read with surrounding whitespace ignored")
    func ownerIsTrimmed() throws {
        let directory = try makeAccountDirectory(owner: "  did:plc:me\n\n")
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(PlusPostMirror.owner(of: directory) == "did:plc:me")
        #expect(PlusPostMirror.mayWrite(directory, as: "did:plc:me"))
    }

    /// An empty owner file is no claim at all, not a claim by the empty DID — which
    /// would otherwise match nothing and lock the directory forever.
    @Test("an empty owner file leaves the directory claimable")
    func emptyOwnerIsNoOwner() throws {
        let directory = try makeAccountDirectory(owner: "   \n")
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(PlusPostMirror.owner(of: directory) == nil)
        #expect(PlusPostMirror.mayWrite(directory, as: "did:plc:me"))
    }

    // MARK: - Writing

    private func post(_ slug: String, title: String? = nil, markdown: String = "Body.")
        -> PlusPostMirror.Post
    {
        PlusPostMirror.Post(
            slug: slug, title: title ?? slug, summary: "", markdown: markdown,
            publishedAt: "2026-07-30T12:00:00Z",
            url: "https://tim.example.com/\(slug)")
    }

    @Test("posts are written as one Markdown file each")
    func writesOneFilePerPost() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let result = try PlusPostMirror.write(
            [post("hello"), post("second")], to: folder, handle: "tim.nooker.app",
            did: "did:plc:me")

        #expect(result == PlusPostMirror.Result(written: 2, removed: 0))
        let directory = PlusPostMirror.directory(in: folder, handle: "tim.nooker.app")
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "hello.md").path))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "second.md").path))
        #expect(PlusPostMirror.owner(of: directory) == "did:plc:me")
    }

    /// The body has to be the Markdown as published, not a rendering of it, or the file
    /// is not a copy and an edit promoted back would change text nobody touched.
    @Test("the body is the Markdown exactly as published")
    func bodyIsVerbatim() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let markdown = "# 제목\n\n- 하나\n- 둘\n\n```swift\nlet x = 1\n```\n"
        try PlusPostMirror.write(
            [post("hi", markdown: markdown)], to: folder, handle: "tim.nooker.app",
            did: "did:plc:me")

        let file = PlusPostMirror.directory(in: folder, handle: "tim.nooker.app")
            .appending(path: "hi.md")
        let text = try String(contentsOf: file, encoding: .utf8)
        let body = try #require(text.range(of: "---\n\n", options: .backwards))
        #expect(String(text[body.upperBound...]) == markdown)
    }

    /// Deleting a post is the only reason the mirror removes anything, and it must
    /// actually remove it — a folder still showing a deleted post is the deletion
    /// guarantee failing where the writer can see it.
    @Test("a post that no longer exists is removed on the next pass")
    func removesWhatIsGone() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = PlusPostMirror.directory(in: folder, handle: "tim.nooker.app")

        try PlusPostMirror.write(
            [post("keep"), post("delete-me")], to: folder, handle: "tim.nooker.app",
            did: "did:plc:me")
        let result = try PlusPostMirror.write(
            [post("keep")], to: folder, handle: "tim.nooker.app", did: "did:plc:me")

        #expect(result == PlusPostMirror.Result(written: 1, removed: 1))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "keep.md").path))
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appending(path: "delete-me.md").path))
    }

    /// The removal pass looks at `.md` files because those are the ones this mirror
    /// writes. Anything else in the directory belongs to the writer.
    @Test("files the mirror did not write are left alone")
    func leavesForeignFilesAlone() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = PlusPostMirror.directory(in: folder, handle: "tim.nooker.app")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: directory.appending(path: "notes.txt"))

        try PlusPostMirror.write(
            [post("hello")], to: folder, handle: "tim.nooker.app", did: "did:plc:me")

        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "notes.txt").path))
    }

    /// The whole reason ownership is recorded. Signing in as a second account must not
    /// delete the first account's posts for not being in the second's repository.
    @Test("another account's posts survive a write by a different account")
    func doesNotTouchAnotherAccount() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = PlusPostMirror.directory(in: folder, handle: "tim.nooker.app")

        try PlusPostMirror.write(
            [post("theirs")], to: folder, handle: "tim.nooker.app", did: "did:plc:the-first-tim")

        // Same handle-derived directory, different account. Nothing may happen.
        let result = try PlusPostMirror.write(
            [post("mine")], to: folder, handle: "tim.nooker.app", did: "did:plc:another-tim")

        #expect(result.refusedAsNotOurs)
        #expect(result.written == 0 && result.removed == 0)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "theirs.md").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "mine.md").path))
        #expect(PlusPostMirror.owner(of: directory) == "did:plc:the-first-tim")
    }

    /// Two devices mirroring the same repository must write the same bytes, or the sync
    /// service sees a conflict on every pass and the folder never settles.
    @Test("the same records produce byte-identical files")
    func writesAreDeterministic() throws {
        let posts = [post("hello", title: "제목: \"인용\""), post("second")]
        var contents: [Data] = []
        for _ in 0..<2 {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            try PlusPostMirror.write(posts, to: folder, handle: "tim.nooker.app", did: "did:plc:me")
            let file = PlusPostMirror.directory(in: folder, handle: "tim.nooker.app")
                .appending(path: "hello.md")
            contents.append(try Data(contentsOf: file))
        }
        #expect(contents[0] == contents[1])
    }

    /// Titles carry colons and quotation marks routinely, and an unquoted value with
    /// either makes a file that reads back wrong.
    @Test("a title with a colon or a quote stays on one readable line")
    func frontMatterQuotes() {
        let document = PlusPostMirror.document(
            for: PlusPostMirror.Post(
                slug: "hi", title: "Nook: a \"reader\"\nand more", summary: "", markdown: "Body.",
                publishedAt: nil, url: nil))
        let titleLine = try? #require(
            document.split(separator: "\n").first { $0.hasPrefix("title:") })
        #expect(titleLine == #"title: "Nook: a \"reader\" and more""#)
    }

    /// A post published before slugs were validated may still have a slug no file can be
    /// named from. Skipping it must not take the rest of the mirror down with it.
    @Test("an unmirrorable slug is skipped, not fatal")
    func skipsUnsafeSlug() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let result = try PlusPostMirror.write(
            [post("../escape"), post("fine")], to: folder, handle: "tim.nooker.app",
            did: "did:plc:me")

        #expect(result.written == 1)
        let directory = PlusPostMirror.directory(in: folder, handle: "tim.nooker.app")
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "fine.md").path))
    }
}


/// What happens when the writer changes something in the folder.
///
/// The mirror is read-only in the sense that it never publishes by itself, not in the
/// sense that it fights the writer. These pin the two halves of that: an edit is
/// always kept, and it is always reported.
@Suite("Nook Plus post mirror edits")
struct PlusPostMirrorEditTests {
    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "nook-mirror-edits-\(UUID().uuidString)")
    }

    private func post(_ slug: String, title: String = "Title", markdown: String = "Body.")
        -> PlusPostMirror.Post
    {
        PlusPostMirror.Post(
            slug: slug, title: title, summary: "", markdown: markdown,
            publishedAt: "2026-07-30T12:00:00Z", url: "https://tim.example.com/\(slug)")
    }

    private func file(_ folder: URL, _ slug: String) -> URL {
        PlusPostMirror.directory(in: folder, handle: "tim.nooker.app")
            .appending(path: "\(slug).md")
    }

    /// A file straight from the mirror is a copy, and may be rewritten or removed.
    @Test("a freshly written file reads back as an untouched copy")
    func freshFileIsUntouched() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try PlusPostMirror.write(
            [post("hello")], to: folder, handle: "tim.nooker.app", did: "did:plc:me")

        guard case .untouchedCopy = PlusPostMirror.classify(file(folder, "hello")) else {
            Issue.record("a file the mirror just wrote was not recognised as its own")
            return
        }
    }

    /// The whole promise of the folder: change the file, and Nook notices.
    @Test("an edited body is detected and reported")
    func editedBodyIsReported() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try PlusPostMirror.write(
            [post("hello", markdown: "Original.")], to: folder, handle: "tim.nooker.app",
            did: "did:plc:me")

        // The writer opens the file and changes the body, leaving the front matter be.
        let target = file(folder, "hello")
        var text = try String(contentsOf: target, encoding: .utf8)
        text = text.replacingOccurrences(of: "Original.", with: "Rewritten by hand.")
        try Data(text.utf8).write(to: target)

        let result = try PlusPostMirror.write(
            [post("hello", markdown: "Original.")], to: folder, handle: "tim.nooker.app",
            did: "did:plc:me")

        #expect(result.edited.count == 1)
        #expect(result.edited.first?.slug == "hello")
        #expect(result.edited.first?.markdown == "Rewritten by hand.")
    }

    /// The one thing that must never happen. A plain mirror would overwrite the edit on
    /// its next pass and the writing would be gone with no way back.
    @Test("an edited file is not overwritten")
    func editedFileSurvivesTheNextPass() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = file(folder, "hello")

        try PlusPostMirror.write(
            [post("hello", markdown: "Original.")], to: folder, handle: "tim.nooker.app",
            did: "did:plc:me")
        var text = try String(contentsOf: target, encoding: .utf8)
        text = text.replacingOccurrences(of: "Original.", with: "Hours of work.")
        try Data(text.utf8).write(to: target)

        // Three more passes, as a store reloading would do.
        for _ in 0..<3 {
            try PlusPostMirror.write(
                [post("hello", markdown: "Original.")], to: folder, handle: "tim.nooker.app",
                did: "did:plc:me")
        }

        let after = try String(contentsOf: target, encoding: .utf8)
        #expect(after.contains("Hours of work."))
        #expect(!after.contains("Original."))
    }

    /// An edited title is a change to publish too, and it lives in the front matter
    /// rather than the body.
    @Test("an edited title is detected")
    func editedTitleIsReported() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = file(folder, "hello")

        try PlusPostMirror.write(
            [post("hello", title: "First go")], to: folder, handle: "tim.nooker.app",
            did: "did:plc:me")
        var text = try String(contentsOf: target, encoding: .utf8)
        text = text.replacingOccurrences(of: #"title: "First go""#, with: #"title: "Better title""#)
        try Data(text.utf8).write(to: target)

        let result = try PlusPostMirror.write(
            [post("hello", title: "First go")], to: folder, handle: "tim.nooker.app",
            did: "did:plc:me")

        #expect(result.edited.first?.title == "Better title")
        #expect(result.edited.first?.markdown == "Body.")
    }

    /// Renaming the file used to be the dangerous case: the new name is not a slug the
    /// mirror knows, so a name-based removal pass would delete it. The slug comes from
    /// inside the file, so the edit is attributed to the right post and kept.
    @Test("a renamed file is kept and attributed to its original post")
    func renamedFileIsKept() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = PlusPostMirror.directory(in: folder, handle: "tim.nooker.app")

        try PlusPostMirror.write(
            [post("hello")], to: folder, handle: "tim.nooker.app", did: "did:plc:me")

        // Renamed and edited, which is what a writer reorganising a folder does.
        let renamed = directory.appending(path: "my-notes.md")
        var text = try String(contentsOf: file(folder, "hello"), encoding: .utf8)
        text = text.replacingOccurrences(of: "Body.", with: "Edited after renaming.")
        try Data(text.utf8).write(to: renamed)
        try FileManager.default.removeItem(at: file(folder, "hello"))

        let result = try PlusPostMirror.write(
            [post("hello")], to: folder, handle: "tim.nooker.app", did: "did:plc:me")

        #expect(FileManager.default.fileExists(atPath: renamed.path))
        #expect(result.edited.contains { $0.slug == "hello" && $0.markdown == "Edited after renaming." })
    }

    /// The record still exists, so the file comes back. Honouring a Finder deletion as
    /// an unpublish would take a post down with no confirmation at all.
    @Test("a file the writer deleted is written again")
    func deletedFileComesBack() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try PlusPostMirror.write(
            [post("hello")], to: folder, handle: "tim.nooker.app", did: "did:plc:me")
        try FileManager.default.removeItem(at: file(folder, "hello"))

        try PlusPostMirror.write(
            [post("hello")], to: folder, handle: "tim.nooker.app", did: "did:plc:me")

        #expect(FileManager.default.fileExists(atPath: file(folder, "hello").path))
    }

    /// Deleted on one device while another had unpublished changes in the folder. The
    /// record is gone, so nothing will rewrite the file — discarding it would be the
    /// only unrecoverable outcome here.
    @Test("an edit whose post was deleted elsewhere is kept, not removed")
    func editOfADeletedPostSurvives() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = file(folder, "hello")

        try PlusPostMirror.write(
            [post("hello")], to: folder, handle: "tim.nooker.app", did: "did:plc:me")
        var text = try String(contentsOf: target, encoding: .utf8)
        text = text.replacingOccurrences(of: "Body.", with: "Work in progress.")
        try Data(text.utf8).write(to: target)

        // The post no longer exists in the repository.
        let result = try PlusPostMirror.write(
            [], to: folder, handle: "tim.nooker.app", did: "did:plc:me")

        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(result.removed == 0)
        #expect(result.edited.first?.markdown == "Work in progress.")
    }

    /// A Markdown file the writer put in the folder themselves has no fingerprint, so
    /// it is none of the mirror's business — neither deleted nor reported as an edit.
    @Test("a Markdown file the mirror never wrote is left alone and not reported")
    func foreignMarkdownIsIgnored() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = PlusPostMirror.directory(in: folder, handle: "tim.nooker.app")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mine = directory.appending(path: "shopping-list.md")
        try Data("# Milk\n".utf8).write(to: mine)

        let result = try PlusPostMirror.write(
            [post("hello")], to: folder, handle: "tim.nooker.app", did: "did:plc:me")

        #expect(FileManager.default.fileExists(atPath: mine.path))
        #expect(result.removed == 0)
        #expect(result.edited.isEmpty)
    }

    /// Whatever the writer typed has to come back out exactly, or promoting an edit
    /// would publish something they did not write.
    @Test("a body round-trips through the file unchanged")
    func bodyRoundTrips() throws {
        let bodies = [
            "Plain.",
            "# 제목\n\n본문 🎉\n",
            "Ends with a newline.\n",
            "\nStarts with a blank line.",
            "A thematic break:\n\n---\n\nafter it.",
            "Front matter lookalike:\n\ntitle: \"not really\"\n",
            "Trailing spaces   \nand a tab\there.",
        ]
        for body in bodies {
            let document = PlusPostMirror.document(
                for: PlusPostMirror.Post(
                    slug: "hi", title: "T", summary: "S", markdown: body,
                    publishedAt: nil, url: nil))
            let parsed = try #require(PlusPostMirror.parse(document))
            #expect(parsed.body == body, "body \(body.debugDescription) did not round-trip")
            #expect(parsed.title == "T")
            #expect(parsed.summary == "S")
        }
    }

    /// The fingerprint has to survive a round trip too, or every file would read back
    /// as an edit and the writer would be asked to publish changes they never made.
    @Test("a title with quotes and colons still reads back as an untouched copy")
    func awkwardTitleIsNotSeenAsAnEdit() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let awkward = PlusPostMirror.Post(
            slug: "hello", title: #"Nook: a "reader", and \more\"#, summary: "왜: 이유",
            markdown: "Body.", publishedAt: nil, url: nil)
        let result = try PlusPostMirror.write(
            [awkward], to: folder, handle: "tim.nooker.app", did: "did:plc:me")
        #expect(result.edited.isEmpty)

        let again = try PlusPostMirror.write(
            [awkward], to: folder, handle: "tim.nooker.app", did: "did:plc:me")
        #expect(again.edited.isEmpty, "an unedited file was reported as an edit")
    }

    /// Moving a field between title and summary must not produce the same digest, or an
    /// edit that only rearranges them would go unnoticed.
    @Test("the fingerprint separates the fields it covers")
    func fingerprintIsUnambiguous() {
        #expect(
            PlusPostMirror.fingerprint(title: "ab", summary: "c", body: "d")
                != PlusPostMirror.fingerprint(title: "a", summary: "bc", body: "d"))
        #expect(
            PlusPostMirror.fingerprint(title: "a", summary: "", body: "b")
                != PlusPostMirror.fingerprint(title: "a", summary: "b", body: ""))
    }
}
