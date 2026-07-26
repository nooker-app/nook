import NookKit
import SwiftUI
import UIKit

/// Follows a site by URL. Nook validates and fetches it first, then dismisses
/// only after the site has actually been accepted. Framed for people who have
/// never heard of feeds: any website address works — discovery finds the
/// site's posts automatically.
struct AddFeedView: View {
    var folders: [String]
    var onAdd: (String, String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var feedURL = ""
    @State private var folderChoice: FolderChoice = .topLevel
    @State private var newFolderName = ""
    @State private var isSubmitting = false
    @State private var submissionError: String?
    @FocusState private var focused: Bool

    private enum FolderChoice: Hashable {
        case topLevel
        case existing(String)
        case newFolder
    }

    private var trimmedFeedURL: String {
        feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedNewFolderName: String {
        newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedFolder: String {
        switch folderChoice {
        case .topLevel:
            return ""
        case .existing(let folder):
            return folder
        case .newFolder:
            return trimmedNewFolderName
        }
    }

    private var canSubmit: Bool {
        !trimmedFeedURL.isEmpty
            && !isSubmitting
            && (folderChoice != .newFolder || !trimmedNewFolderName.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com", text: $feedURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focused)
                        .disabled(isSubmitting)
                        .onSubmit(add)
                }
                // Folder choice only appears once folders exist — a first-time
                // user shouldn't face an organizational decision before their
                // first site is even in.
                Section {
                    if !folders.isEmpty {
                        Picker("Folder", selection: $folderChoice) {
                            Text("Top Level").tag(FolderChoice.topLevel)
                            ForEach(folders, id: \.self) { folder in
                                Text(folder).tag(FolderChoice.existing(folder))
                            }
                            Text("New Folder…").tag(FolderChoice.newFolder)
                        }
                        .pickerStyle(.menu)

                        if folderChoice == .newFolder {
                            TextField("Folder Name", text: $newFolderName)
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                        }
                    }
                } footer: {
                    if isSubmitting {
                        Label {
                            Text("Checking the site…")
                        } icon: {
                            ProgressView()
                        }
                        .labelStyle(.titleAndIcon)
                    } else if let submissionError {
                        Label {
                            Text(submissionError)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.red)
                    } else {
                        // The one place "RSS" may appear, as reassurance for
                        // people who arrived with a feed link in hand.
                        Text("Paste a website address — Nook finds its posts automatically. Direct RSS links work too.")
                    }
                }
            }
            .navigationTitle("Follow a Site")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: add) {
                        if isSubmitting {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Checking…")
                            }
                        } else {
                            Text("Add")
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .task { focused = true }
            .onChange(of: feedURL) { _, _ in
                if submissionError != nil { submissionError = nil }
            }
            .onChange(of: folderChoice) { _, _ in
                if submissionError != nil { submissionError = nil }
            }
            .onChange(of: newFolderName) { _, _ in
                if submissionError != nil { submissionError = nil }
            }
        }
    }

    private func add() {
        guard canSubmit else { return }
        let feedURL = trimmedFeedURL
        let folder = selectedFolder
        isSubmitting = true
        submissionError = nil

        Task {
            do {
                try await onAdd(feedURL, folder)
                await MainActor.run {
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    submissionError = error.localizedDescription
                    isSubmitting = false
                }
            }
        }
    }
}
