import Foundation
import NookPlusProtocol

/// Direct access to a user's PDS.
///
/// Reads go here rather than to the service API, because the PDS holds the
/// authoritative records — see the protocol's client-data-flow document. Only
/// mutations take the service fast path.
public struct PlusPDSClient: Sendable {
    private let host: String
    private let session: URLSession

    public init(host: String, session: URLSession = .shared) {
        self.host = host
        self.session = session
    }

    /// Signs in with a handle (or DID) and password.
    ///
    /// The password goes to the PDS and is not retained: the returned session
    /// is what gets stored.
    public func signIn(identifier: String, password: String) async throws -> PlusSession {
        struct Response: Decodable {
            let did: String
            let handle: String
            let accessJwt: String
            let refreshJwt: String
        }
        let response: Response = try await post(
            "com.atproto.server.createSession",
            body: ["identifier": identifier, "password": password]
        )
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
        return try JSONDecoder().decode(Response.self, from: data)
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
    case upstream(status: Int, kind: String?)

    public var errorDescription: String? {
        switch self {
        case .badRequest:
            return String(localized: "Could not build the request.")
        case .upstream(let status, let kind):
            if status == 401 || kind == "AuthenticationRequired" || kind == "InvalidPassword" {
                return String(localized: "That handle and password did not match.")
            }
            if kind == "AccountTakedown" {
                return String(localized: "This account is not available.")
            }
            return String(localized: "The server could not complete that request.")
        }
    }
}
