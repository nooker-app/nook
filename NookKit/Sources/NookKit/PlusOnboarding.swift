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
        // Reached only when setup finds the account already created: the
        // remedy is a password, not another attempt at signing up.
        case signIn
        case done

        /// How many steps the user actually fills in. Setting up, signing in,
        /// and the finish screen are outcomes, not steps to count towards.
        static let formCount = 4

        /// 1-based position among the filled-in steps, nil for the outcomes.
        var position: Int? {
            switch self {
            case .intro: 1
            case .invitation: 2
            case .address: 3
            case .credentials: 4
            case .working, .signIn, .done: nil
            }
        }

        var completedFraction: Double {
            switch self {
            case .working, .signIn: 1
            case .done: 1
            default: Double((position ?? 1) - 1) / Double(Self.formCount)
            }
        }

        /// The illustration for this step. The app's own first-run tour leads
        /// each page with a wordless image, and a form of bare fields is exactly
        /// what made the earlier version of this screen unreadable to someone
        /// who had never heard of a handle.
        var symbol: String {
            switch self {
            case .intro: "sparkles"
            case .invitation: "ticket"
            case .address: "at"
            case .credentials: "lock.shield"
            case .working: "gearshape.2"
            case .signIn: "person.crop.circle"
            case .done: "checkmark.seal.fill"
            }
        }

        /// One line saying what this step is for, read before the fields.
        var summary: LocalizedStringKey {
            switch self {
            case .intro: "A quick tour of what publishing with Nook means."
            case .invitation: "Publishing is invitation-only for now."
            case .address: "Choose the name people will find you by."
            case .credentials: "Set the password that protects your writing."
            case .working: "Creating your account. This takes a few seconds."
            case .signIn: "This account already exists, so just sign in."
            case .done: "Everything is ready."
            }
        }

        var progressLabel: String {
            switch self {
            case .intro: String(localized: "Welcome", bundle: .module)
            case .invitation: String(localized: "Invitation", bundle: .module)
            case .address: String(localized: "Your address", bundle: .module)
            case .credentials: String(localized: "Sign-in details", bundle: .module)
            case .working: String(localized: "Setting up", bundle: .module)
            case .signIn: String(localized: "Sign in", bundle: .module)
            case .done: String(localized: "Ready", bundle: .module)
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
    /// Lets the user read what a generated password actually put in the field.
    @State private var passwordVisible = false

    enum Availability: Equatable {
        case unknown
        case checking
        case available(String)
        case unavailable(String)

        var isAvailable: Bool { if case .available = self { true } else { false } }
    }

    public var body: some View {
        shell.task { await useInviteLinkIfPresent() }
    }

    /// iOS gets a grouped form with the step's action pinned to the bottom,
    /// which is how every other setup flow on the platform behaves. macOS keeps
    /// the panel layout, where a bottom-right button is the convention instead.
    @ViewBuilder
    private var shell: some View {
        #if os(iOS)
            NavigationStack {
                iOSBody
            }
        #else
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                content
                Spacer(minLength: 0)
                footer
            }
            .padding(24)
            .frame(minWidth: 380, minHeight: 460)
        #endif
    }

    #if os(iOS)
        private var iOSBody: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    hero
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(PlusTheme.canvas.ignoresSafeArea())
            .tint(PlusTheme.accent)
            .navigationTitle(Text("Set up publishing", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { stepIndicator }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .toolbar {
                // Setup is resumable, so leaving part-way is safe and should not
                // look like a trap.
                if step != .done {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { onFinished() } label: { Text("Cancel", bundle: .module) }
                    }
                }
            }
        }
    #endif

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

    #if os(iOS)
        /// The step's symbol and its one-line purpose, sitting above the fields.
        private var hero: some View {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: step.symbol)
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(PlusTheme.accent)
                    .symbolRenderingMode(.hierarchical)
                    .frame(height: 48)
                    .accessibilityHidden(true)

                Text(step.summary, bundle: .module)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        /// Named position rather than a bare bar: "step 2 of 4" tells the user
        /// how much is left, which a progress bar alone does not.
        private var stepIndicator: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(step.progressLabel)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if let position = step.position {
                        Text("Step \(position) of \(Step.formCount)", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                // Never regresses, so it reads as progress rather than as state.
                ProgressView(value: step.completedFraction)
                    .progressViewStyle(.linear)
                    .tint(PlusTheme.accent)
                    .animation(.smooth(duration: 0.35), value: step.completedFraction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(PlusTheme.canvas)
            .overlay(alignment: .bottom) {
                Rectangle().fill(PlusTheme.hairline).frame(height: 0.5)
            }
        }

        private var bottomBar: some View {
            VStack(spacing: 10) {
                primaryButton
                    .buttonStyle(.borderedProminent)
                    .tint(PlusTheme.accent)
                    .fontWeight(.semibold)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                if step != .intro && step != .working && step != .done && step != .signIn {
                    Button { back() } label: { Text("Back", bundle: .module) }
                        .font(.subheadline)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(PlusTheme.canvas)
            .overlay(alignment: .top) {
                Rectangle().fill(PlusTheme.hairline).frame(height: 0.5)
            }
        }
    #endif

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
        case .signIn: signIn
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
            // The handle appears here, not only on the previous step, because it
            // is the username half of the credential. A password manager saves
            // a pair, and without a username field alongside the password
            // fields there is nothing for it to file the password under.
            handleRow

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
            passwordField(text: $password, label: Text("Password", bundle: .module))
            passwordField(text: $confirmPassword, label: Text("Repeat password", bundle: .module))

            if !password.isEmpty && password.count < 8 {
                Text("At least 8 characters.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if !confirmPassword.isEmpty && password != confirmPassword {
                Text("The two passwords do not match.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("Save it somewhere safe. It is the only way back into your repository, and Nook cannot reset it for you.", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The handle, shown as a real username field rather than static text.
    ///
    /// A password manager saves a pair, so without a `.username` field beside
    /// the password fields there is nothing to file the password under. It is
    /// not editable — the name was chosen and checked on the previous step — but
    /// it has to be a laid-out text field for the system to see it at all.
    private var handleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("You will sign in as", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)

            let field = TextField(text: .constant(store.fullHandle(for: label))) {
                Text("Handle", bundle: .module)
            }
            .textContentType(.username)
            .font(.callout.monospaced())
            .disabled(true)

            #if os(iOS)
                field
                    .padding(.vertical, 11)
                    .padding(.horizontal, 12)
                    .background(PlusTheme.card, in: .rect(cornerRadius: 10))
            #else
                field.textFieldStyle(.roundedBorder)
            #endif
        }
    }

    /// A password row that can be read.
    ///
    /// Two reasons it is not a bare `SecureField`. A generated password is
    /// filled in without the user ever seeing it, so there has to be a way to
    /// look at what is about to become the only key to their repository. And on
    /// iOS the concealed bullets are drawn in a colour that does not follow the
    /// dark appearance, which made a filled field look nearly empty; a field
    /// showing real glyphs uses the label colour and does not have that problem.
    @ViewBuilder
    private func passwordField(text: Binding<String>, label: Text) -> some View {
        // Both fields stay in the hierarchy and only their visibility changes.
        // Swapping one for the other changes view identity, which cancels an
        // in-flight AutoFill session — and offering to generate and save the
        // password is the whole point of typing these fields correctly.
        let field = ZStack {
            SecureField(text: text) { label }
                .opacity(passwordVisible ? 0 : 1)
                .allowsHitTesting(!passwordVisible)
                .accessibilityHidden(passwordVisible)
            TextField(text: text) { label }
                .opacity(passwordVisible ? 1 : 0)
                .allowsHitTesting(passwordVisible)
                .accessibilityHidden(!passwordVisible)
        }
        .textContentType(.newPassword)
        .foregroundStyle(.primary)
        .autocorrectionDisabled()
        #if os(iOS)
            .textInputAutocapitalization(.never)
        #endif

        HStack(spacing: 8) {
            #if os(iOS)
                field
                    .padding(.vertical, 11)
                    .padding(.horizontal, 12)
                    .background(PlusTheme.card, in: .rect(cornerRadius: 10))
            #else
                field.textFieldStyle(.roundedBorder)
            #endif

            Button {
                passwordVisible.toggle()
            } label: {
                Image(systemName: passwordVisible ? "eye.slash" : "eye")
                    .accessibilityLabel(
                        passwordVisible
                            ? Text("Hide password", bundle: .module)
                            : Text("Show password", bundle: .module)
                    )
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
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

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 14) {
            explain(
                "This name is already yours",
                "The account was created on an earlier attempt, so there is nothing left to set up. Sign in with the password you chose then."
            )
            LabeledContent {
                Text(store.fullHandle(for: label))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            } label: {
                Text("Your handle", bundle: .module)
            }
            .font(.caption)

            passwordField(text: $password, label: Text("Password", bundle: .module))

            if let failure = store.failure {
                Label { Text(verbatim: failure) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label { Text("You can publish now.", bundle: .module) } icon: { Image(systemName: "checkmark.circle.fill") }
                .foregroundStyle(.green)
                .font(.headline)

            // Setup finishing is not the goal; a first post is. Without saying
            // what happens next, the flow ends on a screen that congratulates
            // the user for nothing they can see yet.
            VStack(alignment: .leading, spacing: 8) {
                nextStep(1, "Write a post", "Give it a title, a short web address, and your text.")
                nextStep(2, "Publish it", "It is written to your own repository first, then to your site.")
                nextStep(3, "Share the link", "Your site has an RSS feed, so anyone can follow it in any reader.")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)

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
        case .signIn:
            Button { Task { await signInInstead() } } label: { Text("Sign In", bundle: .module) }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || store.isWorking)
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
        // A retry with no password cannot succeed and would be reported as a
        // rejected password, which is not what went wrong.
        guard !password.isEmpty else {
            step = .credentials
            return
        }

        step = .working
        await store.signUp(
            invitationCode: invitationCode,
            label: label,
            email: email,
            password: password
        )

        if store.isSignedIn {
            // Only now has the password served its purpose. Clearing it on
            // failure instead would leave "Try Again" nothing to send.
            password = ""
            confirmPassword = ""
            passwordVisible = false
            step = .done
        } else if store.signupNeedsSignIn {
            password = ""
            confirmPassword = ""
            step = .signIn
        } else {
            step = .working
        }
    }

    private func signInInstead() async {
        await store.signIn(handle: store.fullHandle(for: label), password: password)
        if store.isSignedIn {
            password = ""
            passwordVisible = false
            step = .done
        }
    }

    /// A numbered next step for the finish screen.
    @ViewBuilder
    private func nextStep(_ number: Int, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number, format: .number)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .frame(width: 20, height: 20)
                .background(Circle().fill(PlusTheme.accent.opacity(0.15)))
                .foregroundStyle(PlusTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title, bundle: .module).font(.callout.weight(.medium))
                Text(detail, bundle: .module).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        #if os(iOS)
            shape.fill(PlusTheme.card)
        #else
            shape.fill(.quaternary.opacity(0.25))
        #endif
    }

    @ViewBuilder
    private func explain(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        let block = VStack(alignment: .leading, spacing: 3) {
            Text(title, bundle: .module).font(.subheadline.weight(.semibold))
            Text(detail, bundle: .module).font(.callout).foregroundStyle(.secondary)
        }
        #if os(iOS)
            block
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(cardBackground)
        #else
            block
        #endif
    }
}
