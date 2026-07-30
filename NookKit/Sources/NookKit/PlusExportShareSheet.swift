import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// Hands a downloaded export to wherever the writer wants to keep it.
///
/// A share sheet over a local file, not a link. The service's download URL is a
/// bearer credential — anyone holding it can read the archive until it expires — so
/// the bytes are fetched first and it is the file that travels. Sharing the URL
/// would put a working credential into a message, a clipboard, or a screenshot.
struct PlusExportShareSheet: View {
    let file: URL
    let onFinished: () -> Void

    var body: some View {
        #if os(iOS)
            ActivityView(file: file, onFinished: onFinished)
                .ignoresSafeArea()
        #else
            // On the Mac the file is already somewhere reachable, so the useful thing
            // is to say where and offer to reveal it. A share sheet here would be a
            // longer route to the same place.
            VStack(alignment: .leading, spacing: 14) {
                Label {
                    Text("Your copy is ready", bundle: .module).font(.headline)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Text("Every publication and article, exactly as your repository holds them.", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(verbatim: file.lastPathComponent)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                HStack {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    } label: {
                        Text("Show in Finder", bundle: .module)
                    }
                    Spacer()
                    Button { onFinished() } label: { Text("Done", bundle: .module) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(minWidth: 380)
        #endif
    }
}

#if os(iOS)
    /// `UIActivityViewController`, because SwiftUI's `ShareLink` cannot report when it
    /// is finished — and the file is a temporary one this screen has to clear.
    private struct ActivityView: UIViewControllerRepresentable {
        let file: URL
        let onFinished: () -> Void

        func makeUIViewController(context: Context) -> UIActivityViewController {
            let controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            // Called for a completed share and for a cancelled one alike: either way
            // this screen is done with the file.
            controller.completionWithItemsHandler = { _, _, _, _ in onFinished() }
            return controller
        }

        func updateUIViewController(_: UIActivityViewController, context: Context) {}
    }
#endif
