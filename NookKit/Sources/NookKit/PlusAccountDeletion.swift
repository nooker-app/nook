import SwiftUI

/// Deleting the account itself.
///
/// A sheet rather than a row with a confirmation dialog, because this is the only
/// thing in Nook that destroys something the user cannot get back by any means, and
/// it needs room to say so before it asks for anything.
///
/// Two steps, in this order. The host emails a code; the code and the password are
/// then submitted together. Neither is ceremony: the host authorises deletion with
/// something only the account's mailbox receives, so a phone left unlocked cannot end
/// an account, and the password is asked for again because a live session is not
/// enough to justify something irreversible.
public struct PlusAccountDeletionSheet: View {
    private let store: PlusStore
    private let onFinished: () -> Void

    @State private var code = ""
    @State private var password = ""

    /// Asked rather than assumed, and defaulting to on because somebody who has typed
    /// a password and an emailed code to delete their account means all of it. The
    /// footer says what it takes, and the copy of their writing is one screen back.
    @State private var discardDrafts = true

    @State private var confirming = false

    public init(store: PlusStore, onFinished: @escaping () -> Void) {
        self.store = store
        self.onFinished = onFinished
    }

    private var canSubmit: Bool {
        !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
            && !store.isWorking
    }

    public var body: some View {
        NavigationStack {
            Form {
                explanation
                if store.accountDeletionRequested {
                    credentials
                    // Above the toggle and the button, not below them. A wrong code
                    // is reported by the button at the bottom of the form, and a
                    // message placed after it sat below the fold — the one thing the
                    // writer needs to read was the one thing they had to scroll for.
                    failureSection
                    if offersDrafts { draftsSection }
                    submit
                } else {
                    request
                    failureSection
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text("Delete Account", bundle: .module))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        store.cancelAccountDeletion()
                        onFinished()
                    } label: {
                        Text("Cancel", bundle: .module)
                    }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    /// What goes, said in full before anything is asked for.
    ///
    /// Named against the other two things called deletion, because a writer who has
    /// already seen "Leave Nook Plus" has been told their writing survives that, and
    /// the difference here is the entire point.
    private var explanation: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("This deletes your account on the server that stores your writing.", bundle: .module)
                    .font(.headline)
                Text("Your name, your address, every publication, every article, and every image go with it. Published pages come down. Nothing here can be undone, and nothing can bring the account back — a new one starts empty, with a new invitation.", bundle: .module)
                Text("This is not the same as leaving Nook Plus. Leaving keeps your account and everything in it.", bundle: .module)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    private var request: some View {
        Section {
            Button {
                Task { await store.requestAccountDeletion() }
            } label: {
                if store.isWorking {
                    Label {
                        Text("Sending…", bundle: .module)
                    } icon: {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Text("Email Me a Code", bundle: .module)
                }
            }
            .disabled(store.isWorking)
        } footer: {
            Text("The server sends a code to the email address on the account. You will need it, along with your password, on the next step.", bundle: .module)
        }
    }

    private var credentials: some View {
        Section {
            TextField(text: $code) { Text("Code from the email", bundle: .module) }
                .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .textContentType(.oneTimeCode)
                #endif
            SecureField(text: $password) { Text("Your password", bundle: .module) }
                .textContentType(.password)
        } header: {
            Text("Confirm it is you", bundle: .module)
        } footer: {
            Text("Didn’t get it? Check the address the account was made with, then ask again.", bundle: .module)
        }
    }

    @ViewBuilder private var failureSection: some View {
        if let failure = store.failure {
            Section {
                Text(verbatim: failure).foregroundStyle(.red)
            }
        }
    }

    /// Whether there is a decision to offer at all. A disabled toggle over writing
    /// that does not exist is a question about nothing, and it was on screen.
    private var offersDrafts: Bool {
        store.canKeepDrafts && !store.drafts.isEmpty
    }

    private var draftsSection: some View {
        Section {
            Toggle(isOn: $discardDrafts) {
                Text("Also delete drafts on this device", bundle: .module)
            }
        } footer: {
            // Said plainly, because this is the one part of the act that deleting the
            // account does not decide on its own: drafts were never published, so
            // this device may hold the only copy there is.
            Text("Drafts are unpublished writing kept only on this device, so deleting your account does not reach them. Turn this off to keep them.", bundle: .module)
        }
    }

    private var submit: some View {
        Section {
            Button(role: .destructive) {
                confirming = true
            } label: {
                if store.isWorking {
                    Label {
                        Text("Deleting…", bundle: .module)
                    } icon: {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Text("Delete My Account", bundle: .module)
                }
            }
            .disabled(!canSubmit)
            .confirmationDialog(
                Text("Delete your account?", bundle: .module),
                isPresented: $confirming,
                titleVisibility: .visible
            ) {
                Button(role: .destructive) {
                    confirming = false
                    Task {
                        await store.deleteAccount(
                            password: password,
                            token: code,
                            discardingDrafts: discardDrafts && offersDrafts
                        )
                        // Only on success. A failure leaves the sheet open with its
                        // message, which is the one place the writer can act on it.
                        if store.accountDeleted { onFinished() }
                    }
                } label: {
                    Text("Delete Everything", bundle: .module)
                }
                Button(role: .cancel) { confirming = false } label: {
                    Text("Keep My Account", bundle: .module)
                }
            } message: {
                Text("Everything you have written on this account goes, permanently. There is no undo.", bundle: .module)
            }
        } footer: {
            Text("Take a copy of your writing first if you want one — the button is in Settings, under Leaving.", bundle: .module)
        }
    }
}
