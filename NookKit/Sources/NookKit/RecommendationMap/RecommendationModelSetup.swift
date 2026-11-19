#if os(macOS)
import Observation
import SwiftUI

@MainActor @Observable final class RecommendationModelSetup {
    static let shared = RecommendationModelSetup()
    var ready = false
    var downloading = false
    var progress = 0.0
    var failed = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var releaseTask: Task<Void, Never>?
    static var supported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    func check() async { ready = await RecommendationModelAssets.shared.isInstalled() }

    func install() {
        guard !downloading, Self.supported else { return }
        downloading = true
        failed = false
        progress = 0
        task = Task {
            do {
                try await RecommendationModelAssets.shared.install { value in
                    Task { @MainActor in
                        guard self.downloading else { return }
                        self.progress = value
                    }
                }
                ready = true
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { failed = true }
            }
            downloading = false
            task = nil
        }
    }

    func cancel() { task?.cancel() }

    func retainModels(_ active: Bool) {
        releaseTask?.cancel()
        guard !active else { return }
        releaseTask = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            await RecommendationNativeModels.shared.unload()
        }
    }
}

/// Shared by the map and Reading settings; a single installation survives view navigation.
public struct RecommendationModelSettings: View {
    @State private var setup = RecommendationModelSetup.shared
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(String(localized: "On-device connections", bundle: .module), systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
            if setup.ready {
                Label(String(localized: "Ready for offline exploration", bundle: .module), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else if !RecommendationModelSetup.supported {
                Text("Detailed connections require Apple silicon. You can still explore connections based on the words in your articles.", bundle: .module)
                    .foregroundStyle(.secondary)
            } else {
                Text("Download the local models (2.9 GB) to connect articles by meaning, across categories and languages. Article text stays on this Mac. Once downloaded, exploration works offline.", bundle: .module)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if setup.downloading {
                    HStack {
                        ProgressView(value: setup.progress).frame(maxWidth: 220)
                        Text(setup.progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                        Button(String(localized: "Cancel", bundle: .module)) { setup.cancel() }
                    }
                } else {
                    Button(String(localized: "Download models", bundle: .module), systemImage: "arrow.down.circle") { setup.install() }
                    if setup.failed {
                        Text("Download interrupted. Try again to continue with completed files.", bundle: .module)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task { await setup.check() }
    }
}
#endif
