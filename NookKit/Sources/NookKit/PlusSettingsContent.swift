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
    let onCompose: (PlusComposeTarget) -> Void

    init(
        store: PlusStore,
        onSetUp: @escaping () -> Void,
        onSignIn: @escaping () -> Void,
        onCompose: @escaping (PlusComposeTarget) -> Void
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
        // Attached once here rather than per row: the same alert repeated down a list
        // is N presentations racing to be the one that shows.
        .alert(
            Text("Couldn’t delete that post", bundle: .module),
            isPresented: Binding(
                get: { deletionFailure != nil },
                set: { if !$0 { deletionFailure = nil } }
            ),
            presenting: deletionFailure
        ) { _ in
            Button { deletionFailure = nil } label: { Text("OK", bundle: .module) }
        } message: { why in
            Text(verbatim: why)
        }
        .task {
            if store.isSignedIn { await store.loadContent() }
        }
    }

    /// Deletes a post, reporting a failure where the writer is looking.
    ///
    /// The failure is taken off the store so it is told once, here, rather than also
    /// appearing in the banner at the top of a screen the writer would have to scroll
    /// back up to find.
    private func delete(_ record: ATRecord<ArticleRecord>) async {
        deleting = record.uri
        await store.delete(record)
        deleting = nil
        reportFailure()
    }

    /// Takes a post off the web while keeping its text as a draft on this device.
    private func unpublish(_ record: ATRecord<ArticleRecord>) async {
        deleting = record.uri
        await store.unpublish(record)
        deleting = nil
        reportFailure()
    }

    private func reportFailure() {
        if let failure = store.failure {
            deletionFailure = failure
            store.clearFailure()
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
            // Every failure this screen can cause, said out loud.
            //
            // Nothing here showed `store.failure` at all. Deleting a post failed with
            // a 400 seven times over and the only thing the writer saw was the trash
            // button blink: the message was set on the store and never rendered, so a
            // real refusal was indistinguishable from a dead button.
            if let failure = store.failure {
                Section {
                    Label { Text(verbatim: failure) } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.orange)
                    .font(.callout)
                    Button { store.clearFailure() } label: { Text("Dismiss", bundle: .module) }
                        .font(.callout)
                }
            }

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
                    onCompose(.newPost)
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

            // Drafts first: they are the things still waiting on the writer. A
            // published post needs nothing from anybody.
            if !store.drafts.isEmpty {
                Section {
                    ForEach(store.drafts) { draft in
                        draftRow(draft)
                    }
                } header: {
                    Text("Drafts", bundle: .module)
                } footer: {
                    Text("Kept on this device only, and never published until you say so. Nook holds no copy.", bundle: .module)
                }
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

    // MARK: - Drafts

    /// A draft, and the two things to do with one.
    ///
    /// Tapping the row opens it, which is what a row of writing should do; publishing
    /// and discarding are swipes, so the destructive one is never the default gesture.
    @ViewBuilder
    private func draftRow(_ draft: PlusDraft) -> some View {
        Button {
            onCompose(.draft(draft))
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    if draft.displayTitle.isEmpty {
                        Text("Untitled", bundle: .module).foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: draft.displayTitle)
                    }
                    HStack(spacing: 4) {
                        // Said plainly, because a draft that used to be public is a
                        // different thing from one that never was: its old URL is dead.
                        if draft.wasPublished {
                            Text("Unpublished", bundle: .module)
                        }
                        Text(draft.updatedAt, format: .relative(presentation: .named))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { store.discard(draft) } label: {
                Label {
                    Text("Discard", bundle: .module)
                } icon: {
                    Image(systemName: "trash")
                }
            }
        }
        .swipeActions(edge: .leading) {
            Button { onCompose(.draft(draft)) } label: {
                Label {
                    Text("Publish", bundle: .module)
                } icon: {
                    Image(systemName: "paperplane")
                }
            }
            .tint(PlusTheme.accent)
        }
    }


    /// The post the writer has asked to delete, held until they confirm.
    ///
    /// Deleting removes the authoritative record from their repository. One tap on a
    /// small icon did that, permanently, with nothing in between.
    @State private var pendingDeletion: ATRecord<ArticleRecord>?

    /// A failed deletion, reported as an alert on the spot.
    ///
    /// The banner at the top of this screen is the right place for a failure the
    /// writer is about to read anyway, but it is the wrong place for one caused by a
    /// button several sections further down: they press Delete, the row stays, and the
    /// explanation is off-screen behind a scroll. An alert cannot be missed and
    /// arrives where the action was.
    @State private var deletionFailure: String?

    /// The post being deleted, so its own row can show it rather than the whole
    /// screen going busy.
    @State private var deleting: String?

    /// A published post: tap to edit, swipe to take it down.
    ///
    /// Editing is the row's own action because it is the safe one and the one wanted
    /// most often. Taking a post down is a swipe, so it cannot be the thing that
    /// happens when someone means to open it.
    @ViewBuilder
    private func articleRow(_ record: ATRecord<ArticleRecord>) -> some View {
        Button {
            onCompose(.published(record))
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.value.title)
                    Text(record.value.slug)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if deleting == record.uri {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isWorking)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDeletion = record
            } label: {
                Label {
                    Text("Take Down", bundle: .module)
                } icon: {
                    Image(systemName: "trash")
                }
            }
        }
        .confirmationDialog(
            Text("Take this post down?", bundle: .module),
            isPresented: Binding(
                get: { pendingDeletion?.uri == record.uri },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { target in
            // Two different acts, and the difference is the text. Both remove the
            // record — that is what makes a post not public — but one keeps what was
            // written and the other does not.
            if store.canKeepDrafts {
                Button {
                    pendingDeletion = nil
                    Task { await unpublish(target) }
                } label: {
                    Text("Unpublish and Keep a Draft", bundle: .module)
                }
            }
            Button(role: .destructive) {
                pendingDeletion = nil
                Task { await delete(target) }
            } label: {
                Text("Delete the Text Too", bundle: .module)
            }
            Button(role: .cancel) { pendingDeletion = nil } label: {
                Text("Cancel", bundle: .module)
            }
        } message: { target in
            Text(
                "“\(target.value.title)” comes off the web either way. Keeping a draft leaves the text on this device so you can publish it again; deleting the text keeps no copy anywhere.",
                bundle: .module)
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
