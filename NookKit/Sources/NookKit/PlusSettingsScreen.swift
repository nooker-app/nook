import NookPlusProtocol
import SwiftUI

/// The Publishing settings screen, owning everything the rows must not.
///
/// Split out because a `.sheet` attached inside a `List`'s row content is torn
/// down when the row is re-laid-out, which showed up as the setup sheet opening
/// and closing again on the first tap and working on the second. The app's own
/// settings screens already put presentation state and sheets on the view that
/// owns the container, and pass intent down to the row content — this follows
/// that, so the presentation no longer hangs off a row.
///
/// It also owns the store, so a rebuilt row cannot take the session with it.
public struct PlusSettingsScreenContent<Container: View>: View {
    /// Wraps the rows in the host's own container, so macOS can use a `Form` and
    /// iOS a `List` without this type knowing which.
    private let container: (PlusSettingsContent) -> Container

    @State private var store = PlusStore()
    @State private var showingSetup = false
    @State private var showingSignIn = false

    /// What the composer is open on, present only while it is open. Item-driven rather
    /// than a flag beside a value: a sheet built from state set in the same update gets
    /// the old value, which is how the composer once slid up empty.
    @State private var composing: ComposeSession?

    private struct ComposeSession: Identifiable {
        let id = UUID()
        let target: PlusComposeTarget
    }

    /// The post the writer has asked to take down, held until they choose what that
    /// should mean. Here rather than in the rows for the reason in this type's own
    /// note: a presentation attached inside a `List` row is torn down when the row is
    /// laid out again, and revealing a swipe action does that — the dialog appeared and
    /// closed itself immediately, every time.
    @State private var pendingTakeDown: ATRecord<ArticleRecord>?

    /// A post being removed, so its row can show it rather than the screen going busy.
    @State private var removing: String?

    /// A failed removal, told as an alert where the action was. The banner at the top
    /// of the screen is the wrong place for a failure caused by a swipe several
    /// sections down: the row stays and the explanation is behind a scroll.
    @State private var removalFailure: String?

    public init(@ViewBuilder container: @escaping (PlusSettingsContent) -> Container) {
        self.container = container
    }

    public var body: some View {
        container(
            PlusSettingsContent(
                store: store,
                onSetUp: { present(.setUp) },
                onSignIn: { present(.signIn) },
                onCompose: { target in present(.compose(target)) },
                onTakeDown: { record in pendingTakeDown = record },
                removing: removing
            )
        )
        .confirmationDialog(
            Text("Take this post down?", bundle: .module),
            isPresented: Binding(
                get: { pendingTakeDown != nil },
                set: { if !$0 { pendingTakeDown = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingTakeDown
        ) { target in
            // Two different acts, and the difference is the text. Both remove the
            // record — that is what makes a post not public — but one keeps what was
            // written and the other does not.
            if store.canKeepDrafts {
                Button {
                    pendingTakeDown = nil
                    Task { await takeDown(target, keepingDraft: true) }
                } label: {
                    Text("Unpublish and Keep a Draft", bundle: .module)
                }
            }
            Button(role: .destructive) {
                pendingTakeDown = nil
                Task { await takeDown(target, keepingDraft: false) }
            } label: {
                Text("Delete the Text Too", bundle: .module)
            }
            Button(role: .cancel) { pendingTakeDown = nil } label: {
                Text("Cancel", bundle: .module)
            }
        } message: { target in
            Text(
                "“\(target.value.title)” comes off the web either way. Keeping a draft leaves the text on this device so you can publish it again; deleting the text keeps no copy anywhere.",
                bundle: .module)
        }
        .alert(
            Text("Couldn’t take that post down", bundle: .module),
            isPresented: Binding(
                get: { removalFailure != nil },
                set: { if !$0 { removalFailure = nil } }
            ),
            presenting: removalFailure
        ) { _ in
            Button { removalFailure = nil } label: { Text("OK", bundle: .module) }
        } message: { why in
            Text(verbatim: why)
        }
        .task {
            openSetupIfInvited()
            // Drafts are on disk, so they are there before any network call and must
            // be listed whether or not the account can be reached.
            store.loadDrafts()
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
        .sheet(item: $composing) { session in
            PlusComposeView(store: store, target: session.target) { composing = nil }
        }
    }

    /// Removes a post from the web, keeping its text as a draft or not.
    ///
    /// The failure is taken off the store so it is told once, in the alert, rather than
    /// also sitting in the banner at the top of the screen.
    private func takeDown(_ record: ATRecord<ArticleRecord>, keepingDraft: Bool) async {
        removing = record.uri
        if keepingDraft {
            await store.unpublish(record)
        } else {
            await store.delete(record)
        }
        removing = nil
        if let failure = store.failure {
            removalFailure = failure
            store.clearFailure()
        }
    }

    /// Opens setup when an invitation link is waiting.
    ///
    /// Ignored for someone already signed in: a forwarded link must not offer to
    /// replace an account that already exists.
    private func openSetupIfInvited() {
        guard !store.isSignedIn, PlusInviteInbox.shared.pendingCode != nil else { return }
        present(.setUp)
    }

    /// Opens one of the sheets.
    ///
    /// The store outlives all of them, so a failure left by one would otherwise
    /// describe something the user is no longer doing. Cleared here rather than
    /// from inside the sheet: a write to observed state while a sheet is being
    /// presented invalidates the presenting view and dismisses it on the spot.
    private func present(_ sheet: Sheet) {
        store.clearFailure()
        switch sheet {
        case .setUp: showingSetup = true
        case .signIn: showingSignIn = true
        case .compose(let target):
            composing = ComposeSession(target: target)
            // Re-reads the session and renews a token that expired while the app was
            // idle, so Publish is not disabled on a screen that looks signed in.
            Task { await store.prepareToCompose() }
        }
    }

    private enum Sheet {
        case setUp
        case signIn
        case compose(PlusComposeTarget)
    }
}
