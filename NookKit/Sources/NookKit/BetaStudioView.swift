#if os(macOS)
import AppKit
import NookPlusProtocol
import SwiftUI

/// Beta's writing workspace. The text view and Markdown edit operations are the
/// same native engine used by Classic; its presentation and session are separate.
public struct BetaStudioView: View {
    @Bindable private var store: PlusStore
    @Binding private var session: BetaDraftSession?
    private let openSettings: () -> Void

    public init(store: PlusStore, session: Binding<BetaDraftSession?>, openSettings: @escaping () -> Void) {
        self.store = store
        _session = session
        self.openSettings = openSettings
    }

    @State private var selectedPost: ATRecord<ArticleRecord>?
    @State private var filter = ShelfFilter.all
    @State private var search = ""
    @State private var loading = false
    @State private var shelfPosition = ScrollPosition(edge: .top)
    @FocusState private var searchFocused: Bool

    private enum ShelfFilter: String, CaseIterable {
        case all = "All", drafts = "Drafts", published = "Published"
    }

    public var body: some View {
        Group {
            if let session {
                BetaWritingCanvas(store: store, session: session) {
                    guard session.flush() else { return }
                    self.session = nil
                    store.loadDrafts()
                }
            } else if let selectedPost {
                BetaPublishedPostView(record: selectedPost, publicationURL: store.publicationURL) {
                    self.selectedPost = nil
                }
            } else {
                shelf
            }
        }
        .task { await refreshShelf() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard session == nil, selectedPost == nil, !loading else { return }
            Task { await refreshShelf() }
        }
    }

    private func refreshShelf() async {
        guard !loading, !store.isWorking else { return }
        loading = true
        defer { loading = false }
        store.loadDrafts()
        await store.refreshWritingShelf()
    }

    private func matches(_ title: String, _ body: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || title.localizedStandardContains(query) || body.localizedStandardContains(query)
    }

    private var drafts: [PlusDraft] { store.drafts.filter { matches($0.displayTitle, $0.markdown) } }
    private var posts: [ATRecord<ArticleRecord>] { store.articles.filter { matches($0.value.title, $0.value.summary ?? "") } }

    private var shelf: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("YOUR WRITING SPACE").font(.system(size: 10, weight: .semibold)).tracking(2.5).foregroundStyle(.secondary)
                        MagazineHeadline("Studio", size: 42)
                        Text("Every draft and every published story, together.", bundle: .module)
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await refreshShelf() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(MagazineGlassButtonStyle())
                    .help(Text("Refresh", bundle: .module)).disabled(loading || store.isWorking)
                    Button {
                        store.startNewDraft()
                        session = BetaDraftSession()
                        Task { await store.prepareToCompose() }
                    } label: {
                        Label { Text("New post", bundle: .module) } icon: { Image(systemName: "square.and.pencil") }
                    }
                    .buttonStyle(MagazineGlassButtonStyle(prominent: true))
                    .disabled(!store.isSignedIn)
                }
                HStack(spacing: 24) {
                    MagazineGlassSegments(ShelfFilter.allCases, selection: $filter) { item in
                        Text(LocalizedStringKey(item.rawValue), bundle: .module)
                    }.frame(width: 280).accessibilityLabel(Text("Your writing", bundle: .module))
                    Spacer()
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(text: $search, prompt: Text("Find your writing", bundle: .module)) {
                            Text("Find your writing", bundle: .module)
                        }.focused($searchFocused)
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(MagazinePlainButtonStyle()).help(Text("Clear Search", bundle: .module))
                        }
                    }.magazineInput(focused: searchFocused).frame(width: 280)
                }
                if !store.isSignedIn {
                    HStack(spacing: 16) {
                        Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(NookTheme.accent)
                        Text("Sign in to see your published stories and start writing.", bundle: .module)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(action: openSettings) { Text("Open Settings", bundle: .module) }
                            .buttonStyle(MagazineGlassButtonStyle())
                    }.padding(22).background(NookTheme.card, in: RoundedRectangle(cornerRadius: 18))
                }
                if let failure = store.failure {
                    HStack {
                        Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                        Spacer()
                        Button { Task { await refreshShelf() } } label: { Text("Retry", bundle: .module) }
                            .buttonStyle(MagazineGlassButtonStyle()).disabled(loading)
                    }
                }
                if filter != .published {
                    sectionHeading("Drafts", count: drafts.count, icon: "doc.text")
                    if drafts.isEmpty { emptyShelf("No drafts here yet.") }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 22)], spacing: 22) {
                        ForEach(drafts) { draft in
                            Button {
                                session = BetaDraftSession(draft: draft)
                                Task { await store.prepareToCompose() }
                            } label: {
                                writingCard(title: draft.displayTitle, excerpt: draft.markdown,
                                            status: "Draft", date: draft.updatedAt, icon: "pencil")
                            }.buttonStyle(MagazineCardStyle())
                        }
                    }
                }
                if filter != .drafts && store.isSignedIn {
                    sectionHeading("Published", count: posts.count, icon: "checkmark.seal")
                    if loading && store.articles.isEmpty {
                        HStack(spacing: 12) { ProgressView().controlSize(.small); Text("Loading your stories…", bundle: .module) }
                            .foregroundStyle(.secondary).padding(24)
                    } else if posts.isEmpty { emptyShelf("Your published stories will appear here.") }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 22)], spacing: 22) {
                        ForEach(posts, id: \.uri) { post in
                            Button { selectedPost = post } label: {
                                writingCard(title: post.value.title, excerpt: post.value.summary ?? post.value.content,
                                            status: "Published", date: Self.date(post.value.publishedAt), icon: "checkmark.seal")
                            }.buttonStyle(MagazineCardStyle())
                        }
                    }
                }
            }
            .padding(40).frame(maxWidth: 1280).frame(maxWidth: .infinity)
        }
        .scrollPosition($shelfPosition)
    }

    private func sectionHeading(_ title: LocalizedStringKey, count: Int, icon: String) -> some View {
        HStack(spacing: 10) {
            Label { Text(title, bundle: .module) } icon: { Image(systemName: icon) }
                .font(.system(size: 18, weight: .semibold))
            Text(count, format: .number).font(.callout).foregroundStyle(.secondary)
            Rectangle().fill(NookTheme.hairline).frame(height: 1)
        }
    }

    private func emptyShelf(_ text: LocalizedStringKey) -> some View {
        Text(search.isEmpty ? text : "No matching stories.", bundle: .module)
            .foregroundStyle(.secondary).padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(NookTheme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private func writingCard(title: String, excerpt: String, status: LocalizedStringKey, date: Date?, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label { Text(status, bundle: .module) } icon: { Image(systemName: icon) }
                .font(.caption.weight(.medium)).foregroundStyle(NookTheme.accent)
            MagazineHeadline(title.isEmpty ? String(localized: "Untitled", bundle: .module) : title, size: 24, lines: 3)
            Text(excerpt).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            Spacer(minLength: 0)
            HStack {
                if let date { Text(date, style: .date) }
                Spacer()
                Image(systemName: "arrow.up.right")
            }.font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
        .padding(24).background(NookTheme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private struct BetaPublishedPostView: View {
    let record: ATRecord<ArticleRecord>
    let publicationURL: String?
    let onClose: () -> Void
    @Environment(\.openURL) private var openURL

    private var url: URL? {
        PlusOwnFeed.articleURL(publicationURL: publicationURL, slug: record.value.slug).flatMap(URL.init(string:))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) { Label("Studio", systemImage: "arrow.left") }
                    .buttonStyle(MagazineGlassButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                Label { Text("Published", bundle: .module) } icon: { Image(systemName: "checkmark.seal") }
                    .font(.callout).foregroundStyle(.secondary)
                if let url {
                    Button { openURL(url) } label: { Label { Text("Open Original", bundle: .module) } icon: { Image(systemName: "safari") } }
                        .buttonStyle(MagazineGlassButtonStyle())
                    ShareLink(item: url).buttonStyle(MagazineGlassButtonStyle())
                }
            }.padding(.horizontal, 32).padding(.vertical, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    MagazineHeadline(record.value.title, size: 36)
                    if let summary = record.value.summary, !summary.isEmpty {
                        Text(summary).font(.title3).foregroundStyle(.secondary)
                    }
                    Divider()
                    BetaMarkdownPreview(markdown: record.value.content, baseURL: url)
                }.padding(40).frame(maxWidth: 900).frame(maxWidth: .infinity)
            }
        }.background(NookTheme.canvas)
    }
}

/// Both published posts and draft previews use the complete reader, including
/// its anchor navigation. Bare HTMLBlockList displays links but cannot follow them.
private struct BetaMarkdownPreview: View {
    let markdown: String
    var baseURL: URL?
    @State private var rendered: Rendered?

    private struct Source: Equatable {
        let markdown: String
        let baseURL: URL?
    }

    private struct Rendered {
        let source: Source
        let html: String
    }

    private var source: Source { Source(markdown: markdown, baseURL: baseURL) }

    var body: some View {
        Group {
            if let rendered, rendered.source == source {
                HTMLContentView(html: rendered.html, baseURL: baseURL, typography: .current())
            } else { ProgressView().controlSize(.small) }
        }
        .task(id: source) {
            let source = source
            let html = await Task.detached(priority: .userInitiated) {
                let html = PlusMarkdownRenderer.html(from: source.markdown)
                HTMLBlockCache.shared.store(
                    HTMLContentParser.parseWithAnchors(html, baseURL: source.baseURL),
                    html: html, baseURL: source.baseURL)
                return html
            }.value
            guard !Task.isCancelled else { return }
            await HTMLContentText.warmReaderAttributedCache(
                html: html, baseURL: source.baseURL, typography: .current(), maxBlocks: 14)
            guard !Task.isCancelled else { return }
            rendered = Rendered(source: source, html: html)
        }
    }
}

private struct BetaWritingCanvas: View {
    @Bindable var store: PlusStore
    @Bindable var session: BetaDraftSession
    let onClose: () -> Void
    @State private var editor = PlusMarkdownEditorHandle()
    @State private var details = false
    @State private var preview = false
    @State private var slugField = PlusSlugField()

    @FocusState private var focusedField: Field?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Field { case title, address, summary }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onClose) {
                    Label("Studio", systemImage: "arrow.left")
                }.buttonStyle(MagazineGlassButtonStyle())
                Spacer()
                status
                Button { preview.toggle() } label: {
                    Label { Text(preview ? "Edit" : "Preview", bundle: .module) } icon: { Image(systemName: preview ? "pencil" : "eye") }
                }.buttonStyle(MagazineGlassButtonStyle())
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { details.toggle() }
                } label: {
                    Label { Text("Details", bundle: .module) } icon: { Image(systemName: "sidebar.right") }
                }
                .buttonStyle(MagazineGlassButtonStyle(prominent: details))
                .accessibilityValue(Text(details ? "Shown" : "Hidden", bundle: .module))
                Button { Task { await publish() } } label: {
                    if session.isPublishing { ProgressView().controlSize(.small) }
                    else { Label { Text("Publish", bundle: .module) } icon: { Image(systemName: "paperplane") } }
                }
                .buttonStyle(MagazineGlassButtonStyle(prominent: true))
                .disabled(!canPublish)
            }.padding(.horizontal, 28).padding(.vertical, 16)

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 20) {
                    TextField(text: $session.draft.title, prompt: Text("Give your story a title", bundle: .module), axis: .vertical) {
                        Text("Title", bundle: .module)
                    }
                    .font(.system(size: 30, weight: .semibold)).lineLimit(1...3)
                    .focused($focusedField, equals: .title)
                    .magazineInput(focused: focusedField == .title)
                    .onSubmit { editor.focus() }
                    ZStack {
                        PlusMarkdownEditor(text: $session.draft.markdown,
                                           placeholder: String(localized: "Write here. Markdown works.", bundle: .module),
                                           handle: editor, bottomInset: 78)
                            .opacity(preview ? 0 : 1)
                            .allowsHitTesting(!preview).accessibilityHidden(preview)
                        if preview {
                            ScrollView {
                                BetaMarkdownPreview(markdown: session.draft.markdown)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            }
                        }
                    }
                    .padding(18)
                    .background(NookTheme.card, in: RoundedRectangle(cornerRadius: 20))
                    .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(NookTheme.hairline, lineWidth: 0.5).allowsHitTesting(false) }
                    .overlay(alignment: .bottom) {
                        if !preview { formatting.padding(.bottom, 16) }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if details {
                    detailPanel.frame(width: 280)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 24)
            .frame(maxWidth: 1280).frame(maxWidth: .infinity, maxHeight: .infinity)
            if let issue = session.failure ?? store.failure {
                HStack {
                    Text(issue).font(.callout).foregroundStyle(.red).lineLimit(3)
                    if session.failure != nil {
                        Button { session.flush() } label: { Text("Retry", bundle: .module) }
                            .buttonStyle(MagazineGlassButtonStyle())
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.draft.title + "\n\n" + session.draft.markdown, forType: .string)
                    } label: { Text("Copy", bundle: .module) }
                        .buttonStyle(MagazineGlassButtonStyle())
                }.padding()
            }
        }
        .background(NookTheme.canvas)
        .disabled(session.isPublishing)
        .onAppear {
            slugField.fallback = PlusSlug.dated(Date(), avoiding: Set(store.articles.map(\.value.slug)))
            slugField.titleChanged(to: session.draft.title)
            if !session.draft.slug.isEmpty { slugField.changed(to: session.draft.slug) }
            else if !session.draft.title.isEmpty { session.draft.slug = slugField.value }
        }
        .onChange(of: session.draft.title) { _, title in
            slugField.titleChanged(to: title)
            session.draft.slug = slugField.value
        }
    }

    private var detailPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Post details", bundle: .module).font(.headline)
                    Spacer()
                    Button { details = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(MagazineGlassButtonStyle()).help(Text("Close", bundle: .module))
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label { Text("Address", bundle: .module) } icon: { Image(systemName: "link") }
                        .font(.callout.weight(.semibold))
                    TextField(text: Binding(get: { session.draft.slug }, set: { value in
                        slugField.changed(to: value)
                        session.draft.slug = value
                    }), prompt: Text("your-story", bundle: .module)) { Text("Address", bundle: .module) }
                        .focused($focusedField, equals: .address)
                        .magazineInput(focused: focusedField == .address)
                    if let slugIssue {
                        Text(slugIssue).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    } else if let link = PlusOwnFeed.articleURL(publicationURL: store.publicationURL, slug: session.draft.slug) {
                        Text(link).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Suggested from your title. Edit it to keep a custom address.", bundle: .module)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label { Text("Summary", bundle: .module) } icon: { Image(systemName: "text.alignleft") }
                        .font(.callout.weight(.semibold))
                    TextField(text: $session.draft.summary, prompt: Text("A short introduction for your readers", bundle: .module), axis: .vertical) {
                        Text("Summary", bundle: .module)
                    }
                    .lineLimit(4...8).focused($focusedField, equals: .summary)
                    .magazineInput(focused: focusedField == .summary)
                    Text("Optional. Shown in your publication and feed.", bundle: .module)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Label { Text("Your draft stays on this Mac until you publish.", bundle: .module) } icon: { Image(systemName: "lock") }
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(18)
        }
        .glassEffect(.regular.tint(NookTheme.accent.opacity(0.035)), in: RoundedRectangle(cornerRadius: 20))
    }

    private var slugIssue: String? {
        if let problem = PlusSlug.problem(with: session.draft.slug) { return problem.message }
        if store.articles.contains(where: { $0.value.slug == session.draft.slug }) {
            return String(localized: "This address is already used by one of your posts.", bundle: .module)
        }
        return nil
    }

    private var status: some View {
        Label {
            Text(session.failure != nil ? "Save failed" : (session.isDirty ? "Saving…" : "Saved on this Mac"), bundle: .module)
        } icon: {
            Image(systemName: session.failure != nil ? "exclamationmark.triangle" : "checkmark.circle")
        }.font(.callout).foregroundStyle(.secondary)
    }

    private var formatting: some View {
        HStack(spacing: 18) {
            formatButton("Bold", icon: "bold") { PlusMarkdownEdit.wrap($0, selection: $1, with: "**") }
            formatButton("Italic", icon: "italic") { PlusMarkdownEdit.wrap($0, selection: $1, with: "*") }
            formatButton("Heading", icon: "textformat.size") { PlusMarkdownEdit.toggleLinePrefix($0, selection: $1, marker: "## ") }
            formatButton("Quote", icon: "text.quote") { PlusMarkdownEdit.toggleLinePrefix($0, selection: $1, marker: "> ") }
            formatButton("Link", icon: "link") { PlusMarkdownEdit.link($0, selection: $1) }
        }
        .foregroundStyle(NookTheme.accent)
        .buttonStyle(MagazinePlainButtonStyle()).padding(.horizontal, 24).padding(.vertical, 14)
        .glassEffect(.regular.tint(NookTheme.accent.opacity(0.07)), in: Capsule())
    }

    private func formatButton(_ title: String, icon: String,
                              edit: @escaping (String, NSRange) -> PlusMarkdownEdit.Edit) -> some View {
        Button { editor.perform(edit) } label: { Image(systemName: icon) }
            .help(Text(title)).accessibilityLabel(Text(title))
    }

    private var canPublish: Bool {
        store.canPublish && !session.isPublishing
            && !session.draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !session.draft.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && slugIssue == nil
    }

    private func publish() async {
        guard session.beginPublishing() else { return }
        let draft = session.draft
        await store.publish(title: draft.title, slug: draft.slug, markdown: draft.markdown, summary: draft.summary)
        session.endPublishing()
        guard store.failure == nil else { return }
        store.discard(draft)
        onClose()
    }
}
#endif
