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
        .task {
            if store.isSignedIn { await store.loadContent() }
        }
        .sheet(isPresented: $showingSetup) {
            PlusOnboardingView(store: store) { showingSetup = false }
        }
        .sheet(isPresented: $showingSignIn) {
            PlusSignInView(store: store) { showingSignIn = false }
        }
    }

    // MARK: - Not set up

    private var notSetUp: some View {
        Group {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Publish your own writing")
                        .font(.headline)
                    Text(
                        "Nook can turn your writing into a small website with an RSS feed, so anyone can follow you in Nook or any other reader. Your posts are stored in a repository that belongs to you, not inside Nook's database."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Text("Reading feeds works exactly as before whether or not you set this up.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }

            Section {
                Button {
                    showingSetup = true
                } label: {
                    Label("Set Up Publishing", systemImage: "sparkles")
                }
                Button {
                    showingSignIn = true
                } label: {
                    Label("I Already Have an Account", systemImage: "person.crop.circle")
                }
            } footer: {
                Text("Setting up needs an invitation code. Publishing is limited to invited writers for now.")
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
                    LabeledContent("Handle", value: session.handle)
                }
                if let url = store.publicationURL {
                    LabeledContent("Your site") {
                        Link(url, destination: URL(string: url) ?? URL(string: "https://example.com")!)
                            .font(.callout)
                    }
                }
                if store.handleResolutionPending {
                    Text("Your handle is still spreading across the network. Everything works in the meantime.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Sign Out on This Device", role: .destructive) { store.signOut() }
            } header: {
                Text("Your account")
            } footer: {
                Text("Signing out only forgets this device. Your account and your posts are untouched.")
            }

            Section {
                TextField("Title", text: $title)
                TextField("Web address", text: $slug, prompt: Text(verbatim: "my-first-post"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                TextField("One-line summary (optional)", text: $summary)

                TextEditor(text: $markdown)
                    .font(.body)
                    .frame(minHeight: 150)
                    .overlay(alignment: .topLeading) {
                        if markdown.isEmpty {
                            Text("Write here. **Bold**, *italic*, and [links](https://example.com) work.")
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
                        Text("Publish")
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
                        Label("View your post", systemImage: "safari")
                    }
                    .font(.callout)
                }
            } header: {
                Text("Write a post")
            } footer: {
                Text("The web address becomes the last part of the link to this post. Lowercase letters, numbers, and hyphens.")
            }

            Section {
                if store.articles.isEmpty {
                    Text("Nothing published yet.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(store.articles, id: \.uri) { record in
                        articleRow(record)
                    }
                }
                Button("Reload") { Task { await store.loadContent() } }
                    .disabled(store.isWorking)
            } header: {
                Text("Your posts")
            } footer: {
                Text("Read straight from your own repository, so this is what actually exists — not a copy Nook keeps.")
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
            DisclosureGroup("Developer", isExpanded: $showingDeveloper) {
                Picker("Server", selection: $selected) {
                    ForEach(PlusEnvironment.all, id: \.handleDomain) { environment in
                        Text(environment.name).tag(environment)
                    }
                }
                Text(verbatim: selected.apiBaseURL.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                Button("Use This Server") {
                    PlusEnvironment.select(selected)
                    store.use(selected)
                    store.signOut()
                }
                .disabled(selected == PlusEnvironment.current)
            }
        } footer: {
            Text("Only change this if you are testing Nook Plus itself. Accounts do not carry across servers, so switching signs you out.")
        }
    }
}

/// Signing in to an account that already exists.
struct PlusSignInView: View {
    @Bindable var store: PlusStore
    let onFinished: () -> Void

    @State private var handle = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sign in").font(.title2.weight(.semibold))
                Text("Use the handle and password you chose when you set up publishing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                TextField("Handle", text: $handle, prompt: Text(verbatim: "yourname.\(PlusEnvironment.current.handleDomain)"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
            }

            if let failure = store.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Cancel") { onFinished() }
                Spacer()
                Button("Sign In") {
                    Task {
                        await store.signIn(handle: handle, password: password)
                        password = ""
                        if store.isSignedIn { onFinished() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(handle.isEmpty || password.isEmpty || store.isWorking)
            }
        }
        .padding(24)
        .frame(minWidth: 360, minHeight: 280)
    }
}
