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
    /// Lets the formatting buttons act on the body's selection.
    @State private var editor = PlusMarkdownEditorHandle()

    private enum Field: Hashable {
        case title
        case body
    }

    public var body: some View {
        shell
            // The fallback depends on what is already published, which arrives after
            // the screen does. Recomputed when it lands so a Korean title gets a
            // date that does not collide with an existing post.
            .task(id: store.articles.count) { refreshFallback() }
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
                        // Only while the body has focus. A formatting bar over the
                        // title would act on the wrong field, and the keyboard bar is
                        // prime space to spend on something inapplicable.
                        if focus == .body {
                            ToolbarItemGroup(placement: .keyboard) { formattingBar }
                        }
                    }
                    .sheet(isPresented: $showingDetails) { detailsSheet }
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
                // Enter moves to the body rather than doing nothing, so a title and its
                // first sentence are one continuous action.
                .submitLabel(.next)
                .onSubmit { focus = .body }
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
                    handle: editor
                )
                .focused($focus, equals: .body)
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

        /// Markdown that would otherwise be typed character by character on a keyboard
        /// where `*`, `#`, `[`, and a backtick are each two taps deep, mid-sentence.
        ///
        /// Scrollable rather than compressed: eight fixed buttons across the narrowest
        /// phone leaves each one too small to hit, and the ones past the edge are the
        /// ones used least.
        private var formattingBar: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    formatButton("bold", label: Text("Bold", bundle: .module)) {
                        editor.perform { PlusMarkdownEdit.wrap($0, selection: $1, with: "**") }
                    }
                    formatButton("italic", label: Text("Italic", bundle: .module)) {
                        editor.perform { PlusMarkdownEdit.wrap($0, selection: $1, with: "*") }
                    }
                    formatButton("link", label: Text("Link", bundle: .module)) {
                        editor.perform { PlusMarkdownEdit.link($0, selection: $1) }
                    }
                    Divider().frame(height: 20).padding(.horizontal, 4)
                    formatButton("number", label: Text("Heading", bundle: .module)) {
                        editor.perform {
                            PlusMarkdownEdit.toggleLinePrefix($0, selection: $1, marker: "## ")
                        }
                    }
                    formatButton("list.bullet", label: Text("List", bundle: .module)) {
                        editor.perform {
                            PlusMarkdownEdit.toggleLinePrefix($0, selection: $1, marker: "- ")
                        }
                    }
                    formatButton("text.quote", label: Text("Quote", bundle: .module)) {
                        editor.perform {
                            PlusMarkdownEdit.toggleLinePrefix($0, selection: $1, marker: "> ")
                        }
                    }
                    formatButton("chevron.left.forwardslash.chevron.right", label: Text("Code", bundle: .module)) {
                        editor.perform { PlusMarkdownEdit.codeBlock($0, selection: $1) }
                    }
                }
                .padding(.horizontal, 4)
            }
            // The bar owns the keyboard's width; without this the group is centred and
            // the first button sits in the middle of the screen.
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func formatButton(
            _ symbol: String, label: Text, action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .frame(width: 40, height: 34)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(label)
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

    /// The Mac composer, which stays a form.
    ///
    /// A window has the room for one, and a pointer makes a scroll view inside a scroll
    /// view merely untidy rather than unusable. The phone's problem was that neither of
    /// those is true there.
    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                field(Text("Title", bundle: .module)) {
                    TextField(text: $title, prompt: Text(verbatim: "")) {
                        Text("Title", bundle: .module)
                    }
                    .font(.title3.weight(.semibold))
                    .focused($focus, equals: .title)
                    // Making the writer invent a web address by hand was the
                    // fiddliest part of publishing, for a value most people would
                    // rather not think about.
                    .onChange(of: title) { _, latest in slugField.titleChanged(to: latest) }
                }

                addressField

                field(Text("One-line summary (optional)", bundle: .module)) {
                    TextField(text: $summary, prompt: Text(verbatim: "")) {
                        Text("One-line summary (optional)", bundle: .module)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    // Renders while it is being typed, and never rewrites what was
                    // typed. See PlusMarkdownEditor for why that distinction is the
                    // whole design.
                    PlusMarkdownEditor(
                        text: $markdown,
                        placeholder: String(
                            localized: "Write here. **Bold**, *italic*, and [links](https://example.com) work.",
                            bundle: .module),
                        handle: editor
                    )
                    .frame(minHeight: 300)
                    .padding(8)
                    .background(cardBackground)

                    Text("Markdown, styled as you type. Headings, lists, links, quotes, and code all work; images are not supported yet.", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                statusNote
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
    }

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
        await store.publish(
            title: title, slug: slugField.value, markdown: markdown, summary: summary)
        guard store.failure == nil else { return }
        // Cleared only on success, so a rejected post is not lost along with the
        // reason it was rejected.
        title = ""
        slugField.reset()
        summary = ""
        markdown = ""
        onFinished()
    }
}
