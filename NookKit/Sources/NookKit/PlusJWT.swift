import Foundation

/// Reads the expiry out of a session token.
///
/// Only the expiry, and only to decide whether to exchange the refresh token before
/// making a request. Nothing here verifies the signature and nothing may ever trust
/// these claims for a decision about access: the server does that, and a token this
/// device holds is one this device was given, not one it gets to judge. Reading the
/// expiry wrong can only cost an unnecessary refresh or a retry.
///
/// Needed because the PDS's access token lives for hours while the refresh token
/// lives for months, and Nook was using the first and ignoring the second: a writer
/// mid-draft was told to sign in again, when a refresh was available the whole time.
enum PlusJWT {
    /// The `exp` claim, or nil when the token is not a readable JWT.
    static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = base64URLDecoded(parts[1]) else { return nil }
        struct Claims: Decodable { let exp: Double? }
        guard let exp = (try? JSONDecoder().decode(Claims.self, from: payload))?.exp else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    /// Whether the token is expired, or close enough that a request made with it
    /// could arrive after it is.
    ///
    /// A token whose expiry cannot be read is reported as *not* expired: guessing
    /// otherwise would refresh on every single call, and the request itself is the
    /// authority on whether a token still works.
    static func isExpired(_ token: String, leeway: TimeInterval = 120, now: Date) -> Bool {
        guard let expiry = expiry(of: token) else { return false }
        return expiry.timeIntervalSince(now) <= leeway
    }

    /// base64url, which uses `-` and `_` and drops the padding.
    private static func base64URLDecoded(_ value: Substring) -> Data? {
        var text =
            value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = text.count % 4
        if remainder > 0 {
            text += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: text)
    }
}
