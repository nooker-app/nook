import NookPlusProtocol
import SwiftUI

/// The Nook Plus settings rows, shared by macOS and iOS.
///
/// Rows only: presentation state, sheets, and the store live on
/// ``PlusSettingsScreenContent``, because a sheet attached inside a `List` row
/// is dismissed when the row is re-laid-out.
///
/// Someone who has never published anything should be able to read this screen
/// top to bottom and know what to do. Setup runs as a guided flow rather than a
/// form, and anything only a developer needs — which server to talk to — is
/// behind a disclosure that says so.
public struct PlusSettingsContent: View {
    @Bindable var store: PlusStore
    let onSetUp: () -> Void
    let onSignIn: () -> Void
    let onCompose: () -> Void

    init(
        store: PlusStore,
        onSetUp: @escaping () -> Void,
        onSignIn: @escaping () -> Void,
        onCompose: @escaping () -> Void
    ) {
        self.store = store
        self.onSetUp = onSetUp
        self.onSignIn = onSignIn
        self.onCompose = onCompose
    }

    public var body: some View {
        Group {
            if store.isSignedIn {
                signedIn
            } else {
                notSetUp
            }
            // Debug only. Which deployment a build talks to is not a user
            // setting: picking wrong creates an account whose handle belongs to
            // a different service, and a release build has exactly one correct
            // answer. Compiled out rather than hidden, so a release binary does
            // not carry the switch at all.
            #if DEBUG
                developerSection
            #endif
        }
        // The host clears row backgrounds per Section for its own screens, but
        // it cannot reach Sections this package creates. Applied to the
        // container so every row inside inherits it, leaving the warm page
        // colour visible instead of grey cards.
        .listRowBackground(Color.clear)
        .tint(PlusTheme.accent)
        .task {
            if store.isSignedIn { await store.loadContent() }
        }
    }

    // MARK: - Not set up

    private var notSetUp: some View {
        Group {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Publish your own writing", bundle: .module)
                        .font(.headline)
                    Text(
                        "Nook can turn your writing into a small website with an RSS feed, so anyone can follow you in Nook or any other reader. Your posts are stored in a repository that belongs to you, not inside Nook's database."
                    , bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Text("Reading feeds works exactly as before whether or not you set this up.", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }

            Section {
                Button {
                    onSetUp()
                } label: {
                    Label { Text("Set Up Publishing", bundle: .module) } icon: { Image(systemName: "sparkles") }
                }
                Button {
                    onSignIn()
                } label: {
                    Label { Text("I Already Have an Account", bundle: .module) } icon: { Image(systemName: "person.crop.circle") }
                }
            } footer: {
                Text("Setting up needs an invitation code. Publishing is limited to invited writers for now.", bundle: .module)
            }
        }
    }

    // MARK: - Signed in


    private var signedIn: some View {
        Group {
            Section {
                if let session = store.session {
                    LabeledContent { Text(verbatim: session.handle) } label: { Text("Handle", bundle: .module) }
                }
                if let url = store.publicationURL {
                    LabeledContent {
                        Link(url, destination: URL(string: url) ?? URL(string: "https://example.com")!)
                            .font(.callout)
                    } label: {
                        Text("Your site", bundle: .module)
                    }
                }
                if store.handleResolutionPending {
                    Text("Your handle is still spreading across the network. Everything works in the meantime.", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) { store.signOut() } label: { Text("Sign Out on This Device", bundle: .module) }
            } header: {
                Text("Your account", bundle: .module)
            } footer: {
                Text("Signing out only forgets this device. Your account and your posts are untouched.", bundle: .module)
            }

            Section {
                Button {
                    onCompose()
                } label: {
                    Label {
                        Text("Write a post", bundle: .module)
                    } icon: {
                        Image(systemName: "square.and.pencil")
                    }
                }
                .disabled(!store.canPublish)
            } footer: {
                Text("Writing opens its own screen. On iPhone there is a button for it beside the tabs, so publishing does not start in Settings.", bundle: .module)
            }

            Section {
                if store.articles.isEmpty {
                    Text("Nothing published yet.", bundle: .module)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(store.articles, id: \.uri) { record in
                        articleRow(record)
                    }
                }
                Button { Task { await store.loadContent() } } label: { Text("Reload", bundle: .module) }
                    .disabled(store.isWorking)
            } header: {
                Text("Your posts", bundle: .module)
            } footer: {
                Text("Read straight from your own repository, so this is what actually exists — not a copy Nook keeps.", bundle: .module)
            }
        }
    }


    @ViewBuilder
    private func articleRow(_ record: ATRecord<ArticleRecord>) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.value.title)
                Text(record.value.slug)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                Task { await store.delete(record) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(store.isWorking)
        }
    }

    // MARK: - Developer

    @State private var showingDeveloper = false
    @State private var selected = PlusEnvironment.current

    /// Which server to talk to. Not a user setting: picking the wrong one
    /// creates an account whose handle belongs to a different service. It is
    /// disclosed, labelled, and explained rather than exposed as a bare field.
    #if DEBUG
        private var developerSection: some View {
            Section {
                // Outside the disclosure, because which deployment a build talks
                // to is the difference between the feature working and every call
                // failing to resolve a host — and it was invisible until someone
                // thought to open a section marked "Developer".
                LabeledContent {
                    Text(verbatim: store.currentEnvironment.name)
                        .foregroundStyle(
                            store.currentEnvironment == .production
                                ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                } label: {
                    Text("Server", bundle: .module)
                }
                if store.currentEnvironment == .production {
                    Text("The production server is not running yet, so publishing cannot work on this setting. Choose the test server below.", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                DisclosureGroup(isExpanded: $showingDeveloper) {
                    Picker(selection: $selected) {
                        ForEach(PlusEnvironment.all, id: \.handleDomain) { environment in
                            Text(verbatim: environment.name).tag(environment)
                        }
                    } label: {
                        Text("Switch to", bundle: .module)
                    }
                    Text(verbatim: selected.apiBaseURL.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)

                    Button {
                        store.select(selected)
                    } label: {
                        Text("Use This Server", bundle: .module)
                    }
                    // Compared against the store, not UserDefaults: the static
                    // read is not observed, so this stayed enabled after a switch
                    // and the row above kept naming the old server.
                    .disabled(selected == store.currentEnvironment)
                } label: {
                    Text("Developer", bundle: .module)
                }
            } footer: {
                Text("Only change this if you are testing Nook Plus itself. Accounts do not carry across servers, so switching signs you out.", bundle: .module)
            }
            // Keeps the picker on whatever is actually in use, including after a
            // switch made somewhere else.
            .onChange(of: store.currentEnvironment) { _, current in selected = current }
        }
    #endif
}
