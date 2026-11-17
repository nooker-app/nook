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
    @FocusState private var focusedField: Field?

    private enum Field { case address, folder }

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
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 23)).foregroundStyle(NookTheme.accent)
                    .frame(width: 56, height: 56)
                    .glassEffect(.regular.tint(NookTheme.accent.opacity(0.08)), in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add Feed").font(.system(size: 26, weight: .semibold))
                    Text("Bring a publication into your library.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Website or feed address").font(.callout.weight(.semibold))
                HStack(spacing: 12) {
                    Image(systemName: "link").foregroundStyle(NookTheme.accent)
                    TextField("https://example.com", text: $feedURL)
                        .focused($focusedField, equals: .address)
                        .accessibilityLabel("Website or feed address")
                        .onSubmit(addFeed)
                }
                .magazineInput(focused: focusedField == .address)
                Text("Paste an RSS or Atom feed URL, or a website address. Nook will check it before closing.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .disabled(isSubmitting)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Save to").font(.callout.weight(.semibold))
                    Spacer()
                    MagazineGlassMenu {
                        Picker("Folder", selection: $folderChoice) {
                            Text("Top Level").tag(FolderChoice.topLevel)
                            ForEach(folders, id: \.self) { folder in
                                Text(folder).tag(FolderChoice.existing(folder))
                            }
                            Text("New Folder…").tag(FolderChoice.newFolder)
                        }
                    } label: {
                        Label(folderLabel, systemImage: "folder")
                    }
                }
                if folderChoice == .newFolder {
                    TextField("Folder Name", text: $newFolderName)
                        .focused($focusedField, equals: .folder)
                        .magazineInput(focused: focusedField == .folder)
                        .onSubmit(addFeed)
                }
            }
            .disabled(isSubmitting)

            Group {
                if let submissionError {
                    Label(submissionError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).textSelection(.enabled)
                } else {
                    Label(isSubmitting ? "Checking RSS/Atom feed…" : "Nook will only close after it finds a valid feed.",
                          systemImage: isSubmitting ? "antenna.radiowaves.left.and.right" : "checkmark.shield")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(MagazineGlassButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Spacer()
                Button(action: addFeed) {
                    HStack(spacing: 8) {
                        if isSubmitting { ProgressView().controlSize(.small) }
                        else { Image(systemName: "plus") }
                        Text(isSubmitting ? "Checking…" : "Add Feed")
                    }
                }
                .buttonStyle(MagazineGlassButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(32).frame(width: 560)
        .background(NookTheme.canvas)
        .tint(NookTheme.accent)
        .interactiveDismissDisabled(isSubmitting)
        .task { focusedField = .address }
        .onChange(of: feedURL) { _, _ in submissionError = nil }
        .onChange(of: folderChoice) { _, choice in
            submissionError = nil
            if choice == .newFolder { focusedField = .folder }
        }
        .onChange(of: newFolderName) { _, _ in submissionError = nil }
    }

    private var folderLabel: String {
        switch folderChoice {
        case .topLevel: String(localized: "Top Level")
        case .existing(let folder): folder
        case .newFolder: String(localized: "New Folder…")
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

