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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Set up publishing")
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
            TextField("Invitation code", text: $invitationCode, prompt: Text(verbatim: "XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX"))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                #if os(iOS)
                    .textInputAutocapitalization(.characters)
                #endif

            if invitationChecked {
                if store.invitationAccepted {
                    Label("This code works.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                } else {
                    Label(
                        "That code was not recognised. It may have been used already or expired.",
                        systemImage: "exclamationmark.triangle"
                    )
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

            TextField("Name", text: $label, prompt: Text(verbatim: "yourname"))
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
                        Text("Your handle")
                    }
                    LabeledContent {
                        Text(store.publicSiteURL(for: label))
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    } label: {
                        Text("Your site")
                    }
                }
                .font(.caption)
            }

            switch availability {
            case .unknown:
                Text("Lowercase letters, numbers, and hyphens. At least three characters.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .checking:
                ProgressView().controlSize(.small)
            case .available:
                Label("Available.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            case .unavailable(let reason):
                Label(reason, systemImage: "exclamationmark.triangle")
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
            TextField("Email", text: $email, prompt: Text(verbatim: "you@example.com"))
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
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
            SecureField("Repeat password", text: $confirmPassword)
                .textFieldStyle(.roundedBorder)

            if !password.isEmpty && password.count < 8 {
                Text("At least 8 characters.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if !confirmPassword.isEmpty && password != confirmPassword {
                Text("The two passwords do not match.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProgressView().controlSize(.small)
            Text("Creating your repository and your first publication. This takes a few seconds.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let failure = store.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("You can publish now.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)

            if let session = store.session {
                LabeledContent("Handle", value: session.handle)
            }
            if let url = store.publicationURL {
                LabeledContent("Your site") {
                    Link(url, destination: URL(string: url) ?? URL(string: "https://example.com")!)
                        .font(.callout.monospaced())
                }
            }

            if store.handleResolutionPending {
                // The DNS record exists but has not propagated. The account
                // works regardless, so this is a note, not a warning.
                Text("Your handle is still spreading across the network, which can take a few minutes. Everything works in the meantime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Navigation

    private var footer: some View {
        HStack {
            if step != .intro && step != .working && step != .done {
                Button("Back") { back() }
            }
            Spacer()
            primaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .intro:
            Button("Continue") { step = .invitation }
                .keyboardShortcut(.defaultAction)
        case .invitation:
            Button(invitationChecked && store.invitationAccepted ? "Continue" : "Check Code") {
                Task { await checkInvitation() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(invitationCode.isEmpty || store.isWorking)
        case .address:
            Button(availability.isAvailable ? "Continue" : "Check Availability") {
                Task { await checkAvailability() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(label.isEmpty || store.isWorking)
        case .credentials:
            Button("Create Account") { Task { await createAccount() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!credentialsReady || store.isWorking)
        case .working:
            Button("Try Again") { Task { await createAccount() } }
                .disabled(store.isWorking || store.failure == nil)
        case .done:
            Button("Start Writing") { onFinished() }
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
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
    }
}
