import Foundation
import NookPlusProtocol
import Observation

/// Where the Plus service lives. Held in `UserDefaults` so a build can be
/// pointed at staging without recompiling; production values are the
/// defaults.
public struct PlusEnvironment: Sendable, Equatable {
    public var apiBaseURL: URL
    public var pdsHost: String

    public init(apiBaseURL: URL, pdsHost: String) {
        self.apiBaseURL = apiBaseURL
        self.pdsHost = pdsHost
    }

    static let apiKey = "nookPlusAPIBaseURL"
    static let pdsKey = "nookPlusPDSHost"

    /// Reads the configured environment, falling back to production.
    public static var current: PlusEnvironment {
        let defaults = UserDefaults.standard
        let api =
            (defaults.string(forKey: apiKey).flatMap(URL.init(string:)))
            ?? URL(string: "https://api.nooker.app")!
        let pds = defaults.string(forKey: pdsKey) ?? "nooker.social"
        return PlusEnvironment(apiBaseURL: api, pdsHost: pds)
    }

    /// Points this install at a different deployment.
    public static func select(apiBaseURL: URL, pdsHost: String) {
        UserDefaults.standard.set(apiBaseURL.absoluteString, forKey: apiKey)
        UserDefaults.standard.set(pdsHost, forKey: pdsKey)
    }
}

/// Observable state for the Plus surface.
///
/// Deliberately separate from `ReaderStore`: Plus is opt-in, and the reader
/// must keep working with no account and no network. Nothing here is on the
/// reading path.
@MainActor
@Observable
public final class PlusStore {
    public private(set) var session: PlusSession?
    public private(set) var publications: [ATRecord<PublicationRecord>] = []
    public private(set) var articles: [ATRecord<ArticleRecord>] = []
    public private(set) var isWorking = false
    /// User-facing message for the last failure, if any.
    public private(set) var failure: String?
    /// Set after a successful publish so the UI can confirm it.
    public private(set) var lastPublishedURL: String?

    private var environment: PlusEnvironment
    private var pds: PlusPDSClient
    private var service: PlusServiceClient

    public init(environment: PlusEnvironment = .current) {
        self.environment = environment
        self.pds = PlusPDSClient(host: environment.pdsHost)
        self.service = PlusServiceClient(baseURL: environment.apiBaseURL)
        self.session = PlusCredential.current
    }

    public var isSignedIn: Bool { session != nil }

    /// Reloads the client pair after the environment changes.
    public func use(_ environment: PlusEnvironment) {
        self.environment = environment
        self.pds = PlusPDSClient(host: environment.pdsHost)
        self.service = PlusServiceClient(baseURL: environment.apiBaseURL)
    }

    public func signIn(handle: String, password: String) async {
        await perform {
            let session = try await self.pds.signIn(
                identifier: handle.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            _ = PlusCredential.store(session)
            self.session = session
            await self.loadContent()
        }
    }

    /// Signs out of this device only. The account and its records are
    /// untouched — this is not deletion and must never be presented as such.
    public func signOut() {
        PlusCredential.signOut()
        session = nil
        publications = []
        articles = []
        lastPublishedURL = nil
        failure = nil
    }

    /// Reads publications and articles from the PDS, which is authoritative.
    public func loadContent() async {
        guard let did = session?.did else { return }
        await perform {
            self.publications = try await self.pds.publications(did: did)
            self.articles = try await self.pds.articles(did: did)
        }
    }

    /// Publishes an article through the service, which writes the PDS record
    /// and schedules rendering.
    public func publish(title: String, slug: String, markdown: String, summary: String) async {
        guard let publication = publications.first else {
            failure = String(localized: "No publication to publish into yet.")
            return
        }
        await perform {
            let article = try await self.service.createArticle(
                publication: publication.uri,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                slug: slug.trimmingCharacters(in: .whitespacesAndNewlines),
                markdown: markdown,
                summary: summary.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            self.lastPublishedURL = article.url
            await self.loadContent()
        }
    }

    /// Deletes an article, conditioned on the CID last read so a revision the
    /// user has not seen cannot be destroyed.
    public func delete(_ record: ATRecord<ArticleRecord>) async {
        guard let rkey = record.recordKey, let cid = record.cid else {
            failure = String(localized: "That article is missing the information needed to delete it safely.")
            return
        }
        await perform {
            try await self.service.deleteArticle(recordKey: rkey, cid: cid)
            await self.loadContent()
        }
    }

    /// Runs work with a single place for the busy flag and error reporting, so
    /// no caller can forget either.
    private func perform(_ work: @escaping () async throws -> Void) async {
        isWorking = true
        failure = nil
        do {
            try await work()
        } catch {
            failure = message(for: error)
        }
        isWorking = false
    }

    private func message(for error: any Error) -> String {
        if let plus = error as? PlusServiceError {
            switch plus {
            case .sessionInvalid:
                // The stored session is no longer usable; clearing it puts the
                // UI back into a state the user can act on.
                PlusCredential.signOut()
                session = nil
                return String(localized: "Your session expired. Sign in again.")
            case .recordConflict:
                return String(localized: "This article changed elsewhere. Reload before saving again.")
            case .problem(_, _, let detail):
                return detail ?? String(localized: "The service could not complete that request.")
            case .transport:
                return String(localized: "Could not reach the service.")
            }
        }
        if let pdsError = error as? PlusPDSError {
            return pdsError.errorDescription ?? String(localized: "Something went wrong.")
        }
        return error.localizedDescription
    }
}
