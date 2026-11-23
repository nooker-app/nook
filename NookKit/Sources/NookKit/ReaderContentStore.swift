import Foundation

/// The reader's in-memory snapshot. Coordinated iCloud I/O lives on a separate
/// actor: a provider taking minutes to supply a shard must never hold up a cache
/// hit (or a miss that can immediately use the local original-page cache).
///
/// Reloads merge registers, never replace this snapshot wholesale. Unpublished
/// local extractions take precedence until the writer has witnessed the remote
/// clocks and stamped them. None of this publishes into a displayed reader body.
public actor ReaderContentStore {
    private let persistence: any ReaderContentPersistence
    private var merged: [Article.ID: LWWRegister<ReaderContentValue>] = [:]
    private struct Pending {
        var sequence: UInt64
        var value: ReaderContentValue
    }
    private var pending: [Article.ID: Pending] = [:]
    private var sequence: UInt64 = 0
    private var reloadTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var stopped = false

    public init(storage: ReaderStorage, deviceID: String) {
        persistence = ReaderContentFiles(storage: storage, deviceID: deviceID)
    }

    init(persistence: any ReaderContentPersistence) {
        self.persistence = persistence
    }

    /// Coalesce observer/foreground refreshes while one coordinated read is in
    /// flight. Awaiting it suspends this actor, leaving lookups and records free.
    public func reload() async {
        guard !stopped else { return }
        if let reloadTask {
            await reloadTask.value
            return
        }
        let task = Task {
            if let registers = try? await persistence.reload(), !stopped {
                merge(registers)
            }
            reloadTask = nil
            scheduleWrites()
        }
        reloadTask = task
        await task.value
    }

    /// A value copy, not a subscription: a late sync can benefit subsequent
    /// reads without replacing text/scroll/translation in the current reader.
    public func value(for articleID: Article.ID) -> ReaderContentValue? {
        pending[articleID]?.value ?? merged[articleID]?.value
    }

    func recommendationHTML(for articles: [Article]) -> [Article.ID: String] {
        var result: [Article.ID: String] = [:]
        for article in articles {
            guard let value = value(for: article.id), value.status == .success,
                  let html = value.html,
                  NookPostOrigin.cachedBodyIsCurrent(value.sourceFingerprint, for: article) else { continue }
            result[article.id] = html
        }
        return result
    }

    /// Publish immediately, then serialize/coalesce writes independently of the
    /// reading path. Even anchor repair must not await an iCloud write to display.
    public func record(_ value: ReaderContentValue, for articleID: Article.ID) {
        guard !stopped, !Task.isCancelled else { return }
        if value.status == .failed, let existing = self.value(for: articleID),
           existing.status == .success, existing.html?.isEmpty == false { return }
        sequence &+= 1
        pending[articleID] = Pending(sequence: sequence, value: value)
        scheduleWrites()
    }

    private func merge(_ registers: [Article.ID: LWWRegister<ReaderContentValue>]) {
        for (id, register) in registers {
            merged[id] = merged[id]?.merged(with: register) ?? register
        }
    }

    private func scheduleWrites() {
        guard !stopped, writeTask == nil, !pending.isEmpty else { return }
        writeTask = Task {
            // A single drain prevents an older parser result finishing its disk
            // write after the newer result. Edits arriving during I/O remain in
            // pending and are only cleared by their own successful write.
            while !stopped, let (id, update) = pending.min(by: { $0.value.sequence < $1.value.sequence }) {
                do {
                    let register = try await persistence.record(update.value, for: id)
                    merge([id: register])
                    if pending[id]?.sequence == update.sequence { pending[id] = nil }
                } catch {
                    // Keep the local value usable. A later record/reload retries;
                    // a provider error must neither blank the reader nor spin.
                    break
                }
            }
            writeTask = nil
        }
    }

    /// Quiesce before a local reset releases the vault's security scope. Already
    /// coordinated I/O must finish before the directory can safely be removed.
    public func stop() async {
        stopped = true
        await reloadTask?.value
        await writeTask?.value
        pending.removeAll()
    }

    /// Used by storage tests; foreground readers deliberately never wait for it.
    func finishPendingWrites() async {
        await writeTask?.value
    }
}

protocol ReaderContentPersistence: Sendable {
    func reload() async throws -> [Article.ID: LWWRegister<ReaderContentValue>]
    func record(_ value: ReaderContentValue, for id: Article.ID) async throws -> LWWRegister<ReaderContentValue>
}

/// Only this actor can wait on NSFileCoordinator. It owns the on-disk shard and
/// its HLC, so local extractions made while a reload is pending are stamped
/// *after* the clocks it discovers, including peers with a clock ahead of ours.
actor ReaderContentFiles: ReaderContentPersistence {
    private static let maxOwnEntries = 500
    private let storage: ReaderStorage
    private let deviceID: String
    private var own: ReaderContentShardDocument
    private var merged: [Article.ID: LWWRegister<ReaderContentValue>] = [:]
    private var loaded = false

    init(storage: ReaderStorage, deviceID: String) {
        self.storage = storage
        self.deviceID = deviceID
        own = ReaderContentShardDocument(deviceID: deviceID)
    }

    func reload() throws -> [Article.ID: LWWRegister<ReaderContentValue>] {
        // A failed own-shard read must not be mistaken for an empty shard and
        // overwritten by the first extraction after launch.
        if let disk = try storage.readOwnReaderShard(deviceID: deviceID) {
            own.clock = own.clock.witnessed(disk.clock)
            for (id, register) in disk.entries {
                own.entries[id] = own.entries[id]?.merged(with: register) ?? register
            }
        }
        merge(own)
        for peer in storage.loadReaderShards(excluding: deviceID) {
            own.clock = own.clock.witnessed(peer.clock)
            merge(peer)
        }
        loaded = true
        return merged
    }

    func record(_ value: ReaderContentValue, for id: Article.ID) throws -> LWWRegister<ReaderContentValue> {
        if !loaded { _ = try reload() }
        // A successful body may have arrived while the local parser failed.
        // Preserve it just as the foreground path does for an already-known hit.
        if value.status == .failed, let existing = merged[id],
           existing.value.status == .success, existing.value.html?.isEmpty == false {
            return existing
        }
        var value = value
        if value.status == .failed, let previous = merged[id]?.value, previous.status == .failed {
            value.failedEngines = previous.failedVersions.merging(value.failedVersions, uniquingKeysWith: max)
        }
        own.clock = HLC.next(after: own.clock, node: deviceID)
        let register = LWWRegister(value: value, hlc: own.clock)
        own.entries[id] = register
        merged[id] = register
        if own.entries.count > Self.maxOwnEntries {
            let oldest = own.entries.sorted { $0.value.hlc < $1.value.hlc }
                .prefix(own.entries.count - Self.maxOwnEntries)
            for (id, _) in oldest { own.entries[id] = nil }
        }
        try storage.saveReaderShard(own)
        return register
    }

    private func merge(_ shard: ReaderContentShardDocument) {
        for (id, register) in shard.entries {
            own.clock = own.clock.witnessed(register.hlc)
            merged[id] = merged[id]?.merged(with: register) ?? register
        }
    }
}
