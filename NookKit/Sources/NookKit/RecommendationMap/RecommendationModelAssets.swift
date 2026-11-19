#if os(macOS)
import CryptoKit
import Foundation

struct RecommendationModelManifest: Decodable, Sendable {
    struct File: Decodable, Sendable {
        let name: String
        let bytes: Int64
        let sha256: String
    }
    let kind: String
    let id: String
    let revision: String
    let files: [File]
    var directoryName: String { id.replacingOccurrences(of: "/", with: "_") + "-" + revision }
}

enum RecommendationModelError: Error {
    case missingAssets, invalidDownload, unsupportedDevice, invalidVector
}

/// Only pinned model data is downloaded. Article text never leaves the device.
actor RecommendationModelAssets {
    static let shared = RecommendationModelAssets()
    let root: URL
    let models: [RecommendationModelManifest]

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nook/RecommendationModels", isDirectory: true)
        models = Bundle.module.url(forResource: "Models", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([RecommendationModelManifest].self, from: $0) } ?? []
    }

    func directory(_ kind: String) throws -> URL {
        guard let model = models.first(where: { $0.kind == kind }) else { throw RecommendationModelError.missingAssets }
        return root.appendingPathComponent(model.directoryName, isDirectory: true)
    }

    func isInstalled() -> Bool {
        guard models.count == 2 else { return false }
        return models.allSatisfy { model in
            let folder = root.appendingPathComponent(model.directoryName)
            guard (try? String(contentsOf: folder.appendingPathComponent("verified"), encoding: .utf8)) == model.revision else { return false }
            return model.files.allSatisfy { file in
                (try? folder.appendingPathComponent(file.name).resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(file.bytes)
            }
        }
    }

    func install(progress: @Sendable @escaping (Double) -> Void) async throws {
        guard models.count == 2 else { throw RecommendationModelError.missingAssets }
        let total = models.flatMap(\.files).reduce(Int64(0)) { $0 + $1.bytes }
        var completed: Int64 = 0
        for model in models {
            let folder = root.appendingPathComponent(model.directoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in model.files {
                try Task.checkCancellation()
                let target = folder.appendingPathComponent(file.name)
                if try Self.valid(target, file: file) {
                    completed += file.bytes
                    progress(Double(completed) / Double(total))
                    continue
                }
                let start = completed
                let delegate = ModelDownloadProgress { bytes in
                    progress(Double(start + min(file.bytes, bytes)) / Double(total))
                }
                let url = URL(string: "https://huggingface.co/\(model.id)/resolve/\(model.revision)/\(file.name)")!
                let (temporary, response) = try await URLSession.shared.download(for: URLRequest(url: url), delegate: delegate)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      try Self.valid(temporary, file: file) else { throw RecommendationModelError.invalidDownload }
                try Task.checkCancellation()
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: temporary, to: target)
                completed += file.bytes
                progress(Double(completed) / Double(total))
            }
            try model.revision.write(to: folder.appendingPathComponent("verified"), atomically: true, encoding: .utf8)
        }
    }

    static func valid(_ url: URL, file: RecommendationModelManifest.File) throws -> Bool {
        guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(file.bytes),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256
    }
}

private final class ModelDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let update: @Sendable (Int64) -> Void
    private var lastUpdate = Date.distantPast
    init(update: @Sendable @escaping (Int64) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // URLSession serializes delegate callbacks. Do not publish every packet.
        guard Date().timeIntervalSince(lastUpdate) >= 0.2 else { return }
        lastUpdate = .now
        update(totalBytesWritten)
    }
}
#endif
