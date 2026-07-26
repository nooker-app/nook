import Foundation
import WebKit

public struct LocalAppResetOptions: Sendable, Equatable {
    public var preservesGeminiCredential: Bool
    public var preservesWebSessions: Bool

    public init(
        preservesGeminiCredential: Bool = false,
        preservesWebSessions: Bool = false
    ) {
        self.preservesGeminiCredential = preservesGeminiCredential
        self.preservesWebSessions = preservesWebSessions
    }
}

struct LocalAppResetPaths: Sendable {
    var applicationSupportDirectory: URL
    var cachesDirectory: URL
    var localLibraryDirectory: URL? = nil

    static func current(
        includingLocalLibrary: Bool,
        fileManager: FileManager = .default
    ) throws -> Self {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let caches = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let localLibrary: URL?
        if includingLocalLibrary {
            let documents = try fileManager.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            localLibrary = documents.appending(path: "Nook", directoryHint: .isDirectory)
        } else {
            localLibrary = nil
        }
        return Self(
            applicationSupportDirectory: applicationSupport.appending(path: "Nook", directoryHint: .isDirectory),
            cachesDirectory: caches,
            localLibraryDirectory: localLibrary
        )
    }
}

/// Removes only device-local Nook state. The service deliberately has no sync
/// folder parameter, making it impossible for reset code to delete user library
/// files or per-device shards in the selected vault.
public enum LocalAppResetService {
    @MainActor
    public static func reset(
        options: LocalAppResetOptions,
        preservingDeviceID deviceID: String,
        bundleIdentifier: String
    ) async throws {
        let fileManager = FileManager.default
        let paths = try LocalAppResetPaths.current(
            includingLocalLibrary: UserDefaults.standard.bool(forKey: ReaderStore.usesLocalLibraryKey),
            fileManager: fileManager
        )

        try clearLocalFiles(at: paths, fileManager: fileManager)
        URLCache.shared.removeAllCachedResponses()

        if !options.preservesWebSessions {
            HTTPCookieStorage.shared.cookies?.forEach(HTTPCookieStorage.shared.deleteCookie)
        }
        await clearWebsiteData(preservingSessions: options.preservesWebSessions)

        if !options.preservesGeminiCredential {
            _ = GeminiCredential.setAPIKey(nil)
            // Clearing an already-empty credential returns false because there
            // is nothing stored; only fail when a key actually survived.
            if GeminiCredential.hasKey {
                throw CocoaError(.fileWriteNoPermission)
            }
        }

        let defaults = UserDefaults.standard
        let preservedGeminiState = options.preservesGeminiCredential && GeminiCredential.hasKey
        resetDefaults(
            defaults,
            domainName: bundleIdentifier,
            preservingDeviceID: deviceID,
            preservingGeminiState: preservedGeminiState
        )
    }

    static func resetDefaults(
        _ defaults: UserDefaults,
        domainName: String,
        preservingDeviceID deviceID: String,
        preservingGeminiState: Bool
    ) {
        defaults.removePersistentDomain(forName: domainName)
        defaults.set(deviceID, forKey: DeviceIdentity.defaultsKey)
        if preservingGeminiState {
            defaults.set(true, forKey: TranslationSettings.geminiKeyConfiguredKey)
        }
        // The replacement app instance is opened immediately. Force the tiny
        // preserved identity write through cfprefsd before that process boots.
        defaults.synchronize()
    }

    static func clearLocalFiles(
        at paths: LocalAppResetPaths,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: paths.applicationSupportDirectory.path(percentEncoded: false)) {
            try fileManager.removeItem(at: paths.applicationSupportDirectory)
        }
        if let localLibraryDirectory = paths.localLibraryDirectory,
           fileManager.fileExists(atPath: localLibraryDirectory.path(percentEncoded: false)) {
            try fileManager.removeItem(at: localLibraryDirectory)
        }

        guard fileManager.fileExists(atPath: paths.cachesDirectory.path(percentEncoded: false)) else {
            return
        }
        for item in try fileManager.contentsOfDirectory(
            at: paths.cachesDirectory,
            includingPropertiesForKeys: nil
        ) {
            try fileManager.removeItem(at: item)
        }
    }

    @MainActor
    private static func clearWebsiteData(preservingSessions: Bool) async {
        let dataStore = WebViewWarmer.dataStore
        let dataTypes: Set<String>
        if preservingSessions {
            dataTypes = [
                WKWebsiteDataTypeDiskCache,
                WKWebsiteDataTypeMemoryCache,
                WKWebsiteDataTypeOfflineWebApplicationCache,
            ]
        } else {
            dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        }

        let records: [WKWebsiteDataRecord] = await withCheckedContinuation { continuation in
            dataStore.fetchDataRecords(ofTypes: dataTypes) { continuation.resume(returning: $0) }
        }
        await withCheckedContinuation { continuation in
            dataStore.removeData(ofTypes: dataTypes, for: records) { continuation.resume() }
        }
    }
}
