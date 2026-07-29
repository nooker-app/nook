import NookPlusProtocol
import SwiftUI

/// Nook Plus settings, shared by macOS and iOS.
///
/// Someone who has never published anything should be able to read this screen
/// top to bottom and know what to do. Setup runs as a guided flow rather than a
/// form, and anything only a developer needs — which server to talk to — is
/// behind a disclosure that says so.
public struct PlusSettingsContent: View {
    @State private var store = PlusStore()
    @State private var showingSetup = false
    @State private var showingSignIn = false

    public init() {}

    public var body: some View {
        Group {
            if store.isSignedIn {
                signedIn
            } else {
                notSetUp
            }
            developerSection
        }
        // The host clears row backgrounds per Section for its own screens, but
        // it cannot reach Sections this package creates. Applied to the
        // container so every row inside inherits it, leaving the warm page
        // colour visible instead of grey cards.
        .listRowBackground(Color.clear)
        .tint(PlusTheme.accent)
        .task {
            if store.isSignedIn { await store.loadContent() }
            openSetupIfInvited()
        }
        .onChange(of: PlusInviteInbox.shared.pendingCode) { _, code in
            if code != nil { openSetupIfInvited() }
        }
        .sheet(isPresented: $showingSetup) {
            PlusOnboardingView(store: store) { showingSetup = false }
        }
        .sheet(isPresented: $showingSignIn) {
            PlusSignInView(store: store) { showingSignIn = false }
        }
    }

    /// Opens setup when an invitation link is waiting.
    ///
    /// Ignored for someone already signed in: a forwarded link must not offer to
    /// replace an account that already exists.
    private func openSetupIfInvited() {
        guard !store.isSignedIn, PlusInviteInbox.shared.pendingCode != nil else { return }
        showingSetup = true
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
                    showingSetup = true
                } label: {
                    Label { Text("Set Up Publishing", bundle: .module) } icon: { Image(systemName: "sparkles") }
                }
                Button {
                    showingSignIn = true
                } label: {
                    Label { Text("I Already Have an Account", bundle: .module) } icon: { Image(systemName: "person.crop.circle") }
                }
            } footer: {
                Text("Setting up needs an invitation code. Publishing is limited to invited writers for now.", bundle: .module)
            }
        }
    }

    // MARK: - Signed in

    @State private var title = ""
    @State private var slug = ""
    @State private var summary = ""
    @State private var markdown = ""

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
                TextField(text: $title) { Text("Title", bundle: .module) }
                TextField("Web address", text: $slug, prompt: Text(verbatim: "my-first-post"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                TextField(text: $summary) { Text("One-line summary (optional)", bundle: .module) }

                TextEditor(text: $markdown)
                    .font(.body)
                    .frame(minHeight: 150)
                    .overlay(alignment: .topLeading) {
                        if markdown.isEmpty {
                            Text("Write here. **Bold**, *italic*, and [links](https://example.com) work.", bundle: .module)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }

                Button {
                    Task {
                        await store.publish(title: title, slug: slug, markdown: markdown, summary: summary)
                        if store.failure == nil {
                            title = ""
                            slug = ""
                            summary = ""
                            markdown = ""
                        }
                    }
                } label: {
                    if store.isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Publish", bundle: .module)
                    }
                }
                .disabled(!canPublish)

                if let failure = store.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                if let url = store.lastPublishedURL {
                    Link(destination: URL(string: url) ?? URL(string: "https://example.com")!) {
                        Label { Text("View your post", bundle: .module) } icon: { Image(systemName: "safari") }
                    }
                    .font(.callout)
                }
            } header: {
                Text("Write a post", bundle: .module)
            } footer: {
                Text("The web address becomes the last part of the link to this post. Lowercase letters, numbers, and hyphens.", bundle: .module)
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

    private var canPublish: Bool {
        !title.isEmpty && !slug.isEmpty && !markdown.isEmpty
            && !store.publications.isEmpty && !store.isWorking
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
    private var developerSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showingDeveloper) {
                Picker(selection: $selected) {
                    ForEach(PlusEnvironment.all, id: \.handleDomain) { environment in
                        Text(verbatim: environment.name).tag(environment)
                    }
                } label: {
                    Text("Server", bundle: .module)
                }
                Text(verbatim: selected.apiBaseURL.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                Button {
                    PlusEnvironment.select(selected)
                    store.use(selected)
                    store.signOut()
                } label: {
                    Text("Use This Server", bundle: .module)
                }
                .disabled(selected == PlusEnvironment.current)
            } label: {
                Text("Developer", bundle: .module)
            }
        } footer: {
            Text("Only change this if you are testing Nook Plus itself. Accounts do not carry across servers, so switching signs you out.", bundle: .module)
        }
    }
}
