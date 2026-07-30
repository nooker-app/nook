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
    @State private var showingCompose = false

    public init(@ViewBuilder container: @escaping (PlusSettingsContent) -> Container) {
        self.container = container
    }

    public var body: some View {
        container(
            PlusSettingsContent(
                store: store,
                onSetUp: { present(.setUp) },
                onSignIn: { present(.signIn) },
                onCompose: { present(.compose) }
            )
        )
        .task { openSetupIfInvited() }
        .onChange(of: PlusInviteInbox.shared.pendingCode) { _, code in
            if code != nil { openSetupIfInvited() }
        }
        .sheet(isPresented: $showingSetup) {
            PlusOnboardingView(store: store) { showingSetup = false }
        }
        .sheet(isPresented: $showingSignIn) {
            PlusSignInView(store: store) { showingSignIn = false }
        }
        .sheet(isPresented: $showingCompose) {
            PlusComposeView(store: store) { showingCompose = false }
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

    /// Opens one of the two sheets.
    ///
    /// The store outlives both, so a failure left by one would otherwise
    /// describe something the user is no longer doing. Cleared here rather than
    /// from inside the sheet: a write to observed state while a sheet is being
    /// presented invalidates the presenting view and dismisses it on the spot.
    private func present(_ sheet: Sheet) {
        store.clearFailure()
        switch sheet {
        case .setUp: showingSetup = true
        case .signIn: showingSignIn = true
        case .compose: showingCompose = true
        }
    }

    private enum Sheet {
        case setUp
        case signIn
        case compose
    }
}
