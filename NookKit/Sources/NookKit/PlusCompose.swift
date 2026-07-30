import SwiftUI

/// Writing and publishing a post.
///
/// A screen of its own, reached from the reader rather than from Settings. The
/// form used to live in a settings section, which meant writing something began
/// with navigating into preferences: the wrong place for the one thing a writer
/// opens the app to do.
///
/// Shared by both platforms so there is one composer rather than two that drift.
public struct PlusComposeView: View {
    @Bindable var store: PlusStore
    let onFinished: () -> Void

    public init(store: PlusStore, onFinished: @escaping () -> Void) {
        self.store = store
        self.onFinished = onFinished
    }

    @State private var title = ""
    @State private var slug = ""
    /// True once the address has been edited by hand, after which the title stops
    /// driving it. Without this, correcting the address would be undone by the
    /// next keystroke in the title.
    @State private var slugEdited = false
    @State private var summary = ""
    @State private var markdown = ""
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case title
        case body
    }

    public var body: some View {
        #if os(iOS)
            NavigationStack {
                form
                    .background(PlusTheme.canvas.ignoresSafeArea())
                    .tint(PlusTheme.accent)
                    .navigationTitle(Text("New post", bundle: .module))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { onFinished() } label: { Text("Cancel", bundle: .module) }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { Task { await publish() } } label: {
                                if store.isWorking {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Publish", bundle: .module).fontWeight(.semibold)
                                }
                            }
                            .disabled(!canPublish)
                        }
                    }
            }
            .onAppear { focus = .title }
        #else
            VStack(alignment: .leading, spacing: 0) {
                form
                Divider()
                HStack {
                    Button { onFinished() } label: { Text("Cancel", bundle: .module) }
                    Spacer()
                    Button { Task { await publish() } } label: { Text("Publish", bundle: .module) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canPublish)
                }
                .padding(16)
            }
            .frame(minWidth: 520, minHeight: 460)
        #endif
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let published = store.lastPublishedURL, let url = URL(string: published) {
                    // Kept on screen after publishing so the writer can see the
                    // thing they just made, rather than being returned to a list
                    // and told it worked.
                    Label {
                        Link(destination: url) { Text("View your post", bundle: .module) }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .foregroundStyle(.green)
                    .font(.callout)
                }

                field(Text("Title", bundle: .module)) {
                    TextField(text: $title, prompt: Text(verbatim: "")) {
                        Text("Title", bundle: .module)
                    }
                    .font(.title3.weight(.semibold))
                    .focused($focus, equals: .title)
                    .onChange(of: title) { _, latest in
                        // The address follows the title until the writer takes it
                        // over. Making them invent one by hand was the fiddliest
                        // part of publishing, for a value most people would rather
                        // not think about.
                        if !slugEdited { slug = PlusSlug.derive(from: latest) }
                    }
                }

                field(Text("Web address", bundle: .module)) {
                    HStack(spacing: 2) {
                        if let base = store.publicationBaseURL {
                            Text(verbatim: base + "/")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        TextField(text: $slug, prompt: Text(verbatim: "my-first-post")) {
                            Text("Web address", bundle: .module)
                        }
                        .font(.caption.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                        #endif
                        .onChange(of: slug) { _, _ in slugEdited = true }
                    }
                }

                field(Text("One-line summary (optional)", bundle: .module)) {
                    TextField(text: $summary, prompt: Text(verbatim: "")) {
                        Text("One-line summary (optional)", bundle: .module)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    // Renders while it is being typed, and never rewrites what was
                    // typed. See PlusMarkdownEditor for why that distinction is the
                    // whole design.
                    PlusMarkdownEditor(text: $markdown)
                        .frame(minHeight: 300)
                        .overlay(alignment: .topLeading) {
                            if markdown.isEmpty {
                                Text("Write here. **Bold**, *italic*, and [links](https://example.com) work.", bundle: .module)
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                        .padding(8)
                        .background(cardBackground)

                    Text("Markdown, styled as you type. Headings, lists, links, quotes, and code all work; images are not supported yet.", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let failure = store.failure {
                    Label { Text(verbatim: failure) } icon: { Image(systemName: "exclamationmark.triangle") }
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private func field<Content: View>(_ label: Text, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            label
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
                .padding(.vertical, 9)
                .padding(.horizontal, 11)
                .background(cardBackground)
        }
    }

    @ViewBuilder
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        #if os(iOS)
            shape.fill(PlusTheme.card)
        #else
            shape.fill(.quaternary.opacity(0.25))
        #endif
    }

    private var canPublish: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && store.canPublish
    }

    private func publish() async {
        await store.publish(title: title, slug: slug, markdown: markdown, summary: summary)
        guard store.failure == nil else { return }
        // Cleared only on success, so a rejected post is not lost along with the
        // reason it was rejected.
        title = ""
        slug = ""
        slugEdited = false
        summary = ""
        markdown = ""
        onFinished()
    }
}

/// Turns a title into a usable web address.
///
/// Exists so nobody has to invent one. The rules match what the service accepts
/// for an article slug: lowercase, ASCII letters and digits, single hyphens
/// between words.
enum PlusSlug {
    static let maximumLength = 60

    static func derive(from title: String) -> String {
        var out = ""
        var pendingHyphen = false

        for scalar in title.lowercased().unicodeScalars {
            switch scalar {
            case "a"..."z", "0"..."9":
                let separator = pendingHyphen && !out.isEmpty
                // Checked before appending, not after. Measuring the result of an
                // append can only discover that the limit was already passed.
                if out.utf8.count + (separator ? 2 : 1) > maximumLength { return out }
                if separator { out.append("-") }
                pendingHyphen = false
                out.unicodeScalars.append(scalar)
            default:
                // Anything else, including a letter from another script, becomes a
                // word break rather than being transliterated. A title with no
                // ASCII at all yields nothing, and the writer types an address
                // themselves; guessing at a romanisation would be worse than
                // asking.
                pendingHyphen = true
            }
        }
        return out
    }
}
