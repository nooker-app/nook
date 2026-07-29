import SwiftUI

/// Guided setup for Nook Plus, shared by macOS and iOS.
///
/// Written for someone who has never heard of AT Protocol. Each step explains
/// what it is asking for and why before asking for it, because the earlier
/// version of this screen presented "Handle" and "Deployment" as bare fields
/// and there was no way to guess what either meant.
public struct PlusOnboardingView: View {
    @Bindable var store: PlusStore
    let onFinished: () -> Void

    public init(store: PlusStore, onFinished: @escaping () -> Void) {
        self.store = store
        self.onFinished = onFinished
    }

    /// Where the user is in setup.
    enum Step: Int, CaseIterable {
        case intro
        case invitation
        case address
        case credentials
        case working
        case done

        var progressLabel: String {
            switch self {
            case .intro: String(localized: "Welcome")
            case .invitation: String(localized: "Invitation")
            case .address: String(localized: "Your address")
            case .credentials: String(localized: "Sign-in details")
            case .working: String(localized: "Setting up")
            case .done: String(localized: "Ready")
            }
        }
    }

    @State private var step: Step = .intro
    /// True when the code came from a link, which changes what the invitation
    /// step says if it has to be shown after all.
    @State private var arrivedByLink = false
    @State private var invitationCode = ""
    @State private var invitationChecked = false
    @State private var label = ""
    @State private var availability: Availability = .unknown
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""

    enum Availability: Equatable {
        case unknown
        case checking
        case available(String)
        case unavailable(String)

        var isAvailable: Bool { if case .available = self { true } else { false } }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            Divider()
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(minWidth: 380, minHeight: 460)
        .task { await useInviteLinkIfPresent() }
    }

    /// Consumes a code that arrived by link, checks it, and moves straight to
    /// choosing a name.
    ///
    /// The check still happens: the link saves typing, not verification. An
    /// expired or spent code has to fail here rather than three steps later,
    /// after the user has picked a name and a password.
    private func useInviteLinkIfPresent() async {
        guard invitationCode.isEmpty, let code = PlusInviteInbox.shared.take() else { return }
        invitationCode = code
        arrivedByLink = true
        await store.checkInvitation(code)
        invitationChecked = true
        step = store.invitationAccepted ? .address : .invitation
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Set up publishing", bundle: .module)
                .font(.title2.weight(.semibold))
            Text(step.progressLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .intro: intro
        case .invitation: invitation
        case .address: address
        case .credentials: credentials
        case .working: working
        case .done: done
        }
    }

    // MARK: - Steps

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            explain(
                "What this is",
                "Nook can publish your own writing as a small website with an RSS feed, so anyone can read it in Nook or any other reader."
            )
            explain(
                "Where your posts live",
                "Your posts are stored in a personal repository that belongs to you, not inside Nook's database. If Nook ever disappears, your writing does not."
            )
            explain(
                "What you need",
                "An invitation code. Publishing is limited to invited writers for now."
            )
        }
    }

    private var invitation: some View {
        VStack(alignment: .leading, spacing: 14) {
            explain(
                "Invitation code",
                "The code you were given when you were invited. It looks like four groups of letters and numbers."
            )
            TextField(text: $invitationCode, prompt: Text(verbatim: "XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX")) { Text("Invitation code", bundle: .module) }
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                #if os(iOS)
                    .textInputAutocapitalization(.characters)
                #endif

            if arrivedByLink && !store.invitationAccepted {
                Label {
                    Text("The invitation in that link cannot be used. It may have been used already or expired.", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(.orange)
                .font(.callout)
            }

            if invitationChecked && !arrivedByLink {
                if store.invitationAccepted {
                    Label { Text("This code works.", bundle: .module) } icon: { Image(systemName: "checkmark.circle.fill") }
                        .foregroundStyle(.green)
                        .font(.callout)
                } else {
                    Label {
                        Text("That code was not recognised. It may have been used already or expired.", bundle: .module)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .foregroundStyle(.orange)
                    .font(.callout)
                }
            }
        }
    }

    private var address: some View {
        VStack(alignment: .leading, spacing: 14) {
            explain(
                "Your address",
                "Pick a short name. It becomes both your identity on the network and the address of your site, so choose something you are happy to be known by."
            )

            TextField(text: $label, prompt: Text(verbatim: "yourname")) { Text("Name", bundle: .module) }
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                .onChange(of: label) { _, _ in availability = .unknown }

            if !label.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent {
                        Text(store.fullHandle(for: label))
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    } label: {
                        Text("Your handle", bundle: .module)
                    }
                    LabeledContent {
                        Text(store.publicSiteURL(for: label))
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    } label: {
                        Text("Your site", bundle: .module)
                    }
                }
                .font(.caption)
            }

            switch availability {
            case .unknown:
                Text("Lowercase letters, numbers, and hyphens. At least three characters.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .checking:
                ProgressView().controlSize(.small)
            case .available:
                Label { Text("Available.", bundle: .module) } icon: { Image(systemName: "checkmark.circle.fill") }
                    .foregroundStyle(.green)
                    .font(.callout)
            case .unavailable(let reason):
                Label { Text(verbatim: reason) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 14) {
            explain(
                "Email",
                "Used only to recover your account if you forget your password. It is never shown on your site."
            )
            TextField(text: $email, prompt: Text(verbatim: "you@example.com")) { Text("Email", bundle: .module) }
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                #endif

            explain(
                "Password",
                "Protects your repository. Nook stores it nowhere: it goes straight to the host that keeps your posts."
            )
            SecureField(text: $password) { Text("Password", bundle: .module) }
                .textFieldStyle(.roundedBorder)
            SecureField(text: $confirmPassword) { Text("Repeat password", bundle: .module) }
                .textFieldStyle(.roundedBorder)

            if !password.isEmpty && password.count < 8 {
                Text("At least 8 characters.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if !confirmPassword.isEmpty && password != confirmPassword {
                Text("The two passwords do not match.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProgressView().controlSize(.small)
            Text("Creating your repository and your first publication. This takes a few seconds.", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let failure = store.failure {
                Label { Text(verbatim: failure) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label { Text("You can publish now.", bundle: .module) } icon: { Image(systemName: "checkmark.circle.fill") }
                .foregroundStyle(.green)
                .font(.headline)

            if let session = store.session {
                LabeledContent { Text(verbatim: session.handle) } label: { Text("Handle", bundle: .module) }
            }
            if let url = store.publicationURL {
                LabeledContent {
                    Link(url, destination: URL(string: url) ?? URL(string: "https://example.com")!)
                        .font(.callout.monospaced())
                } label: {
                    Text("Your site", bundle: .module)
                }
            }

            if store.handleResolutionPending {
                // The DNS record exists but has not propagated. The account
                // works regardless, so this is a note, not a warning.
                Text("Your handle is still spreading across the network, which can take a few minutes. Everything works in the meantime.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Navigation

    private var footer: some View {
        HStack {
            if step != .intro && step != .working && step != .done {
                Button { back() } label: { Text("Back", bundle: .module) }
            }
            Spacer()
            primaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .intro:
            Button { step = .invitation } label: { Text("Continue", bundle: .module) }
                .keyboardShortcut(.defaultAction)
        case .invitation:
            Button {
                Task { await checkInvitation() }
            } label: {
                if invitationChecked && store.invitationAccepted {
                    Text("Continue", bundle: .module)
                } else {
                    Text("Check Code", bundle: .module)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(invitationCode.isEmpty || store.isWorking)
        case .address:
            Button {
                Task { await checkAvailability() }
            } label: {
                if availability.isAvailable {
                    Text("Continue", bundle: .module)
                } else {
                    Text("Check Availability", bundle: .module)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(label.isEmpty || store.isWorking)
        case .credentials:
            Button { Task { await createAccount() } } label: { Text("Create Account", bundle: .module) }
                .keyboardShortcut(.defaultAction)
                .disabled(!credentialsReady || store.isWorking)
        case .working:
            Button { Task { await createAccount() } } label: { Text("Try Again", bundle: .module) }
                .disabled(store.isWorking || store.failure == nil)
        case .done:
            Button { onFinished() } label: { Text("Start Writing", bundle: .module) }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var credentialsReady: Bool {
        !email.isEmpty && password.count >= 8 && password == confirmPassword
    }

    private func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private func checkInvitation() async {
        if invitationChecked && store.invitationAccepted {
            step = .address
            return
        }
        await store.checkInvitation(invitationCode)
        invitationChecked = true
        if store.invitationAccepted { step = .address }
    }

    private func checkAvailability() async {
        if availability.isAvailable {
            step = .credentials
            return
        }
        availability = .checking
        let result = await store.checkHandle(label: label)
        switch result {
        case .available(let handle):
            availability = .available(handle)
            step = .credentials
        case .unavailable(let reason):
            availability = .unavailable(reason)
        }
    }

    private func createAccount() async {
        step = .working
        await store.signUp(
            invitationCode: invitationCode,
            label: label,
            email: email,
            password: password
        )
        // The password has served its purpose and must not linger in view state.
        password = ""
        confirmPassword = ""
        step = store.isSignedIn ? .done : .working
    }

    @ViewBuilder
    private func explain(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title, bundle: .module).font(.subheadline.weight(.semibold))
            Text(detail, bundle: .module).font(.callout).foregroundStyle(.secondary)
        }
    }
}
