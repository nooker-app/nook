import AppKit
import NookKit
import SwiftUI
import UniformTypeIdentifiers

struct MagazineAddFeedSheet: View {
    var folders: [String]
    var onAdd: (String, String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var feedURL = ""
    @State private var folderChoice: FolderChoice = .topLevel
    @State private var newFolderName = ""
    @State private var isSubmitting = false
    @State private var submissionError: String?
    @FocusState private var isFocused: Bool

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
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add Feed")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Paste an RSS or Atom feed URL, or a website address. Nook will check it before closing.")
                    .foregroundStyle(.secondary)
            }

            TextField("https://example.com/feed.xml", text: $feedURL)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .disabled(isSubmitting)

            VStack(alignment: .leading, spacing: 8) {
                Text("Folder")
                    .font(.callout.weight(.semibold))
                Picker("Folder", selection: $folderChoice) {
                    Text("Top Level").tag(FolderChoice.topLevel)
                    ForEach(folders, id: \.self) { folder in
                        Text(folder).tag(FolderChoice.existing(folder))
                    }
                    Text("New Folder…").tag(FolderChoice.newFolder)
                }
                .labelsHidden()
                .pickerStyle(.menu)

                if folderChoice == .newFolder {
                    TextField("Folder Name", text: $newFolderName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Group {
                if isSubmitting {
                    Label {
                        Text("Checking RSS/Atom feed…")
                    } icon: {
                        ProgressView()
                    }
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                } else if let submissionError {
                    Label {
                        Text(submissionError)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.red)
                } else {
                    Text("Nook will only close after it finds a valid feed.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .frame(minHeight: 22, alignment: .leading)

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    addFeed()
                } label: {
                    if isSubmitting {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking…")
                        }
                    } else {
                        Text("Add")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(24)
        .frame(width: 440)
        .task { isFocused = true }
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

    private func addFeed() {
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

struct MagazineOPMLImportRequest: Identifiable {
    let id = UUID()
    let feeds: [OPMLFeed]
}

struct MagazineOPMLImportView: View {
    let feeds: [OPMLFeed]
    let existingKeys: Set<String>
    var onImport: ([OPMLFeed]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<OPMLFeed.ID>
    @State private var icons: [OPMLFeed.ID: NSImage] = [:]
    private let faviconService = FaviconService()

    init(feeds: [OPMLFeed], existingKeys: Set<String>, onImport: @escaping ([OPMLFeed]) -> Void) {
        self.feeds = feeds
        self.existingKeys = existingKeys
        self.onImport = onImport
        // Default to the feeds that are not already subscribed.
        let isNew: (OPMLFeed) -> Bool = { feed in
            !(existingKeys.contains(feed.feedURL.feedIdentityKey)
                || (feed.siteURL.map { existingKeys.contains($0.feedIdentityKey) } ?? false))
        }
        _selection = State(initialValue: Set(feeds.filter(isNew).map(\.id)))
    }

    private func isExisting(_ feed: OPMLFeed) -> Bool {
        existingKeys.contains(feed.feedURL.feedIdentityKey)
            || (feed.siteURL.map { existingKeys.contains($0.feedIdentityKey) } ?? false)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            List {
                ForEach(groupedFeeds, id: \.category) { group in
                    Section(group.category ?? String(localized: "Ungrouped")) {
                        ForEach(group.feeds) { feed in
                            feedRow(feed)
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520, idealHeight: 640)
        .task {
            await loadIcons()
        }
    }

    /// Temporarily fetches site favicons just for the preview list (not cached
    /// to the sync folder; that happens when a feed is actually imported).
    private func loadIcons() async {
        await withTaskGroup(of: (OPMLFeed.ID, Data?).self) { group in
            for feed in feeds {
                let iconURL = feed.siteURL ?? feed.feedURL
                group.addTask {
                    (feed.id, await faviconService.fetchFavicon(for: iconURL))
                }
            }
            for await (id, data) in group {
                if let data, let image = NSImage(data: data) {
                    icons[id] = image
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Import Feeds")
                    .font(.headline)
                Text("Choose which feeds to import.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(allSelected ? "Deselect All" : "Select All") {
                selection = allSelected ? [] : Set(feeds.map(\.id))
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(selection.count) selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button("Import \(selection.count) Feeds") {
                onImport(feeds.filter { selection.contains($0.id) })
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(selection.isEmpty)
        }
        .padding(16)
        .background(.bar)
    }

    private var allSelected: Bool { selection.count == feeds.count }

    private var groupedFeeds: [(category: String?, feeds: [OPMLFeed])] {
        var order: [String?] = []
        var map: [String?: [OPMLFeed]] = [:]
        for feed in feeds {
            if map[feed.category] == nil { order.append(feed.category) }
            map[feed.category, default: []].append(feed)
        }
        return order.map { (category: $0, feeds: map[$0] ?? []) }
    }

    private func feedRow(_ feed: OPMLFeed) -> some View {
        Toggle(isOn: binding(for: feed)) {
            HStack(spacing: 8) {
                Group {
                    if let icon = icons[feed.id] {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "globe")
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(feed.title)
                            .lineLimit(1)
                        if isExisting(feed) {
                            Text("Already added")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text(feed.feedURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func binding(for feed: OPMLFeed) -> Binding<Bool> {
        Binding {
            selection.contains(feed.id)
        } set: { isOn in
            if isOn { selection.insert(feed.id) } else { selection.remove(feed.id) }
        }
    }
}

