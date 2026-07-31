import NookPlusProtocol
import SwiftUI

/// What the composer was opened on.
///
/// One screen for all three, because they are the same act — writing — and a separate
/// editor per case is how two of them end up subtly different. What changes is the
/// button at the end and what it does.
public enum PlusComposeTarget {
    /// Nothing yet.
    case newPost
    /// Unpublished writing kept on this device. Publishing it removes the draft.
    case draft(PlusDraft)
    /// A post that is already public. Saving replaces the record, so its links keep
    /// working.
    case published(ATRecord<ArticleRecord>)
}

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
    let target: PlusComposeTarget
    let onFinished: () -> Void

    public init(
        store: PlusStore,
        target: PlusComposeTarget = .newPost,
        onFinished: @escaping () -> Void
    ) {
        self.store = store
        self.target = target
        self.onFinished = onFinished
    }

    /// Whether this screen has loaded its target's text yet. The text lives in `@State`
    /// so it survives every redraw, which means it must be filled once rather than on
    /// each pass — otherwise every keystroke would be overwritten by the original.
    @State private var loaded = false

    @State private var title = ""
    /// Follows the title until the writer takes it over. The rule lives in
    /// PlusSlugField because deciding which writes are the view's own is the part
    /// that was wrong, and it cannot be tested from here.
    @State private var slugField = PlusSlugField()
    @State private var summary = ""
    @State private var markdown = ""
    @FocusState private var focus: Field?
    /// The address and summary, which are set once and then not thought about. They
    /// used to sit between the title and the body, pushing writing a third of the way
    /// down the screen for two values most posts never change.
    @State private var showingDetails = false
    @State private var showingMarkdownHelp = false
    @State private var showingFootnoteEditor = false
    @State private var showingTableOfContents = false
    @State private var footnoteLabel = "1"
    @State private var footnoteText = ""
    @State private var footnoteIsNew = true
    /// Lets the formatting buttons act on the body's selection, and Return on the title
    /// move the caret into it. Both need the text view itself, which SwiftUI's focus
    /// and selection machinery cannot reach.
    @State private var editor = PlusMarkdownEditorHandle()

    /// Asked when leaving with writing that has never been published.
    @State private var askAboutDraft = false

    /// Only the title. The body's focus lives in the text view, and a case here for it
    /// was a value that could be set but never took effect.
    private enum Field: Hashable {
        case title
    }

    /// What the screen is called, so the writer knows whether they are about to change
    /// something people can already read.
    private var screenTitle: Text {
        switch target {
        case .newPost: Text("New post", bundle: .module)
        case .draft: Text("Draft", bundle: .module)
        case .published: Text("Edit post", bundle: .module)
        }
    }

    /// Publishing and replacing are different acts and are named differently. A button
    /// that says "Publish" on something already public says nothing about what it will
    /// do to the version people are reading.
    private var submitLabel: Text {
        switch target {
        case .newPost, .draft: Text("Publish", bundle: .module)
        case .published: Text("Save", bundle: .module)
        }
    }

    public var body: some View {
        shell
            // Once, before anything else: filling the fields on every pass would
            // overwrite each keystroke with the original text.
            .task { load() }
            // The fallback depends on what is already published, which arrives after
            // the screen does. Recomputed when it lands so a Korean title gets a
            // date that does not collide with an existing post.
            .task(id: store.articles.count) { refreshFallback() }
    }

    /// Fills the fields from whatever the composer was opened on.
    private func load() {
        guard !loaded else { return }
        loaded = true
        switch target {
        case .newPost:
            break
        case .draft(let draft):
            title = draft.title
            summary = draft.summary
            markdown = draft.markdown
            // Pinned: an address the writer already chose is not something to
            // overwrite from the title on the next keystroke.
            if !draft.slug.isEmpty { slugField.changed(to: draft.slug) }
        case .published(let record):
            title = record.value.title
            summary = record.value.summary ?? ""
            markdown = record.value.content
            slugField.changed(to: record.value.slug)
        }
    }

    /// True once the writer has something that is not what they started with.
    private var hasUnsavedChanges: Bool {
        switch target {
        case .newPost:
            return !PlusDraft(title: title, summary: summary, markdown: markdown).isEmpty
        case .draft(let draft):
            return title != draft.title || summary != draft.summary
                || markdown != draft.markdown || slugField.value != draft.slug
        case .published(let record):
            return title != record.value.title || summary != (record.value.summary ?? "")
                || markdown != record.value.content || slugField.value != record.value.slug
        }
    }

    /// The address used when a title yields nothing.
    ///
    /// Dated rather than transliterated: a machine's reading of someone's words does
    /// not belong in their permanent URL, and a date is at least honest and readable.
    private func refreshFallback() {
        let taken = Set(store.articles.map(\.value.slug))
        slugField.fallback = PlusSlug.dated(Date(), avoiding: taken)
        // Apply it now if the title already needs it.
        slugField.titleChanged(to: title)
    }

    @ViewBuilder
    private var shell: some View {
        #if os(iOS)
            NavigationStack {
                writingSurface
                    .background(PlusTheme.canvas.ignoresSafeArea())
                    .tint(PlusTheme.accent)
                    .navigationTitle(screenTitle)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarLeading) {
                            Button { cancel() } label: { Text("Cancel", bundle: .module) }
                            Button { showingMarkdownHelp = true } label: {
                                Image(systemName: "questionmark.circle")
                            }
                            .accessibilityLabel(Text("Markdown help", bundle: .module))
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { Task { await publish() } } label: {
                                if store.isWorking {
                                    ProgressView().controlSize(.small)
                                } else {
                                    submitLabel.fontWeight(.semibold)
                                }
                            }
                            .disabled(!canPublish)
                        }
                        // The formatting bar is not here. `.keyboard` placement is
                        // rendered for the focused *SwiftUI* view, and the body is a
                        // UITextView, so the bar flashed as the title gave up focus and
                        // never returned. It is the text view's own accessory view now —
                        // see PlusMarkdownAccessoryBar.
                    }
                    .sheet(isPresented: $showingDetails) { detailsSheet }
                    .sheet(isPresented: $showingMarkdownHelp) { markdownHelp }
                    .sheet(isPresented: $showingFootnoteEditor) { footnoteEditor }
                    .sheet(isPresented: $showingTableOfContents) { tableOfContents }
                    .confirmationDialog(
                        Text("Keep this as a draft?", bundle: .module),
                        isPresented: $askAboutDraft,
                        titleVisibility: .visible
                    ) {
                        Button { keepAsDraft() } label: { Text("Keep as Draft", bundle: .module) }
                        Button(role: .destructive) { onFinished() } label: {
                            Text("Discard", bundle: .module)
                        }
                        Button(role: .cancel) {} label: { Text("Keep Writing", bundle: .module) }
                    } message: {
                        Text("It stays on this device and is not published until you say so.", bundle: .module)
                    }
            }
            .onAppear { if title.isEmpty { focus = .title } }
        #else
            VStack(alignment: .leading, spacing: 0) {
                macToolbar
                Divider()
                macWritingSurface
            }
            .frame(minWidth: 720, minHeight: 600)
            .background(PlusTheme.canvas)
            .tint(PlusTheme.accent)
            .sheet(isPresented: $showingDetails) { macDetailsSheet }
            .sheet(isPresented: $showingMarkdownHelp) { markdownHelp }
            .sheet(isPresented: $showingFootnoteEditor) { footnoteEditor }
            .sheet(isPresented: $showingTableOfContents) { tableOfContents }
            .onAppear { if title.isEmpty { focus = .title } }
            .confirmationDialog(
                Text("Keep this as a draft?", bundle: .module),
                isPresented: $askAboutDraft,
                titleVisibility: .visible
            ) {
                Button { keepAsDraft() } label: { Text("Keep as Draft", bundle: .module) }
                Button(role: .destructive) { onFinished() } label: {
                    Text("Discard", bundle: .module)
                }
                Button(role: .cancel) {} label: { Text("Keep Writing", bundle: .module) }
            } message: {
                Text("It stays on this device and is not published until you say so.", bundle: .module)
            }
        #endif
    }

    // MARK: - iOS: the body is the screen

    #if os(iOS)
        /// Title, then the body, and nothing between them.
        ///
        /// The composer used to be a form: a scroll view holding a title field, the
        /// address, a summary, and then the body in a 300-point box. Two problems, both
        /// of which made writing feel like filling something in rather than writing.
        ///
        /// Writing began a third of the way down the screen, behind two fields that are
        /// set once and then never thought about. Those now live behind the address
        /// line, which stays visible because it is also where a rejected address is
        /// reported.
        ///
        /// And the text view scrolls, so it was a scroll view inside a scroll view.
        /// Which one moved depended on where a finger landed, and the outer one knew
        /// nothing about the caret, so the line being typed could sit under the
        /// keyboard. Now there is one scrolling surface: the body, which keeps its own
        /// caret in view because that is what a text view does.
        private var writingSurface: some View {
            VStack(alignment: .leading, spacing: 0) {
                TextField(text: $title, prompt: Text("Title", bundle: .module)) {
                    Text("Title", bundle: .module)
                }
                .font(.title2.weight(.semibold))
                .focused($focus, equals: .title)
                // Return moves to the body rather than doing nothing, so a title and its
                // first sentence are one continuous action. Through the editor's handle,
                // because `@FocusState` cannot reach into a text view SwiftUI does not
                // own: setting it to `.body` registered a value nothing acted on.
                .submitLabel(.next)
                .onSubmit { editor.focus() }
                .onChange(of: title) { _, latest in slugField.titleChanged(to: latest) }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)

                addressLine

                if let note = statusNote {
                    note
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                }

                // Renders while it is being typed, and never rewrites what was typed.
                // See PlusMarkdownEditor for why that distinction is the whole design.
                PlusMarkdownEditor(
                    text: $markdown,
                    placeholder: String(localized: "Write here. Markdown works.", bundle: .module),
                    handle: editor,
                    onOpenFootnote: openFootnote,
                    onOpenTableOfContents: { showingTableOfContents = true },
                    onRequestFootnote: beginFootnote,
                    onRequestHelp: { showingMarkdownHelp = true }
                )
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity)
            }
        }

        /// One line: the address as the URL it will become, and a way into the rest.
        ///
        /// Tappable across its width, because a writer looking for the summary looks
        /// here — this is the only thing on screen that is about the post rather than
        /// in it. Turns orange and states the problem when the address is one the
        /// service would refuse, so moving it out of the form did not hide it.
        private var addressLine: some View {
            Button {
                showingDetails = true
            } label: {
                HStack(spacing: 6) {
                    if let problem = slugField.problem {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(verbatim: problem.message)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    } else {
                        Text(verbatim: fullAddress)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                        .imageScale(.small)
                }
                .font(.caption.monospaced())
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(alignment: .bottom) {
                PlusTheme.hairline.frame(height: 0.5)
            }
            .accessibilityLabel(Text("Web address and summary", bundle: .module))
            .accessibilityValue(Text(verbatim: slugField.problem?.message ?? fullAddress))
        }

        private var fullAddress: String {
            guard let base = store.publicationBaseURL else { return slugField.value }
            return base + "/" + slugField.value
        }

        /// The two values a post is given once.
        private var detailsSheet: some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        addressField
                        field(Text("One-line summary (optional)", bundle: .module)) {
                            TextField(text: $summary, prompt: Text(verbatim: "")) {
                                Text("One-line summary (optional)", bundle: .module)
                            }
                        }
                        Text("Markdown, styled as you type. Headings, lists, links, quotes, and code all work; images are not supported yet.", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                }
                .background(PlusTheme.canvas.ignoresSafeArea())
                .tint(PlusTheme.accent)
                .navigationTitle(Text("Post details", bundle: .module))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingDetails = false } label: { Text("Done", bundle: .module) }
                            .fontWeight(.semibold)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    #endif

    // MARK: - Writing tools

    private var markdownHelp: some View {
        PlusMarkdownHelpView(insert: insertFromHelp)
    }

    private func insertFromHelp(_ kind: PlusMarkdownHelpView.Example.Kind) {
        switch kind {
        case .heading:
            editor.perform { PlusMarkdownEdit.toggleLinePrefix($0, selection: $1, marker: "## ") }
        case .bold:
            editor.perform { PlusMarkdownEdit.wrap($0, selection: $1, with: "**") }
        case .italic:
            editor.perform { PlusMarkdownEdit.wrap($0, selection: $1, with: "*") }
        case .strikethrough:
            editor.perform { PlusMarkdownEdit.wrap($0, selection: $1, with: "~~") }
        case .inlineCode:
            editor.perform { PlusMarkdownEdit.wrap($0, selection: $1, with: "`") }
        case .link:
            editor.perform { PlusMarkdownEdit.link($0, selection: $1) }
        case .list:
            editor.perform { PlusMarkdownEdit.toggleLinePrefix($0, selection: $1, marker: "- ") }
        case .numberedList:
            editor.perform { PlusMarkdownEdit.toggleLinePrefix($0, selection: $1, marker: "1. ") }
        case .quote:
            editor.perform { PlusMarkdownEdit.toggleLinePrefix($0, selection: $1, marker: "> ") }
        case .code:
            editor.perform { PlusMarkdownEdit.codeBlock($0, selection: $1) }
        case .table:
            editor.perform {
                PlusMarkdownEdit.insertBlock(
                    $0,
                    selection: $1,
                    source: "| Name | Value |\n| --- | --- |\n| Nook | Plus |")
            }
        case .thematicBreak:
            editor.perform {
                PlusMarkdownEdit.insertBlock($0, selection: $1, source: "---")
            }
        case .paragraphBreak:
            editor.perform { PlusMarkdownEdit.paragraphBreak($0, selection: $1) }
        case .lineBreak:
            editor.perform { PlusMarkdownEdit.breakLine($0, selection: $1, kind: .line) }
        case .tableOfContents:
            editor.perform { PlusMarkdownEdit.tableOfContents($0, selection: $1) }
        case .footnote:
            showingMarkdownHelp = false
            Task { @MainActor in
                await Task.yield()
                beginFootnote()
            }
            return
        }
        showingMarkdownHelp = false
        editor.focus()
    }

    private func beginFootnote() {
        footnoteLabel = PlusMarkdownDocumentIndex(markdown).nextNumericFootnoteLabel
        footnoteText = ""
        footnoteIsNew = true
        showingFootnoteEditor = true
    }

    private func openFootnote(_ label: String) {
        let definition = PlusMarkdownDocumentIndex(markdown).definition(label: label)
        footnoteLabel = label
        footnoteText = definition?.content ?? ""
        footnoteIsNew = false
        showingFootnoteEditor = true
    }

    private func saveFootnote() {
        let label = footnoteLabel
        let content = footnoteText
        if footnoteIsNew {
            editor.performTransaction {
                PlusMarkdownEdit.footnote($0, selection: $1, label: label, content: content)
            }
        } else {
            editor.perform { source, selection in
                var edit = PlusMarkdownEdit.updateFootnote(
                    source, label: label, content: content)
                    ?? PlusMarkdownEdit.appendFootnoteDefinition(
                        source, label: label, content: content)
                edit.selection = selection
                return edit
            }
        }
        showingFootnoteEditor = false
        editor.focus()
    }

    private var footnoteEditor: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(verbatim: "[^\(footnoteLabel)]")
                    .font(.title3.monospaced().weight(.semibold))
                    .foregroundStyle(PlusTheme.accent)

                Text("The definition is stored as [^1]: without a list dash.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $footnoteText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        PlusTheme.hairline.opacity(0.35),
                        in: RoundedRectangle(cornerRadius: 10))
                    .frame(minHeight: 180)
            }
            .padding(20)
            .background(PlusTheme.canvas.ignoresSafeArea())
            .navigationTitle(
                footnoteIsNew
                    ? Text("New footnote", bundle: .module)
                    : Text("Footnote", bundle: .module))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { showingFootnoteEditor = false } label: {
                        Text("Cancel", bundle: .module)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { saveFootnote() } label: {
                        Text("Save", bundle: .module)
                    }
                    .disabled(footnoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(iOS)
            .presentationDetents([.medium, .large])
        #else
            .frame(width: 520, height: 380)
        #endif
    }

    private var tableOfContents: some View {
        let headings = PlusMarkdownDocumentIndex(markdown).headings
        return NavigationStack {
            Group {
                if headings.isEmpty {
                    ContentUnavailableView(
                        "No headings yet",
                        systemImage: "list.bullet.indent",
                        description: Text(
                            "Add headings with # markers and they will appear here.",
                            bundle: .module))
                } else {
                    List(headings) { heading in
                        Button {
                            showingTableOfContents = false
                            editor.select(heading.range)
                        } label: {
                            HStack(spacing: 8) {
                                Text(verbatim: String(repeating: "#", count: heading.level))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                                Text(verbatim: heading.title)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(.leading, CGFloat(max(0, heading.level - 1)) * 10)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(Text("Table of contents", bundle: .module))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { showingTableOfContents = false } label: {
                        Text("Done", bundle: .module)
                    }
                }
            }
        }
        #if os(iOS)
            .presentationDetents([.medium, .large])
        #else
            .frame(width: 500, height: 520)
        #endif
    }

    /// What is stopping publishing, or what is being waited for. Nil when there is
    /// nothing to say.
    @ViewBuilder
    private var statusNote: (some View)? {
        if let failure = store.failure {
            Label { Text(verbatim: failure) } icon: { Image(systemName: "exclamationmark.triangle") }
                .foregroundStyle(.orange)
                .font(.callout)
        } else if store.publications.isEmpty {
            // Publish stays disabled until the publication arrives, and a button that
            // is dim for no stated reason reads as broken. The fields are usable
            // meanwhile; only publishing waits.
            Label {
                Text("Getting your publication ready. You can write in the meantime.", bundle: .module)
            } icon: {
                ProgressView().controlSize(.small)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    #if os(macOS)
        /// The Mac uses the same writing-first hierarchy as iOS: actions in a narrow
        /// top bar, then a large title and a body that owns all remaining space.
        /// Address and summary are available without occupying the writing canvas.
        private var macToolbar: some View {
            HStack(spacing: 12) {
                Button { cancel() } label: { Text("Cancel", bundle: .module) }
                    .keyboardShortcut(.cancelAction)

                screenTitle
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                HStack(spacing: 4) {
                    Button {
                        editor.perform {
                            PlusMarkdownEdit.tableOfContents($0, selection: $1)
                        }
                    } label: {
                        Label {
                            Text("Table of contents", bundle: .module)
                        } icon: {
                            Image(systemName: "list.bullet.indent")
                        }
                    }
                    .help(Text("Insert table of contents", bundle: .module))

                    Button { beginFootnote() } label: {
                        Label {
                            Text("Footnote", bundle: .module)
                        } icon: {
                            Image(systemName: "text.badge.plus")
                        }
                    }
                    .help(Text("Add footnote", bundle: .module))

                    Button { showingMarkdownHelp = true } label: {
                        Label {
                            Text("Markdown help", bundle: .module)
                        } icon: {
                            Image(systemName: "questionmark.circle")
                        }
                    }
                    .help(Text("Markdown help", bundle: .module))
                }
                .labelStyle(.iconOnly)

                Button { Task { await publish() } } label: {
                    if store.isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        submitLabel.fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canPublish)
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
        }

        private var macWritingSurface: some View {
            VStack(alignment: .leading, spacing: 0) {
                TextField(text: $title, prompt: Text("Title", bundle: .module)) {
                    Text("Title", bundle: .module)
                }
                .textFieldStyle(.plain)
                .font(.largeTitle.weight(.semibold))
                .focused($focus, equals: .title)
                .onSubmit { editor.focus() }
                .onChange(of: title) { _, latest in slugField.titleChanged(to: latest) }
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 12)

                macAddressLine

                if let note = statusNote {
                    note
                        .padding(.horizontal, 28)
                        .padding(.top, 12)
                }

                PlusMarkdownEditor(
                    text: $markdown,
                    placeholder: String(localized: "Write here. Markdown works.", bundle: .module),
                    handle: editor,
                    onOpenFootnote: openFootnote,
                    onOpenTableOfContents: { showingTableOfContents = true },
                    onRequestFootnote: beginFootnote,
                    onRequestHelp: { showingMarkdownHelp = true }
                )
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        private var macAddressLine: some View {
            Button {
                showingDetails = true
            } label: {
                HStack(spacing: 7) {
                    if let problem = slugField.problem {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(verbatim: problem.message)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    } else {
                        Text(verbatim: macFullAddress)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 8)
                    Text("Post details", bundle: .module)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                        .imageScale(.small)
                }
                .font(.caption.monospaced())
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(alignment: .bottom) {
                PlusTheme.hairline.frame(height: 0.5)
            }
        }

        private var macFullAddress: String {
            guard let base = store.publicationBaseURL else { return slugField.value }
            return base + "/" + slugField.value
        }

        private var macDetailsSheet: some View {
            VStack(alignment: .leading, spacing: 18) {
                Text("Post details", bundle: .module)
                    .font(.title2.weight(.semibold))

                addressField

                field(Text("One-line summary (optional)", bundle: .module)) {
                    TextField(text: $summary, prompt: Text(verbatim: "")) {
                        Text("One-line summary (optional)", bundle: .module)
                    }
                }

                Text("Markdown, styled as you type. Headings, lists, links, quotes, and code all work; images are not supported yet.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button { showingDetails = false } label: {
                        Text("Done", bundle: .module)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 500)
        }
    #endif

    /// The web address, shown as the link it will become.
    ///
    /// Presented as a whole URL rather than a bare field, because that is what it is,
    /// and because the writer needs to see the result to judge it. What is wrong with
    /// it is said beside it: an address the service would reject used to be accepted
    /// silently and fail after the writing was done.
    private var addressField: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Web address", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                // Only after an edit, and only when there is something else to go
                // back to. Offering it while the field is already following would be
                // a button that does nothing.
                if slugField.isPinned, !slugField.suggestion.isEmpty,
                    slugField.suggestion != slugField.value
                {
                    Button {
                        slugField.useSuggestion()
                    } label: {
                        Text("Use suggestion", bundle: .module)
                    }
                    .font(.caption)
                }
            }

            HStack(spacing: 0) {
                if let base = store.publicationBaseURL {
                    Text(verbatim: base + "/")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .layoutPriority(-1)
                }
                TextField(
                    text: Binding(
                        get: { slugField.value },
                        set: { slugField.changed(to: $0) }
                    ),
                    prompt: Text(verbatim: "my-first-post")
                ) {
                    Text("Web address", bundle: .module)
                }
                .font(.caption.monospaced())
                .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                #endif
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 11)
            .background(addressBackground)

            if let problem = slugField.problem {
                Label { Text(verbatim: problem.message) } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption)
                .foregroundStyle(.orange)
            } else if !slugField.isPinned && !slugField.value.isEmpty {
                Text("Suggested from your title. Edit it if you would rather choose.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Outlined in orange while the address is one the service would refuse, so the
    /// problem is visible without reading.
    @ViewBuilder
    private var addressBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        #if os(iOS)
            shape.fill(PlusTheme.card)
                .overlay(
                    shape.strokeBorder(
                        slugField.problem == nil ? AnyShapeStyle(.clear) : AnyShapeStyle(.orange),
                        lineWidth: 1.5))
        #else
            shape.fill(.quaternary.opacity(0.25))
                .overlay(
                    shape.strokeBorder(
                        slugField.problem == nil ? AnyShapeStyle(.clear) : AnyShapeStyle(.orange),
                        lineWidth: 1.5))
        #endif
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
            // Validated rather than merely non-empty. An address the service refuses
            // used to be accepted here and rejected after the writing was done.
            && slugField.problem == nil
            && !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && store.canPublish
    }

    private func publish() async {
        switch target {
        case .newPost:
            await store.publish(
                title: title, slug: slugField.value, markdown: markdown, summary: summary)
        case .draft(let draft):
            await store.publish(
                title: title, slug: slugField.value, markdown: markdown, summary: summary)
            // Only once it is public. A draft discarded before the publish succeeded
            // would be writing lost to a failed request.
            if store.failure == nil { store.discard(draft) }
        case .published(let record):
            await store.update(
                record, title: title, slug: slugField.value, markdown: markdown,
                summary: summary)
        }
        guard store.failure == nil else { return }
        // Cleared only on success, so a rejected post is not lost along with the
        // reason it was rejected.
        title = ""
        slugField.reset()
        summary = ""
        markdown = ""
        onFinished()
    }

    /// Leaves the screen, deciding what happens to writing that was not published.
    ///
    /// Nothing is thrown away silently. Writing that has never been public is offered
    /// as a draft, because the alternative is losing it to a mis-tap on Cancel; an edit
    /// to something already published is discarded, because the post itself is
    /// untouched and keeping a second copy of it as a draft would be two versions of
    /// one thing with nothing to say which is current.
    private func cancel() {
        guard hasUnsavedChanges else {
            onFinished()
            return
        }
        switch target {
        case .published:
            onFinished()
        case .newPost, .draft:
            if store.canKeepDrafts {
                askAboutDraft = true
            } else {
                onFinished()
            }
        }
    }

    /// Keeps what is on screen as a draft and leaves.
    private func keepAsDraft() {
        var draft: PlusDraft
        if case .draft(let existing) = target {
            draft = existing
        } else {
            draft = PlusDraft()
            if case .published = target { draft.wasPublished = true }
        }
        draft.title = title
        draft.slug = slugField.value
        draft.summary = summary
        draft.markdown = markdown
        store.save(draft)
        guard store.failure == nil else { return }
        onFinished()
    }
}
