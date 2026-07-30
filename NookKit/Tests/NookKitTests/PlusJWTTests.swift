import Foundation
import Testing

@testable import NookKit

/// Reading a token's expiry decides whether Nook refreshes the session or throws the
/// writer out, which is the bug these exist for.
@Suite("Nook Plus token expiry")
struct PlusJWTTests {
    /// Builds a token shaped like the PDS's: three dot-separated base64url parts,
    /// of which only the payload is ever read. The signature is deliberately junk —
    /// nothing here may depend on it.
    private func token(exp: Double?) -> String {
        var claims: [String: Any] = ["sub": "did:plc:example", "scope": "com.atproto.access"]
        if let exp { claims["exp"] = exp }
        let payload = try! JSONSerialization.data(withJSONObject: claims)
        return "eyJhbGciOiJFUzI1NksifQ.\(base64URL(payload)).not-a-real-signature"
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("the expiry claim is read")
    func readsExpiry() {
        let expiry = now.addingTimeInterval(7200)
        #expect(PlusJWT.expiry(of: token(exp: expiry.timeIntervalSince1970)) == expiry)
    }

    /// The PDS's access token lasts hours, so a fresh one must not be refreshed on
    /// every call.
    @Test("a token with hours left is not expired")
    func fresh() {
        #expect(!PlusJWT.isExpired(token(exp: now.addingTimeInterval(7200).timeIntervalSince1970), now: now))
    }

    @Test("a token past its expiry is expired")
    func past() {
        #expect(PlusJWT.isExpired(token(exp: now.addingTimeInterval(-1).timeIntervalSince1970), now: now))
        #expect(PlusJWT.isExpired(token(exp: now.addingTimeInterval(-7200).timeIntervalSince1970), now: now))
    }

    /// A token that expires while the request is in flight is no use, so the leeway
    /// counts as expired.
    @Test("a token expiring within the leeway is expired")
    func leeway() {
        let soon = token(exp: now.addingTimeInterval(30).timeIntervalSince1970)
        #expect(PlusJWT.isExpired(soon, leeway: 120, now: now))
        #expect(!PlusJWT.isExpired(soon, leeway: 10, now: now))
    }

    /// An unreadable token is reported as usable: the request is the authority, and
    /// guessing "expired" would refresh before every single call.
    @Test("an unreadable token is not called expired")
    func unreadable() {
        for value in ["", "not-a-jwt", "a.b", "a.b.c.d", "header.@@@.signature", token(exp: nil)] {
            #expect(PlusJWT.expiry(of: value) == nil, "\(value) should not parse")
            #expect(!PlusJWT.isExpired(value, now: now), "\(value) should not be called expired")
        }
    }

    /// base64url payloads arrive without padding, and a decoder that requires it
    /// would silently fail to read the expiry — which reads as "never expires".
    @Test("payloads are decoded at every unpadded length")
    func padding() {
        for extra in 0..<4 {
            let claims = ["exp": 1_800_007_200, "pad": String(repeating: "x", count: extra)] as [String: Any]
            let payload = try! JSONSerialization.data(withJSONObject: claims)
            let value = "header.\(base64URL(payload)).signature"
            #expect(PlusJWT.expiry(of: value) != nil, "length %4 == \(payload.count % 3) failed to decode")
        }
    }
}
