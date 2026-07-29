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
        } catch PlusPDSError.upstream(let status, let kind) where isRejected(status: status, kind: kind) {
            // A handle this host does not have an account for looks exactly like
            // a wrong password from here, so the distinguishable case — a handle
            // that plainly belongs elsewhere — is named.
            if belongsElsewhere(identifier) {
                throw PlusPDSError.foreignHandle(host: host)
            }
            throw PlusPDSError.upstream(status: status, kind: kind)
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

        let (data, response) = try await session.data(from: url)
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
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body ?? [:])

        let (data, response) = try await session.data(for: request)
        try check(response, data)
        if data.isEmpty, let empty = "{}".data(using: .utf8) {
            // Some methods answer 200 with no body. Decoding nothing fails, so
            // an empty object stands in for "it worked and said nothing".
            return try JSONDecoder().decode(Response.self, from: empty)
        }
        return try JSONDecoder().decode(Response.self, from: data)
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
            }
            let kind = (try? JSONDecoder().decode(Failure.self, from: data))?.error
            throw PlusPDSError.upstream(status: http.statusCode, kind: kind)
        }
    }
}

/// Failures reaching a PDS.
public enum PlusPDSError: Error, LocalizedError, Sendable {
    case badRequest
    /// The handle belongs to a server other than the one Nook talks to.
    case foreignHandle(host: String)
    case upstream(status: Int, kind: String?)

    public var errorDescription: String? {
        switch self {
        case .badRequest:
            return String(localized: "Could not build the request.", bundle: .module)
        case .foreignHandle:
            return String(
                localized: "That handle belongs to a different server. Nook can only sign in to accounts on its own server.",
                bundle: .module
            )
        case .upstream(let status, let kind):
            if status == 401 || kind == "AuthenticationRequired" || kind == "InvalidPassword" {
                return String(localized: "That handle and password did not match.", bundle: .module)
            }
            if kind == "AccountTakedown" {
                return String(localized: "This account is not available.", bundle: .module)
            }
            if kind == "ExpiredToken" || kind == "InvalidToken" {
                return String(
                    localized: "That reset code is not usable. Request a new one.", bundle: .module)
            }
            return String(localized: "The server could not complete that request.", bundle: .module)
        }
    }
}
