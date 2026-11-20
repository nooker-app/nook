#if os(macOS)
import Observation
import SwiftUI

@MainActor @Observable final class RecommendationModelSetup {
    static let shared = RecommendationModelSetup()
    var ready = false
    var checked = false
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

    func check() async {
        ready = await RecommendationModelAssets.shared.isInstalled()
        checked = true
    }

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
    private let onReady: () -> Void
    public init(onReady: @escaping () -> Void = {}) { self.onReady = onReady }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(String(localized: "On-device connections", bundle: .module), systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
            if !RecommendationModelSetup.supported {
                Text("Detailed connections require Apple silicon. You can still explore connections based on the words in your articles.", bundle: .module)
                    .foregroundStyle(.secondary)
            } else {
                Text("Find related ideas, even when the words or languages differ.", bundle: .module)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(RecommendationModelManifest.bundled, id: \.id) { model in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(model.kind == "embedding"
                                    ? String(localized: "Understand article meaning", bundle: .module)
                                    : String(localized: "Refine related stories", bundle: .module))
                                    .fontWeight(.medium)
                                Spacer(minLength: 8)
                                Text(model.byteCount, format: .byteCount(style: .decimal))
                                    .foregroundStyle(.secondary)
                            }
                            Text(model.id).font(.caption).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Link(destination: model.sourceURL) {
                                Label("Hugging Face", systemImage: "arrow.up.right")
                                    .font(.caption).foregroundStyle(NookTheme.accent)
                            }.buttonStyle(.plain).pointerStyle(.link)
                        }
                        if model.kind == "embedding" { Divider() }
                    }
                }
                .padding(14).background(NookTheme.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 8) {
                    Text("Community conversions hosted on Hugging Face. Nook downloads a pinned version and verifies each file before use.", bundle: .module)
                    Label(String(localized: "Article text stays on this Mac. Model downloads connect to Hugging Face; analysis runs locally.", bundle: .module), systemImage: "lock.shield")
                    Text("After downloading, Nook analyzes your library once. Larger libraries take longer. You can keep exploring, and completed analysis is saved on this Mac.", bundle: .module)
                }.font(.caption).foregroundStyle(.secondary)
                if setup.ready {
                    Label(String(localized: "Ready for offline exploration", bundle: .module), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(NookTheme.accent)
                } else if setup.downloading {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Downloading models", bundle: .module)
                            Spacer()
                            Text(setup.progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                        }
                        ProgressView(value: setup.progress).tint(NookTheme.accent)
                        Button(String(localized: "Cancel", bundle: .module)) { setup.cancel() }
                    }
                } else if setup.checked {
                    Button { setup.install() } label: {
                        Label {
                            Text("Download models · \(RecommendationModelManifest.totalBytes, format: .byteCount(style: .decimal))", bundle: .module)
                        } icon: { Image(systemName: "arrow.down.circle") }
                    }
                    if setup.failed {
                        Text("Download interrupted. Try again to continue with completed files.", bundle: .module)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .font(.callout).fixedSize(horizontal: false, vertical: true)
        .task { await setup.check() }
        .onChange(of: setup.ready) { _, ready in if ready { onReady() } }
    }
}
#endif
