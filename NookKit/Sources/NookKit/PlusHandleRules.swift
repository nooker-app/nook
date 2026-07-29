import Foundation

/// The rules a chosen name has to satisfy, checked before anything is sent.
///
/// A copy of what the service enforces, kept here so a name that cannot work is
/// refused where the user can still see why. Without it the screen previewed a
/// handle and a site address for a name the service would reject — the strongest
/// possible signal that the name was fine, shown for one that was not.
///
/// Deliberately a duplicate rather than a shared artefact: the service is the
/// authority, so this is an early answer, never the verdict. Anything this
/// accepts is still checked there, and a mismatch shows up as a rejection rather
/// than as a name that silently means something else.
public enum PlusHandleRules {
    public static let minimumLength = 3
    public static let maximumLength = 18

    /// Why a name cannot be used.
    public enum Problem: Equatable, Sendable {
        case empty
        case tooShort
        case tooLong
        /// Anything outside lowercase ASCII letters, digits, and hyphens.
        ///
        /// The service rejects non-ASCII outright, which rules out Korean,
        /// Japanese, and Chinese names. That is not a gap to fill later: a
        /// handle lives in a public namespace resolved through DNS, and
        /// lookalike letters from other scripts would let one account
        /// impersonate another.
        case unsupportedCharacters
        case hyphenAtEdge
        case doubleHyphen
        case digitsOnly
        case reserved

        public var message: String {
            switch self {
            case .empty:
                String(localized: "Choose a name.", bundle: .module)
            case .tooShort:
                String(localized: "At least 3 characters.", bundle: .module)
            case .tooLong:
                String(localized: "At most 18 characters.", bundle: .module)
            case .unsupportedCharacters:
                String(
                    localized:
                        "Use lowercase English letters, numbers, and hyphens. A handle is a web address, so it cannot contain Korean, Japanese, Chinese, or accented letters.",
                    bundle: .module
                )
            case .hyphenAtEdge:
                String(localized: "Cannot start or end with a hyphen.", bundle: .module)
            case .doubleHyphen:
                String(localized: "Cannot contain two hyphens in a row.", bundle: .module)
            case .digitsOnly:
                String(localized: "Needs at least one letter.", bundle: .module)
            case .reserved:
                String(localized: "That name is reserved.", bundle: .module)
            }
        }
    }

    /// Lower-cases and trims, the way the service does before comparing.
    public static func normalize(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The first thing wrong with a name, or nil when it is usable.
    public static func problem(with label: String) -> Problem? {
        let label = normalize(label)
        if label.isEmpty { return .empty }

        // Counted in UTF-8 bytes, as the service does, so a name that passes
        // here cannot fail there on length alone.
        let length = label.utf8.count
        if length < minimumLength { return .tooShort }
        if length > maximumLength { return .tooLong }

        var hasLetter = false
        for character in label.unicodeScalars {
            switch character {
            case "a"..."z": hasLetter = true
            case "0"..."9", "-": break
            default: return .unsupportedCharacters
            }
        }

        if label.hasPrefix("-") || label.hasSuffix("-") { return .hyphenAtEdge }
        // A resolver reads "xn--" and similar as punycode.
        if label.contains("--") { return .doubleHyphen }
        if !hasLetter { return .digitsOnly }
        if reserved.contains(label) { return .reserved }
        return nil
    }

    /// Whether a name is worth previewing and sending.
    public static func isUsable(_ label: String) -> Bool {
        problem(with: label) == nil
    }

    /// Names the service withholds. Kept in step with `internal/handle`; a name
    /// missing here is caught by the availability check instead of being
    /// accepted.
    private static let reserved: Set<String> = [
        // Service identity and impersonation risk.
        "nook", "nooker", "nookplus", "plus", "official", "team", "staff",
        "admin", "administrator", "moderator", "moderation", "support",
        "help", "helpdesk", "security", "legal", "billing",
        // Well-known role addresses.
        "abuse", "postmaster", "hostmaster", "webmaster", "noc",
        "root", "sysadmin", "info", "noreply", "no-reply", "mailer-daemon",
        // Infrastructure and protocol names that must stay routable.
        "www", "api", "app", "cdn", "static", "assets", "mail", "smtp",
        "imap", "ns", "ns1", "ns2", "dns", "mx", "pds", "xrpc", "atproto",
        "did", "plc", "feed", "feeds", "rss", "atom", "sitemap",
        "well-known", "wellknown", "acme", "status", "health", "metrics",
        // Environment names.
        "staging", "production", "prod", "dev", "test", "sandbox", "demo",
        // Product surfaces likely to become real routes.
        "about", "blog", "docs", "terms", "privacy", "pricing", "settings",
        "account", "accounts", "login", "logout", "signup", "register",
        "invite", "invites", "search", "explore", "discover", "home",
    ]
}
