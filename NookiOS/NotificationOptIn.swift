import NookKit
import SwiftUI
import UserNotifications

/// What the reader is asked once the tutorial is behind them, and the only place
/// a first notification prompt can come from.
///
/// Nook used to ask iOS for notification permission on the first launch of every
/// install. Nothing had been switched on deliberately — the badge simply defaulted
/// to on, which was enough to satisfy the "are any notification features in use"
/// check — so the system prompt appeared over the tutorial, before the reader had
/// any idea what it was for. A prompt is asked once and answered forever, and
/// spending it on someone who has not yet seen the app is spending it badly.
///
/// So all three settings now start off, this screen explains what each one does,
/// and the prompt only follows a switch the reader turned on themselves.
struct NotificationOptInSheet: View {
    /// Set once the reader has answered, so this is never shown twice. Separate
    /// from the tutorial's own flag: replaying the tutorial should not re-ask a
    /// question already answered.
    static let seenKey = "hasSeenNotificationOptIn"

    @Environment(\.dismiss) private var dismiss

    @AppStorage("showUnreadBadge") private var showUnreadBadge = false
    @AppStorage(BackgroundRefresh.enabledKey) private var newArticleNotifications = false
    @AppStorage("autoRefreshEnabled") private var autoRefreshEnabled = false
    @AppStorage(NotificationOptInSheet.seenKey) private var hasSeenOptIn = false

    /// Local until the reader confirms, so backing out of the sheet changes
    /// nothing. Writing straight to `@AppStorage` would leave a half-made choice
    /// behind if they swiped it away.
    @State private var wantsBadge = false
    @State private var wantsAlerts = false
    @State private var wantsAutoRefresh = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header

                    VStack(spacing: 0) {
                        choice(
                            icon: "bell.badge",
                            title: "New articles",
                            detail: "Nook checks your feeds in the background and tells you when something arrives. Needs permission to show notifications.",
                            isOn: $wantsAlerts)
                        Divider().padding(.leading, 60)
                        choice(
                            icon: "app.badge",
                            title: "Unread count",
                            detail: "Shows how many unread articles are waiting, on the app icon. Also needs notification permission — that is what iOS calls the badge.",
                            isOn: $wantsBadge)
                        Divider().padding(.leading, 60)
                        choice(
                            icon: "arrow.clockwise",
                            title: "Refresh on opening",
                            detail: "Fetches your feeds when you come back to Nook, so the list is current. Needs no permission and uses no background time.",
                            isOn: $wantsAutoRefresh)
                    }
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 20)

                    Text(footnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 32)
                }
                .padding(.vertical, 28)
            }
            .safeAreaInset(edge: .bottom) { actions }
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 92, height: 92)
                Image(systemName: "bell.badge")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
            }
            Text("Keeping up with your feeds")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("All of this is off. Turn on only what you want — you can change any of it later in Settings.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 32)
    }

    /// The sentence changes with the choice, so the button never surprises: it
    /// says whether iOS is about to ask for anything.
    private var footnote: LocalizedStringKey {
        needsAuthorization
            ? "iOS will ask you to allow notifications next."
            : "Nothing here asks iOS for permission."
    }

    /// Only the two that need it. Refreshing on opening is not a notification, and
    /// prompting for it would be the same mistake in a smaller place.
    private var needsAuthorization: Bool { wantsAlerts || wantsBadge }

    private var actions: some View {
        VStack(spacing: 10) {
            Button(action: confirm) {
                Text(needsAuthorization ? "Continue" : "Done")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)

            Button(action: skip) {
                Text("Not now")
                    .font(.subheadline)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private func choice(
        icon: String, title: LocalizedStringKey, detail: LocalizedStringKey, isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, alignment: .center)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// Applies the choice, then asks iOS — in that order, and only if something
    /// that needs asking was turned on.
    private func confirm() {
        showUnreadBadge = wantsBadge
        newArticleNotifications = wantsAlerts
        autoRefreshEnabled = wantsAutoRefresh
        hasSeenOptIn = true

        Task {
            if needsAuthorization {
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
            }
            // After the answer, so a refused prompt does not leave a background
            // task scheduled for notifications that cannot be delivered.
            if wantsAlerts { BackgroundRefresh.schedule() }
            dismiss()
        }
    }

    /// Leaves every setting as it is — off — and asks iOS for nothing.
    private func skip() {
        hasSeenOptIn = true
        dismiss()
    }
}
