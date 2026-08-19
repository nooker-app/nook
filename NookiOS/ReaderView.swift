import NaturalLanguage
import NookKit
import SafariServices
import SwiftUI
import Translation

/// The iOS article reader. Mirrors the macOS reader: a native, selectable body
/// (system typography) with a toggle into the styled `WKWebView` reader/original
/// page presented as a sheet.
/// Reports the inline title's measured height so the reader knows the scroll
/// distance at which it passes under the navigation bar.
private struct TitleHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// A scroll sample for the chrome auto-hide: the vertical offset plus how far
/// the bottom is, so toggling can be suppressed near the end (where the bottom
/// bar's collapse/expand would rubber-band the offset and oscillate the bars).
private struct ScrollSnapshot: Equatable {
    var y: CGFloat
    var distanceToBottom: CGFloat
}

struct ReaderDetailView: View {
    @Bindable var store: ReaderStore
    /// The article to show, as a binding the compact tab shell owns, so the pushed
    /// reader is driven by its own value — not the shared, scope-dependent
    /// `store.selectedArticle` (which another tab's scope change can null out) — and
    /// so previous/next swipe can move it. nil on iPad, where the split-view detail
    /// follows `store.selectedArticle`.
    var articleOverride: Binding<Article?>? = nil

    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system
    @AppStorage("readerLinkBehavior") private var readerLinkBehavior = ReaderLinkBehavior.inApp
    /// Opt-in: press-and-hold the article body to open the in-app browser. Off by
    /// default now that the native reader covers most reading; the toolbar button
    /// still opens the browser.
    @AppStorage(ReaderStore.longPressOpensBrowserKey) private var longPressOpensBrowser = false
    @AppStorage("readerFont") private var readerFont = ReaderFont.system
    @AppStorage("readerFontSize") private var readerFontSize = 18
    @AppStorage("readerLineHeight") private var readerLineHeight = 1.7
    @AppStorage("readerLetterSpacing") private var readerLetterSpacing = 0.0
    @AppStorage("readerBackgroundOption") private var readerBackgroundOption = ReaderColorOption.automatic
    @AppStorage("readerBackgroundHex") private var readerBackgroundHex = "#FFFFFF"
    @AppStorage("readerTextOption") private var readerTextOption = ReaderColorOption.automatic
    @AppStorage("readerTextHex") private var readerTextHex = "#1A1A1A"
    @AppStorage("readerControlHand") private var defaultControlSide = ReaderControlSide.right
    @AppStorage("readerHandedness") private var readerHandedness = ReaderHandedness.right
    @AppStorage("readerAdaptiveControlsEnabled") private var adaptiveControlsEnabled = true
    @AppStorage(ArticleSummarySettings.enabledKey) private var summariesEnabled = false
    @AppStorage(ArticleSummarySettings.automaticKey) private var summariesAutomatic = false
    @AppStorage(ArticleSummarySettings.styleKey) private var summaryStyleRaw = ArticleSummaryStyle.concise.rawValue
    @AppStorage(TranslationSettings.summaryProviderKey) private var summaryProviderRaw = TranslationProvider.appleIntelligence.rawValue

    @State private var isShowingInfo = false
    @State private var confirmingDelete = false
    @AppStorage(TourFlags.seenReaderGestureHintKey) private var seenReaderGestureHint = false
    /// The interactive reader coach mark step shown the first time the reader ever
    /// opens (nil = inactive). The persisted flag is marked immediately so it's
    /// strictly one-shot; this drives the transient spotlight walkthrough, and
    /// lives on the parent so it survives the per-article `.id` reset (letting the
    /// pull-to-next step carry over to the next article).
    @State private var coachStep: ReaderCoachStep?
    /// The open-original glass button's measured global frame, so the coach mark
    /// spotlights the real control exactly.
    @State private var originalButtonFrame: CGRect = .zero
    @State private var imagePresenter = ArticleImagePresenter()
    @State private var haptics = ReaderHaptics()
    @State private var pendingBuildup: Task<Void, Never>?
    /// Session-only override inferred from qualified native-reader scrolls. The
    /// configured default remains untouched and is restored as soon as the policy
    /// sees scrolling return to that side.
    @State private var controlsAreAdaptivelyMirrored = false
    /// Non-observable storage keeps the first few evidence samples from
    /// invalidating the reader. SwiftUI state changes only when the effective
    /// control layout actually changes.
    @State private var handAdaptation = HandAdaptationBookkeeping()

    // Native title handling: the full title renders inline at the top of the
    // article; once it scrolls up under the navigation bar, the bar's own title
    // fades in — the standard iOS large-to-inline title reveal, but keeping the
    // full multi-line inline title so long titles stay fully readable.
    @State private var titleHidden = false
    @State private var titleHeight: CGFloat = 0
    /// Safari-style chrome auto-hide: scrolling down fades the top and bottom bars
    /// (background + controls) so the body has the screen; scrolling up (or
    /// reaching the top) brings them back. The bars keep their layout space and
    /// only their opacity/background change, so nothing shifts and the scroll
    /// offset never feeds back. Reset per article (identity-keyed on article id).
    @State private var chromeHidden = false
    /// Scroll bookkeeping for a stable auto-hide: accumulate distance since the
    /// last direction change and only flip once it passes a threshold, so momentum
    /// and tiny jitters can't flicker the bars.
    ///
    /// Deliberately a plain (non-Observable) class box: these values are written
    /// on EVERY scroll tick, and as `@State` scalars each write re-executed the
    /// whole reader body per frame. Mutating a non-observed box is invalidation-
    /// free; only the derived flips (`titleHidden`/`chromeHidden`) touch state.
    @State private var scrollBook = ScrollBookkeeping()

    @MainActor
    private final class ScrollBookkeeping {
        var lastY: CGFloat = 0
        var accum: CGFloat = 0
    }

    @MainActor
    private final class HandAdaptationBookkeeping {
        private var policy = ReaderControlAdaptationPolicy()

        func record(
            _ observedSide: ReaderControlSide,
            primaryHand: ReaderHandedness
        ) -> Bool {
            policy.record(observedSide, primaryHand: primaryHand)
        }

        func reset() {
            policy.reset()
        }
    }
    /// A bottom-edge pull clears only the floating action bar so the next-article
    /// indicator can own that space. It deliberately does not change `chromeHidden`:
    /// toggling the navigation chrome during elastic overscroll can move the scroll
    /// view's geometry, especially when a short article rests at both edges.
    @State private var bottomPullEngaged = false

    /// The press must stay put this long before the haptic build-up begins, so a
    /// swipe or scroll (which moves past the gesture's maximumDistance well
    /// within this window) never kicks off a stray vibration.
    private let hapticStartDelay: Double = 0.16

    // Double-tap star "burst" overlay.
    @State private var starBurstOn = true
    @State private var starBurstScale: CGFloat = 0.4
    @State private var starBurstOpacity: Double = 0

    // On-device translation. Offered only when the detected content language
    // differs from the app's language. Prefers Apple Intelligence (natural,
    // inline) and falls back to the system Translation overlay.
    @State private var detectedLanguage: String?
    @State private var isShowingTranslation = false
    @State private var translatedTitle: String?
    @State private var translatedBody: [String]?
    @State private var isTranslated = false
    @State private var isTranslating = false
    /// Streaming in-place translator for the rich (contentHTML) reader: it swaps
    /// each block's text as it arrives while preserving markup. The legacy
    /// `translatedBody` path above still handles plain-paragraph-only articles.
    @State private var nativeTranslator = NativeArticleTranslator()
    @State private var summaryController = ArticleSummaryController()
    @State private var summaryRequestedArticleID: String?
    @State private var summaryArticleID: String?
    @State private var summaryGenerationID = 0
    @State private var summaryScrollRequestID = 0

    /// The language to translate into: the app's chosen language, or the system
    /// language when set to "System".
    private var targetLanguage: Locale.Language {
        let locale = appLanguage == .system ? Locale.current : appLanguage.locale
        return locale.language
    }

    /// True when the article's detected language differs from the target, so
    /// translation is worth offering.
    private var canTranslate: Bool {
        guard let detected = detectedLanguage,
              let target = targetLanguage.languageCode?.identifier else { return false }
        // Compare base languages so a script-qualified detection ("zh-Hans")
        // isn't treated as different from the bare target ("zh").
        let detectedBase = Locale.Language(identifier: detected).languageCode?.identifier ?? detected
        return detectedBase != target
    }

    /// The HTML the reader is actually showing: the reader-mode extraction when
    /// ready, else the feed's own content HTML (nil = plain-paragraph body). The
    /// translator must consume exactly this so its per-block overrides line up
    /// with the rendered blocks.
    /// Cache-warming identity: changes when the article switches, and again whenever
    /// the reader's HTML changes — reader-mode content arriving, or a different parser
    /// producing a different body.
    ///
    /// The body's identity and not just "ready": on a switch back to a body this
    /// session already has, the state goes `.ready(A)` → `.ready(B)` with no
    /// `.loading` in between, so a key that only said "ready" never changed and the
    /// one switch that should have been free was the one that hitched through the
    /// importer on first scroll.
    private func warmingKey(for article: Article) -> String {
        if case .ready(let html) = store.readerContentState(for: article) {
            return "\(article.id)|ready|\(html.hashValue)"
        }
        return "\(article.id)"
    }

    private func renderedReaderHTML(for article: Article) -> String? {
        if store.usesReaderContentByDefault, case .ready(let extracted) = store.readerContentState(for: article) {
            return extracted
        }
        return article.contentHTML
    }

    /// Whether the currently-selected article is showing a translation. Rich
    /// articles use the streaming native translator; others use the legacy
    /// plain-body path.
    private func translationActive(_ article: Article) -> Bool {
        renderedReaderHTML(for: article) != nil ? nativeTranslator.isActive : isTranslated
    }

    /// Whether a translation is in progress (either path).
    private var translationBusy: Bool {
        nativeTranslator.isTranslating || isTranslating
    }

    /// The title to show: the streamed translation for rich articles, the legacy
    /// translated title otherwise, else the original.
    private func displayTitle(_ article: Article) -> String {
        if renderedReaderHTML(for: article) != nil {
            return nativeTranslator.isActive ? (nativeTranslator.translatedTitle ?? article.title) : article.title
        }
        return isTranslated ? (translatedTitle ?? article.title) : article.title
    }

    private var readerStyle: ReaderStyle {
        ReaderStyle(
            font: readerFont,
            fontSize: readerFontSize,
            lineHeight: readerLineHeight,
            letterSpacing: readerLetterSpacing,
            backgroundOption: readerBackgroundOption,
            backgroundHex: readerBackgroundHex,
            textOption: readerTextOption,
            textHex: readerTextHex
        )
    }

    /// The article currently on screen, re-resolved live from the store by ID so
    /// mutations made in the reader (star, read) reflect immediately — the captured
    /// `pushed` snapshot the compact shell drives this with wouldn't otherwise
    /// update. Falls back to the snapshot if the store no longer has it.
    private var currentArticle: Article? {
        guard store.isStorageConfigured,
              let base = articleOverride?.wrappedValue ?? store.selectedArticle else { return nil }
        return store.article(withID: base.id) ?? base
    }

    var body: some View {
        Group {
            if !store.isStorageConfigured {
                ContentUnavailableView {
                    Label("Set Up Sync", systemImage: "icloud.and.arrow.up")
                } description: {
                    Text("Choose a sync folder so Nook keeps your feeds in sync across your devices.")
                }
            } else if let article = currentArticle {
                reader(article)
            } else {
                ContentUnavailableView("Select an Article", systemImage: "newspaper")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("ListBackground").ignoresSafeArea())
        // Keep the left-edge swipe-to-go-back working even while the reader hides
        // its back button (immersive reading). Hiding the back button otherwise
        // makes the system disable the interactive pop gesture.
        .background(InteractivePopGestureEnabler())
        .articleImageOverlay(imagePresenter)
        // The interactive coach marks live here — outside the per-article `.id`
        // subtree in `reader(_:)` — so their step survives an article change (the
        // pull-to-next step advances onto the next article without resetting).
        .onPreferenceChange(OriginalButtonFrameKey.self) { originalButtonFrame = $0 }
        .overlay {
            GeometryReader { proxy in
                if coachStep != nil, currentArticle != nil {
                    ReaderCoachMarks(
                        step: $coachStep,
                        size: proxy.size,
                        originalButtonRect: originalButtonFrame == .zero ? nil : originalButtonFrame,
                        onNext: { advanceCoach(from: $0) },
                        onSkip: { withAnimation { coachStep = nil } }
                    )
                }
            }
            .ignoresSafeArea()
        }
        // Advance the walkthrough when the taught action actually happens.
        .onChange(of: currentArticle?.isStarred ?? false) { _, starred in
            if starred { advanceCoach(from: .star) }
        }
        .onChange(of: currentArticle?.id) { _, _ in
            advanceCoach(from: .pullNext)
        }
        .onChange(of: store.isBrowserPresented) { _, presented in
            if presented { advanceCoach(from: .original) }
        }
    }

    /// Advances the coach walkthrough from `step` to the next one (or ends it),
    /// but only if that step is the one currently showing — so a live action and
    /// the "Next" button share one path and out-of-order changes are ignored.
    private func advanceCoach(from step: ReaderCoachStep) {
        guard coachStep == step else { return }
        withAnimation(.easeInOut(duration: 0.28)) { coachStep = step.next }
    }

    private func reader(_ article: Article) -> some View {
        GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
                ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(article)

                    Group {
                        if summariesEnabled, let summary = summaryController.summary {
                            ArticleSummaryCard(
                                summary: summary,
                                style: summaryController.style,
                                provider: summaryController.provider
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .id(summaryAnchorID(for: article))

                    Divider()

                    readerBody(article)

                    // The page's own discussion, under the article it belongs to. Only
                    // legibility extracts it, so an article read with Readability and
                    // never re-read simply has no section here.
                    if let comments = store.readerComments(for: article) {
                        Divider()
                        ReaderCommentsSection(
                            thread: comments, baseURL: article.url,
                            typography: readerStyle.typography, selectable: false)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                // Fill at least the whole viewport so the gestures also fire in
                // the empty space below a short article, not only on the text.
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                // Double-tap the body to star; press-and-hold (opt-in) to open the
                // web view with a build-up of haptic taps ending in one deep pulse.
                .onTapGesture(count: 2) {
                    let willStar = !article.isStarred
                    store.toggleStarred(articleID: article.id)
                    haptics.star(on: willStar)
                    triggerStarBurst(on: willStar)
                }
                // Single tap toggles the chrome, so it can be controlled without
                // scrolling. It can only HIDE once the large inline title has
                // scrolled away (same condition the scroll auto-hide uses) — a tap
                // while the big title still shows does nothing; showing is always
                // allowed. Disabled during the coach marks (chrome is frozen then).
                .onTapGesture {
                    guard coachStep == nil else { return }
                    if chromeHidden {
                        withAnimation(.easeInOut(duration: 0.25)) { chromeHidden = false }
                    } else if titleHidden {
                        scrollBook.accum = 0
                        withAnimation(.easeInOut(duration: 0.25)) { chromeHidden = true }
                    }
                }
                .modifier(LongPressToOpenBrowser(
                    enabled: longPressOpensBrowser,
                    minimumDuration: hapticStartDelay + ReaderHaptics.buildupDuration,
                    onOpen: {
                        pendingBuildup?.cancel()
                        pendingBuildup = nil
                        openBrowser(for: article)
                    },
                    onPressingChanged: { pressing in
                        if pressing {
                            // Defer the haptic; if the finger moves (swipe/scroll),
                            // the gesture cancels and pressing flips false first.
                            pendingBuildup = Task {
                                try? await Task.sleep(for: .seconds(hapticStartDelay))
                                if !Task.isCancelled { haptics.startLongPressBuildup() }
                            }
                        } else {
                            pendingBuildup?.cancel()
                            pendingBuildup = nil
                            haptics.cancelLongPressBuildup()
                        }
                    }
                ))
                // This marker lives INSIDE the scroll content, so its ancestor
                // chain reliably reaches the outer UIScrollView. It adds a target
                // to that view's existing pan recognizer rather than introducing
                // another recognizer, leaving horizontal pop gestures untouched.
                .background {
                    ReaderScrollPanObserver(enabled: adaptiveControlsEnabled) { side in
                        recordReaderScroll(from: side)
                    }
                }
            }
            // Pull past the bottom for the next article, past the top for the
            // previous one. The web reader keeps its own bottom-only affordance.
            .readerSwipeNavigation(
                nextTitle: store.article(after: article.id)?.title,
                previousTitle: store.article(before: article.id)?.title,
                onNext: { navigateReader(forward: true) },
                onPrevious: { navigateReader(forward: false) },
                onPullEngagedChange: { engaged in
                    // The bottom bar is an overlay, so fading it cannot alter the
                    // active scroll view's layout or interrupt this pull.
                    if engaged != bottomPullEngaged {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            bottomPullEngaged = engaged
                        }
                    }
                }
            )
            .onPreferenceChange(TitleHeightKey.self) { titleHeight = $0 }
            // Reveal the navigation-bar title once the inline title has scrolled up
            // under the bar (its bottom = top padding + its height). The content top
            // sits at the bar's bottom, so the raw scroll offset is the distance
            // travelled — no bar-geometry math needed.
            .onScrollGeometryChange(for: ScrollSnapshot.self) { geo in
                let maxY = max(0, geo.contentSize.height - geo.containerSize.height)
                // Elastic overscroll is a gesture beyond an edge, not reading
                // progress. Clamp it away so a one-screen article's bottom pull
                // cannot masquerade as scrolling its title under the top bar.
                let boundedY = min(max(0, geo.contentOffset.y), maxY)
                return ScrollSnapshot(y: boundedY, distanceToBottom: maxY - boundedY)
            } action: { _, snap in
                // Freeze the chrome while the coach marks are up, so the bottom bar
                // (and its document button, spotlighted in one step) stays put.
                guard coachStep == nil else { return }
                let newY = snap.y
                // Content starts under the bar with 16pt top padding, so the inline
                // title's bottom passes the bar after scrolling ~padding + height.
                let pastTitle = newY > titleHeight + 8
                if pastTitle != titleHidden {
                    withAnimation(.easeInOut(duration: 0.2)) { titleHidden = pastTitle }
                }

                let delta = newY - scrollBook.lastY
                scrollBook.lastY = newY

                // Near the bottom, freeze the bars: the bottom bar's collapse/expand
                // there changes the content height and rubber-bands the offset, which
                // would otherwise bounce the bars in and out.
                guard snap.distanceToBottom > 100 else { return }

                // Chrome auto-hide with hysteresis. Accumulate scroll distance since
                // the last direction change; only flip after a sustained move, and
                // always show near the top.
                if (delta > 0) != (scrollBook.accum > 0) { scrollBook.accum = 0 }
                scrollBook.accum += delta

                let target: Bool
                if !pastTitle {
                    target = false
                } else if scrollBook.accum > 44 {
                    target = true
                } else if scrollBook.accum < -44 {
                    target = false
                } else {
                    target = chromeHidden
                }
                if target != chromeHidden {
                    scrollBook.accum = 0
                    withAnimation(.easeInOut(duration: 0.25)) { chromeHidden = target }
                }
            }
                .onChange(of: summaryScrollRequestID) { _, _ in
                    withAnimation(.easeInOut(duration: 0.3)) {
                        scrollProxy.scrollTo(summaryAnchorID(for: article), anchor: .top)
                    }
                }
            }
        }
        // System inline title: correct width, truncation, and position (centered in
        // the real space between the back button and trailing group) — no custom
        // bounding. Empty near the top (the big inline title in the body shows
        // there); once that scrolls away it fills in, which also anchors the bar's
        // height so hiding the controls never collapses it.
        .navigationTitle(titleHidden ? displayTitle(article) : "")
        .navigationBarTitleDisplayMode(.inline)
        // Hide the chrome by fading the bar BACKGROUNDS (not by removing the bars),
        // so the bars keep their layout space and the body never shifts. Content
        // already scrolls under the translucent bars, so a hidden background simply
        // reveals the body beneath — Safari-style — top and bottom. Controls fade
        // via opacity alongside (below).
        .toolbarBackground(chromeHidden ? .hidden : .automatic, for: .navigationBar)
        // Hide the system back button too while immersed (its own glass capsule
        // would otherwise linger); the edge-swipe back gesture still works, and
        // scrolling up brings the bar — and the button — right back.
        .navigationBarBackButtonHidden(chromeHidden)
        .overlay {
            Image(systemName: starBurstOn ? "star.fill" : "star.slash.fill")
                .font(.system(size: 104, weight: .bold))
                .foregroundStyle(starBurstOn ? .yellow : .white)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                .scaleEffect(starBurstScale)
                .opacity(starBurstOpacity)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            if translationBusy {
                TranslationProgressBanner()
            }
        }
        // Bottom action bar. Rendered as a content overlay of Liquid Glass capsules
        // (matching the native `.bottomBar` look) rather than a system bottom bar,
        // so its buttons are ordinary SwiftUI views the coach mark can measure and
        // spotlight exactly — while never participating in layout (no shift/bounce).
        .overlay(alignment: .bottom) { readerBottomBar(article) }
        .animation(.easeInOut(duration: 0.2), value: translationBusy)
        .toolbar {
            // The button controls carry iOS 26 glass capsules, so remove them (not
            // just fade them) while immersed — a fade would leave the empty pills.
            // The system navigationTitle (below) fills the bar once the inline title
            // scrolls away, which also keeps the bar from collapsing (no shift).
            if !chromeHidden {
                // Top-right stays a single, uncrowded "more" menu for the occasional
                // actions; the frequent ones live in the bottom toolbar below.
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        // Translation lives on the bottom bar (right side) for quick
                        // access; the menu keeps the occasional actions.
                        Button {
                            isShowingInfo = true
                        } label: {
                            Label("Article Info", systemImage: "info.circle")
                        }
                        Menu {
                            CategoryMenuItems(store: store, article: article)
                        } label: {
                            Label("Categories", systemImage: "tag")
                        }
                        // Only where a parser actually ran: with reader content off
                        // and no offline copy, the reader is showing the feed's own
                        // body and there is nothing to re-read.
                        if store.usesReaderContentByDefault || store.isOfflineSaved(article.id) {
                            Menu {
                                ReaderParserMenuItems(
                                    store: store, article: article,
                                    onChange: { haptics.selectionChanged() })
                            } label: {
                                Label("Parser", systemImage: "text.viewfinder")
                            }
                            .accessibilityValue(Text(store.displayedReaderParser(for: article).label))
                        }
                        Link(destination: article.url) {
                            Label("Open Original", systemImage: "safari")
                        }
                        Divider()
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label("Delete Article", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task(id: article.id) {
            // Detect the article's language so translation is offered only when
            // it differs from the app's language; reset any prior translation.
            isShowingTranslation = false
            isTranslated = false
            translatedTitle = nil
            translatedBody = nil
            nativeTranslator.stop()
            detectedLanguage = nil
            // Start reader-mode extraction first so it isn't delayed behind
            // language detection.
            store.ensureReaderContent(for: article)
            // First time the reader is ever opened, run the interactive coach-mark
            // walkthrough once. Mark the flag immediately so it's strictly
            // one-shot; the walkthrough persists across article changes (its state
            // lives on the parent), so this guard also keeps a later article change
            // from restarting it.
            if !seenReaderGestureHint {
                seenReaderGestureHint = true
                withAnimation { coachStep = .star }
            }
            // Detect the language off the main actor so the recognizer doesn't
            // run on the transition frame.
            let detected = await Task.detached { Self.detectLanguage(for: article) }.value
            if !Task.isCancelled { detectedLanguage = detected }
        }
        .task(id: summaryTaskKey(for: article)) {
            if summaryArticleID != article.id {
                summaryController.reset()
                summaryRequestedArticleID = nil
                summaryArticleID = article.id
            }
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
        // Warm the reader's text-import cache after the open transition settles, so
        // per-block WebKit imports don't stall scrolling. Re-runs when reader-mode
        // content becomes ready (to warm the extracted HTML shown then), and cancels
        // on article switch. Skipped while translating (the translator replaces
        // blocks, so warming the untranslated keys would be wasted).
        .task(id: warmingKey(for: article)) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, !nativeTranslator.isActive else { return }
            if let html = renderedReaderHTML(for: article) {
                await HTMLContentText.warmReaderAttributedCache(
                    html: html, baseURL: article.url, typography: readerStyle.typography
                )
            }
        }
        // If reader-mode content finishes extracting AFTER translation was turned
        // on, restart the translator against the now-rendered extracted HTML so
        // its per-block overrides line up with what's shown.
        .onChange(of: store.readerContentState(for: article)) { _, newValue in
            guard nativeTranslator.isActive, case .ready(let extracted) = newValue else { return }
            nativeTranslator.start(html: extracted, baseURL: article.url, title: article.title, into: targetLanguageName)
        }
        .onChange(of: summariesEnabled) { _, enabled in
            guard !enabled else { return }
            summaryRequestedArticleID = nil
            summaryController.reset()
        }
        .onChange(of: defaultControlSide) { _, _ in
            resetHandAdaptation()
        }
        .onChange(of: readerHandedness) { _, _ in
            resetHandAdaptation()
        }
        .onChange(of: adaptiveControlsEnabled) { _, _ in
            resetHandAdaptation()
        }
        .translationPresentation(
            isPresented: $isShowingTranslation,
            text: Self.translationText(for: article)
        )
        .sheet(isPresented: $store.isBrowserPresented) {
            InAppBrowserSheet(
                store: store,
                article: article,
                style: readerStyle,
                linkOpensInApp: readerLinkBehavior == .inApp
            )
        }
        .sheet(isPresented: $isShowingInfo) {
            ArticleInfoView(store: store, article: article)
        }
        .confirmationDialog(
            "Delete this article?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Article", role: .destructive) { deleteAndClose(article) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It's removed from your list on all your devices. This can't be undone.")
        }
        // Floated over the article rather than placed in it: the point of the
        // re-parse chip is that what you were reading stays where it was.
        .overlay(alignment: .top) {
            if store.isReparsing(article) {
                ReaderReparsingBanner(engine: store.displayedReaderParser(for: article))
                    .padding(.top, 10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.isReparsing(article))
        .id(article.id)
        .transition(.push(from: readerNavForward ? .bottom : .top))
    }

    /// Waits for Reader extraction so the model never summarizes feed fallback
    /// text while the native reader is about to replace it with full content.
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
        summaryController.reset()
        summaryController.beginLoading()
        summaryArticleID = article.id
        summaryRequestedArticleID = article.id
        summaryGenerationID += 1
    }

    /// Whether the last article change moved forward (next). Drives the push
    /// transition direction so previous/next slide the natural way.
    @State private var readerNavForward = true

    /// Navigates to the adjacent article with a directional push animation.
    private func navigateReader(forward: Bool) {
        // Navigate relative to the article actually on screen (the override binding
        // when pushed in a tab, else the store selection), and move BOTH that
        // binding and the store selection — otherwise the pushed reader keeps
        // showing the captured article and the gesture appears to do nothing.
        let currentID = (articleOverride?.wrappedValue ?? store.selectedArticle)?.id
        guard let currentID else { return }
        guard let next = forward ? store.article(after: currentID) : store.article(before: currentID) else { return }
        readerNavForward = forward
        // The old pull modifier may leave the hierarchy as soon as selection
        // changes, before it gets a chance to report its final disengaged state.
        // Reset all per-article chrome bookkeeping explicitly so the new article
        // always starts from a stable, visible top position.
        bottomPullEngaged = false
        chromeHidden = false
        titleHidden = false
        scrollBook.lastY = 0
        scrollBook.accum = 0
        withAnimation(.easeInOut(duration: 0.3)) {
            store.selectedArticleID = next.id
            articleOverride?.wrappedValue = next
        }
    }

    /// Deletes the article (its original is gone) and leaves the reader: clears
    /// the pushed binding to pop on iPhone; on iPad the store clears the selection
    /// so the detail column empties.
    private func deleteAndClose(_ article: Article) {
        store.deleteArticle(articleID: article.id)
        articleOverride?.wrappedValue = nil
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
                VStack(alignment: .leading, spacing: 12) {
                    if store.droppedEmbedCount(for: article) > 0 {
                        ReaderDroppedEmbedsNotice(
                            count: store.droppedEmbedCount(for: article),
                            onUseReadability: {
                                haptics.selectionChanged()
                                store.setReaderParser(.readability, for: article)
                            })
                    }
                    HTMLContentView(html: html, baseURL: article.url, selectable: false, translator: nativeTranslator, typography: readerStyle.typography)
                }
            case .gone:
                VStack(alignment: .leading, spacing: 14) {
                    ReaderUnavailableNotice(
                        reason: .gone,
                        onRetry: { store.retryReaderContent(for: article) },
                        onDelete: { deleteAndClose(article) }
                    )
                    originalArticleBody(article)
                }
            case .failed:
                // The page is still there; it just yielded no body. Deleting is
                // not the remedy, so it is not offered — but the other parser
                // might be, and it reads pages this one refuses.
                VStack(alignment: .leading, spacing: 14) {
                    ReaderUnavailableNotice(
                        reason: .notExtracted,
                        otherParser: store.displayedReaderParser(for: article).other,
                        onRetry: { store.retryReaderContent(for: article) },
                        onUseOtherParser: {
                            haptics.selectionChanged()
                            store.setReaderParser(
                                store.displayedReaderParser(for: article).other, for: article)
                        },
                        onDelete: { deleteAndClose(article) }
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

    /// The article's original feed content — the pre-experiment reading surface.
    @ViewBuilder
    private func originalArticleBody(_ article: Article) -> some View {
        if let html = article.contentHTML {
            // Text selection is disabled so the double-tap / long-press gestures
            // own the body. The translator streams translated blocks when active.
            // Deferred: a cold open renders plain paragraphs during the push and
            // swaps in styled blocks once parsed/warmed off the transition.
            DeferredHTMLContentView(
                html: html,
                baseURL: article.url,
                placeholderParagraphs: article.bodyParagraphs,
                selectable: false,
                translator: nativeTranslator,
                typography: readerStyle.typography
            )
        } else if isTranslated, let translatedBody {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(translatedBody.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.system(size: readerStyle.typography.bodySize, design: readerStyle.typography.fontDesign))
                        .kerning(readerStyle.typography.kern)
                        .lineSpacing(readerStyle.typography.lineSpacing)
                        .textSelection(.enabled)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(article.bodyParagraphs, id: \.self) { paragraph in
                    Text(paragraph)
                        .font(.system(size: readerStyle.typography.bodySize, design: readerStyle.typography.fontDesign))
                        .kerning(readerStyle.typography.kern)
                        .lineSpacing(readerStyle.typography.lineSpacing)
                }
            }
        }
    }

    private func header(_ article: Article) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title first and prominent (system text style, Dynamic Type), the way
            // Safari Reader / News present an article.
            Text(displayTitle(article))
                .font(.title.weight(.bold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { g in
                        Color.clear.preference(key: TitleHeightKey.self, value: g.size.height)
                    }
                )

            // Source + date as a single secondary metadata line. The feed name
            // truncates with an ellipsis so a long name never wraps or pushes the
            // date off; the date keeps its intrinsic width.
            HStack(spacing: 6) {
                if let feed = store.feed(for: article.feedID) {
                    if let icon = store.faviconImage(for: feed) {
                        icon.resizable().aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    } else {
                        Image(systemName: feed.systemImage).imageScale(.small)
                    }
                    Text(feed.displayTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                }
                Text(article.publishedAt.localized(date: .abbreviated, time: .shortened))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

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
        }
    }

    /// Pops a large star over the article that springs in, holds, then fades
    /// out and drifts up — the visual counterpart to the double-tap star.
    private func triggerStarBurst(on: Bool) {
        starBurstOn = on
        starBurstScale = 0.4
        starBurstOpacity = 0
        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
            starBurstScale = 1.0
            starBurstOpacity = 1.0
        }
        Task {
            try? await Task.sleep(for: .seconds(0.45))
            withAnimation(.easeOut(duration: 0.35)) {
                starBurstOpacity = 0
                starBurstScale = 1.3
            }
        }
    }

    private func openBrowser(for article: Article) {
        store.browserMode = store.resolvedBrowserMode(for: article)
        store.isBrowserPresented = true
    }

    /// The reader's bottom action bar, built to look like the native iOS 26
    /// `.bottomBar`: Liquid Glass capsules floating over the content (share + star
    /// grouped on the leading side, open-original trailing), with content scrolling
    /// under them. It's a content overlay — so it never affects layout (no
    /// collapse/shift/bounce) and its buttons are ordinary SwiftUI views the coach
    /// mark can measure. Fades with the reading chrome or while its bottom-edge
    /// pull indicator owns the same space.
    private func readerBottomBar(_ article: Article) -> some View {
        let isHidden = chromeHidden || bottomPullEngaged
        let effectiveSide = adaptiveControlsEnabled && controlsAreAdaptivelyMirrored
            ? defaultControlSide.opposite
            : defaultControlSide
        return GlassBarContainer {
            HStack(spacing: 0) {
                if effectiveSide == .right {
                    readerSecondaryControls(article, for: effectiveSide)
                    Spacer(minLength: 0)
                    readerPrimaryControls(article, for: effectiveSide)
                } else {
                    readerPrimaryControls(article, for: effectiveSide)
                    Spacer(minLength: 0)
                    readerSecondaryControls(article, for: effectiveSide)
                }
            }
            .tint(Color("AccentColor"))
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .opacity(isHidden ? 0 : 1)
        .allowsHitTesting(!isHidden)
        .animation(.easeInOut(duration: 0.25), value: isHidden)
        .animation(.snappy(duration: 0.3), value: effectiveSide)
    }

    /// Frequent reading actions. These favor the configured/effective side.
    @ViewBuilder
    private func readerPrimaryControls(
        _ article: Article,
        for side: ReaderControlSide
    ) -> some View {
        HStack(spacing: 2) {
            if side == .left {
                readerOpenButton(article)
                readerSummaryButton(article)
                readerTranslateButton(article)
            } else {
                readerTranslateButton(article)
                readerSummaryButton(article)
                readerOpenButton(article)
            }
        }
        .glassCapsule()
        .animation(.easeInOut(duration: 0.2), value: canTranslate)
    }

    @ViewBuilder
    private func readerSecondaryControls(
        _ article: Article,
        for side: ReaderControlSide
    ) -> some View {
        HStack(spacing: 2) {
            if side == .left {
                readerStarButton(article)
                readerShareButton(article)
            } else {
                readerShareButton(article)
                readerStarButton(article)
            }
        }
        .glassCapsule()
    }

    @ViewBuilder
    private func readerTranslateButton(_ article: Article) -> some View {
        if canTranslate {
            Button {
                toggleTranslation(article)
            } label: {
                Group {
                    if translationBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: translationActive(article) ? "character.bubble.fill" : "character.bubble")
                            .font(.system(size: 20))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 52, height: 48)
            }
            .disabled(translationBusy)
            .help(translationActive(article) ? "Show Original" : "Translate")
        }
    }

    /// Opens the in-app browser on tap; long-press chooses the article parser.
    ///
    /// A `Menu` with a `primaryAction` rather than a sixth button: five 52-point
    /// controls plus capsule padding already fill the bar on a 375-point phone, and
    /// the coach mark spotlights this button's frame, so it has to stay one control
    /// in one place.
    private func readerOpenButton(_ article: Article) -> some View {
        Menu {
            // Only where a parser ran. With reader content off and no offline copy the
            // reader shows the feed's own body, and a long press would open a menu whose
            // items change nothing on screen.
            if store.usesReaderContentByDefault || store.isOfflineSaved(article.id) {
                ReaderParserMenuItems(
                    store: store, article: article,
                    onChange: { haptics.selectionChanged() })
            }
        } label: {
            Image(systemName: "doc.plaintext")
                .font(.system(size: 20))
                .frame(width: 52, height: 48)
        } primaryAction: {
            openBrowser(for: article)
        }
        .reportGlobalFrame(OriginalButtonFrameKey.self)
        .help("Open Reader / Original")
        .accessibilityLabel(Text("Open Reader / Original"))
        .accessibilityValue(Text(store.displayedReaderParser(for: article).label))
    }

    @ViewBuilder
    private func readerSummaryButton(_ article: Article) -> some View {
        if summariesEnabled {
            Button {
                if summaryController.summary != nil {
                    summaryScrollRequestID += 1
                } else {
                    requestSummary(for: article)
                }
            } label: {
                Group {
                    if summaryController.isLoading {
                        ProgressView().controlSize(.small)
                    } else if summaryController.issue != nil {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 20))
                    } else {
                        Image(systemName: summaryController.summary == nil
                            ? "apple.intelligence"
                            : "checkmark.circle.fill")
                            .font(.system(size: 20))
                    }
                }
                .frame(width: 52, height: 48)
            }
            .disabled(summaryController.isLoading)
            .accessibilityLabel(summaryController.isLoading ? "Summarizing…" : "Summarize")
            .help(summaryController.isLoading ? "Summarizing…" : "Summarize")
        }
    }

    private func summaryAnchorID(for article: Article) -> String {
        "article-summary-\(article.id)"
    }

    private func readerShareButton(_ article: Article) -> some View {
        ArticleShareMenu(
            articleURL: article.url,
            title: article.title,
            markdown: {
                nativeTranslator.translatedMarkdown
                    ?? store.nativeReaderMarkdown(for: article)
            }
        ) { copied in
            Image(systemName: copied ? "checkmark" : "square.and.arrow.up")
                .font(.system(size: 20))
                .frame(width: 52, height: 48)
        }
    }

    private func readerStarButton(_ article: Article) -> some View {
        Button {
            let willStar = !article.isStarred
            store.toggleStarred(articleID: article.id)
            haptics.star(on: willStar)
        } label: {
            Image(systemName: article.isStarred ? "star.fill" : "star")
                .font(.system(size: 20))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 52, height: 48)
        }
    }

    private func resetHandAdaptation() {
        handAdaptation.reset()
        withAnimation(.snappy(duration: 0.3)) {
            controlsAreAdaptivelyMirrored = false
        }
    }

    /// Records one already-qualified vertical scroll sample. Handedness decides
    /// whether the DEFAULT layout remains in force; control placement is a
    /// separate preference and is only mirrored for opposite-hand use.
    private func recordReaderScroll(from observedSide: ReaderControlSide) {
        guard adaptiveControlsEnabled else { return }
        let shouldMirror = handAdaptation.record(
            observedSide,
            primaryHand: readerHandedness
        )
        guard shouldMirror != controlsAreAdaptivelyMirrored else { return }
        withAnimation(.snappy(duration: 0.3)) {
            controlsAreAdaptivelyMirrored = shouldMirror
        }
    }

    // MARK: - Translation

    /// Detects the dominant language of an article's text (e.g. "en", "ko").
    nonisolated static func detectLanguage(for article: Article) -> String? {
        let sample = (article.bodyParagraphs.prefix(4).joined(separator: " ") + " " + article.title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        return recognizer.dominantLanguage?.rawValue
    }

    /// The text handed to the system translation overlay: the title followed by
    /// the article body.
    private static func translationText(for article: Article) -> String {
        ([article.title] + article.bodyParagraphs)
            .joined(separator: "\n\n")
    }

    /// The target language's English name for the translation prompt (e.g.
    /// "Korean"), which reads more reliably to the model than a code.
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

    /// Toggles inline translation. Uses Apple Intelligence for a natural
    /// translation when available; otherwise presents the system Translation
    /// overlay as a fallback.
    private func toggleTranslation(_ article: Article) {
        // Rich articles translate in place, block by block, preserving markup —
        // against the same HTML the reader renders (extracted reader-mode content
        // when ready), so overrides line up with the shown blocks.
        if let html = renderedReaderHTML(for: article) {
            if nativeTranslator.isActive {
                nativeTranslator.stop()
            } else if NaturalTranslator.isAvailable(for: TranslationSettings.readerProvider()) {
                nativeTranslator.start(
                    html: html, baseURL: article.url, title: article.title, into: targetLanguageName
                )
            } else {
                isShowingTranslation = true
            }
            return
        }

        // Plain-paragraph articles: legacy whole-body translation.
        if isTranslated {
            isTranslated = false
            return
        }
        if translatedBody != nil {
            isTranslated = true
            return
        }
        guard NaturalTranslator.isAvailable(for: TranslationSettings.readerProvider()) else {
            isShowingTranslation = true
            return
        }
        isTranslating = true
        let body = article.bodyParagraphs
        let title = article.title
        let language = targetLanguageName
        let provider = TranslationSettings.readerProvider()
        Task {
            defer { isTranslating = false }
            do {
                async let titleText = NaturalTranslator.translate(title, into: language, provider: provider)
                async let bodyText = NaturalTranslator.translate(body.joined(separator: "\n\n"), into: language, provider: provider)
                let (t, b) = try await (titleText, bodyText)
                // Guard against the model "answering" an imperative title instead
                // of translating it: drop a result that ballooned past the source.
                let cleanedTitle = t.trimmingCharacters(in: .whitespacesAndNewlines)
                translatedTitle = cleanedTitle.count <= max(120, title.count * 4) ? cleanedTitle : title
                translatedBody = b
                    .components(separatedBy: "\n\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                isTranslated = true
            } catch {
                // Apple Intelligence unavailable mid-flight — fall back.
                isShowingTranslation = true
            }
        }
    }

}

/// Passively observes the native reader's EXISTING UIScrollView pan recognizer.
/// Adding a target does not participate in gesture arbitration, so UIKit remains
/// free to give a horizontal drag to NavigationStack's interactive pop gesture.
/// The observer reports only completed, clearly vertical reading scrolls.
private struct ReaderScrollPanObserver: UIViewRepresentable {
    var enabled: Bool
    var onQualifiedScroll: (ReaderControlSide) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(enabled: enabled, onQualifiedScroll: onQualifiedScroll)
    }

    func makeUIView(context: Context) -> UIView {
        let marker = UIView(frame: .zero)
        marker.backgroundColor = .clear
        marker.isUserInteractionEnabled = false
        return marker
    }

    func updateUIView(_ marker: UIView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.onQualifiedScroll = onQualifiedScroll
        context.coordinator.isActive = true

        if enabled {
            context.coordinator.scheduleAttachment(from: marker)
        } else {
            context.coordinator.detach()
        }
    }

    static func dismantleUIView(_ marker: UIView, coordinator: Coordinator) {
        coordinator.isActive = false
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        var enabled: Bool
        var onQualifiedScroll: (ReaderControlSide) -> Void
        var isActive = true

        private weak var scrollView: UIScrollView?
        private var beganOnSide: ReaderControlSide?
        private var attachmentScheduled = false

        init(
            enabled: Bool,
            onQualifiedScroll: @escaping (ReaderControlSide) -> Void
        ) {
            self.enabled = enabled
            self.onQualifiedScroll = onQualifiedScroll
        }

        /// SwiftUI can update the representable before it has joined the UIKit
        /// hierarchy. Retry across a few run-loop turns; once attached, later
        /// updates are constant-time.
        func scheduleAttachment(from marker: UIView, attemptsRemaining: Int = 4) {
            guard isActive, enabled, scrollView == nil, !attachmentScheduled else { return }
            attachmentScheduled = true
            DispatchQueue.main.async { [weak self, weak marker] in
                guard let self else { return }
                self.attachmentScheduled = false
                guard self.isActive, self.enabled, let marker else { return }
                if !self.attachIfPossible(from: marker), attemptsRemaining > 1 {
                    self.scheduleAttachment(
                        from: marker,
                        attemptsRemaining: attemptsRemaining - 1
                    )
                }
            }
        }

        @discardableResult
        private func attachIfPossible(from marker: UIView) -> Bool {
            var ancestor = marker.superview
            while let current = ancestor, !(current is UIScrollView) {
                ancestor = current.superview
            }
            guard let resolved = ancestor as? UIScrollView else { return false }

            scrollView = resolved
            resolved.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
            return true
        }

        func detach() {
            scrollView?.panGestureRecognizer.removeTarget(
                self,
                action: #selector(handlePan(_:))
            )
            scrollView = nil
            beganOnSide = nil
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard enabled, let scrollView else {
                beganOnSide = nil
                return
            }

            switch gesture.state {
            case .began:
                let width = scrollView.bounds.width
                guard width > 0 else {
                    beganOnSide = nil
                    return
                }
                let xRatio = gesture.location(in: scrollView).x / width
                if xRatio <= 0.42 {
                    beganOnSide = .left
                } else if xRatio >= 0.58 {
                    beganOnSide = .right
                } else {
                    // The middle band is deliberately weak evidence of either
                    // hand, so it never moves the controls.
                    beganOnSide = nil
                }

            case .ended:
                defer { beganOnSide = nil }
                guard let beganOnSide else { return }
                let movement = gesture.translation(in: scrollView)
                guard abs(movement.y) >= 44,
                      abs(movement.y) > abs(movement.x) * 1.35 else { return }
                onQualifiedScroll(beganOnSide)

            case .cancelled, .failed:
                // Interactive pop normally causes the scroll pan to fail/cancel.
                // Such a horizontal navigation gesture is never adaptation data.
                beganOnSide = nil

            default:
                break
            }
        }
    }
}

/// Restores the navigation stack's left-edge swipe-to-go-back while a pushed
/// screen hides its back button. SwiftUI (via UIKit) disables the
/// `interactivePopGestureRecognizer` when there's no visible back button, so the
/// reader's immersive mode — which hides the button — would otherwise lose the
/// edge swipe. This installs a permissive gesture delegate that allows the pop
/// whenever the stack has something to pop back to, and restores the original
/// delegate when it goes away.
private struct InteractivePopGestureEnabler: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        // Defer so the view is in the hierarchy and `navigationController` resolves.
        DispatchQueue.main.async {
            guard let gesture = controller.navigationController?.interactivePopGestureRecognizer else { return }
            context.coordinator.navigationController = controller.navigationController
            if context.coordinator.originalDelegate == nil, gesture.delegate !== context.coordinator {
                context.coordinator.originalDelegate = gesture.delegate
            }
            gesture.delegate = context.coordinator
            gesture.isEnabled = true
        }
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        if let gesture = coordinator.navigationController?.interactivePopGestureRecognizer,
           gesture.delegate === coordinator {
            gesture.delegate = coordinator.originalDelegate
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var navigationController: UINavigationController?
        weak var originalDelegate: UIGestureRecognizerDelegate?

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // Only pop when there's a screen to go back to (never at the root).
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}

/// Article metadata, mirroring the macOS inspector: status, published date,
/// reading time, read/starred toggles, and the source feed.
struct ArticleInfoView: View {
    @Bindable var store: ReaderStore
    let article: Article

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Article") {
                    LabeledContent("Status", value: article.isRead ? String(localized: "Read") : String(localized: "Unread"))
                    LabeledContent("Published", value: article.publishedAt.localized(date: .abbreviated, time: .shortened))
                    LabeledContent("Reading Time", value: String(localized: "\(article.estimatedReadMinutes) min"))
                    Toggle("Starred", isOn: store.starredBinding(articleID: article.id))
                    Toggle("Read", isOn: store.readBinding(articleID: article.id))
                }

                if let feed = store.feed(for: article.feedID) {
                    Section("Source") {
                        LabeledContent("Feed", value: feed.displayTitle)
                        if !feed.category.isEmpty {
                            LabeledContent("Category", value: feed.category)
                        }
                        LabeledContent(
                            "Last Refresh",
                            value: feed.lastFetchedAt?.localized(date: .abbreviated, time: .shortened) ?? String(localized: "Never")
                        )
                        Link("Open Site", destination: feed.siteURL)
                        Link("Open Feed", destination: feed.feedURL)
                    }
                }

                Section {
                    Link("Open Article", destination: article.url)
                }
            }
            .navigationTitle("Article Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// The in-app browser sheet: the shared `ArticleWebView` with a toolbar to
/// switch reader/original, open in the system browser, and share.
struct InAppBrowserSheet: View {
    @Bindable var store: ReaderStore
    let article: Article
    let style: ReaderStyle
    let linkOpensInApp: Bool

    @Environment(\.dismiss) private var dismiss
    @AppStorage("markReadOnOpen") private var markReadOnOpen = true
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system
    @State private var isTranslationOn = false
    @State private var translationInFlight = false
    @State private var loadingProgress: Double = 0
    /// Only for the parser switch's selection click. The re-render is instant, so
    /// without it the tap is the one control here with no response at all.
    @State private var haptics = ReaderHaptics()
    @State private var bottomPull: CGFloat = 0
    /// The page's live URL (following redirects / navigation), handed to Safari.
    @State private var currentWebURL: URL?
    /// When set, present the page in Safari (shares the system session, so
    /// logins and passkeys work); nil dismisses.
    @State private var safariURL: URL?

    /// Web-view translation uses Apple Intelligence; offer it only when that's
    /// available and the article's language differs from the app's.
    private var canTranslate: Bool {
        guard NaturalTranslator.isAvailable(for: TranslationSettings.readerProvider()),
              let detected = ReaderDetailView.detectLanguage(for: article),
              let target = targetLanguage.languageCode?.identifier else { return false }
        let detectedBase = Locale.Language(identifier: detected).languageCode?.identifier ?? detected
        return detectedBase != target
    }

    private var targetLanguage: Locale.Language {
        let locale = appLanguage == .system ? Locale.current : appLanguage.locale
        return locale.language
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

    /// A short bottom pull-up opens the next article; a longer one closes the
    /// browser; anything less snaps back.
    private func handleBottomRelease(_ amount: CGFloat) {
        if amount >= BottomPullAffordance.closeThreshold {
            dismiss()
        } else if amount >= BottomPullAffordance.nextThreshold {
            store.selectNextArticle()
            bottomPull = 0
        } else {
            withAnimation(.easeOut(duration: 0.2)) { bottomPull = 0 }
        }
    }

    var body: some View {
        NavigationStack {
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
                onBottomOverscroll: { bottomPull = $0 },
                onBottomOverscrollEnded: handleBottomRelease,
                onURLChange: { currentWebURL = $0 },
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
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) {
                WebLoadingBar(progress: loadingProgress)
            }
            .overlay(alignment: .bottom) {
                BottomPullAffordance(pull: bottomPull, nextTitle: store.article(after: article.id)?.title)
            }
            .overlay(alignment: .top) {
                if translationInFlight {
                    TranslationProgressBanner()
                }
            }
            .animation(.easeInOut(duration: 0.2), value: translationInFlight)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    if store.browserMode == .reader {
                        // Tap switches reader/original, as it always has; long-press
                        // chooses the parser. The principal slot holds one item and
                        // the trailing group is already three controls.
                        Menu {
                            ReaderParserMenuItems(
                                store: store, article: article, surface: .browser,
                                onChange: { haptics.selectionChanged() })
                        } label: {
                            Label("Reader", systemImage: "doc.plaintext")
                        } primaryAction: {
                            store.toggleBrowserMode()
                        }
                        .accessibilityLabel(Text("Reader Mode"))
                        .accessibilityValue(Text(store.browserParser(for: article).label))
                    } else {
                        // A plain button on the original page: no parser runs there,
                        // so a menu would have nothing in it and long-pressing would
                        // present an empty container.
                        Button {
                            store.toggleBrowserMode()
                        } label: {
                            Label("Original", systemImage: "globe")
                        }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if canTranslate {
                        Button {
                            isTranslationOn.toggle()
                        } label: {
                            Image(systemName: isTranslationOn ? "character.bubble.fill" : "character.bubble")
                        }
                    }
                    Button {
                        // Open the CURRENT page in Safari (in-app) — it shares the
                        // system session, so logins and passkeys, which an embedded
                        // WKWebView can't do for arbitrary sites, work there.
                        let target = currentWebURL ?? article.url
                        safariURL = ["http", "https"].contains(target.scheme?.lowercased() ?? "") ? target : article.url
                    } label: {
                        Image(systemName: "safari")
                    }
                    .accessibilityLabel(Text("Open in Safari"))
                    ShareLink(item: article.url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .fullScreenCover(isPresented: Binding(get: { safariURL != nil }, set: { if !$0 { safariURL = nil } })) {
            if let safariURL {
                SafariView(url: safariURL).ignoresSafeArea()
            }
        }
        .task(id: article.id) {
            store.retainArticle(id: article.id)
            if markReadOnOpen {
                store.markArticleOpened(articleID: article.id)
            }
        }
    }
}

/// Presents a page in `SFSafariViewController` — a real Safari surface that runs
/// in its own process with the user's Safari session, so logins and passkeys
/// (which an embedded WKWebView can't do for arbitrary sites) work. Shown in-app
/// as a full-screen cover; its session doesn't flow back into our WKWebView.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Applies the press-and-hold-to-open-browser gesture only when the opt-in
/// setting is enabled; otherwise the body carries no long-press gesture.
private struct LongPressToOpenBrowser: ViewModifier {
    let enabled: Bool
    let minimumDuration: Double
    let onOpen: () -> Void
    let onPressingChanged: (Bool) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onLongPressGesture(
                minimumDuration: minimumDuration,
                maximumDistance: 10,
                perform: onOpen,
                onPressingChanged: onPressingChanged
            )
        } else {
            content
        }
    }
}

/// A small "translating" banner shown while the model works, so a slow
/// translation reads as in-progress rather than stuck.
struct TranslationProgressBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            if TranslationSettings.readerProvider() == .gemini {
                Text("Translating with Gemini…").font(.subheadline)
            } else {
                Text("Translating with Apple Intelligence…").font(.subheadline)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .padding(.top, 10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
