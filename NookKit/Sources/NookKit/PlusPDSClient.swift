import Foundation
import NookPlusProtocol

/// Direct access to a user's PDS.
///
/// Reads go here rather than to the service API, because the PDS holds the
/// authoritative records — see the protocol's client-data-flow document. Only
/// mutations take the service fast path.
public struct PlusPDSClient: Sendable {
    private let host: String
    /// Handle domains this host issues accounts under. Used only to tell a
    /// foreign handle from a mistyped password.
    private let issuedDomains: [String]
    private let session: URLSession

    public init(host: String, issuedDomains: [String] = [], session: URLSession = .shared) {
        self.host = host
        self.issuedDomains = issuedDomains.map { $0.lowercased() }
        self.session = session
    }

    /// Signs in with a handle (or DID) and password.
    ///
    /// The password goes to the PDS and is not retained: the returned session
    /// is what gets stored.
    ///
    /// The host is fixed by configuration, not derived from the identifier, so a
    /// handle belonging to some other server cannot work here. That is reported
    /// as such rather than as a wrong password — the earlier wording sent people
    /// to check a password that was never the problem.
    public func signIn(identifier: String, password: String) async throws -> PlusSession {
        struct Response: Decodable {
            let did: String
            let handle: String
            let accessJwt: String
            let refreshJwt: String
        }
        let response: Response
        do {
            response = try await post(
                "com.atproto.server.createSession",
                body: ["identifier": identifier, "password": password]
            )
        } catch PlusPDSError.upstream(let status, let kind, let message)
            where isRejected(status: status, kind: kind)
        {
            // A handle this host does not have an account for looks exactly like
            // a wrong password from here, so the distinguishable case — a handle
            // that plainly belongs elsewhere — is named.
            if belongsElsewhere(identifier) {
                throw PlusPDSError.foreignHandle(host: host)
            }
            throw PlusPDSError.upstream(status: status, kind: kind, message: message)
        }
        return PlusSession(
            did: response.did,
            handle: response.handle,
            accessJWT: response.accessJwt,
            refreshJWT: response.refreshJwt
        )
    }

    /// Exchanges a refresh token for a fresh session.
    public func refresh(_ session: PlusSession) async throws -> PlusSession {
        struct Response: Decodable {
            let did: String
            let handle: String
            let accessJwt: String
            let refreshJwt: String
        }
        let response: Response = try await post(
            "com.atproto.server.refreshSession",
            body: nil,
            bearer: session.refreshJWT
        )
        return PlusSession(
            did: response.did,
            handle: response.handle,
            accessJWT: response.accessJwt,
            refreshJWT: response.refreshJwt
        )
    }

    /// Asks the host to email a password-reset code.
    ///
    /// The host owns this, not Nook's service: the password only ever goes to the
    /// host, so only it can change one. Reports nothing about whether the address
    /// belongs to an account — answering that would let anyone test addresses.
    public func requestPasswordReset(email: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await post(
            "com.atproto.server.requestPasswordReset",
            body: ["email": email.trimmingCharacters(in: .whitespacesAndNewlines)]
        )
    }

    /// Sets a new password using the code from that email.
    public func resetPassword(token: String, newPassword: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await post(
            "com.atproto.server.resetPassword",
            body: [
                "token": token.trimmingCharacters(in: .whitespacesAndNewlines),
                "password": newPassword,
            ]
        )
    }

    /// Lists a repository's publications, newest first.
    public func publications(did: String) async throws -> [ATRecord<PublicationRecord>] {
        try await list(did: did, collection: PublicationRecord.typeNSID)
    }

    /// Lists a repository's articles, newest first.
    public func articles(did: String) async throws -> [ATRecord<ArticleRecord>] {
        try await list(did: did, collection: ArticleRecord.typeNSID)
    }

    /// Where a blob in a repository can be read from.
    ///
    /// Built rather than fetched so a view can hand it to `AsyncImage` and let the
    /// system do the loading and caching. Unauthenticated: a blob referenced by a
    /// public record is public.
    ///
    /// The repository is the right source for showing an icon back to its owner. The
    /// served copy under the publication's prefix is derived, and it does not exist
    /// until the service has rendered — so a writer who has just chosen an image
    /// would be looking at nothing.
    public func blobURL(did: String, cid: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/xrpc/com.atproto.sync.getBlob"
        components.queryItems = [
            .init(name: "did", value: did),
            .init(name: "cid", value: cid),
        ]
        return components.url
    }

    /// Uploads an image to the signed-in writer's own repository and returns the
    /// reference to store in a record.
    ///
    /// The bytes go straight from this device to the writer's PDS. They do not pass
    /// through the Nook service: the session is already at the PDS boundary, so
    /// routing user content through a second host would add a place for it to be
    /// without adding anything, and would make uploading depend on the service
    /// being reachable.
    ///
    /// The blob is the source image. Producing the sizes a page and a feed need is
    /// the service's work, so nothing here resizes or re-encodes.
    public func uploadBlob(
        _ data: Data, mimeType: String, bearer: String
    ) async throws -> Blob {
        guard let url = URL(string: "https://\(host)/xrpc/com.atproto.repo.uploadBlob") else {
            throw PlusPDSError.badRequest
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        // The raw bytes with their own type — uploadBlob takes the image itself,
        // not a JSON envelope around it.
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (responseData, response) = try await reach {
            try await session.data(for: request)
        }
        try check(response, responseData)
        return try JSONDecoder().decode(UploadedBlob.self, from: responseData).blob
    }

    private func list<Value: Codable & Sendable & Equatable>(
        did: String, collection: String
    ) async throws -> [ATRecord<Value>] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/xrpc/com.atproto.repo.listRecords"
        components.queryItems = [
            .init(name: "repo", value: did),
            .init(name: "collection", value: collection),
            .init(name: "limit", value: "100"),
            // Newest first: record keys are time-ordered, so reversing the
            // key order is also reverse-chronological.
            .init(name: "reverse", value: "false"),
        ]
        guard let url = components.url else { throw PlusPDSError.badRequest }

        let (data, response) = try await reach { try await session.data(from: url) }
        try check(response, data)
        return try JSONDecoder().decode(ATRecordPage<Value>.self, from: data).records
    }

    private func post<Response: Decodable>(
        _ method: String, body: [String: String]?, bearer: String? = nil
    ) async throws -> Response {
        guard let url = URL(string: "https://\(host)/xrpc/\(method)") else {
            throw PlusPDSError.badRequest
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        // No body means no body, and no content type either.
        //
        // This used to send `{}` with `Content-Type: application/json` regardless,
        // which the host refuses for a method that takes no input:
        // "A request body was provided when none was expected", 400. The only such
        // method here is `refreshSession`, so every two hours the app tried to renew
        // its session, was rejected, and told the writer to sign in again — with a
        // refresh token valid for ninety days sitting in the Keychain.
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await reach { try await session.data(for: request) }
        try check(response, data)
        if data.isEmpty, let empty = "{}".data(using: .utf8) {
            // Some methods answer 200 with no body. Decoding nothing fails, so
            // an empty object stands in for "it worked and said nothing".
            return try JSONDecoder().decode(Response.self, from: empty)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    /// Runs a request, naming a failure to reach the host as such.
    private func reach(
        _ send: () async throws -> (Data, URLResponse)
    ) async throws -> (Data, URLResponse) {
        do {
            return try await send()
        } catch let error as URLError {
            throw PlusPDSError.transport(error)
        }
    }

    /// Whether the host rejected the credentials as opposed to failing.
    private func isRejected(status: Int, kind: String?) -> Bool {
        status == 401 || kind == "AuthenticationRequired" || kind == "InvalidPassword"
    }

    /// Whether an identifier is a handle that clearly belongs to another server.
    ///
    /// Deliberately narrow: it only claims foreignness for a handle whose domain
    /// this host could not have issued. A bare name, a DID, or a handle under
    /// this host's own domain stays a credentials problem, because that is what
    /// it most likely is.
    private func belongsElsewhere(_ identifier: String) -> Bool {
        guard !identifier.hasPrefix("did:"), identifier.contains(".") else { return false }
        let lowered = identifier.lowercased()
        for domain in issuedDomains where lowered.hasSuffix("." + domain) {
            return false
        }
        return true
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            // The PDS reports a machine-readable kind; the prose message is
            // not shown to users verbatim.
            struct Failure: Decodable {
                let error: String?
                let message: String?
            }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            // The prose is kept, not discarded. When nothing here recognises the
            // kind, the host's own sentence is the only thing that explains what
            // happened, and a screen that says "something went wrong" instead
            // leaves the user with nowhere to go.
            throw PlusPDSError.upstream(
                status: http.statusCode, kind: failure?.error, message: failure?.message)
        }
    }
}

/// Failures reaching a PDS.
public enum PlusPDSError: Error, LocalizedError, Sendable {
    case badRequest
    /// The host could not be reached at all. Carried rather than left as a bare
    /// URLError so a caller can tell "no such host" — a build pointed at a
    /// deployment that does not exist — from a network that is merely down.
    case transport(any Error)
    /// The handle belongs to a server other than the one Nook talks to.
    case foreignHandle(host: String)
    case upstream(status: Int, kind: String?, message: String?)

    public var errorDescription: String? {
        switch self {
        case .badRequest:
            return String(localized: "Could not build the request.", bundle: .module)
        case .transport:
            return String(localized: "Could not reach the server that stores your posts.", bundle: .module)
        case .foreignHandle:
            return String(
                localized: "That handle belongs to a different server. Nook can only sign in to accounts on its own server.",
                bundle: .module
            )
        case .upstream(let status, let kind, let message):
            if status == 401 || kind == "AuthenticationRequired" || kind == "InvalidPassword" {
                return String(localized: "That handle and password did not match.", bundle: .module)
            }
            if kind == "AccountTakedown" {
                return String(localized: "This account is not available.", bundle: .module)
            }
            // A spent token, which the host reports the same way whether it was a
            // reset code or a session. Session expiry is handled before a request is
            // made (see `PlusStore.refreshSessionIfExpired`), so by the time this is
            // read the token in question is one the user typed. Said generally enough
            // to be true either way: claiming "reset code" was wrong every time a
            // session reached here, and told the writer to request a code they had
            // never asked for.
            if kind == "ExpiredToken" || kind == "InvalidToken" {
                return String(
                    localized: "That code or session is no longer valid. Request a new one, or sign in again.",
                    bundle: .module)
            }
            if status == 429 || kind == "RateLimitExceeded" {
                return String(
                    localized: "Too many attempts. Wait a few minutes and try again.", bundle: .module)
            }
            // Falls back to the host's wording rather than a sentence that says
            // nothing. It is English, which is a real shortcoming, but a user who
            // can read what the server actually objected to can act on it; one
            // told only that a request failed cannot.
            if let message, !message.isEmpty {
                return message
            }
            return String(localized: "The server could not complete that request.", bundle: .module)
        }
    }
}

/// The `com.atproto.repo.uploadBlob` response: the stored blob's reference.
private struct UploadedBlob: Decodable {
    let blob: Blob
}
