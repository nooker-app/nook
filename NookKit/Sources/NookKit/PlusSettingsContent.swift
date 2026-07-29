import NookPlusProtocol
import SwiftUI

/// Nook Plus settings: sign in, publish, and review what has been published.
///
/// Plus is opt-in. Nothing here runs unless the user opens this pane, and the
/// reader works identically for someone who never does.
public struct PlusSettingsContent: View {
    @State private var store = PlusStore()

    public init() {}

    public var body: some View {
        Group {
            if store.isSignedIn {
                signedIn
            } else {
                signIn
            }
        }
        .task {
            if store.isSignedIn { await store.loadContent() }
        }
    }

    // MARK: - Signed out

    @State private var handle = ""
    @State private var password = ""

    private var signIn: some View {
        Group {
            Section("Nook Plus") {
                Text(
                    "Publish your own writing to the web and to feeds. Your posts live in your own repository, so they stay yours."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Sign in") {
                TextField("Handle", text: $handle, prompt: Text(verbatim: "you.example.app"))
                    .textContentType(.username)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)

                Button {
                    Task {
                        await store.signIn(handle: handle, password: password)
                        // The password is not needed after this and must not
                        // linger in view state.
                        password = ""
                    }
                } label: {
                    if store.isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Sign In")
                    }
                }
                .disabled(handle.isEmpty || password.isEmpty || store.isWorking)

                if let failure = store.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            environmentSection
        }
    }

    // MARK: - Signed in

    @State private var title = ""
    @State private var slug = ""
    @State private var summary = ""
    @State private var markdown = ""

    private var signedIn: some View {
        Group {
            Section("Account") {
                LabeledContent("Handle", value: store.session?.handle ?? "")
                if let did = store.session?.did {
                    LabeledContent("Identifier") {
                        Text(did)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                if let publication = store.publications.first {
                    LabeledContent("Publication", value: publication.value.name)
                }
                // Signing out clears this device's stored session and nothing
                // else. Saying so prevents it reading as deletion.
                Button("Sign Out on This Device", role: .destructive) { store.signOut() }
            }

            Section("New post") {
                TextField("Title", text: $title)
                TextField("Slug", text: $slug, prompt: Text(verbatim: "my-first-post"))
                    .autocorrectionDisabled()
                TextField("Summary (optional)", text: $summary)
                TextEditor(text: $markdown)
                    .font(.body.monospaced())
                    .frame(minHeight: 140)
                    .overlay(alignment: .topLeading) {
                        if markdown.isEmpty {
                            Text("Write in Markdown…")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }

                Button {
                    Task {
                        await store.publish(
                            title: title, slug: slug, markdown: markdown, summary: summary)
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
                .disabled(
                    title.isEmpty || slug.isEmpty || markdown.isEmpty
                        || store.publications.isEmpty || store.isWorking)

                if store.publications.isEmpty && !store.isWorking {
                    Text("No publication found in your repository yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let failure = store.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                if let url = store.lastPublishedURL {
                    // Read from the response, never assembled locally: the
                    // canonical form can change without the record changing.
                    Link(destination: URL(string: url) ?? URL(string: "https://example.com")!) {
                        Label("View published post", systemImage: "safari")
                    }
                    .font(.callout)
                }
            }

            Section("Published") {
                if store.articles.isEmpty {
                    Text("Nothing published yet.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(store.articles, id: \.uri) { record in
                        articleRow(record)
                    }
                }
                Button("Reload from My Repository") {
                    Task { await store.loadContent() }
                }
                .disabled(store.isWorking)
            }

            environmentSection
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

    // MARK: - Deployment

    @State private var apiBase = PlusEnvironment.current.apiBaseURL.absoluteString
    @State private var pdsHost = PlusEnvironment.current.pdsHost

    /// Lets a build be pointed at a non-production deployment. Exposed because
    /// the alternative is hard-coding a host, which the project's
    /// configuration rules forbid.
    private var environmentSection: some View {
        Section("Deployment") {
            TextField("Service API", text: $apiBase)
                .autocorrectionDisabled()
            TextField("PDS host", text: $pdsHost)
                .autocorrectionDisabled()
            Button("Use This Deployment") {
                guard let url = URL(string: apiBase), !pdsHost.isEmpty else { return }
                PlusEnvironment.select(apiBaseURL: url, pdsHost: pdsHost)
                store.use(PlusEnvironment(apiBaseURL: url, pdsHost: pdsHost))
            }
            Text("Changing this signs nothing out, but the stored session only works against the deployment that issued it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
