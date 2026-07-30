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
    /// Asks the host to confirm taking a post down. The dialog cannot live here: see
    /// the note above about presentations inside a `List`.
    let onTakeDown: (ATRecord<ArticleRecord>) -> Void
    /// Asks the host to confirm leaving the service. Same reason it is not a dialog
    /// attached here.
    let onLeave: () -> Void
    /// Asks the host to confirm throwing away a change made in the sync folder. Also a
    /// dialog, so also not attached here — and worth confirming, because the file is
    /// the only copy of that writing.
    let onDiscardFolderEdit: (PlusPostMirror.Edit) -> Void
    /// The post currently being removed, so its row can show it. Owned by the host,
    /// which is where the work is run from.
    let removing: String?

    init(
        store: PlusStore,
        onSetUp: @escaping () -> Void,
        onSignIn: @escaping () -> Void,
        onCompose: @escaping (PlusComposeTarget) -> Void,
        onTakeDown: @escaping (ATRecord<ArticleRecord>) -> Void,
        onLeave: @escaping () -> Void,
        onDiscardFolderEdit: @escaping (PlusPostMirror.Edit) -> Void,
        removing: String?
    ) {
        self.store = store
        self.onSetUp = onSetUp
        self.onSignIn = onSignIn
        self.onCompose = onCompose
        self.onTakeDown = onTakeDown
        self.onLeave = onLeave
        self.onDiscardFolderEdit = onDiscardFolderEdit
        self.removing = removing
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

            folderEditsSection

            mirrorSection

            leavingSection
        }
    }

    /// Changes the writer made to the files, waiting to be published.
    ///
    /// First of the folder sections, and only present when there is something in it,
    /// because it is the one part of this screen that is about writing the writer has
    /// done and Nook has not acted on. Nothing here has been published and nothing has
    /// been thrown away — the file is exactly as they left it.
    @ViewBuilder
    private var folderEditsSection: some View {
        if !store.folderEdits.isEmpty {
            Section {
                ForEach(store.folderEdits, id: \.slug) { edit in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: edit.title.isEmpty ? edit.slug : edit.title)
                            .font(.headline)
                        Text(verbatim: edit.file.lastPathComponent)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        HStack {
                            Button {
                                Task { await store.publishFolderEdit(edit) }
                            } label: {
                                Text("Publish This Change", bundle: .module)
                            }
                            .disabled(store.isWorking)
                            Spacer()
                            Button(role: .destructive) {
                                onDiscardFolderEdit(edit)
                            } label: {
                                Text("Discard", bundle: .module)
                            }
                            .disabled(store.isWorking)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Changes in your folder", bundle: .module)
            } footer: {
                Text("You edited these files outside Nook. Nothing is published until you say so, and the files are exactly as you left them.", bundle: .module)
            }
        }
    }

    /// Where the posts are on disk.
    ///
    /// Nook is a folder-backed tool everywhere else, and posts were the one thing a
    /// writer made that they could not open in Finder. This says where they are, and
    /// says plainly what the files are: copies, kept current from the repository. A
    /// folder that looked authoritative would invite editing that quietly went nowhere.
    ///
    /// Shown only once a pass has actually written something. A path offered before the
    /// directory exists sends the writer to a Finder window that is not there — and
    /// nothing is written at all when no sync folder has been chosen, or when the
    /// folder already holds another account's posts under the same name.
    @ViewBuilder
    private var mirrorSection: some View {
        if let directory = store.mirroredDirectory {
            Section {
                Button {
                    PlusPostMirror.reveal(directory)
                } label: {
                    Label {
                        // Named for the app that opens, which is not the same one on
                        // both platforms. "Show in Finder" on an iPhone is an
                        // instruction to use something that is not there.
                        #if os(macOS)
                            Text("Show Posts in Finder", bundle: .module)
                        #else
                            Text("Show Posts in Files", bundle: .module)
                        #endif
                    } icon: {
                        Image(systemName: "folder")
                    }
                }
                LabeledContent {
                    // The path, not just the folder name: a writer with more than one
                    // sync folder needs to know which one this is.
                    Text(verbatim: directory.path(percentEncoded: false))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } label: {
                    Text("Folder", bundle: .module)
                }
            } header: {
                Text("Posts on this device", bundle: .module)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Every published post is written here as a Markdown file, named after its address.", bundle: .module)
                    Text("These are copies. Nook keeps them up to date from your repository, so editing one does not change the published post and deleting one does not unpublish it — use the post's own row for that.", bundle: .module)
                }
            }
        }
    }

    /// Leaving the service.
    ///
    /// Last, and on its own, because it is the one thing here that cannot be undone
    /// by doing it again.
    ///
    /// Three different things get called "delete my account", and the difference is
    /// the whole point of this section's wording: what leaves is Nook's hold on the
    /// writer, not anything they wrote. The publications and articles are records in
    /// their own repository and stay there; the handle and the account stay; what
    /// goes is the membership and the public pages Nook generated. Deleting the
    /// account itself belongs to the repository host, is irreversible, and is
    /// deliberately not offered here.
    private var leavingSection: some View {
        Section {
            // Before leaving, and in the same section as it, because the contract's
            // advice is export first and a client that offers one without the other
            // is doing the writer a disservice. It is useful on its own too: a copy
            // of your own writing is not something you should have to be leaving to
            // get.
            Button {
                Task { await store.exportWriting() }
            } label: {
                Label {
                    if store.isExporting {
                        Text("Preparing your copy…", bundle: .module)
                    } else {
                        Text("Download a Copy of Your Writing", bundle: .module)
                    }
                } icon: {
                    if store.isExporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.doc")
                    }
                }
            }
            .disabled(store.isExporting || store.isWorking)

            Button(role: .destructive) {
                onLeave()
            } label: {
                Label {
                    Text("Leave Nook Plus", bundle: .module)
                } icon: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                }
            }
            .disabled(store.isWorking)
        } header: {
            Text("Leaving", bundle: .module)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("The copy is a file of your own records — every publication and article, exactly as your repository holds them.", bundle: .module)
                Text("Your publications and articles stay in your repository, and your name and account are untouched. What goes is your membership and the pages Nook publishes for you.", bundle: .module)
                Text("This is not the same as signing out, and not the same as deleting your account. Coming back needs a new invitation.", bundle: .module)
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
                if removing == record.uri {
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
                onTakeDown(record)
            } label: {
                Label {
                    Text("Take Down", bundle: .module)
                } icon: {
                    Image(systemName: "trash")
                }
            }
        }
        // The confirmation is not attached here, and must not be. A presentation
        // inside a `List` row goes away when the row is laid out again, and revealing
        // a swipe action is exactly that: the dialog appeared and vanished on its own
        // every time. It lives on the host, outside the list — the same reason the
        // sheets do, per the note at the top of this file.
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
                    // This used to say the production server was not running, which
                    // stopped being true the day it was deployed. The warning it
                    // needs now is the opposite one: everything here is real. An
                    // account created from a development build is a real account, it
                    // spends a real invitation, and neither can be undone.
                    Text("This is the real service. Anything you create here is real: a signup spends an invitation and cannot be undone.", bundle: .module)
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
