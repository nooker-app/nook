import Foundation

/// A post that is not published.
///
/// Drafts are the client's, not the service's. The PDS holds public articles only —
/// a record existing there *is* the post being public — so there is nowhere on the
/// service to keep something unfinished, and nothing about a draft should leave the
/// device. That is a deliberate boundary, not a gap: an unpublished thought is not
/// content the service has any business storing.
///
/// The consequence is that this file is the only copy. It is written atomically and
/// read defensively for that reason.
public struct PlusDraft: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    /// The web address the writer chose, kept so republishing lands on the same URL
    /// and existing links to it still work.
    public var slug: String
    public var summary: String
    public var markdown: String
    /// When it was last written. Drafts are listed newest first.
    public var updatedAt: Date

    /// Set when this draft came from a post that had been published, so the UI can
    /// say so rather than presenting it as something never seen.
    ///
    /// Deliberately not a record key to reuse: the PDS assigns one on create, so
    /// publishing this again makes a new record with a new key. The slug carries the
    /// address across; the record-key alias does not survive, and pretending
    /// otherwise would promise a permalink that breaks.
    public var wasPublished: Bool

    public init(
        id: UUID = UUID(),
        title: String = "",
        slug: String = "",
        summary: String = "",
        markdown: String = "",
        updatedAt: Date = Date(),
        wasPublished: Bool = false
    ) {
        self.id = id
        self.title = title
        self.slug = slug
        self.summary = summary
        self.markdown = markdown
        self.updatedAt = updatedAt
        self.wasPublished = wasPublished
    }

    /// What to call it in a list. A draft usually has no title yet, and "Untitled"
    /// for every one of them is a list that cannot be read.
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let firstLine =
            markdown
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""
        // Markdown markers in a list row read as noise, so the leading ones go.
        let stripped = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "#>-*` \t"))
        if stripped.isEmpty { return "" }
        return String(stripped.prefix(60))
    }

    /// Whether there is anything worth keeping. An empty draft is not saved: a list
    /// filling up with blank rows because a screen was opened and closed is worse
    /// than losing nothing.
    public var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Drafts on this device.
///
/// One file per draft rather than one file holding all of them, so a write cannot
/// take the others down with it and a single unreadable file costs exactly one draft.
/// Reads skip what they cannot decode instead of failing: a corrupt file must not
/// make the rest of someone's writing unreachable.
public struct PlusDraftStore: Sendable {
    private let directory: URL

    /// Timestamps carry fractional seconds.
    ///
    /// `JSONEncoder.DateEncodingStrategy.iso8601` writes whole seconds only, which
    /// made every draft saved within the same second sort arbitrarily — the list
    /// order would have looked random to anyone saving two things in quick
    /// succession. Decoding accepts both forms, because this file is the only copy
    /// and refusing to read one written by an older build would lose it.
    /// Built per call rather than shared: `ISO8601DateFormatter` is not `Sendable`, and
    /// a formatter is cheap next to the file write it accompanies.
    private static func fractional() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractional().string(from: date))
        }
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = fractional().date(from: text) { return date }
            // Whole seconds too: a file written by an earlier build is still the only
            // copy of that draft, and refusing to read it would lose it.
            if let date = ISO8601DateFormatter().date(from: text) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "not an ISO 8601 timestamp: \(text)")
        }
        return decoder
    }

    /// The default location: this device's Application Support, not the reader's sync
    /// folder. A draft is private and unfinished; putting it somewhere that syncs
    /// would publish it to every device the folder reaches, which is a decision only
    /// the writer gets to make.
    public static func `default`() throws -> PlusDraftStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return try PlusDraftStore(directory: base.appending(path: "NookPlusDrafts"))
    }

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Every draft, newest first.
    public func all() -> [PlusDraft] {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = Self.decoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                // Skipped rather than thrown: one unreadable file must not hide the
                // rest of someone's drafts.
                return try? decoder.decode(PlusDraft.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Writes a draft, replacing any earlier version of it.
    ///
    /// Atomic, because this file is the only copy: a partial write on a low battery
    /// or a crash mid-save would leave the writer with neither the old text nor the
    /// new. `.atomic` writes to a temporary file and renames.
    public func save(_ draft: PlusDraft) throws {
        var stamped = draft
        stamped.updatedAt = Date()
        try Self.encoder().encode(stamped).write(to: url(for: draft.id), options: .atomic)
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    private func url(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }
}
