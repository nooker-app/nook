import CryptoKit
import Foundation

/// Where a writer's published posts appear inside their own sync folder, and whose
/// they are.
///
/// Nook is already a folder-backed tool: feeds, article caches, and icons all live in
/// a directory the reader chose. Posts did not, which meant the one thing a writer
/// makes themselves was the one thing they could not open in Finder. This puts them
/// there.
///
/// A **mirror**, not a store. The authoritative copy is the record in the writer's
/// PDS repository; these files are written from it and can be rebuilt from it at any
/// time. That is what makes it safe to delete and rewrite them — and why an edit made
/// here has to be promoted deliberately rather than published the moment a text
/// editor saves.
///
/// ## Why ownership is the hard part
///
/// A sync folder can be shared, so the folder may hold posts belonging to an account
/// that is not the one signed in — a second account on another device, or the same
/// device after signing out of one and into another. The dangerous operation is not
/// a name collision, it is deletion: a mirror that removes "files my repository does
/// not account for" would delete somebody else's writing.
///
/// So every directory records its owner's DID, and nothing touches a directory whose
/// recorded owner is not the account doing the work. The DID rather than the handle,
/// because the DID is the stable content-owner identifier and a handle is a mutable
/// presentation attribute — a rename must not orphan a mirror, and two accounts must
/// not be able to collide by both choosing the same name.
enum PlusPostMirror {
    /// The directory holding every mirrored account, inside the sync folder.
    static let directoryName = "Posts"

    /// The file inside an account's directory naming its owner.
    ///
    /// Dot-prefixed so it stays out of the way in Finder, and plain text so an
    /// operator looking at a folder they do not recognise can see whose it is.
    static let ownerFileName = ".nook-owner"

    /// The directory for one account.
    ///
    /// Named from the handle, because a writer opening their sync folder should
    /// recognise it. Identity does not depend on the name: ``owner(of:)`` reads the
    /// DID from inside.
    static func directory(in syncFolder: URL, handle: String) -> URL {
        syncFolder
            .appending(path: directoryName, directoryHint: .isDirectory)
            .appending(path: folderName(for: handle), directoryHint: .isDirectory)
    }

    /// A handle reduced to something safe as a single path component.
    ///
    /// Handles are already restricted to letters, digits, and hyphens per label, so
    /// this mostly drops the domain: `tim.nooker.app` becomes `tim`. A handle that
    /// somehow arrives with a separator in it is refused rather than sanitised,
    /// because a directory name assembled from an unexpected string is how a write
    /// escapes the folder it was meant for.
    static func folderName(for handle: String) -> String {
        let firstLabel = handle.split(separator: ".").first.map(String.init) ?? handle
        let allowed = firstLabel.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return allowed.isEmpty ? "account" : allowed
    }

    /// The file one post is mirrored to.
    ///
    /// Named from the slug, which is what the post's public URL is built from, so the
    /// file a writer opens is recognisably the page a reader sees. Derived from the
    /// record rather than from anything local, so two devices mirroring the same
    /// repository write byte-identical trees and never fight.
    static func file(in accountDirectory: URL, slug: String) -> URL? {
        // A slug that is not a single safe path component is refused rather than
        // repaired. Slugs are validated on the way in, and the ones that predate that
        // validation are exactly the values not to trust with a file path.
        guard isSafeComponent(slug) else { return nil }
        return accountDirectory.appending(path: slug + ".md", directoryHint: .notDirectory)
    }

    /// Whether a value is safe to use as one path component.
    ///
    /// Refuses anything empty, anything with a separator, and the two relative names.
    /// Deliberately not a sanitiser: silently rewriting `../../etc/passwd` into
    /// something harmless hides that a caller passed it at all.
    static func isSafeComponent(_ value: String) -> Bool {
        if value.isEmpty || value == "." || value == ".." { return false }
        if value.hasPrefix(".") { return false }
        if value.contains("/") || value.contains("\\") || value.contains("\0") { return false }
        return true
    }

    // MARK: - Ownership

    /// Reads the DID recorded for a directory, or nil when there is none.
    static func owner(of accountDirectory: URL) -> String? {
        let file = accountDirectory.appending(path: ownerFileName, directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: file),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        let did = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return did.isEmpty ? nil : did
    }

    /// Whether this account may write to a directory.
    ///
    /// Three answers, and the middle one is the point:
    ///
    /// - no directory yet, or one with no owner recorded → may claim it
    /// - owner matches → may write
    /// - owner is somebody else → **must not touch it**, not even to delete a file
    ///   the current repository does not account for
    ///
    /// An unowned directory is claimable because a writer may have created `Posts/`
    /// themselves, and refusing to use it would be a mirror that silently never
    /// appears.
    static func mayWrite(_ accountDirectory: URL, as did: String) -> Bool {
        guard let recorded = owner(of: accountDirectory) else { return true }
        return recorded == did
    }
}

// MARK: - Writing the mirror

extension PlusPostMirror {
    /// One post, as the mirror needs it.
    struct Post {
        var slug: String
        var title: String
        var summary: String
        var markdown: String
        /// The record's own timestamp, copied through as a string rather than parsed
        /// and reformatted. A round trip through `Date` would rewrite the value — a
        /// different fractional precision or offset for the same instant — and make the
        /// file differ from the record for no reason.
        var publishedAt: String?
        /// The public URL, written into the file so somebody reading it in Finder can
        /// find the page it corresponds to.
        var url: String?
    }

    /// What a write changed, for logging and for telling the writer.
    struct Result: Equatable {
        var written = 0
        var removed = 0
        /// Files left untouched because they were not the mirror's to change.
        var left = 0
        /// Hand edits found in the folder, in no particular order. These files were not
        /// written over; the app decides what to offer.
        var edited: [Edit] = []
        /// True when the directory belongs to another account and nothing was done.
        var refusedAsNotOurs = false
    }

    /// Mirrors an account's posts into the sync folder.
    ///
    /// Two rules, and everything here follows from them:
    ///
    /// **Nothing the writer touched is overwritten or deleted.** Each file carries a
    /// fingerprint of what the mirror put in it, so a file can be classified without
    /// any stored state: matching means an untouched copy, which may be rewritten or
    /// removed freely; not matching means the writer's own work, which is left exactly
    /// as it is and reported instead. That covers a hand edit, a renamed file, and a
    /// file that was never ours, with the same test.
    ///
    /// **Nothing is deleted that a record does not account for.** A copy whose slug is
    /// no longer published is removed, which is how a deleted post leaves the folder. A
    /// file the writer deleted comes back — the record still exists, and re-creating it
    /// loses nothing, where honouring the deletion would unpublish a post from a Finder
    /// gesture with no confirmation.
    @discardableResult
    static func write(
        _ posts: [Post], to syncFolder: URL, handle: String, did: String
    ) throws -> Result {
        let directory = directory(in: syncFolder, handle: handle)

        // Before anything, including the removal pass. A shared folder may hold
        // another account's posts, and this is what stops them being deleted for not
        // being in a repository that was never theirs.
        guard mayWrite(directory, as: did) else {
            return Result(refusedAsNotOurs: true)
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Claimed on every pass, not only at creation: a folder restored from a backup
        // or copied by hand may have the posts and not the marker.
        try Data(did.utf8).write(
            to: directory.appending(path: ownerFileName), options: .atomic)

        var result = Result()
        var ours: Set<String> = []

        for post in posts {
            guard let file = file(in: directory, slug: post.slug) else { continue }
            ours.insert(file.lastPathComponent)

            let document = document(for: post)
            switch classify(file) {
            case .missing:
                try Data(document.utf8).write(to: file, options: .atomic)
                result.written += 1
            case .untouchedCopy:
                // Rewritten unconditionally rather than compared first: the record may
                // have changed on another device, and a copy nobody touched has nothing
                // worth keeping.
                try Data(document.utf8).write(to: file, options: .atomic)
                result.written += 1
            case .edited(let edit):
                // The writer's work. Left alone, and reported so the app can offer to
                // publish it — overwriting here is the one thing that would lose
                // writing, and it is what a plain mirror would do.
                result.edited.append(edit)
            case .notOurs:
                result.left += 1
            }
        }

        let existing =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in existing where file.pathExtension == "md" {
            if ours.contains(file.lastPathComponent) { continue }
            switch classify(file) {
            case .untouchedCopy:
                // A copy of a post that is no longer published. This is the deletion
                // reaching the folder.
                try? FileManager.default.removeItem(at: file)
                result.removed += 1
            case .edited(let edit):
                // Edited, and its post is gone — deleted on another device while this
                // one had unpublished changes. Kept, and offered as writing to publish
                // again rather than silently discarded.
                result.edited.append(edit)
            case .notOurs, .missing:
                result.left += 1
            }
        }
        return result
    }

    /// What a file in the mirror directory is.
    enum Classification {
        case missing
        /// Written by the mirror and unchanged since.
        case untouchedCopy
        /// Written by the mirror and changed by the writer.
        case edited(Edit)
        /// Not written by the mirror. Somebody else's file, or the writer's own.
        case notOurs
    }

    /// A change the writer made in the folder, as the app needs it to offer publishing.
    struct Edit: Equatable {
        /// The slug recorded in the file, which is the post it is a copy of — read from
        /// the front matter rather than the file name, so renaming the file does not
        /// turn an edit into a different post.
        var slug: String
        var title: String
        var summary: String
        var markdown: String
        /// Where the change is, for a message that can name the file.
        var file: URL
    }

    /// Decides whether a file is an untouched copy, an edit, or none of the mirror's
    /// business.
    ///
    /// The test is the fingerprint: recompute it over the file's current title,
    /// summary, and body, and compare with the one recorded in the file. Self-contained
    /// on purpose — no index to fall out of date, and it gives the right answer for a
    /// file copied to another machine, restored from a backup, or renamed.
    static func classify(_ file: URL) -> Classification {
        guard let data = try? Data(contentsOf: file),
            let text = String(data: data, encoding: .utf8)
        else {
            // Unreadable rather than absent — a partial sync, or not text at all.
            // Treated as not ours, because the one thing not to do with a file that
            // cannot be read is delete it.
            return FileManager.default.fileExists(atPath: file.path) ? .notOurs : .missing
        }
        guard let parsed = parse(text), let recorded = parsed.fingerprint else {
            return .notOurs
        }
        let edit = Edit(
            slug: parsed.slug, title: parsed.title, summary: parsed.summary,
            markdown: parsed.body, file: file)
        return recorded == fingerprint(title: parsed.title, summary: parsed.summary, body: parsed.body)
            ? .untouchedCopy : .edited(edit)
    }

    /// The file's contents: front matter, then the Markdown as written.
    ///
    /// Front matter rather than a separate index, because the file has to be
    /// self-describing — somebody finding it in a backup years later should be able to
    /// tell what it is without Nook. The body is byte-for-byte what was published, so
    /// the file is a faithful copy and not a rendering.
    static func document(for post: Post) -> String {
        var lines = ["---"]
        lines.append("title: " + quoted(post.title))
        lines.append("slug: " + quoted(post.slug))
        if !post.summary.isEmpty {
            lines.append("summary: " + quoted(post.summary))
        }
        if let publishedAt = post.publishedAt, !publishedAt.isEmpty {
            lines.append("published: " + publishedAt)
        }
        if let url = post.url, !url.isEmpty {
            lines.append("url: " + url)
        }
        // What makes an edit detectable without any stored state, and therefore what
        // makes it safe to delete a file at all. Last of the values, so a writer
        // skimming the front matter reads the useful ones first.
        lines.append(
            fingerprintField + ": "
                + fingerprint(title: post.title, summary: post.summary, body: post.markdown))
        // Said in the file, because the file is where somebody will be when they
        // wonder. A mirror that looked editable and silently was not would be worse
        // than one that says so.
        lines.append("# This file is a copy of a post published from Nook.")
        lines.append("# Edit it and Nook will notice, and offer to publish the change.")
        lines.append("# Until you say so, the published post is unchanged.")
        lines.append("---")
        lines.append("")
        lines.append(post.markdown)
        return lines.joined(separator: "\n")
    }

    /// The front-matter key holding the fingerprint.
    static let fingerprintField = "nook-fingerprint"

    /// A fingerprint of the parts of a post a writer can change in the folder.
    ///
    /// Over title, summary, and body — the three values an edit can reach — with
    /// lengths included so no rearrangement of the same characters across fields
    /// produces the same digest. Not a security boundary: this detects an edit, and a
    /// writer who forges it only misleads themselves.
    static func fingerprint(title: String, summary: String, body: String) -> String {
        let canonical = "\(title.utf8.count):\(title)\n\(summary.utf8.count):\(summary)\n\(body.utf8.count):\(body)"
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// A mirrored file read back: its front-matter values and its body.
    struct Parsed {
        var title = ""
        var slug = ""
        var summary = ""
        var fingerprint: String?
        var body = ""
    }

    /// Reads a mirrored file, or nil when it is not one.
    ///
    /// Deliberately narrow: it understands the format this type writes and nothing
    /// else. A Markdown file the writer put in the folder themselves has no front
    /// matter, parses as nil, and is therefore never classified as the mirror's to
    /// delete — which is the behaviour that matters.
    static func parse(_ text: String) -> Parsed? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---" else { return nil }
        guard let closing = lines.dropFirst().firstIndex(of: "---") else { return nil }

        var parsed = Parsed()
        for line in lines[1..<closing] {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<separator])
            let value = unquoted(
                String(line[line.index(after: separator)...])
                    .trimmingCharacters(in: .whitespaces))
            switch key {
            case "title": parsed.title = value
            case "slug": parsed.slug = value
            case "summary": parsed.summary = value
            case fingerprintField: parsed.fingerprint = value
            default: break
            }
        }

        // The blank line after the front matter is part of the separator, not of the
        // body — ``document(for:)`` writes it — so a body that legitimately starts with
        // a blank line survives a round trip.
        var start = closing + 1
        if start < lines.count, lines[start].isEmpty { start += 1 }
        parsed.body = lines[start...].joined(separator: "\n")
        return parsed
    }

    /// Quotes a front-matter value, escaping what would otherwise break the line.
    ///
    /// Titles contain colons and quotation marks routinely, and an unquoted value
    /// carrying either makes a file that no parser — including a future version of
    /// this one — reads back correctly.
    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    /// The inverse of ``quoted(_:)``, and a no-op on a value that was never quoted.
    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else {
            return value
        }
        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

}

// MARK: - Showing the folder

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

extension PlusPostMirror {
    /// Opens the mirror directory in the system's file browser.
    ///
    /// Two platforms, two different things. On the Mac, Finder can be pointed straight
    /// at a directory. On iOS there is no equivalent, so the folder is handed to the
    /// Files app through `shareddocuments:`, which only reaches folders the app has
    /// made visible — which the sync folder is, since it is the one the reader chose.
    @MainActor
    static func reveal(_ directory: URL) {
        #if canImport(AppKit)
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        #elseif canImport(UIKit)
            // Rebuilt with the scheme swapped rather than by string surgery on the
            // path, so a folder name with a space or a non-Latin script survives.
            guard var parts = URLComponents(url: directory, resolvingAgainstBaseURL: false)
            else { return }
            parts.scheme = "shareddocuments"
            guard let target = parts.url else { return }
            UIApplication.shared.open(target)
        #endif
    }
}
