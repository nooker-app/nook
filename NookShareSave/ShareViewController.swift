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
            guard let shared = await extractSharedURL(), let deepLink = deepLink(for: shared) else {
                extensionContext?.completeRequest(returningItems: nil)
                return
            }
            openAndFinish(deepLink)
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

    /// Hands the deep link to the system and finishes the request WITHOUT
    /// waiting on the open's completion handler: the moment the host app comes
    /// to the foreground this process is suspended, and a completeRequest that
    /// was still pending never runs — PlugInKit then treats the extension as
    /// hung and drops it from the share sheet until the container app
    /// relaunches and re-registers it.
    private func openAndFinish(_ url: URL) {
        var finished = false
        let finish = { [weak self] in
            guard !finished else { return }
            finished = true
            self?.extensionContext?.completeRequest(returningItems: nil)
        }

        if let context = extensionContext {
            context.open(url) { [weak self] success in
                if !success { self?.openViaResponderChain(url) }
                finish()
            }
        } else {
            openViaResponderChain(url)
        }
        // Safety net: finish even if the open callback is swallowed by the
        // app-switch suspension (the exact race this ordering exists to beat).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { finish() }
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
