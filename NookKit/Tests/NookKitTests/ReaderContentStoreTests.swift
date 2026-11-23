import Foundation
import Testing
@testable import NookKit

@Suite("Reader cache stays available during sync")
struct ReaderContentStoreTests {
    actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var calls = 0
        func wait() async {
            calls += 1
            if !open { await withCheckedContinuation { waiters.append($0) } }
        }
        func release() {
            open = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
        func entered() async {
            for _ in 0..<500 where calls == 0 { try? await Task.sleep(for: .milliseconds(2)) }
            #expect(calls > 0)
        }
    }

    actor Files: ReaderContentPersistence {
        var registers: [String: LWWRegister<ReaderContentValue>] = [:]
        var clock = HLC.zero
        var readGate: Gate?
        var writeGate: Gate?
        var failWrite = false
        private(set) var reads = 0
        private(set) var writes = 0
        func configure(read: Gate? = nil, write: Gate? = nil, fail: Bool = false) {
            readGate = read
            writeGate = write
            failWrite = fail
        }
        func seed(_ value: ReaderContentValue, id: String = "story", clock: HLC) {
            registers[id] = LWWRegister(value: value, hlc: clock)
            self.clock = self.clock.witnessed(clock)
        }
        func reload() async -> [String: LWWRegister<ReaderContentValue>] {
            reads += 1
            let snapshot = registers
            await readGate?.wait()
            return snapshot
        }
        func record(_ value: ReaderContentValue, for id: String) async throws -> LWWRegister<ReaderContentValue> {
            writes += 1
            await writeGate?.wait()
            if failWrite { throw CocoaError(.fileWriteUnknown) }
            clock = HLC.next(after: clock, node: "local")
            let register = LWWRegister(value: value, hlc: clock)
            registers[id] = register
            return register
        }
    }

    static func body(_ text: String, engine: ReaderParserEngine = .legibility) -> ReaderContentValue {
        ReaderContentValue(status: .success, html: "<p>\(text)</p>", engine: engine)
    }

    func tempStorage() throws -> ReaderStorage {
        let url = FileManager.default.temporaryDirectory.appending(path: "nook-reader-sync-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return ReaderStorage(directoryURL: url)
    }

    @Test("A real coordinated file wait cannot block cache hits, misses, or new extractions")
    func coordinatedReadDoesNotBlockReader() async throws {
        let storage = try tempStorage()
        defer { try? FileManager.default.removeItem(at: storage.directoryURL) }
        let store = ReaderContentStore(storage: storage, deviceID: "local")
        await store.record(Self.body("already read"), for: "story")
        await store.finishPendingWrites()
        let held = Gate()
        let file = storage.readerDirectoryURL.appending(path: "local.json")
        let blocker = Task.detached {
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: file, options: [], error: &error) { _ in
                Task { await held.release() }
                Thread.sleep(forTimeInterval: 1.5)
            }
            return error == nil
        }
        await held.wait()
        let start = ContinuousClock.now
        let reload = Task { await store.reload() }
        try await Task.sleep(for: .milliseconds(100))
        let lookupStart = ContinuousClock.now
        #expect(await store.value(for: "story") == Self.body("already read"))
        #expect(await store.value(for: "uncached") == nil)
        await store.record(Self.body("new extraction"), for: "new")
        #expect(await store.value(for: "new") == Self.body("new extraction"))
        let foreground = lookupStart.duration(to: .now)
        #expect(foreground < .milliseconds(250), "reader operations took \(foreground)")
        #expect(await blocker.value)
        await reload.value
        let background = start.duration(to: .now)
        #expect(background >= .seconds(1), "the test must actually hold coordinated I/O")
        await store.finishPendingWrites()
        print("Reader cache: coordinated wait \(background), foreground hit/miss/record \(foreground)")
        #expect(storage.loadOwnReaderShard(deviceID: "local")?.entries["new"]?.value == Self.body("new extraction"))
    }

    @Test("Cold-cache lookups miss immediately while the initial sync is pending")
    func coldCacheDoesNotWait() async {
        let files = Files()
        let gate = Gate()
        await files.configure(read: gate)
        let store = ReaderContentStore(persistence: files)
        let reload = Task { await store.reload() }
        await gate.entered()
        #expect(await store.value(for: "story") == nil)
        await store.record(Self.body("local"), for: "story")
        #expect(await store.value(for: "story") == Self.body("local"))
        await gate.release()
        await reload.value
        await store.finishPendingWrites()
    }

    @Test("Late sync cannot replace an extraction awaiting publication; refresh requests coalesce")
    func localWinsWhileSyncPending() async {
        let files = Files()
        let read = Gate(), write = Gate()
        let future = HLC(physicalMillis: 9_000_000_000_000, counter: 0, node: "peer")
        await files.seed(Self.body("peer"), clock: future)
        await files.configure(read: read, write: write)
        let store = ReaderContentStore(persistence: files)
        let first = Task { await store.reload() }
        await read.entered()
        let second = Task { await store.reload() }
        await store.record(Self.body("local"), for: "story")
        await write.entered()
        await read.release()
        await first.value
        await second.value
        #expect(await files.reads == 1)
        #expect(await store.value(for: "story") == Self.body("local"))
        await write.release()
        await store.finishPendingWrites()
        #expect(await store.value(for: "story") == Self.body("local"))
        #expect(await files.registers["story"]!.hlc > future)
    }

    @Test("A stale reload finishing after a committed extraction is merged, not installed wholesale")
    func staleReloadAfterWrite() async {
        let files = Files()
        let gate = Gate()
        await files.seed(Self.body("old"), clock: HLC.next(after: .zero, node: "peer"))
        await files.configure(read: gate)
        let store = ReaderContentStore(persistence: files)
        let reload = Task { await store.reload() }
        await gate.entered()
        await store.record(Self.body("new"), for: "story")
        await store.finishPendingWrites()
        await gate.release()
        await reload.value
        #expect(await store.value(for: "story") == Self.body("new"))
    }

    @Test("A slow earlier parser write never clears or overwrites a newer parser choice")
    func latestParserSurvivesSlowWrite() async {
        let files = Files(), gate = Gate()
        await files.configure(write: gate)
        let store = ReaderContentStore(persistence: files)
        await store.record(Self.body("first"), for: "story")
        await gate.entered()
        await store.record(Self.body("intermediate"), for: "story")
        let last = Self.body("last", engine: .readability)
        await store.record(last, for: "story")
        #expect(await store.value(for: "story") == last)
        await gate.release()
        await store.finishPendingWrites()
        #expect(await files.writes == 2)
        #expect(await files.registers["story"]?.value == last)
        #expect(await store.value(for: "story") == last)
    }

    @Test("A failed write retains the local body and retries on the next sync")
    func retryFailedWrite() async {
        let files = Files()
        await files.configure(fail: true)
        let store = ReaderContentStore(persistence: files)
        await store.record(Self.body("retained"), for: "story")
        await store.finishPendingWrites()
        #expect(await store.value(for: "story") == Self.body("retained"))
        await files.configure()
        await store.reload()
        await store.finishPendingWrites()
        #expect(await files.registers["story"]?.value == Self.body("retained"))
    }

    @Test("First write preserves existing own entries and outranks a skewed peer clock")
    func firstWriteMergesDiskBeforeStamping() async throws {
        let storage = try tempStorage()
        defer { try? FileManager.default.removeItem(at: storage.directoryURL) }
        let old = HLC(physicalMillis: 100, counter: 0, node: "local")
        let future = HLC(physicalMillis: 9_000_000_000_000, counter: 0, node: "peer")
        try storage.saveReaderShard(ReaderContentShardDocument(deviceID: "local", clock: old,
            entries: ["existing": LWWRegister(value: Self.body("keep"), hlc: old)]))
        let peer = ReaderContentShardDocument(deviceID: "peer", clock: future,
            entries: ["story": LWWRegister(value: Self.body("peer old"), hlc: future)])
        try storage.saveReaderShard(peer)
        let store = ReaderContentStore(storage: storage, deviceID: "local")
        await store.record(Self.body("fresh local"), for: "story")
        await store.finishPendingWrites()
        let disk = try #require(storage.loadOwnReaderShard(deviceID: "local"))
        #expect(disk.entries["existing"]?.value == Self.body("keep"))
        #expect(disk.entries["story"]?.value == Self.body("fresh local"))
        #expect(try #require(disk.entries["story"]).hlc > future)
        #expect(storage.loadOwnReaderShard(deviceID: "peer") == peer)
        let reopened = ReaderContentStore(storage: storage, deviceID: "local")
        await reopened.reload()
        #expect(await reopened.value(for: "story") == Self.body("fresh local"))
    }

    @Test("Unreadable own data is never replaced with an empty shard; recovery retries safely")
    func corruptOwnShardIsPreserved() async throws {
        let storage = try tempStorage()
        defer { try? FileManager.default.removeItem(at: storage.directoryURL) }
        try FileManager.default.createDirectory(at: storage.readerDirectoryURL, withIntermediateDirectories: true)
        let file = storage.readerDirectoryURL.appending(path: "local.json")
        let damaged = Data("{unfinished".utf8)
        try damaged.write(to: file)
        let store = ReaderContentStore(storage: storage, deviceID: "local")
        await store.record(Self.body("local"), for: "story")
        await store.finishPendingWrites()
        #expect(try Data(contentsOf: file) == damaged)
        #expect(await store.value(for: "story") == Self.body("local"))
        try storage.saveReaderShard(ReaderContentShardDocument(deviceID: "local"))
        await store.reload()
        await store.finishPendingWrites()
        #expect(storage.loadOwnReaderShard(deviceID: "local")?.entries["story"]?.value == Self.body("local"))
    }

    @Test("A success discovered during sync survives a concurrent parser failure")
    func lateSuccessSurvivesFailure() async throws {
        let storage = try tempStorage()
        defer { try? FileManager.default.removeItem(at: storage.directoryURL) }
        let clock = HLC.next(after: .zero, node: "peer")
        try storage.saveReaderShard(ReaderContentShardDocument(deviceID: "peer", clock: clock,
            entries: ["story": LWWRegister(value: Self.body("good"), hlc: clock)]))
        let store = ReaderContentStore(storage: storage, deviceID: "local")
        await store.record(.failure(engine: .readability, previous: nil, sourceFingerprint: nil), for: "story")
        await store.finishPendingWrites()
        #expect(await store.value(for: "story") == Self.body("good"))
        await store.record(.failure(engine: .legibility, previous: nil, sourceFingerprint: nil), for: "story")
        #expect(await store.value(for: "story") == Self.body("good"))
    }

    @Test("Late results from another library cannot leak into this library's cache")
    func libraryIsolation() async {
        let oldFiles = Files(), gate = Gate()
        await oldFiles.configure(read: gate)
        await oldFiles.seed(Self.body("old library"), clock: HLC.next(after: .zero, node: "old"))
        let oldStore = ReaderContentStore(persistence: oldFiles)
        let reload = Task { await oldStore.reload() }
        await gate.entered()
        let newStore = ReaderContentStore(persistence: Files())
        await newStore.record(Self.body("new library"), for: "story")
        await newStore.finishPendingWrites()
        await gate.release()
        await reload.value
        #expect(await newStore.value(for: "story") == Self.body("new library"))
    }
}

extension ReaderContentStoreTests {
    @Test("Sync changes the cache without replacing the displayed reader body or its parser")
    @MainActor
    func visibleReaderIsPinned() async throws {
        let files = Files()
        let original = Self.body("On screen", engine: .readability)
        await files.seed(original, clock: Fixture.hlc(100))
        let cache = ReaderContentStore(persistence: files)
        await cache.reload()
        let reader = ReaderStore._makeForTesting(readerContentStore: cache)
        var article = Fixture.article("story", feedID: "test")
        // An inert URL: the reader's background origin check must not use a site.
        article.url = FileManager.default.temporaryDirectory.appending(path: "nook-sync-test-\(UUID()).html")
        #expect(reader.usesReaderContentByDefault)
        reader.ensureReaderContent(for: article)
        for _ in 0..<400 {
            if case .ready = reader.readerContentState(for: article) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(reader.readerContentState(for: article) == .ready(original.html!))
        let newer = Self.body("Late peer text", engine: .legibility)
        await files.seed(newer, clock: Fixture.hlc(200))
        await cache.reload()
        #expect(await cache.value(for: article.id) == newer)
        reader.ensureReaderContent(for: article)
        #expect(reader.readerContentState(for: article) == .ready(original.html!))
        #expect(reader.readerContentEngine(for: article) == .readability)
        await reader.prepareForLocalReset()
    }
}

extension ReaderContentStoreTests {
    @Test("Reset drains in-flight I/O and prevents pending or later writes from reviving the cache")
    func stopDrainsWriter() async {
        let files = Files(), gate = Gate()
        await files.configure(write: gate)
        let store = ReaderContentStore(persistence: files)
        await store.record(Self.body("writing"), for: "first")
        await gate.entered()
        await store.record(Self.body("queued"), for: "second")
        let stop = Task { await store.stop() }
        // Keep I/O held while the actor processes stop.
        try? await Task.sleep(for: .milliseconds(20))
        await gate.release()
        await stop.value
        await store.record(Self.body("too late"), for: "third")
        await store.reload()
        await store.finishPendingWrites()
        #expect(await files.writes == 1)
        #expect(await files.reads == 0)
        #expect(await store.value(for: "second") == nil)
        #expect(await store.value(for: "third") == nil)
    }

    @Test("Peer failure history survives a locally queued failure")
    func lateFailureHistoryMerges() async throws {
        let storage = try tempStorage()
        defer { try? FileManager.default.removeItem(at: storage.directoryURL) }
        let clock = HLC.next(after: .zero, node: "peer")
        let previous = ReaderContentValue.failure(engine: .legibility, previous: nil, sourceFingerprint: "same")
        try storage.saveReaderShard(ReaderContentShardDocument(deviceID: "peer", clock: clock,
            entries: ["story": LWWRegister(value: previous, hlc: clock)]))
        let store = ReaderContentStore(storage: storage, deviceID: "local")
        await store.record(.failure(engine: .readability, previous: nil, sourceFingerprint: "same"), for: "story")
        await store.finishPendingWrites()
        let result = try #require(await store.value(for: "story"))
        #expect(Set(result.recordedFailures) == [.legibility, .readability])
        #expect(storage.loadOwnReaderShard(deviceID: "local")?.entries["story"]?.value == result)
    }
}

extension ReaderContentStoreTests {
    @Test("Cached comments remain readable while real reconciliation waits on a coordinated shard")
    func commentsDoNotWaitForReconcile() async throws {
        let storage = try tempStorage()
        defer { try? FileManager.default.removeItem(at: storage.directoryURL) }
        let replica = try ReplicaStore(syncDirectory: storage.directoryURL, deviceID: "local",
            databaseDirectory: storage.directoryURL.appending(path: "database"))
        let payload = Data("committed comments".utf8)
        try replica.saveComments(payload, for: "story")
        try storage.saveContentShard(ContentShardDocument(deviceID: "peer"))
        _ = try replica.reconcile(storage: storage)
        let held = Gate()
        let file = storage.contentDirectoryURL.appending(path: "peer.json")
        let blocker = Task.detached {
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: file, options: [], error: &error) { _ in
                Task { await held.release() }
                Thread.sleep(forTimeInterval: 1.5)
            }
            return error == nil
        }
        await held.wait()
        let start = ContinuousClock.now
        let reconcile = Task.detached { try replica.reconcile(storage: storage) }
        try await Task.sleep(for: .milliseconds(100))
        let readStart = ContinuousClock.now
        #expect(try replica.comments(for: "story") == payload)
        #expect(try replica.comments(for: "missing") == nil)
        let foreground = readStart.duration(to: .now)
        #expect(foreground < .milliseconds(250), "comment reads took \(foreground)")
        #expect(await blocker.value)
        _ = try await reconcile.value
        let background = start.duration(to: .now)
        #expect(background >= .seconds(1))
        print("Reader comments: coordinated sync \(background), snapshot reads \(foreground)")
    }
}
