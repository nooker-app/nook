import SwiftUI

/// Which kind of account someone is signing in with.
///
/// Offered as a visible choice because "handle" means nothing to someone who has
/// not met AT Protocol, and typing a full handle is a guessing game: the part
/// after the dot is the one thing they have no way to know. Picking a kind fills
/// that in, leaving only the name they chose.
///
/// The kinds that Nook cannot serve yet are listed rather than hidden. Someone
/// who has a Bluesky account will look for it, and finding nothing is
/// indistinguishable from the app being broken; finding it greyed out with a
/// reason is an answer. What must not happen is offering it and failing, which
/// is what happens today — the request goes to Nook's own host and comes back as
/// a rejected password, so the user blames a password that is perfectly fine.
enum PlusAccountKind: String, CaseIterable, Identifiable, Sendable {
    /// A handle Nook issued, on Nook's own repository host.
    case nook
    /// A Bluesky account, on Bluesky's host.
    case bluesky
    /// Any other host, including one the user runs.
    case other

    var id: String { rawValue }

    /// Whether signing in with this kind works today.
    ///
    /// Only `nook` does. The repository host is fixed by configuration in both
    /// the app and the service, the service validates a token against that one
    /// host, and publishing requires a membership that only the invitation flow
    /// creates — so an account elsewhere cannot sign in, and could not publish
    /// if it did.
    var isSupported: Bool { self == .nook }

    var symbol: String {
        switch self {
        case .nook: "book.closed.fill"
        case .bluesky: "cloud.fill"
        case .other: "server.rack"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .nook: "Nook account"
        case .bluesky: "Bluesky account"
        case .other: "Another server"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .nook: "The name you chose when you set up publishing here."
        case .bluesky: "Not yet. Publishing through Nook needs an account on Nook's own server."
        case .other: "Not yet. Nook can only reach its own server at the moment."
        }
    }

    /// The suffix a name gets, for the kinds where it is known.
    func handleSuffix(_ environment: PlusEnvironment) -> String? {
        switch self {
        case .nook: environment.handleDomain
        case .bluesky: "bsky.social"
        case .other: nil
        }
    }
}

/// Signing in to an account that already exists.
///
/// Built around picking a kind first and typing a name second, because the name
/// is the only part the user actually knows. A full handle can still be typed —
/// someone who already knows theirs should not be made to click through a
/// chooser — but it is the fallback, not the main path.
struct PlusSignInView: View {
    @Bindable var store: PlusStore
    let onFinished: () -> Void

    /// Prefills the name, for a flow that already knows it.
    var initialName: String = ""

    @State private var kind: PlusAccountKind = .nook
    @State private var name = ""
    @State private var password = ""
    @State private var typingFullHandle = false
    @State private var fullHandle = ""

    var body: some View {
        content
            .onAppear { if name.isEmpty { name = initialName } }
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) { form }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle(Text("Sign in", bundle: .module))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { onFinished() } label: { Text("Cancel", bundle: .module) }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { Task { await signIn() } } label: { Text("Sign In", bundle: .module) }
                            .disabled(!canSubmit)
                    }
                }
            }
        #else
            VStack(alignment: .leading, spacing: 18) {
                form
                Spacer(minLength: 0)
                HStack {
                    Button { onFinished() } label: { Text("Cancel", bundle: .module) }
                    Spacer()
                    Button { Task { await signIn() } } label: { Text("Sign In", bundle: .module) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSubmit)
                }
            }
            .padding(24)
            .frame(minWidth: 360, minHeight: 340)
        #endif
    }

    @ViewBuilder
    private var form: some View {
        if typingFullHandle {
            fullHandleForm
        } else {
            kindChooser
            if kind.isSupported {
                nameField
                passwordField
            } else {
                unsupportedNote
            }
        }

        if let failure = store.failure {
            Label { Text(verbatim: failure) } icon: { Image(systemName: "exclamationmark.triangle") }
                .foregroundStyle(.red)
                .font(.callout)
        }

        Button {
            typingFullHandle.toggle()
            store.clearFailure()
        } label: {
            if typingFullHandle {
                Text("Choose an account type instead", bundle: .module)
            } else {
                Text("I know my full handle", bundle: .module)
            }
        }
        .font(.footnote)
    }

    private var kindChooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What kind of account?", bundle: .module)
                .font(.subheadline.weight(.semibold))

            ForEach(PlusAccountKind.allCases) { candidate in
                Button {
                    kind = candidate
                    store.clearFailure()
                } label: {
                    kindRow(candidate)
                }
                .buttonStyle(.plain)
                .disabled(!candidate.isSupported)
            }
        }
    }

    private func kindRow(_ candidate: PlusAccountKind) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: candidate.symbol)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(candidate.isSupported ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title, bundle: .module)
                    .font(.callout.weight(.medium))
                Text(candidate.detail, bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if candidate == kind && candidate.isSupported {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(selected: candidate == kind && candidate.isSupported))
        .contentShape(.rect)
        .opacity(candidate.isSupported ? 1 : 0.55)
    }

    @ViewBuilder
    private func rowBackground(selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        #if os(iOS)
            shape.fill(PlusTheme.card)
                .overlay(shape.strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2))
        #else
            shape.fill(.quaternary.opacity(selected ? 0.6 : 0.25))
                .overlay(shape.strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.5))
        #endif
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                TextField(text: $name, prompt: Text(verbatim: "yourname")) { Text("Name", bundle: .module) }
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                if let suffix = kind.handleSuffix(store.currentEnvironment) {
                    Text(verbatim: ".\(suffix)")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .fieldChrome()

            Text("Just the name. The rest is filled in for you.", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var passwordField: some View {
        SecureField(text: $password) { Text("Password", bundle: .module) }
            // Lets the system offer the password it saved during setup, which is
            // the only reason a user has to remember it at all.
            .textContentType(.password)
            .fieldChrome()
    }

    private var fullHandleForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your full handle", bundle: .module)
                .font(.subheadline.weight(.semibold))
            TextField(text: $fullHandle, prompt: Text(verbatim: "yourname.\(store.currentEnvironment.handleDomain)")) {
                Text("Handle", bundle: .module)
            }
            .textContentType(.username)
            .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never)
            #endif
            .fieldChrome()

            passwordField

            Text("Only accounts on Nook's own server can sign in at the moment.", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var unsupportedNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(kind.detail, bundle: .module)
                .font(.callout)
            Text("Nook stores your posts in a repository on its own server, and publishing needs an account there. Support for other servers is not decided yet.", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(selected: false))
    }

    private var submittedHandle: String {
        if typingFullHandle {
            return fullHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let suffix = kind.handleSuffix(store.currentEnvironment) else { return "" }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return clean.isEmpty ? "" : "\(clean).\(suffix)"
    }

    private var canSubmit: Bool {
        !submittedHandle.isEmpty && !password.isEmpty && !store.isWorking
            && (typingFullHandle || kind.isSupported)
    }

    private func signIn() async {
        await store.signIn(handle: submittedHandle, password: password)
        password = ""
        if store.isSignedIn { onFinished() }
    }
}

extension View {
    /// One place for the field chrome, because `.roundedBorder` draws concealed
    /// text in a colour that ignores the dark appearance on iOS — a filled
    /// password field looked empty.
    @ViewBuilder
    fileprivate func fieldChrome() -> some View {
        #if os(iOS)
            self
                .padding(.vertical, 11)
                .padding(.horizontal, 12)
                .background(PlusTheme.card, in: .rect(cornerRadius: 10))
        #else
            self.textFieldStyle(.roundedBorder)
        #endif
    }
}
