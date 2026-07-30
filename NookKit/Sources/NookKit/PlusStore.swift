import Foundation
import NookPlusProtocol
import NookPlusServiceAPI
import Observation

/// Where the Plus service lives. Held in `UserDefaults` so a build can be
/// pointed at staging without recompiling; production values are the
/// defaults.
public struct PlusEnvironment: Sendable, Hashable {
    public var apiBaseURL: URL
    public var pdsHost: String
    /// Where public sites are served, used to preview a URL before signup.
    public var publicBaseURL: String
    /// Suffix handles are issued under.
    public var handleDomain: String
    /// Shown in the developer section so it is obvious which server is in use.
    public var name: String

    public init(apiBaseURL: URL, pdsHost: String, publicBaseURL: String, handleDomain: String, name: String) {
        self.apiBaseURL = apiBaseURL
        self.pdsHost = pdsHost
        self.publicBaseURL = publicBaseURL
        self.handleDomain = handleDomain
        self.name = name
    }

    /// The real service. Nothing a user does can change this; only the
    /// developer section can.
    public static let production = PlusEnvironment(
        apiBaseURL: URL(string: "https://api.nooker.app")!,
        pdsHost: "nooker.social",
        publicBaseURL: "https://nooker.app",
        handleDomain: "nooker.app",
        name: String(localized: "Production", bundle: .module)
    )

    /// The test service. Accounts created here are throwaway.
    public static let staging = PlusEnvironment(
        apiBaseURL: URL(string: "https://api.staging.nooker.app")!,
        pdsHost: "pds.staging.nooker.social",
        publicBaseURL: "https://staging.nooker.app",
        handleDomain: "staging.nooker.app",
        name: String(localized: "Staging (test server)", bundle: .module)
    )

    public static let all: [PlusEnvironment] = [production, staging]

    static let selectionKey = "nookPlusEnvironment"

    /// The selected environment, production unless a developer changed it.
    public static var current: PlusEnvironment {
        let name = UserDefaults.standard.string(forKey: selectionKey)
        return all.first { $0.handleDomain == name } ?? production
    }

    /// Switches deployments. Exposed only through the developer section: a
    /// reader has no reason to know this exists, and picking wrong would create
    /// an account on a server their handle does not belong to.
    public static func select(_ environment: PlusEnvironment) {
        UserDefaults.standard.set(environment.handleDomain, forKey: selectionKey)
    }
}

/// Result of checking whether a name can be claimed.
public enum HandleCheck: Equatable, Sendable {
    case available(String)
    case unavailable(String)
}

/// Observable state for the Plus surface.
///
/// Deliberately separate from `ReaderStore`: Plus is opt-in, and the reader
/// must keep working with no account and no network. Nothing here is on the
/// reading path.
@MainActor
@Observable
public final class PlusStore {
    /// A new session is proof the expiry has been dealt with, wherever it came
    /// from — a refresh, a sign-in, or signing out.
    public private(set) var session: PlusSession? {
        didSet { if session != oldValue, sessionExpired { sessionExpired = false } }
    }
    /// Mirrored into defaults on every change, so the Feeds screen can offer the
    /// writer their own publication without holding a store or making a call.
    /// Observed here rather than at each call site because signup, loading content,
    /// and signing out all change it, and one of them would eventually be missed.
    public private(set) var publications: [ATRecord<PublicationRecord>] = [] {
        didSet { PlusOwnFeed.remember(publicationURL: publicationURL) }
    }
    public private(set) var articles: [ATRecord<ArticleRecord>] = []
    public private(set) var isWorking = false
    /// User-facing message for the last failure, if any.
    public private(set) var failure: String?
    /// The post just published, for the caller that shows it in the reader.
    /// Belongs to one publish rather than to the store's lifetime, so opening the
    /// composer again clears it: it used to survive, and the next draft opened with
    /// a link to the previous post still on screen.
    public private(set) var lastPublishedURL: String?
    /// Whether the last checked invitation code was usable.
    public private(set) var invitationAccepted = false
    /// True when signup succeeded but the handle has not propagated yet. The
    /// account works regardless, so this is a note rather than a failure.
    public private(set) var handleResolutionPending = false
    /// True when signup found the account already created and the submitted
    /// password did not open it. Nothing is broken — the remedy is to sign in
    /// with the original password, so the UI offers that instead of a retry
    /// that cannot succeed.
    public private(set) var signupNeedsSignIn = false
    /// Which field the last failure blames, when the service named one. A screen
    /// that reports "use a different email address" has to be able to send the
    /// user to the email field; otherwise the instruction is impossible to
    /// follow.
    public private(set) var failureField: ProblemReason.Field?

    private var environment: PlusEnvironment
    private var pds: PlusPDSClient
    private var service: PlusServiceClient

    public init(environment: PlusEnvironment = .current) {
        self.environment = environment
        self.pds = PlusPDSClient(host: environment.pdsHost, issuedDomains: [environment.handleDomain])
        self.service = PlusServiceClient(baseURL: environment.apiBaseURL)
        self.session = PlusCredential.current
    }

    public var isSignedIn: Bool { session != nil }

    /// The deployment in use. Read by screens that need to show what a name will
    /// become; they must not read `PlusEnvironment.current` themselves, or a
    /// developer switch would leave the two disagreeing.
    public var currentEnvironment: PlusEnvironment { environment }

    /// Clears the last failure, for a screen where the user has changed
    /// something and the old message no longer describes anything.
    ///
    /// Writes nothing when there is nothing to clear. Observation fires on write
    /// rather than on change, so an unconditional assignment invalidates every
    /// observer — which, called while a sheet was being presented, dismissed it
    /// on the spot.
    public func clearFailure() {
        if failure != nil { failure = nil }
        if signupNeedsSignIn { signupNeedsSignIn = false }
        if failureField != nil { failureField = nil }
    }

    /// Switches deployments: persists the choice, rebuilds the clients, and
    /// forgets the session.
    ///
    /// One call rather than three, and it goes through the store so the change is
    /// observed. Reading the choice back from `UserDefaults` is not: SwiftUI does
    /// not watch it, so the screen kept showing the old server and the button
    /// that made the change looked like it had done nothing.
    public func select(_ environment: PlusEnvironment) {
        guard environment != self.environment else { return }
        PlusEnvironment.select(environment)
        use(environment)
        signOut()
    }

    /// Reloads the client pair after the environment changes.
    public func use(_ environment: PlusEnvironment) {
        self.environment = environment
        self.pds = PlusPDSClient(host: environment.pdsHost, issuedDomains: [environment.handleDomain])
        self.service = PlusServiceClient(baseURL: environment.apiBaseURL)
    }

    /// The full handle a chosen name would produce, shown while typing so the
    /// user can see what they are actually getting.
    public func fullHandle(for label: String) -> String {
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return clean.isEmpty ? "" : "\(clean).\(environment.handleDomain)"
    }

    /// The public site URL a chosen name would produce.
    public func publicSiteURL(for label: String) -> String {
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return clean.isEmpty ? "" : "\(environment.publicBaseURL)/@\(clean)"
    }

    /// Checks an invitation code before asking for anything else, so a bad code
    /// is caught at the step where it can still be corrected.
    public func checkInvitation(_ code: String) async {
        invitationAccepted = false
        await perform {
            self.invitationAccepted = try await self.service.verifyInvitation(
                code: code.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Checks whether a name can be claimed, translating the service's reason
    /// codes into something a person can act on.
    public func checkHandle(label: String) async -> HandleCheck {
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var outcome = HandleCheck.unavailable(String(localized: "Could not check that name.", bundle: .module))
        await perform {
            let result = try await self.service.handleAvailability(handle: self.fullHandle(for: clean))
            if result.available {
                outcome = .available(result.handle)
            } else {
                outcome = .unavailable(Self.explain(reason: result.reason))
            }
        }
        if let failure { outcome = .unavailable(failure) }
        return outcome
    }

    private static func explain(reason: String?) -> String {
        switch reason {
        case "taken":
            return String(localized: "Someone already has that name.", bundle: .module)
        case "reserved":
            return String(localized: "That name is reserved.", bundle: .module)
        default:
            return String(localized: "Use lowercase letters, numbers, and hyphens, at least three characters.", bundle: .module)
        }
    }

    /// Creates an account and signs in.
    ///
    /// The idempotency key is generated once per attempt and kept for retries,
    /// so pressing "Try Again" resumes the same signup rather than starting a
    /// second one — which would otherwise create a second identity.
    private var signupKey: String?
    /// The code and name the current key was minted for.
    ///
    /// A key belongs to one signup, and the service rejects it outright if it
    /// arrives with a different code or handle. Without remembering what it was
    /// for, a user who corrected either — exactly what a rejection tells them to
    /// do — was permanently stuck on "this idempotency key was used for a
    /// different signup", with no way out but relaunching the app.
    private var signupIdentity: SignupIdentity?

    private struct SignupIdentity: Equatable {
        let code: String
        let handle: String
    }

    public func signUp(invitationCode: String, label: String, email: String, password: String) async {
        let identity = SignupIdentity(
            code: invitationCode.trimmingCharacters(in: .whitespacesAndNewlines),
            handle: fullHandle(for: label)
        )
        // A changed code or name is a different signup, so it needs a key of its
        // own. Reusing the old one is refused by the service and cannot be
        // recovered from within the flow.
        if signupIdentity != identity {
            signupKey = nil
            signupIdentity = identity
        }
        let key = signupKey ?? UUID().uuidString
        signupKey = key
        signupNeedsSignIn = false
        failureField = nil
        isWorking = true
        failure = nil

        do {
            let result = try await service.signUp(
                idempotencyKey: key,
                invitationCode: invitationCode.trimmingCharacters(in: .whitespacesAndNewlines),
                handle: fullHandle(for: label),
                displayName: label,
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            let session = PlusSession(
                did: result.did,
                handle: result.handle,
                accessJWT: result.session.accessJwt,
                refreshJWT: result.session.refreshJwt
            )
            _ = PlusCredential.store(session)
            self.session = session
            handleResolutionPending = !(result.handleResolves ?? true)
            signupKey = nil
            signupIdentity = nil
            await loadContent()
        } catch PlusServiceError.rejected(.accountPasswordMismatch, _) {
            // Not a failure to fix by retrying: the account exists and only the
            // password is wrong, so the flow moves to signing in.
            signupNeedsSignIn = true
            failure = PlusStore.message(for: .accountPasswordMismatch)
        } catch PlusServiceError.rejected(let reason, _) {
            failure = PlusStore.message(for: reason)
            failureField = reason.offendingField
        } catch {
            failure = message(for: error)
        }
        isWorking = false
    }

    /// Whether a post can be published right now: signed in, with a publication
    /// to publish into, and nothing else in flight.
    public var canPublish: Bool {
        isSignedIn && !publications.isEmpty && !isWorking
    }

    /// The publication's public URL without a trailing slash, for showing what an
    /// address will become. Nil until the publication is known.
    public var publicationBaseURL: String? { publicationURL }

    /// The publication's public URL, once known.
    public var publicationURL: String? {
        guard let slug = publications.first?.value.slug else { return nil }
        return "\(environment.publicBaseURL)/@\(slug)"
    }

    /// Whether a reset code has been requested, so the UI can ask for it.
    public private(set) var passwordResetRequested = false

    /// Asks the repository host to email a reset code.
    ///
    /// Succeeds whether or not the address has an account: the host does not say,
    /// and neither does this, because answering would let anyone test addresses.
    public func requestPasswordReset(email: String) async {
        isWorking = true
        failure = nil
        do {
            try await pds.requestPasswordReset(email: email)
            passwordResetRequested = true
        } catch PlusPDSError.upstream(let status, _, _) where status == 400 {
            // A 400 from this endpoint means the host found no account for the
            // address. Its own wording is "account does not have an email
            // address", which describes the row it looked at rather than the
            // thing the user needs to know. Decided by status and endpoint rather
            // than by matching that prose, which is not ours to depend on.
            failure = String(
                localized: "No publishing account uses this email address. Check it for typos, or set up publishing first.",
                bundle: .module
            )
        } catch PlusPDSError.upstream(let status, _, _) where status >= 500 {
            // The host answers 500 when it cannot send the mail, which says
            // nothing about why. Every reachable cause is on the sending side, so
            // the message points there rather than at the address the user just
            // typed correctly.
            failure = String(
                localized: "The server could not send the email. It may not be able to send to this address yet. Ask whoever runs the server.",
                bundle: .module
            )
        } catch {
            failure = message(for: error)
        }
        isWorking = false
    }

    /// Sets a new password from the emailed code, then signs in with it.
    ///
    /// Signing in straight after is the point: the user came here locked out, and
    /// a screen that says "password changed" and then asks them to log in again
    /// has stopped one step short.
    public func resetPassword(identifier: String, token: String, newPassword: String) async {
        await perform {
            try await self.pds.resetPassword(token: token, newPassword: newPassword)
            self.passwordResetRequested = false
            let session = try await self.pds.signIn(
                identifier: identifier.trimmingCharacters(in: .whitespacesAndNewlines),
                password: newPassword
            )
            _ = PlusCredential.store(session)
            self.session = session
            await self.loadContent()
        }
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

    // MARK: - Taking a copy away

    /// The archive, once it has been fetched onto this device.
    public private(set) var exportFile: URL?

    /// True while an export is being built and fetched, which takes a round trip or
    /// two more than most things here.
    public private(set) var isExporting = false

    /// Builds an export and downloads it, leaving a file to share.
    ///
    /// The bytes are fetched here rather than the download link being handed to the
    /// UI. That link is a bearer credential — anyone holding it can read the archive
    /// until it expires — so putting it into a share sheet would invite it into a
    /// message or a clipboard. Downloading first means what gets shared is a file,
    /// which is what somebody asking for a copy of their writing actually wants.
    ///
    /// Polls, because the service answers 202 with whatever status it reached. In
    /// practice a repository small enough to render is small enough to package in the
    /// request, so this usually completes on the first answer.
    public func exportWriting() async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }

        exportFile = nil
        await perform {
            var job = try await self.service.requestExport(idempotencyKey: UUID().uuidString)

            // Bounded: a job that never finishes must not spin here forever. Five
            // attempts over about fifteen seconds, after which the writer is told to
            // try again rather than left watching a spinner.
            for attempt in 0..<5 where job.status == .pending || job.status == .processing {
                try await Task.sleep(for: .seconds(attempt == 0 ? 1 : 3))
                job = try await self.service.getExport(id: job.id)
            }

            switch job.status {
            case .completed:
                break
            case .failed:
                throw PlusExportError.serviceFailed
            case .pending, .processing:
                throw PlusExportError.stillWorking
            }
            guard let link = job.downloadUrl, let url = URL(string: link) else {
                throw PlusExportError.noDownloadLink
            }
            self.exportFile = try await self.downloadArchive(from: url)
        }
    }

    /// Fetches the archive into a file this device owns.
    private func downloadArchive(from url: URL) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PlusExportError.downloadFailed(status: http.statusCode)
        }
        // Named for a person looking at it in Files, and dated so two exports do not
        // overwrite one another.
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withFullDate]
        let name = "nook-export-\(stamp.string(from: Date())).json"
        let file = FileManager.default.temporaryDirectory.appending(path: name)
        try data.write(to: file, options: .atomic)
        return file
    }

    /// Clears a fetched archive, for a screen that has finished with it.
    public func clearExportFile() {
        if exportFile != nil { exportFile = nil }
    }

    // MARK: - Leaving the service

    /// Set once a disconnection has been accepted, so the screen can report what
    /// happened rather than simply emptying itself.
    public private(set) var disconnected = false

    /// Leaves Nook Plus, keeping everything the writer owns.
    ///
    /// Three different things get called "delete my account" and this is the middle
    /// one. It removes the membership, the service's operational data, and every
    /// public page the service generated. It does **not** touch the repository: the
    /// account, its DID, its handle, and every publication and article stay exactly
    /// as they are, and the writer can still read and export them.
    ///
    /// Signing out locally afterwards because the membership is gone: leaving the
    /// session in place would present a signed-in Plus screen for an account the
    /// service no longer knows. The draft files are deliberately left alone — they
    /// are the writer's, were never the service's, and deleting them here would be
    /// this method quietly doing the one thing it promises not to.
    public func disconnect() async {
        var accepted = false
        await perform {
            _ = try await self.service.requestDisconnection(idempotencyKey: UUID().uuidString)
            accepted = true
        }
        guard accepted, failure == nil else { return }
        signOut()
        disconnected = true
    }

    /// Clears the confirmation, for a screen that has shown it.
    public func acknowledgeDisconnection() {
        if disconnected { disconnected = false }
    }

    /// Reads publications and articles from the PDS, which is authoritative.
    public func loadContent() async {
        guard let did = session?.did else { return }
        await perform {
            self.publications = try await self.pds.publications(did: did)
            self.articles = try await self.pds.articles(did: did)
        }
    }

    /// Exchanges the refresh token when the access token is spent.
    ///
    /// The PDS issues an access token that lasts hours and a refresh token that lasts
    /// months. Nook had `refresh` implemented and called it from nowhere, so the
    /// first token's expiry looked like being signed out: a writer mid-draft was
    /// asked for their password again, hours after signing in, with a valid refresh
    /// token sitting in the Keychain the whole time.
    ///
    /// Failing to refresh is not treated as being signed out. The session is left in
    /// place and the writer is told what happened, because clearing it here would
    /// take a draft down with it for what may be a network problem.
    ///
    /// Returns whether the session is fit to make a request with, having set a
    /// message when it is not.
    @discardableResult
    private func refreshSessionIfExpired(now: Date = Date()) async -> Bool {
        guard let current = session else { return false }
        guard PlusJWT.isExpired(current.accessJWT, now: now) else { return true }
        do {
            let renewed = try await pds.refresh(current)
            // The Keychain is what the API client reads its token from, not this
            // property, so a failed write means the next request still carries the
            // spent token. Treated as an expiry rather than reported as success.
            guard PlusCredential.store(renewed) else {
                sessionExpired = true
                return false
            }
            session = renewed
            return true
        } catch let error as PlusPDSError {
            if case .transport(let cause) = error {
                // Being unable to reach the host is not an expired session. Asking
                // for a password because the network is down would be a lie, and
                // signing in is the one thing that cannot be done offline.
                failure = unreachableMessage(cause)
                return false
            }
            // The host rejected the refresh token itself. This is the only case where
            // signing in again really is the remedy, and saying so is more use than
            // the host's prose.
            sessionExpired = true
            return false
        } catch {
            failure = message(for: error)
            return false
        }
    }

    /// Set when the session could not be renewed, so a screen can ask for a sign-in
    /// rather than reporting a failure the writer cannot act on.
    public private(set) var sessionExpired = false

    /// Re-reads the stored session and reloads what belongs to it.
    ///
    /// The composer keeps its own store so a cancelled draft survives, and that store
    /// read the Keychain once when it was built. Signing in again happens on another
    /// screen with another store, so the composer went on holding the dead session:
    /// `canPublish` stayed false and Publish stayed disabled until the app was
    /// relaunched, with the writing still on screen.
    public func prepareToCompose() async {
        startNewDraft()
        let stored = PlusCredential.current
        if stored != session {
            session = stored
            // They belong to the session that was replaced, not to this one.
            if !publications.isEmpty { publications = [] }
            if !articles.isEmpty { articles = [] }
        }
        guard isSignedIn else { return }
        if publications.isEmpty {
            await loadContent()
        } else {
            // Nothing to load, but the token may still have expired while the app sat
            // in the background.
            await refreshSessionIfExpired()
        }
    }

    /// Clears what belonged to the last publish, for a composer being opened
    /// again.
    ///
    /// The store outlives the composer sheet so a cancelled draft survives, which
    /// also meant the previous post's confirmation did: reopening the composer
    /// showed a link to something already published.
    /// Writes only what has actually changed. This runs while the composer sheet is
    /// being presented, and an unconditional write to observed state invalidates the
    /// presenting view — which dismisses the sheet on the spot. Same reasoning as
    /// ``clearFailure``.
    public func startNewDraft() {
        if lastPublishedURL != nil { lastPublishedURL = nil }
        clearFailure()
    }

    /// Publishes an article through the service, which writes the PDS record
    /// and schedules rendering.
    public func publish(title: String, slug: String, markdown: String, summary: String) async {
        guard let publication = publications.first else {
            failure = String(localized: "No publication to publish into yet.", bundle: .module)
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

    /// Replaces a published article with an edited version.
    ///
    /// Separate from ``publish`` because it is a different act: the record keeps its
    /// identity, so links to it keep working and the record-key alias is unchanged.
    /// Changing the slug moves the readable URL and leaves the old one dead, which is
    /// the writer's decision to make and the UI's job to say.
    public func update(
        _ record: ATRecord<ArticleRecord>,
        title: String,
        slug: String,
        markdown: String,
        summary: String
    ) async {
        guard let rkey = record.recordKey else {
            failure = String(
                localized: "That article is missing the information needed to edit it.",
                bundle: .module)
            return
        }
        let cid = record.cid?.trimmingCharacters(in: .whitespacesAndNewlines)
        await perform {
            let article = try await self.service.updateArticle(
                recordKey: rkey,
                cid: (cid?.isEmpty ?? true) ? nil : cid,
                publication: record.value.publication,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                slug: slug.trimmingCharacters(in: .whitespacesAndNewlines),
                markdown: markdown,
                summary: summary.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            self.lastPublishedURL = article.url
            await self.loadContent()
        }
    }

    // MARK: - Drafts

    /// Unpublished writing on this device, newest first.
    public private(set) var drafts: [PlusDraft] = []

    /// Opened lazily and kept, so a reader who never writes pays nothing for it. Nil
    /// when the directory could not be made, which leaves drafts unavailable rather
    /// than crashing — the reader is unaffected either way.
    private var draftStore: PlusDraftStore? = {
        try? PlusDraftStore.default()
    }()

    /// Whether drafts can be kept at all. False only if the store could not be
    /// opened, in which case the UI must not offer to keep one.
    public var canKeepDrafts: Bool { draftStore != nil }

    public func loadDrafts() {
        guard let draftStore else { return }
        drafts = draftStore.all()
    }

    /// Saves a draft, or removes it if there is nothing left in it.
    ///
    /// Deleting an emptied draft rather than keeping it: a list filling with blank
    /// rows because a screen was opened and closed is worse than losing nothing.
    public func save(_ draft: PlusDraft) {
        guard let draftStore else {
            failure = String(
                localized: "Drafts cannot be saved on this device.", bundle: .module)
            return
        }
        if draft.isEmpty {
            draftStore.delete(draft.id)
        } else {
            do {
                try draftStore.save(draft)
            } catch {
                // The only copy failed to write, and saying nothing would let the
                // writer close the screen believing it was kept.
                failure = String(
                    localized: "That draft could not be saved. Copy your text somewhere safe before closing.",
                    bundle: .module)
                return
            }
        }
        loadDrafts()
    }

    public func discard(_ draft: PlusDraft) {
        draftStore?.delete(draft.id)
        loadDrafts()
    }

    /// Removes a published post from the web while keeping its text as a draft.
    ///
    /// The record is deleted, which is what makes it not public — that is what a PDS
    /// record means. The text is written locally first, so a failure to delete leaves
    /// a draft rather than nothing, and the writer can try again.
    ///
    /// Republishing makes a *new* record, so the record-key alias changes. The slug is
    /// carried over, so the readable URL is the one it had.
    public func unpublish(_ record: ATRecord<ArticleRecord>) async {
        guard canKeepDrafts else {
            failure = String(
                localized: "Drafts cannot be saved on this device.", bundle: .module)
            return
        }
        save(
            PlusDraft(
                title: record.value.title,
                slug: record.value.slug,
                summary: record.value.summary ?? "",
                markdown: record.value.content,
                wasPublished: true
            ))
        // Only if the draft is safely on disk. Deleting first would risk removing the
        // post and losing the text.
        guard failure == nil else { return }
        await delete(record)
    }

    /// Deletes an article, conditioned on the CID last read where there is one, so a
    /// revision the user has not seen is not destroyed silently.
    ///
    /// A missing or empty CID no longer refuses the deletion. The record key is what
    /// identifies the record, and the service treats an absent `If-Match` as an
    /// unconditional delete by design; refusing instead left the writer unable to
    /// remove their own post at all, which is worse than the edge case the condition
    /// guards against — a revision made on another device between the list being read
    /// and the delete being tapped.
    ///
    /// An empty string mattered as much as nil: it passed a `let cid` binding and then
    /// went out as `If-Match: ""`, which the service rejects as malformed.
    public func delete(_ record: ATRecord<ArticleRecord>) async {
        guard let rkey = record.recordKey else {
            failure = String(localized: "That article is missing the information needed to delete it safely.", bundle: .module)
            return
        }
        let cid = record.cid?.trimmingCharacters(in: .whitespacesAndNewlines)
        await perform {
            try await self.service.deleteArticle(
                recordKey: rkey, cid: (cid?.isEmpty ?? true) ? nil : cid)
            await self.loadContent()
        }
    }

    /// Runs work with a single place for the busy flag and error reporting, so
    /// no caller can forget either.
    private func perform(_ work: @escaping () async throws -> Void) async {
        isWorking = true
        failure = nil
        // Renewed before the work, not retried after it fails. The work is not always
        // idempotent — retrying a publish that had already been written would make a
        // second post — so a spent token is replaced first and the work runs once.
        //
        // Only when there is a session to renew: signing up and signing in come
        // through here too, and they are how a session comes to exist.
        if session != nil, await !refreshSessionIfExpired() {
            if sessionExpired {
                // Said here rather than letting the work fail on its own: the host
                // answers a spent token with "ExpiredToken", which by the time it
                // reaches a message reads as a bad password-reset code.
                failure = String(
                    localized: "Your session has expired. Sign in again to continue.", bundle: .module)
            }
            // Any other reason already left its own message, and it is a better one
            // than "sign in again" — a network that is down is not an expiry.
            isWorking = false
            return
        }
        do {
            try await work()
        } catch PlusServiceError.rejected(let reason, _) {
            failure = PlusStore.message(for: reason)
            failureField = reason.offendingField
        } catch {
            failure = message(for: error)
        }
        isWorking = false
    }

    /// The user-facing sentence for a named cause.
    ///
    /// Written here rather than taken from the response so it is translated and
    /// says what to do next. The service's own `detail` is English prose meant
    /// for a log.
    static func message(for reason: ProblemReason) -> String {
        switch reason {
        case .emailAlreadyUsed:
            String(localized: "Another account already uses this email address. Use a different one.", bundle: .module)
        case .emailInvalid:
            String(localized: "That email address was not accepted. Check it for typos.", bundle: .module)
        case .passwordTooWeak:
            String(localized: "That password is too weak. Use a longer one.", bundle: .module)
        case .handleTaken:
            String(localized: "That name is already taken. Choose another.", bundle: .module)
        case .handleInvalid:
            String(localized: "That name cannot be used. Use lowercase letters, numbers, and hyphens.", bundle: .module)
        case .invitationNotFound:
            String(localized: "That invitation was not recognised.", bundle: .module)
        case .invitationExpired:
            String(localized: "That invitation has expired. Ask for a new one.", bundle: .module)
        case .invitationExhausted:
            String(localized: "That invitation has already been used up. Ask for a new one.", bundle: .module)
        case .accountPasswordMismatch:
            String(localized: "An account with this name already exists. Sign in with the password you chose when you created it.", bundle: .module)
        case .repositoryHostRejected:
            String(localized: "The server that stores your posts refused these details. Try a different email address or password.", bundle: .module)
        }
    }

    private func message(for error: any Error) -> String {
        if let plus = error as? PlusServiceError {
            switch plus {
            case .sessionInvalid:
                // The stored session is no longer usable; clearing it puts the
                // UI back into a state the user can act on.
                PlusCredential.signOut()
                session = nil
                return String(localized: "Your session expired. Sign in again.", bundle: .module)
            case .recordConflict:
                return String(localized: "This article changed elsewhere. Reload before saving again.", bundle: .module)
            case .problem(_, _, let detail):
                // A cause the user can act on arrives as a `reason` and is
                // translated above. This is what is left: a type this build does
                // not recognise. Showing the service's own sentence is untidy —
                // it is English, written for a log — but it names what happened,
                // and "could not complete that request" names nothing at all.
                if let detail, !detail.isEmpty {
                    return detail
                }
                return String(localized: "The service could not complete that request.", bundle: .module)
            case .rejected(let reason, _):
                return PlusStore.message(for: reason)
            case .transport(let cause):
                return unreachableMessage(cause)
            }
        }
        if let pdsError = error as? PlusPDSError {
            if case .transport(let cause) = pdsError {
                return unreachableMessage(cause)
            }
            return pdsError.errorDescription ?? String(localized: "Something went wrong.", bundle: .module)
        }
        return unreachableMessage(error)
    }

    /// What to say when the service could not be reached.
    ///
    /// A host that does not resolve is not the same failure as a network that is
    /// down, and the difference matters: the first one is almost always a build
    /// pointed at a deployment that does not exist, and the raw
    /// "could not find a server with the specified hostname" gives the user
    /// nothing to act on. Naming the deployment turns it into a one-tap fix.
    private func unreachableMessage(_ error: any Error) -> String {
        let url = error as? URLError
        if url?.code == .cannotFindHost || url?.code == .dnsLookupFailed {
            return String(
                localized:
                    "The \(environment.name) server is not reachable: there is no such host as \(environment.pdsHost). Check the server in Developer settings.",
                bundle: .module
            )
        }
        if url?.code == .notConnectedToInternet || url?.code == .networkConnectionLost {
            return String(localized: "No network connection.", bundle: .module)
        }
        // Names the reason the system gave. It is not always graceful, but a user
        // looking at a failure needs to know whether it was a timeout, a refused
        // connection, or a certificate, and a single sentence covering all three
        // tells them none of it.
        if let url {
            return String(
                localized: "Could not reach the service: \(url.localizedDescription)", bundle: .module)
        }
        return String(localized: "Could not reach the service.", bundle: .module)
    }
}

/// What can go wrong building an export, in the writer's terms.
///
/// Separate cases rather than one message, because the remedies differ: "try again
/// in a moment" and "something on the service failed" are different situations and
/// a single sentence covering both would be useful for neither.
enum PlusExportError: Error, LocalizedError {
    /// The service reported the job as failed.
    case serviceFailed
    /// Still being built when the client stopped waiting.
    case stillWorking
    /// Completed, but with no link to fetch — a service-side problem.
    case noDownloadLink
    /// The archive could not be fetched.
    case downloadFailed(status: Int)

    var errorDescription: String? {
        switch self {
        case .serviceFailed:
            return String(
                localized: "Your export could not be prepared. Try again in a few minutes.",
                bundle: .module)
        case .stillWorking:
            return String(
                localized: "Your export is still being prepared. Try again in a moment.",
                bundle: .module)
        case .noDownloadLink:
            return String(
                localized: "Your export was prepared but could not be downloaded. Try again.",
                bundle: .module)
        case .downloadFailed(let status):
            // The status is included: a 403 means the link expired while it was being
            // used, which is a different thing from the service being unreachable,
            // and somebody reporting the problem should be able to say which.
            return String(
                localized: "Your export could not be downloaded (\(status)). Try again.",
                bundle: .module)
        }
    }
}
