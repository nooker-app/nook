#if os(macOS)
import AppKit
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

    public var body: some View {
        Group {
            if let session {
                BetaWritingCanvas(store: store, session: session) {
                    guard session.flush() else { return }
                    self.session = nil
                    store.loadDrafts()
                }
            } else {
                shelf
            }
        }
        .task { store.loadDrafts() }
    }

    private var shelf: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("YOUR WRITING SPACE").font(.system(size: 10, weight: .semibold)).tracking(2.5).foregroundStyle(.secondary)
                        MagazineHeadline("Studio", size: 42)
                        Text("A space for what you have to say.", bundle: .module)
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        session = BetaDraftSession()
                        Task { await store.prepareToCompose() }
                    } label: {
                        Label { Text("New post", bundle: .module) } icon: { Image(systemName: "square.and.pencil") }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!store.isSignedIn)
                }
                Divider()
                if !store.isSignedIn {
                    ContentUnavailableView {
                        Label { Text("Your words belong here.", bundle: .module) } icon: { Image(systemName: "square.and.pencil") }
                    } description: {
                        Text("Sign in to Nook+ in Publishing settings to start writing.", bundle: .module)
                    } actions: {
                        Button { openSettings() } label: { Text("Open Settings", bundle: .module) }
                            .buttonStyle(MagazineGlassButtonStyle())
                    }
                    .frame(minHeight: 300)
                } else {
                    Text("Drafts", bundle: .module).font(.title2)
                    if store.drafts.isEmpty {
                        ContentUnavailableView {
                            Label { Text("Start with a thought.", bundle: .module) } icon: { Image(systemName: "pencil.and.outline") }
                        } description: {
                            Text("Your drafts stay on this Mac until you publish them.", bundle: .module)
                        }
                        .frame(minHeight: 240)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 22)], spacing: 22) {
                        ForEach(store.drafts) { draft in
                            Button {
                                session = BetaDraftSession(draft: draft)
                                Task { await store.prepareToCompose() }
                            } label: {
                                VStack(alignment: .leading, spacing: 16) {
                                    Image(systemName: "doc.text").font(.title2).foregroundStyle(.secondary)
                                    MagazineHeadline(draft.displayTitle, size: 24, lines: 3)
                                    Text(draft.markdown).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                                    Spacer(minLength: 0)
                                    Text(draft.updatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
                                .padding(24)
                                .background(NookTheme.card, in: RoundedRectangle(cornerRadius: 18))
                            }
                            .buttonStyle(MagazineCardStyle())
                        }
                    }
                }
            }
            .padding(40).frame(maxWidth: 1280).frame(maxWidth: .infinity)
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Label { Text("Drafts", bundle: .module) } icon: { Image(systemName: "arrow.left") }
                }.buttonStyle(MagazineGlassButtonStyle())
                Spacer()
                status
                Button { preview.toggle() } label: {
                    Label { Text(preview ? "Edit" : "Preview", bundle: .module) } icon: { Image(systemName: preview ? "pencil" : "eye") }
                }.buttonStyle(MagazineGlassButtonStyle())
                Button { details.toggle() } label: {
                    Label { Text("Details", bundle: .module) } icon: { Image(systemName: "slider.horizontal.3") }
                }.buttonStyle(MagazineGlassButtonStyle())
                Button { Task { await publish() } } label: { Text("Publish", bundle: .module) }
                    .buttonStyle(.glassProminent)
                    .disabled(!canPublish)
            }.padding(.horizontal, 28).padding(.vertical, 16)
            VStack(alignment: .leading, spacing: 16) {
                TextField(text: $session.draft.title, prompt: Text("Title", bundle: .module)) { Text("Title", bundle: .module) }
                    .font(.system(size: 34, weight: .semibold))
                    .textFieldStyle(.plain)
                    .onSubmit { editor.focus() }
                if details {
                    TextField(text: $session.draft.slug, prompt: Text("Address", bundle: .module)) { Text("Address", bundle: .module) }
                    TextField(text: $session.draft.summary, prompt: Text("Summary", bundle: .module)) { Text("Summary", bundle: .module) }
                }
                Divider()
                ZStack {
                    PlusMarkdownEditor(text: $session.draft.markdown,
                                       placeholder: String(localized: "Write here. Markdown works.", bundle: .module),
                                       handle: editor, bottomInset: 70)
                        .opacity(preview ? 0 : 1)
                        .allowsHitTesting(!preview)
                        .accessibilityHidden(preview)
                    if preview {
                        ScrollView {
                            Text(.init(session.draft.markdown))
                                .font(.system(size: 18)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    if !preview { formatting.padding(.bottom, 12) }
                }
            }
            .padding(.horizontal, 40).padding(.top, 24)
            .frame(maxWidth: 920).frame(maxWidth: .infinity, maxHeight: .infinity)
            if let issue = session.failure ?? store.failure {
                HStack {
                    Text(issue).font(.callout).foregroundStyle(.red).lineLimit(3)
                    Button { session.flush() } label: { Text("Retry", bundle: .module) }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.draft.title + "\n\n" + session.draft.markdown, forType: .string)
                    } label: { Text("Copy", bundle: .module) }
                }.padding()
            }
        }
        .background(NookTheme.canvas)
        .disabled(session.isPublishing)
        .onAppear {
            slugField.fallback = PlusSlug.dated(Date(), avoiding: Set(store.articles.map(\.value.slug)))
            if !session.draft.slug.isEmpty { slugField.changed(to: session.draft.slug) }
        }
        .onChange(of: session.draft.title) { _, title in
            slugField.titleChanged(to: title)
            session.draft.slug = slugField.value
        }
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
        .buttonStyle(.plain).padding(.horizontal, 24).padding(.vertical, 14)
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
            && !session.draft.slug.isEmpty
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
