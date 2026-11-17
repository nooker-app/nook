// Beta owns its presentation; Classic's reader implementation stays intact.
import AppKit
import NaturalLanguage
import NookKit
import SwiftUI
import Translation

struct MagazineReaderDetail: View {
    @Bindable var store: ReaderStore
    let articleID: Article.ID
    let heroNamespace: Namespace.ID
    let nextTitle: String?
    let previousTitle: String?
    let onClose: () -> Void
    let onNavigate: (Bool) -> Void
    @State private var contentReady = false
    @State private var pull = MagazinePullPresentation()
    @State private var pullResetTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @AppStorage("markReadOnOpen") private var markReadOnOpen = true
    @AppStorage("markReadDelaySeconds") private var markReadDelaySeconds = 3
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system
    @AppStorage(ArticleSummarySettings.enabledKey) private var summariesEnabled = false
    @AppStorage(ArticleSummarySettings.automaticKey) private var summariesAutomatic = false
    @AppStorage(ArticleSummarySettings.styleKey) private var summaryStyleRaw = ArticleSummaryStyle.concise.rawValue
    @AppStorage(TranslationSettings.summaryProviderKey) private var summaryProviderRaw = TranslationProvider.appleIntelligence.rawValue
    // Typography settings drive the native reader body (family, size, leading,
    // kern). Observed here so a settings change restyles the open article live.
    @AppStorage("readerFont") private var readerFont = ReaderFont.system
    @AppStorage("readerFontSize") private var readerFontSize = 18
    @AppStorage("readerLineHeight") private var readerLineHeight = 1.7
    @AppStorage("readerLetterSpacing") private var readerLetterSpacing = 0.0

    private var readerTypography: ReaderTypography {
        ReaderTypography(
            font: readerFont,
            fontSize: CGFloat(readerFontSize),
            lineHeightMultiple: readerLineHeight,
            letterSpacingEM: readerLetterSpacing
        )
    }

    // Translation (Apple Intelligence). Rich (contentHTML) articles stream an
    // in-place translation preserving markup; plain-body articles fall back to a
    // whole-body translation.
    //
    // The reader is updated in place across articles (see `readerPushID`), so this
    // state outlives the article. The session keeps it tagged with its article and
    // reads it only for that article: a new article's first body sees a clean
    // reader, not the previous article's translation or summary.
    @State private var session = ReaderArticleSession()
    /// The article the delete confirmation was raised for.
    @State private var pendingDeleteID: Article.ID?
    @State private var summaryRequestedArticleID: String?
    @State private var summaryGenerationID = 0

    private var targetLanguage: Locale.Language {
        (appLanguage == .system ? Locale.current : appLanguage.locale).language
    }

    private var targetLanguageName: String {
        // Give the model the script for Chinese so it doesn't guess Simplified vs
        // Traditional; other languages use their plain English name.
        if let script = targetLanguage.script?.identifier {
            if script == "Hans" { return "Simplified Chinese" }
            if script == "Hant" { return "Traditional Chinese" }
        }
        let code = targetLanguage.languageCode?.identifier ?? "en"
        return Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code
    }

    /// Offer translation whenever the article's language differs from the target.
    /// Apple Intelligence is used when available; otherwise the button falls back
    /// to the system Translation overlay (so the button matches iOS and never
    /// silently disappears when Apple Intelligence is off/unsupported).
    private func canTranslate(_ article: Article) -> Bool {
        guard let detected = session.detectedLanguage(for: article.id),
              let target = targetLanguage.languageCode?.identifier else { return false }
        let detectedBase = Locale.Language(identifier: detected).languageCode?.identifier ?? detected
        return detectedBase != target
    }

    private static func translationText(for article: Article) -> String {
        ([article.title] + article.bodyParagraphs).joined(separator: "\n\n")
    }

    nonisolated static func detectLanguage(for article: Article) -> String? {
        let sample = (article.bodyParagraphs.prefix(4).joined(separator: " ") + " " + article.title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        return recognizer.dominantLanguage?.rawValue
    }

    /// The HTML the reader is actually showing: the reader-mode extraction when
    /// ready, else the feed's own content HTML (nil = plain-paragraph body). The
    /// translator must consume exactly this so its per-block overrides line up
    /// with the rendered blocks.
    private func renderedReaderHTML(for article: Article) -> String? {
        if store.usesReaderContentByDefault, case .ready(let extracted) = store.readerContentState(for: article) {
            return extracted
        }
        return article.contentHTML
    }

    private func translationActive(_ article: Article) -> Bool {
        if renderedReaderHTML(for: article) != nil {
            return session.translator(for: article.id)?.isActive ?? false
        }
        return session.plainTranslation(for: article.id) != nil
    }

    private func displayTitle(_ article: Article) -> String {
        if renderedReaderHTML(for: article) != nil {
            guard let translator = session.translator(for: article.id), translator.isActive else { return article.title }
            return translator.translatedTitle ?? article.title
        }
        return session.plainTranslation(for: article.id)?.title ?? article.title
    }

    /// Toggles translation: rich articles stream in place; plain-body articles
    /// translate the whole body once. A length guard keeps an "answered"
    /// imperative title from replacing the real one.
    private func toggleTranslation(_ article: Article) {
        session.begin(articleID: article.id)
        if let html = renderedReaderHTML(for: article) {
            let translator = session.translator
            if translator.isActive {
                translator.stop()
            } else if NaturalTranslator.isAvailable(for: TranslationSettings.readerProvider()) {
                translator.start(html: html, baseURL: article.url, title: article.title, into: targetLanguageName)
            } else {
                session.setShowingSystemTranslation(true, for: article.id)
            }
            return
        }

        if session.plainTranslation(for: article.id) != nil {
            session.setPlainTranslationShown(false, for: article.id)
            return
        }
        if session.hasPlainTranslation(for: article.id) {
            session.setPlainTranslationShown(true, for: article.id)
            return
        }
        guard NaturalTranslator.isAvailable(for: TranslationSettings.readerProvider()) else {
            session.setShowingSystemTranslation(true, for: article.id)
            return
        }
        let language = targetLanguageName
        let provider = TranslationSettings.readerProvider()
        // Tagged with the article inside the session: a result that returns after
        // the reader moved to another article is dropped, not shown there.
        session.translatePlainBody(articleID: article.id, title: article.title, paragraphs: article.bodyParagraphs) { text in
            try await NaturalTranslator.translate(text, into: language, provider: provider)
        }
    }

    var body: some View {
        #if DEBUG || NOOK_PERFORMANCE_TRACE
        let _ = MainThreadLog.readerBody()
        #endif
        baseContent
    }

    @ViewBuilder
    private var baseContent: some View {
        if !store.isStorageConfigured {
            ContentUnavailableView {
                Label("Set Up iCloud Sync", systemImage: "icloud.and.arrow.up")
            } description: {
                Text("Choose a folder in iCloud Drive and Nook keeps your feeds in sync across your devices.")
            }
        } else if let article = store.article(withID: articleID) ?? store.listedArticle(withID: articleID) {
            // The settled selection: held back only while the list selection is
            // key-repeating, so the reader renders where the user stops.
            articleReader(article)
        } else {
            ContentUnavailableView {
                Label("Select an Article", systemImage: "newspaper")
            } description: {
                Text("Choose a story from the article list.")
            }
        }
    }

    /// Whether the last article change moved forward (next). Drives the push
    /// transition direction so previous/next slide the natural way.
    @State private var readerNavForward = true

    /// The reader's identity. It changes only for reader-pane previous/next, whose
    /// push transition needs the old article to leave and the new one to arrive.
    ///
    /// Any other article change updates the reader in place. Keyed by the article,
    /// every change built the whole reader again — its controls, menus, dialogs and
    /// gestures — and that, not the article's text, was the cost: 108 ms a change on
    /// a one-paragraph article (worst 114), 0 in place (readerTTFR 116 → 51). It was
    /// the single long turn left in ↓ key repeat. The subviews that hold per-article
    /// state (summary, `HTMLContentView`, comments) keep their own `.id(article.id)`,
    /// and the scroll position is put back at the top explicitly. The reader's own
    /// translation and summary state lives in `session`, which is read only for the
    /// article it is bound to. The footer's Share menu keeps no id either: rebuilding
    /// its pop-up button alone cost ~35 ms a change. It clears its "copied" checkmark
    /// itself when the article's URL changes; its save sheet blocks the window while
    /// it is open.
    @State private var readerPushID = 0
    @State private var readerScrollPosition = ScrollPosition(edge: .top)

    /// Navigates to the adjacent article with a directional push animation.
    private func navigateReader(forward: Bool) {
        readerNavForward = forward
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.32, bounce: 0.06)) {
            readerPushID += 1
            onNavigate(forward)
        }
    }

    private func articleReader(_ article: Article) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                articleHeader(article)

                if contentReady {
                if summariesEnabled {
                    let summaryController = session.summary(for: article.id)
                    Group {
                        if let summaryController, let summary = summaryController.summary {
                            ArticleSummaryCard(
                                summary: summary,
                                style: summaryController.style,
                                provider: summaryController.provider
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        } else {
                            ArticleSummaryActionButton(
                                isLoading: summaryController?.isLoading ?? false,
                                issue: summaryController?.issue
                            ) {
                                requestSummary(for: article)
                            }
                        }
                    }
                    .id(article.id)
                }

                Divider()

                // In-document anchors and their flash are per-document state, so
                // each `HTMLContentView` carries the article's id itself.
                readerBody(article)

                // The page's own discussion, under the article it belongs to. Only
                // legibility extracts it, so an article read with Readability and never
                // re-read simply has no section here.
                if let comments = store.readerComments(for: article) {
                    Divider()
                    ReaderCommentsSection(
                        thread: comments, baseURL: article.url, typography: readerTypography,
                        translator: session.translator(for: article.id), translationLanguage: targetLanguageName)
                    .id(article.id)
                }

                Divider()

                HStack {
                    Button { openURL(article.url) } label: {
                        Label("Open Original", systemImage: "safari")
                    }
                    .buttonStyle(MagazineGlassButtonStyle())

                    ArticleShareMenu(
                        articleURL: article.url,
                        title: article.title,
                        markdown: {
                            session.translator(for: article.id)?.translatedMarkdown
                                ?? store.nativeReaderMarkdown(for: article)
                        }
                    ) { copied in
                        HStack(spacing: 7) {
                            Label("Share", systemImage: copied ? "checkmark" : "square.and.arrow.up")
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                                .accessibilityHidden(true)
                        }
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(MagazineGlassButtonStyle())

                    Spacer()

                    Button(role: .destructive) {
                        pendingDeleteID = article.id
                    } label: {
                        Label("Delete Article", systemImage: "trash")
                    }
                    .buttonStyle(MagazineGlassButtonStyle())
                }
                .buttonStyle(MagazineGlassButtonStyle())
                }
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 36)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .background {
                MagazineReaderGestureProbe(articleID: article.id,
                    enabled: contentReady,
                    hasNext: nextTitle != nil, hasPrevious: previousTitle != nil,
                    onChange: updatePull, onAction: performGesture)
            }
        }
        .scrollPosition($readerScrollPosition)
        .onChange(of: article.id, initial: true) { oldID, newID in
            // Hand the per-article state to the new article. Its first body already
            // read the session as empty; this clears what the old article left.
            if session.begin(articleID: newID) {
                summaryRequestedArticleID = nil
            }
            // The confirmation was for the article that just left.
            pendingDeleteID = nil
            pullResetTask?.cancel()
            pull = MagazinePullPresentation()
            // A new article opens at its top, as it did when each article was a new
            // scroll view. Every `scrollTo` is a new request, unequal to the last
            // even for the same edge, so this applies when the binding still reads
            // `.top` from the previous article but an anchor jump moved the view.
            if oldID != newID {
                readerScrollPosition.scrollTo(edge: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NookTheme.canvas)
        .confirmationDialog(
            "Delete this article?",
            isPresented: Binding(
                get: { pendingDeleteID != nil },
                set: { if !$0 { pendingDeleteID = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeleteID
        ) { articleID in
            // The article the dialog was raised for, not whichever is current now.
            Button("Delete Article", role: .destructive) { store.deleteArticle(articleID: articleID) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It's removed from your list on all your devices. This can't be undone.")
        }
        .overlay(alignment: .top) {
            if session.isTranslating(for: article.id) {
                MagazineTranslationBanner()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: SameArticleFlag(articleID: article.id, isOn: session.isTranslating(for: article.id)))
        .translationPresentation(
            isPresented: Binding(
                get: { session.isShowingSystemTranslation(for: article.id) },
                set: { session.setShowingSystemTranslation($0, for: article.id) }
            ),
            text: Self.translationText(for: article)
        )
        .task(id: article.id) {
            contentReady = false
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            contentReady = true
            // The change handler has normally bound the article already; binding
            // here too keeps the language detection below from being dropped.
            if session.begin(articleID: article.id) {
                summaryRequestedArticleID = nil
            }
            // Start reader-mode extraction first so it isn't delayed behind
            // language detection.
            store.ensureReaderContent(for: article)
            // Detect the language off the main actor so the recognizer doesn't
            // run on the transition frame.
            let detected = await Task.detached { Self.detectLanguage(for: article) }.value
            // Re-detected per article so the Translate action is offered only when
            // the language differs from the target.
            if !Task.isCancelled { session.setDetectedLanguage(detected, for: article.id) }
            await markReadAfterDwell(article)
        }
        .task(id: summaryTaskKey(for: article)) {
            if session.begin(articleID: article.id) {
                summaryRequestedArticleID = nil
            }
            let summaryController = session.summary
            let manuallyRequested = summaryRequestedArticleID == article.id
            guard ArticleSummarySettings.shouldGenerate(
                isEnabled: summariesEnabled,
                isAutomatic: summariesAutomatic,
                isManuallyRequested: manuallyRequested
            ) else {
                if !summariesEnabled { summaryController.reset() }
                return
            }
            guard let markdown = summaryMarkdown(for: article) else {
                summaryController.beginLoading()
                return
            }
            await summaryController.load(
                ArticleSummaryRequest(
                    title: article.title,
                    markdown: markdown,
                    style: ArticleSummaryStyle(rawValue: summaryStyleRaw) ?? .concise,
                    provider: TranslationProvider(rawValue: summaryProviderRaw) ?? .appleIntelligence,
                    outputLanguage: targetLanguageName
                )
            )
        }
        // If reader-mode content finishes extracting AFTER translation was turned
        // on, restart the translator against the now-rendered extracted HTML so
        // its per-block overrides line up with what's shown.
        .onChange(of: ReaderContentChange(articleID: article.id, state: store.readerContentState(for: article))) { oldValue, newValue in
            // Only this article's extraction finishing; a different article is a
            // new reader, whose translation the article task has already reset.
            guard oldValue.articleID == newValue.articleID else { return }
            guard let translator = session.translator(for: article.id), translator.isActive,
                  case .ready(let extracted) = newValue.state else { return }
            translator.start(html: extracted, baseURL: article.url, title: article.title, into: targetLanguageName)
        }
        .onChange(of: summariesEnabled) { _, enabled in
            guard !enabled else { return }
            summaryRequestedArticleID = nil
            session.summary.reset()
        }
        // Pull past the bottom for the next article, past the top for the
        // previous one. The web reader keeps its own bottom-only affordance.
        .offset(x: !reduceMotion && pull.edge == .leading ? pull.distance * 0.18 : 0)
        .overlay {
            MagazineReaderGestureOverlay(pull: pull, nextTitle: nextTitle, previousTitle: previousTitle)
        }
        .onDisappear { pullResetTask?.cancel() }
        // Floated over the article rather than placed in it: the point of the
        // re-parse chip is that what you were reading stays where it was.
        .overlay(alignment: .top) {
            if let reparse = store.reparse(for: article) {
                ReaderReparsingBanner(reparse)
                    .padding(.top, 10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: SameArticleFlag(articleID: article.id, isOn: store.isReparsing(article)))
        .id(readerPushID)
        .transition(.push(from: readerNavForward ? .bottom : .top))
    }

    private func updatePull(_ value: MagazinePullPresentation) {
        pullResetTask?.cancel()
        if value.edge == nil {
            var resting = pull
            resting.distance = 0
            resting.progress = 0
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.28, bounce: 0.12)) { pull = resting }
            pullResetTask = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                pull = MagazinePullPresentation()
            }
        } else {
            pull = value
        }
    }

    private func performGesture(_ action: MagazineGestureAction) {
        switch action {
        case .next: navigateReader(forward: true)
        case .previous: navigateReader(forward: false)
        case .close: onClose()
        }
    }

    /// The article's reader-content state, tagged with the article so a change of
    /// article can be told apart from that article's extraction finishing.
    private struct ReaderContentChange: Equatable {
        let articleID: Article.ID
        let state: ReaderStore.ReaderContentState?
    }

    /// An `.animation(_:value:)` value that changes only when the flag changes for
    /// the same article. With the reader updated in place, opening another article
    /// whose flag differs (one still re-parsing, say) must not animate the article
    /// swap; before, the new article was a new view and nothing animated it.
    private struct SameArticleFlag: Equatable {
        let articleID: Article.ID
        let isOn: Bool

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.articleID != rhs.articleID || lhs.isOn == rhs.isOn
        }
    }

    /// Summaries consume exactly the Markdown represented by the visible native
    /// reader. While Reader extraction is still loading there is deliberately no
    /// fallback request: the task reruns when the final visible body is known.
    private func summaryMarkdown(for article: Article) -> String? {
        if store.usesReaderContentByDefault || store.isOfflineSaved(article.id) {
            switch store.readerContentState(for: article) {
            case .ready, .failed, .gone:
                return store.nativeReaderMarkdown(for: article)
            case .loading, .none:
                return nil
            }
        }
        return store.nativeReaderMarkdown(for: article)
    }

    private func summaryTaskKey(for article: Article) -> String {
        let contentState: String
        switch store.readerContentState(for: article) {
        case .ready(let html): contentState = "ready:\(html.hashValue)"
        case .failed: contentState = "failed"
        case .gone: contentState = "gone"
        case .loading: contentState = "loading"
        case .none: contentState = "none"
        }
        return [
            article.id,
            String(summariesEnabled),
            String(summariesAutomatic),
            contentState,
            summariesAutomatic
                ? "\(summaryStyleRaw)|\(summaryProviderRaw)|\(targetLanguageName)"
                : (summaryRequestedArticleID == article.id ? "manual:\(summaryGenerationID)" : "idle"),
        ].joined(separator: "|")
    }

    private func requestSummary(for article: Article) {
        session.begin(articleID: article.id)
        session.summary.reset()
        session.summary.beginLoading()
        summaryRequestedArticleID = article.id
        summaryGenerationID += 1
    }

    /// The reader body: reader-mode-extracted content when the experiment is on,
    /// falling back to the original feed content (with a notice) on failure.
    @ViewBuilder
    private func readerBody(_ article: Article) -> some View {
        // Show the extracted content when the experiment is on OR the user saved
        // this article offline (their explicit choice to keep the full content).
        if store.usesReaderContentByDefault || store.isOfflineSaved(article.id) {
            switch store.readerContentState(for: article) {
            case .ready(let html):
                VStack(alignment: .leading, spacing: 14) {
                    if store.droppedEmbedCount(for: article) > 0 {
                        ReaderDroppedEmbedsNotice(
                            count: store.droppedEmbedCount(for: article),
                            onUseReadability: { store.setReaderParser(.readability, for: article) })
                    }
                    HTMLContentView(html: html, baseURL: article.url, translator: session.translator(for: article.id), typography: readerTypography)
                        .id(article.id)
                }
            case .gone:
                VStack(alignment: .leading, spacing: 16) {
                    ReaderUnavailableNotice(
                        reason: .gone,
                        onRetry: { store.retryReaderContent(for: article) },
                        onDelete: { store.deleteArticle(articleID: article.id) }
                    )
                    originalArticleBody(article)
                }
            case .failed:
                // The page is still there; it just yielded no body. Deleting is
                // not the remedy, so it is not offered — but the other parser
                // might be, and it reads pages this one refuses.
                VStack(alignment: .leading, spacing: 16) {
                    ReaderUnavailableNotice(
                        reason: .notExtracted,
                        otherParser: store.displayedReaderParser(for: article).other,
                        onRetry: { store.retryReaderContent(for: article) },
                        onUseOtherParser: {
                            store.setReaderParser(
                                store.displayedReaderParser(for: article).other, for: article)
                        },
                        onDelete: { store.deleteArticle(articleID: article.id) }
                    )
                    originalArticleBody(article)
                }
            case .loading, .none:
                ReaderLoadingPlaceholder()
            }
        } else {
            originalArticleBody(article)
        }
    }

    /// The article's original feed content (HTML, translated paragraphs, or plain
    /// paragraphs) — the pre-experiment reading surface.
    @ViewBuilder
    private func originalArticleBody(_ article: Article) -> some View {
        if let html = article.contentHTML {
            HTMLContentView(html: html, baseURL: article.url, translator: session.translator(for: article.id), typography: readerTypography)
                .id(article.id)
        } else if let translation = session.plainTranslation(for: article.id) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(translation.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.system(size: readerTypography.bodySize, design: readerTypography.fontDesign))
                        .kerning(readerTypography.kern)
                        .lineSpacing(readerTypography.lineSpacing)
                        .textSelection(.enabled)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(article.bodyParagraphs, id: \.self) { paragraph in
                    Text(paragraph)
                        .font(.system(size: readerTypography.bodySize, design: readerTypography.fontDesign))
                        .kerning(readerTypography.kern)
                        .lineSpacing(readerTypography.lineSpacing)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// Keeps the article visible while reading, then marks it read only after
    /// the user dwells for the configured delay. Navigating away cancels this
    /// task before the delay elapses, so the article stays unread.
    private func markReadAfterDwell(_ article: Article) async {
        store.retainArticle(id: article.id)
        guard markReadOnOpen else { return }

        do {
            if markReadDelaySeconds > 0 {
                try await Task.sleep(for: .seconds(Double(markReadDelaySeconds)))
            } else {
                await Task.yield()
            }
            store.markArticleOpened(articleID: article.id)
        } catch {
            // Cancelled before the dwell completed — leave it unread.
        }
    }

    /// Hides the standfirst summary when it merely repeats the body, which
    /// happens for feeds that only ship a short description.
    private func shouldShowSummary(_ article: Article) -> Bool {
        let summary = article.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return false }
        let firstParagraph = article.bodyParagraphs.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary != firstParagraph
    }

    /// The feed's name and icon.
    @ViewBuilder
    private func bylineFeed(_ article: Article) -> some View {
        if let feed = store.feed(for: article.feedID) {
            Label {
                Text(feed.displayTitle)
            } icon: {
                if let icon = store.faviconImage(for: feed) {
                    icon
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                } else {
                    Image(systemName: feed.systemImage)
                }
            }
        }
    }

    /// When it was published and how long it takes to read.
    private func bylineMetadata(_ article: Article) -> some View {
        HStack(spacing: 8) {
            Text(article.publishedAt.localized(date: .abbreviated, time: .shortened))
            Text("·")
            Text("\(article.estimatedReadMinutes) min read")
        }
    }

    private func articleHeader(_ article: Article) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            MagazineArticleHeading(article: article, feedTitle: store.feed(for: article.feedID)?.displayTitle ?? "", namespace: heroNamespace, expanded: true)
            Button("Open in Reader", systemImage: "safari") {
                store.selectedArticleID = article.id
                store.isBrowserPresented = true
            }
            .buttonStyle(MagazineGlassButtonStyle())

            if translationActive(article) {
                Group {
                    if TranslationSettings.readerProvider() == .gemini {
                        Label("Translated by Gemini", systemImage: "sparkles")
                    } else {
                        Label("Translated by Apple Intelligence", systemImage: "apple.intelligence")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if shouldShowSummary(article) {
                Text(article.summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }

            HStack(spacing: 10) {
                Button {
                    store.toggleStarred(articleID: article.id)
                } label: {
                    Label(article.isStarred ? "Starred" : "Star", systemImage: article.isStarred ? "star.fill" : "star")
                }

                if canTranslate(article) {
                    Button {
                        toggleTranslation(article)
                    } label: {
                        Label(
                            translationActive(article) ? "Show Original" : "Translate",
                            systemImage: translationActive(article) ? "character.bubble.fill" : "character.bubble"
                        )
                    }
                    .disabled(session.isTranslating(for: article.id))
                }

                MagazineGlassMenu {
                    CategoryMenuItems(store: store, article: article)
                } label: {
                    Label("Categories", systemImage: "tag")
                }
                .fixedSize()

                // Only where it can do something: with reader content off and no
                // offline copy, the reader is showing the feed's own body and no
                // parser ran.
                if store.usesReaderContentByDefault || store.isOfflineSaved(article.id) {
                    Button {
                        store.refreshReaderContent(for: article)
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isReparsing(article))
                    .help("Fetch this article's page again and parse it fresh (⌘⇧R)")

                    MagazineGlassMenu {
                        ReaderParserMenuItems(store: store, article: article)
                    } label: {
                        Label("Parser", systemImage: "text.viewfinder")
                    }
                    .fixedSize()
                    .help("Re-read this article with the other parser")
                    .accessibilityValue(Text(store.displayedReaderParser(for: article).label))
                }
            }
            .buttonStyle(MagazineGlassButtonStyle())
        }
    }
}

/// A small banner shown while an article translation streams in.
private struct MagazineTranslationBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Translating…")
                .font(.callout)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .padding(.top, 12)
    }
}


struct MagazineBrowserPanel: View {
    @Bindable var store: ReaderStore
    let article: Article
    let style: ReaderStyle
    let linkOpensInApp: Bool
    @Binding var dragOffset: CGFloat
    var onClose: () -> Void

    @Environment(\.openURL) private var openURL
    @AppStorage("markReadOnOpen") private var markReadOnOpen = true
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system
    @State private var loadingProgress: Double = 0
    @State private var bottomPull: CGFloat = 0
    @State private var isTranslationOn = false
    @State private var translationInFlight = false

    private var targetLanguage: Locale.Language {
        (appLanguage == .system ? Locale.current : appLanguage.locale).language
    }

    private var targetLanguageName: String {
        // Give the model the script for Chinese so it doesn't guess Simplified vs
        // Traditional; other languages use their plain English name.
        if let script = targetLanguage.script?.identifier {
            if script == "Hans" { return "Simplified Chinese" }
            if script == "Hant" { return "Traditional Chinese" }
        }
        let code = targetLanguage.languageCode?.identifier ?? "en"
        return Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code
    }

    /// Web-view translation uses Apple Intelligence in place; offer it only when
    /// that's available and the article's language differs from the app's.
    private var canTranslate: Bool {
        guard NaturalTranslator.isAvailable(for: TranslationSettings.readerProvider()),
              let detected = MagazineReaderDetail.detectLanguage(for: article),
              let target = targetLanguage.languageCode?.identifier else { return false }
        // Compare base languages: the detector returns script-qualified codes
        // (e.g. "zh-Hans") while the target is the bare subtag ("zh"), so an
        // unnormalized compare would offer a pointless same-language translation.
        let detectedBase = Locale.Language(identifier: detected).languageCode?.identifier ?? detected
        return detectedBase != target
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            WebLoadingBar(progress: loadingProgress)
            Divider()
            ArticleWebView(
                url: article.url,
                useReaderMode: store.browserMode == .reader,
                style: style,
                parserEngine: store.browserParser(for: article),
                linkOpensInApp: linkOpensInApp,
                translate: isTranslationOn,
                translationLanguage: targetLanguageName,
                onTranslatingChange: { translationInFlight = $0 },
                onLoadingProgress: { loadingProgress = $0 },
                onOverscroll: { amount in
                    dragOffset = amount
                },
                onOverscrollEnded: { amount in
                    if amount > 140 {
                        onClose()
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) { dragOffset = 0 }
                    }
                },
                onBottomOverscroll: { bottomPull = $0 },
                onBottomOverscrollEnded: handleBottomRelease,
                // The parser that actually drew the page, which is not always the one
                // asked for: it may not have run, or may have found no article and
                // left the previous body up. The menu's check-mark follows this.
                onParserResolved: { store.setBrowserParser($0, for: article) }
            )
            // The parser is deliberately NOT part of this identity. `ArticleWebView`
            // keeps a copy of the page and re-renders from it, so switching engines
            // costs nothing; putting it here would tear the web view down and
            // download the article again.
            .id("\(article.id)|\(store.browserMode.rawValue)|\(style.identity)")
            .overlay(alignment: .bottom) {
                BottomPullAffordance(pull: bottomPull, nextTitle: store.article(after: article.id)?.title)
            }
            .overlay(alignment: .top) {
                if translationInFlight {
                    MagazineTranslationBanner()
                }
            }
            .animation(.easeInOut(duration: 0.2), value: translationInFlight)
        }
        .frame(maxWidth: 980)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.3), radius: 30, y: 6)
        .padding(.top, 44)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        .offset(y: max(0, dragOffset))
        .task(id: article.id) {
            store.retainArticle(id: article.id)
            if markReadOnOpen {
                store.markArticleOpened(articleID: article.id)
            }
        }
    }

    /// Decides what a bottom pull-up did on release: a short pull opens the next
    /// article, a longer pull closes the browser, otherwise it snaps back.
    private func handleBottomRelease(_ amount: CGFloat) {
        if amount >= BottomPullAffordance.closeThreshold {
            onClose()
        } else if amount >= BottomPullAffordance.nextThreshold {
            store.selectNextArticle()
            bottomPull = 0
        } else {
            withAnimation(.easeOut(duration: 0.2)) { bottomPull = 0 }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
                Button { onClose() } label: {
                    Image(systemName: "xmark")
                }
                .keyboardShortcut("w", modifiers: .command)
                .help("Close")

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { store.toggleBrowserMode() }
                } label: {
                    Label(
                        store.browserMode == .reader ? "Reader Mode" : "Original Page",
                        systemImage: store.browserMode == .reader ? "doc.plaintext" : "globe"
                    )
                }
                .help("Switch Reader / Original (⌘⇧F)")

                // Reader mode only: on the original page nothing is parsed, so the
                // control would be inert. Icon-only, like its neighbours.
                if store.browserMode == .reader {
                    Menu {
                        ReaderParserMenuItems(store: store, article: article, surface: .browser)
                    } label: {
                        Image(systemName: "text.viewfinder")
                    }
                    .fixedSize()
                    .help("Choose the article parser")
                    .accessibilityLabel(Text("Article Parser"))
                    .accessibilityValue(Text(store.browserParser(for: article).label))
                }

                Spacer()

                if canTranslate {
                    Button {
                        isTranslationOn.toggle()
                    } label: {
                        Image(systemName: isTranslationOn ? "character.bubble.fill" : "character.bubble")
                    }
                    .help(isTranslationOn ? "Show Original Text" : "Translate")
                }

                Button { openURL(article.url) } label: {
                    Image(systemName: "safari")
                }
                .help("Open Original")

                ShareLink(item: article.url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Share")
            }
            .buttonStyle(.borderless)
        .padding(.top, 22)
        .padding(.bottom, 9)
        .padding(.horizontal, 14)
        .background(.bar)
    }
}

