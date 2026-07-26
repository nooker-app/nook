import UIKit
import UniformTypeIdentifiers

/// Share-sheet extension: takes the URL of the page the user is viewing and
/// offers three ways into Nook, each handed off via a `nook://` deep link so
/// all storage-touching work happens in the app (no App Group needed — works
/// with a free developer account):
/// - Follow the site immediately (auto-discovering its RSS/Atom feed),
/// - Find the feed address first (result sheet with copy/add/report),
/// - Save the page itself as an article (for sites with no feed at all).
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        Task {
            guard let shared = await extractSharedURL() else {
                extensionContext?.completeRequest(returningItems: nil)
                return
            }
            presentActions(for: shared)
        }
    }

    // MARK: - Action picker

    private func presentActions(for shared: URL) {
        let alert = UIAlertController(
            title: "Nook",
            message: shared.absoluteString,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L.followSite, style: .default) { [weak self] _ in
            self?.forward(shared, host: "add-feed")
        })
        alert.addAction(UIAlertAction(title: L.findFeed, style: .default) { [weak self] _ in
            self?.forward(shared, host: "discover-feed")
        })
        alert.addAction(UIAlertAction(title: L.saveArticle, style: .default) { [weak self] _ in
            self?.forward(shared, host: "save-article")
        })
        alert.addAction(UIAlertAction(title: L.cancel, style: .cancel) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        present(alert, animated: true)
    }

    private func forward(_ shared: URL, host: String) {
        Task {
            if let deepLink = Self.deepLink(for: shared, host: host) {
                await open(deepLink)
            }
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    // MARK: - Localization (inline: the extension has no string catalog, and
    // registering one would mean project-file surgery for four strings)

    private enum L {
        private static var lang: String {
            Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        }

        static var followSite: String {
            switch lang {
            case "ko": "사이트 구독"
            case "ja": "サイトをフォロー"
            case "zh": "关注网站"
            default: "Follow This Site"
            }
        }

        static var findFeed: String {
            switch lang {
            case "ko": "피드 주소 찾기"
            case "ja": "フィードのアドレスを探す"
            case "zh": "查找源地址"
            default: "Find the Feed Address"
            }
        }

        static var saveArticle: String {
            switch lang {
            case "ko": "페이지를 글로 저장"
            case "ja": "ページを記事として保存"
            case "zh": "将页面保存为文章"
            default: "Save Page as Article"
            }
        }

        static var cancel: String {
            switch lang {
            case "ko": "취소"
            case "ja": "キャンセル"
            case "zh": "取消"
            default: "Cancel"
            }
        }
    }

    // MARK: - Plumbing

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

    private static func deepLink(for shared: URL, host: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&?=+/:")
        let encoded = shared.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "nook://\(host)?url=\(encoded)")
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
