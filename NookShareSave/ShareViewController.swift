import UIKit
import UniformTypeIdentifiers

/// One-tap share action: forwards the shared page to Nook via
/// `nook://save-article?url=…`. Each share action ships as its own extension target so
/// it appears as its own row in the share sheet (and can be individually
/// favorited there); all storage-touching work happens in the app.
final class ShareViewController: UIViewController {
    private let deepLinkHost = "save-article"

    override func viewDidLoad() {
        super.viewDidLoad()
        Task {
            if let shared = await extractSharedURL(), let deepLink = deepLink(for: shared) {
                await open(deepLink)
            }
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// Finds the shared web URL among the extension's input attachments.
    private func extractSharedURL() async -> URL? {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }

        if let urlProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            return await withCheckedContinuation { continuation in
                urlProvider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    continuation.resume(returning: item as? URL)
                }
            }
        }
        if let textProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            return await withCheckedContinuation { continuation in
                textProvider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                    let url = (item as? String).flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    continuation.resume(returning: url)
                }
            }
        }
        return nil
    }

    private func deepLink(for shared: URL) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&?=+/:")
        let encoded = shared.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "nook://\(deepLinkHost)?url=\(encoded)")
    }

    /// Opens the containing app. Uses the extension context first; if that is
    /// refused, walks the responder chain to reach UIApplication as a fallback.
    private func open(_ url: URL) async {
        let opened = await withCheckedContinuation { continuation in
            guard let context = extensionContext else {
                continuation.resume(returning: false)
                return
            }
            context.open(url) { continuation.resume(returning: $0) }
        }
        if !opened { openViaResponderChain(url) }
    }

    private func openViaResponderChain(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = current.next
        }
    }
}
