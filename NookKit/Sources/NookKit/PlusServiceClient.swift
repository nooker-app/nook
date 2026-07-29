import Foundation
import HTTPTypes
import NookPlusServiceAPI
import OpenAPIRuntime
import OpenAPIURLSession

/// Attaches the Plus session's bearer token to outgoing requests.
///
/// The protocol package's generated client deliberately stops at the
/// transport abstraction, so authentication is the app's responsibility.
/// Keeping it in middleware means no call site can forget it.
struct PlusAuthenticationMiddleware: ClientMiddleware {
    /// Reads the token at request time rather than capturing it, so a
    /// refresh takes effect without rebuilding the client.
    let token: @Sendable () -> String?

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        if let token = token() {
            request.headerFields[.authorization] = "Bearer \(token)"
        }
        return try await next(request, body, baseURL)
    }
}

/// Errors a caller of the Plus service needs to distinguish. Anything a
/// client should react to differently gets its own case; the rest arrive as
/// `.problem` carrying the contract's stable type.
public enum PlusServiceError: Error, Sendable {
    /// Not signed in, or the session is no longer valid. Refresh, then retry.
    case sessionInvalid
    /// The record changed since it was read. Re-read, reconcile, then retry —
    /// never resend without the condition, which would discard the other
    /// change.
    case recordConflict
    /// A problem type from the contract that this call did not special-case.
    case problem(ProblemType?, status: Int, detail: String?)
    /// The service could not be reached, or answered unintelligibly.
    case transport(any Error)
}

/// Thin wrapper over the generated service client.
///
/// Deliberately small: it owns the transport, authentication, and error
/// mapping, and nothing about Plus product behaviour. Reading publications
/// and articles is not here at all — those come straight from the user's PDS,
/// which is the authoritative source.
public struct PlusServiceClient: Sendable {
    private let client: Client
    private let session: @Sendable () -> PlusSession?

    /// - Parameters:
    ///   - baseURL: the service API base URL, supplied by configuration. Never
    ///     hard-code it: staging and production differ.
    ///   - session: reads the current session at call time.
    ///   - urlSession: injectable so tests need no network.
    public init(
        baseURL: URL,
        session: @escaping @Sendable () -> PlusSession? = { PlusCredential.current },
        urlSession: URLSession = .shared
    ) {
        self.session = session
        self.client = Client(
            serverURL: baseURL,
            transport: URLSessionTransport(
                configuration: .init(session: urlSession)
            ),
            middlewares: [
                PlusAuthenticationMiddleware(token: { session()?.accessJWT })
            ]
        )
    }

    /// Whether an invitation code is currently usable. Unauthenticated: it runs
    /// before an account exists.
    public func verifyInvitation(code: String) async throws -> Bool {
        do {
            return try await client.verifyInvitation(body: .json(.init(code: code)))
                .ok.body.json.redeemable
        } catch let error as ClientError {
            throw PlusServiceError.transport(error)
        }
    }

    /// Whether a handle is available, with the service's reason when it is not.
    public func handleAvailability(handle: String) async throws
        -> Operations.checkHandleAvailability.Output.Ok.Body.jsonPayload
    {
        do {
            return try await client.checkHandleAvailability(query: .init(handle: handle))
                .ok.body.json
        } catch let error as ClientError {
            throw PlusServiceError.transport(error)
        }
    }

    /// Creates an account.
    ///
    /// The idempotency key is supplied by the caller so a retry resumes the same
    /// signup. Generating one here would make every retry a new identity.
    public func signUp(
        idempotencyKey: String,
        invitationCode: String,
        handle: String,
        displayName: String,
        email: String,
        password: String
    ) async throws -> Operations.signup.Output.Created.Body.jsonPayload {
        do {
            return try await client.signup(
                headers: .init(Idempotency_hyphen_Key: idempotencyKey),
                body: .json(
                    .init(
                        invitationCode: invitationCode,
                        handle: handle,
                        displayName: displayName,
                        email: email,
                        password: password
                    ))
            ).created.body.json
        } catch let error as ClientError {
            throw PlusServiceError.transport(error)
        }
    }

    /// The signed-in member's state.
    public func member() async throws -> Components.Schemas.Member {
        guard session() != nil else { throw PlusServiceError.sessionInvalid }
        do {
            return try await client.getMe().ok.body.json
        } catch let error as ClientError {
            throw PlusServiceError.transport(error)
        }
    }

    /// Publishes an article. The service writes the PDS record and schedules
    /// rendering; a success here means the authoritative record exists.
    public func createArticle(
        publication: String,
        title: String,
        slug: String,
        markdown: String,
        summary: String
    ) async throws -> Components.Schemas.Article {
        guard session() != nil else { throw PlusServiceError.sessionInvalid }
        var input = Components.Schemas.ArticleInput(
            publication: publication,
            title: title,
            content: markdown,
            slug: slug
        )
        if !summary.isEmpty {
            input.summary = summary
        }
        do {
            return try await client.createArticle(
                headers: .init(Idempotency_hyphen_Key: UUID().uuidString),
                body: .json(input)
            ).created.body.json
        } catch let error as ClientError {
            throw PlusServiceError.transport(error)
        }
    }

    /// Deletes an article, conditioned on the CID the caller last read.
    ///
    /// Passing the CID is what prevents deleting a revision the user has not
    /// seen. Omitting it makes the delete unconditional, which is why `cid` is
    /// not optional here even though the API allows it.
    public func deleteArticle(recordKey: String, cid: String) async throws {
        guard session() != nil else { throw PlusServiceError.sessionInvalid }
        do {
            _ = try await client.deleteArticle(
                path: .init(rkey: recordKey),
                headers: .init(If_hyphen_Match: quoted(cid))
            ).noContent
        } catch let error as ClientError {
            throw PlusServiceError.transport(error)
        }
    }

    /// Requests disconnection from Nook Plus.
    ///
    /// This keeps the PDS account, its DID, and every record. It is neither
    /// content deletion nor account deletion; a client must not present it as
    /// either.
    public func requestDisconnection(idempotencyKey: String) async throws
        -> Components.Schemas.DisconnectionReceipt
    {
        guard session() != nil else { throw PlusServiceError.sessionInvalid }
        do {
            return try await client.requestServiceDisconnection(
                headers: .init(Idempotency_hyphen_Key: idempotencyKey)
            ).accepted.body.json
        } catch let error as ClientError {
            throw PlusServiceError.transport(error)
        }
    }

    /// CIDs travel as quoted strong entity tags; an unquoted value is
    /// rejected as a malformed request.
    private func quoted(_ cid: String) -> String {
        cid.hasPrefix("\"") ? cid : "\"\(cid)\""
    }
}

extension PlusServiceError {
    /// Maps a problem document to the case a caller should act on.
    public static func from(_ problem: Components.Schemas.Problem) -> PlusServiceError {
        let type = ProblemType(unchecked: problem._type)
        switch type {
        case .invalidSession:
            return .sessionInvalid
        case .recordConflict:
            return .recordConflict
        default:
            return .problem(type, status: problem.status, detail: problem.detail)
        }
    }
}
