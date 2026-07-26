import Foundation
import Testing
@testable import NookKit

@Suite("Local app reset")
struct LocalAppResetServiceTests {
    @Test("Clears preferences while preserving the sync-safe device identity")
    func resetsDefaultsAndPreservesDeviceIdentity() throws {
        let suiteName = "LocalAppResetServiceTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("bookmark", forKey: ReaderStorage.bookmarkDefaultsKey)
        defaults.set(42, forKey: "readerFontSize")

        LocalAppResetService.resetDefaults(
            defaults,
            domainName: suiteName,
            preservingDeviceID: "device-A",
            preservingGeminiState: false
        )

        #expect(defaults.string(forKey: DeviceIdentity.defaultsKey) == "device-A")
        #expect(defaults.object(forKey: ReaderStorage.bookmarkDefaultsKey) == nil)
        #expect(defaults.object(forKey: "readerFontSize") == nil)
        #expect(defaults.object(forKey: TranslationSettings.geminiKeyConfiguredKey) == nil)
    }

    @Test("Restores the Gemini availability mirror only when requested")
    func optionallyPreservesGeminiMirror() throws {
        let suiteName = "LocalAppResetServiceTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        LocalAppResetService.resetDefaults(
            defaults,
            domainName: suiteName,
            preservingDeviceID: "device-A",
            preservingGeminiState: true
        )

        #expect(defaults.bool(forKey: TranslationSettings.geminiKeyConfiguredKey))
    }

    @Test("Deletes app-local support and cache contents")
    func deletesOnlyLocalFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "nook-reset-\(UUID())", directoryHint: .isDirectory)
        let applicationSupport = root.appending(path: "Application Support/Nook", directoryHint: .isDirectory)
        let caches = root.appending(path: "Caches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try Data("offline".utf8).write(to: applicationSupport.appending(path: "Offline.html"))
        try Data("cache".utf8).write(to: caches.appending(path: "response.cache"))
        defer { try? FileManager.default.removeItem(at: root) }

        try LocalAppResetService.clearLocalFiles(
            at: LocalAppResetPaths(
                applicationSupportDirectory: applicationSupport,
                cachesDirectory: caches
            ),
            fileManager: .default
        )

        #expect(!FileManager.default.fileExists(atPath: applicationSupport.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: caches.path).isEmpty)
    }

    @Test("Never touches a sync folder outside the local reset paths")
    func preservesSyncFolderExactly() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "nook-reset-\(UUID())", directoryHint: .isDirectory)
        let applicationSupport = root.appending(path: "Application Support/Nook", directoryHint: .isDirectory)
        let caches = root.appending(path: "Caches", directoryHint: .isDirectory)
        let sync = root.appending(path: "Sync", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sync.appending(path: ".nook/state"), withIntermediateDirectories: true)
        let library = sync.appending(path: "NookLibrary.json")
        let shard = sync.appending(path: ".nook/state/device.json")
        try Data("library".utf8).write(to: library)
        try Data("state".utf8).write(to: shard)
        let before = try [library, shard].map { try Data(contentsOf: $0) }
        defer { try? FileManager.default.removeItem(at: root) }

        try LocalAppResetService.clearLocalFiles(
            at: LocalAppResetPaths(
                applicationSupportDirectory: applicationSupport,
                cachesDirectory: caches
            ),
            fileManager: .default
        )

        let after = try [library, shard].map { try Data(contentsOf: $0) }
        #expect(after == before)
    }

    @Test("Deletes the app-owned local library when it is explicitly included")
    func deletesLocalLibrary() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "nook-reset-\(UUID())", directoryHint: .isDirectory)
        let applicationSupport = root.appending(path: "Application Support/Nook", directoryHint: .isDirectory)
        let caches = root.appending(path: "Caches", directoryHint: .isDirectory)
        let localLibrary = root.appending(path: "Documents/Nook", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localLibrary, withIntermediateDirectories: true)
        try Data("local".utf8).write(to: localLibrary.appending(path: "NookLibrary.json"))
        defer { try? FileManager.default.removeItem(at: root) }

        try LocalAppResetService.clearLocalFiles(
            at: LocalAppResetPaths(
                applicationSupportDirectory: applicationSupport,
                cachesDirectory: caches,
                localLibraryDirectory: localLibrary
            ),
            fileManager: .default
        )

        #expect(!FileManager.default.fileExists(atPath: localLibrary.path))
    }
}
