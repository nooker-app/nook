import Foundation

/// Invitation links: `nook://plus/invite?code=…`
///
/// A link carrying a code is a bearer credential — whoever sees it can redeem
/// it, including anyone the recipient forwards it to. That is inherent to
/// shareable invites and is why codes have a use count and an expiry rather
/// than being unlimited.
///
/// The custom scheme is used rather than an https link on purpose: an https URL
/// would put the code in a path or query that load balancers, CDNs, and
/// analytics all log, and this project's rules say an invitation code must
/// never reach a log. A `nook://` URL is resolved entirely by the operating
/// system and never reaches a server.
///
/// The tradeoff is that the link does nothing for someone without the app
/// installed. An https landing page could fix that, and would need the code in
/// a URL *fragment* — which browsers do not send to the server — plus the
/// associated-domains entitlement. Worth doing when there is a website to land
/// on; not worth the logging risk before then.
public enum PlusInviteLink {
    static let scheme = "nook"
    static let host = "plus"
    static let path = "/invite"
    static let codeParameter = "code"

    /// Builds a shareable link for a code.
    public static func url(code: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        components.queryItems = [URLQueryItem(name: codeParameter, value: code)]
        return components.url
    }

    /// Extracts the code from an incoming link, or nil when the URL is not one.
    ///
    /// The code is returned as written; validation and redemption stay on the
    /// server, so a malformed or expired code fails the same way a typed one
    /// does rather than being silently treated as absent.
    public static func code(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme,
            url.host?.lowercased() == host,
            url.path == path,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let code = components.queryItems?
                .first(where: { $0.name == codeParameter })?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !code.isEmpty
        else { return nil }
        return code
    }
}

/// A pending invitation handed to the app by a link.
///
/// Held here rather than passed through view state because the link can arrive
/// before any Plus screen exists — the app may have been launched by it.
@MainActor
@Observable
public final class PlusInviteInbox {
    public static let shared = PlusInviteInbox()

    /// The code most recently received from a link, if it has not been consumed.
    public private(set) var pendingCode: String?

    private init() {}

    /// Records a code from an incoming link. Returns whether the URL was one.
    @discardableResult
    public func accept(_ url: URL) -> Bool {
        guard let code = PlusInviteLink.code(from: url) else { return false }
        pendingCode = code
        return true
    }

    /// Takes the pending code, clearing it so a completed signup cannot be
    /// restarted by the same link sitting in memory.
    public func take() -> String? {
        defer { pendingCode = nil }
        return pendingCode
    }

    /// Discards a pending code, for a user who backs out of setup.
    public func clear() { pendingCode = nil }
}
