import NookKit
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Device-local flags for the first-run tutorial. Kept in the view layer (not
/// ReaderStore) per the project's state split, and never synced — completing the
/// tour is per-install UI state.
enum TourFlags {
    static let hasCompletedWelcomeKey = "hasCompletedWelcome"
    static let seenReaderGestureHintKey = "seenReaderGestureHint"
    static let seenListHintKey = "seenListTapHint"
}

/// In-memory coordinator that lets the welcome cover drive the live app: after
/// the tour adds starter sites, nudge the user to open their first story.
/// View-layer only (never persisted or synced), shared via `.environment`.
@MainActor
@Observable
final class TourCoordinator {
    /// The tutorial finished adding sites: the shell switches to Home, and Home
    /// spotlights the list once it's on screen with articles. Kept as a standing
    /// request (not an edge) so it survives the tab switch and is consumed by Home
    /// itself when it appears — no cross-view onChange race.
    var pendingFirstStoryHint = false
    /// True from the moment the list spotlight is requested until it's dismissed.
    /// The article list mounts its first-row frame publisher (a per-scroll-frame
    /// GeometryReader preference) only while this is set, so steady-state
    /// scrolling never pays for the tutorial.
    var listHintActive = false
}

// MARK: - Starter picks (locale-aware)

/// A curated interest bundle the tour offers as a one-tap subscribe. Bundles
/// differ by the user's language: Korean-language users get Korean-first
/// sources; everyone else gets the English set. Every URL was verified to
/// serve a live feed at authoring time.
struct StarterPick: Identifiable, Hashable {
    let id: String
    /// Display title — already in the set's language, so not re-localized.
    let title: String
    let symbol: String
    let feedURLs: [String]

    /// The set for the current language.
    static var current: [StarterPick] {
        Locale.current.language.languageCode?.identifier == "ko" ? korean : english
    }

    // Deliberately tech/science-only: starter bundles must be socially and
    // politically neutral, so no news or current-affairs sources.
    static let korean: [StarterPick] = [
        StarterPick(id: "ko-dev", title: "IT·개발", symbol: "chevron.left.forwardslash.chevron.right", feedURLs: [
            "https://news.hada.io/rss/news",
        ]),
        StarterPick(id: "ko-techblog", title: "기술 블로그", symbol: "text.rectangle.page", feedURLs: [
            "https://techblog.woowahan.com/feed/",
            "https://tech.kakao.com/feed/",
        ]),
        StarterPick(id: "tech-news", title: "테크 뉴스", symbol: "cpu", feedURLs: [
            "https://www.theverge.com/rss/index.xml",
        ]),
        StarterPick(id: "science", title: "과학·우주", symbol: "atom", feedURLs: [
            "https://www.quantamagazine.org/feed/",
            "https://www.nasa.gov/rss/dyn/breaking_news.rss",
        ]),
        StarterPick(id: "hn", title: "개발자 커뮤니티", symbol: "person.2", feedURLs: [
            "https://news.ycombinator.com/rss",
        ]),
    ]

    static let english: [StarterPick] = [
        StarterPick(id: "tech", title: "Tech", symbol: "cpu", feedURLs: [
            "https://www.theverge.com/rss/index.xml",
            "https://feeds.arstechnica.com/arstechnica/index",
        ]),
        StarterPick(id: "dev", title: "Developers", symbol: "chevron.left.forwardslash.chevron.right", feedURLs: [
            "https://news.ycombinator.com/rss",
            "https://daringfireball.net/feeds/main",
        ]),
        StarterPick(id: "science", title: "Science & Space", symbol: "atom", feedURLs: [
            "https://www.quantamagazine.org/feed/",
            "https://www.nasa.gov/rss/dyn/breaking_news.rss",
        ]),
    ]
}

// MARK: - Welcome tour

/// The first-run welcome tour, rebuilt for people who have never heard of RSS:
/// one page says what the app does in plain words, one page picks starter
/// interests and subscribes with a single tap. No folder step (the library
/// starts locally), no URL copying, no jargon. Skippable at any moment and
/// replayable from Settings; reading gestures are taught later, in context.
struct WelcomeSheet: View {
    @Bindable var store: ReaderStore
    /// Called when the tour is finished or skipped; the caller records completion
    /// and dismisses.
    var onFinish: () -> Void

    @Environment(TourCoordinator.self) private var tour

    private enum Page: Hashable { case welcome, starter }

    @State private var page: Page = .welcome

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color("ListBackground").ignoresSafeArea()

            TabView(selection: $page) {
                TourPage(
                    illustration: AnyView(NestInboxIllustration()),
                    title: "Your favorite sites, one quiet place",
                    message: "Follow the sites you love, and their new posts gather here automatically — no accounts, no algorithm, just your reading. Don't know where to start? We'll suggest some next.",
                    primaryTitle: "Continue",
                    onPrimary: { withAnimation { page = .starter } }
                )
                .tag(Page.welcome)

                StarterPicksPage(store: store, onStart: startReading)
                    .tag(Page.starter)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button(action: onFinish) {
                Text("Skip")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(.trailing, 20)
            .padding(.top, 12)
            .accessibilityLabel(Text("Skip tutorial"))
        }
        .tint(Color("AccentColor"))
    }

    /// Subscribes the chosen bundles and hands off to the list spotlight. The
    /// adds are best-effort (a single unreachable source must not interrupt
    /// the tour with an error alert); at least one succeeding is enough to
    /// land the user on a filling Home list.
    private func startReading() {
        tour.pendingFirstStoryHint = true
        onFinish()
    }
}

/// The starter-picks page: interest chips (multi-select, one-tap subscribe),
/// an optional on-device title-translation toggle, and a direct "follow by
/// address" escape hatch for people who already know what they want to read.
private struct StarterPicksPage: View {
    @Bindable var store: ReaderStore
    var onStart: () -> Void

    @State private var selectedPicks: Set<String> = []
    @State private var isAddingSite = false
    @State private var addedManually = false
    @State private var isSubscribing = false
    @State private var translateTitles = true

    @AppStorage(ReaderStore.translateListTitlesKey) private var translateListTitles = false
    @AppStorage(ReaderStore.translateTitlesPromoSeenKey) private var hasSeenTranslatePromo = false

    private let picks = StarterPick.current
    private var canStart: Bool { !selectedPicks.isEmpty || addedManually }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 44)

            VStack(spacing: 8) {
                Text("What do you like to read?")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("Pick a few to start — you can follow any site later.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(picks) { pick in
                    StarterPickChip(pick: pick, selected: selectedPicks.contains(pick.id)) {
                        if selectedPicks.contains(pick.id) {
                            selectedPicks.remove(pick.id)
                        } else {
                            selectedPicks.insert(pick.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .sensoryFeedback(.selection, trigger: selectedPicks)

            // On-device title translation, offered right where foreign-language
            // sources may have just been picked — the "wow" lands on the very
            // first Home list instead of a next-launch promo sheet.
            if NaturalTranslator.isAvailable {
                Toggle(isOn: $translateTitles) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show titles in your language")
                            .font(.subheadline.weight(.medium))
                        Text("Translated on this device. Change anytime in Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 32)
            }

            Button {
                Task { await subscribeAndStart() }
            } label: {
                if isSubscribing {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 14)
                } else {
                    Text("Start Reading")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 44)
            .disabled(!canStart || isSubscribing)

            Button {
                isAddingSite = true
            } label: {
                Text("Or follow a site by its address")
                    .font(.subheadline)
            }

            Spacer()
            Spacer()
        }
        .padding(.bottom, 44)
        .sheet(isPresented: $isAddingSite) {
            AddFeedView(folders: store.feedFolders) { feedURL, folder in
                try await store.addFeed(urlString: feedURL, toFolder: folder)
                addedManually = true
            }
        }
    }

    private func subscribeAndStart() async {
        isSubscribing = true
        defer { isSubscribing = false }
        if NaturalTranslator.isAvailable {
            // Recording the promo as seen keeps the next-launch sheet away
            // whether the toggle was left on or turned off.
            translateListTitles = translateTitles
            hasSeenTranslatePromo = true
        }
        let urls = picks.filter { selectedPicks.contains($0.id) }.flatMap(\.feedURLs)
        for url in urls {
            // Best-effort: one dead source must not derail the whole tour.
            try? await store.addFeed(urlString: url)
        }
        // Adding leaves the last feed selected; clear so the spotlight targets
        // the user's own first tap.
        store.selectedArticleID = nil
        onStart()
    }
}

private struct StarterPickChip: View {
    let pick: StarterPick
    let selected: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : pick.symbol)
                    .font(.subheadline)
                    .contentTransition(.symbolEffect(.replace))
                Text(pick.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1.5)
            )
            .foregroundStyle(selected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The starter-picks page presentable on its own — the Feeds tab's empty state
/// offers it to anyone who skipped the tour.
struct StarterPicksSheet: View {
    @Bindable var store: ReaderStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            StarterPicksPage(store: store, onStart: { dismiss() })
                .background(Color("ListBackground").ignoresSafeArea())
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .tint(Color("AccentColor"))
    }
}

/// One tour page: a looping illustration, a title, a short message, and an
/// optional primary button.
private struct TourPage: View {
    let illustration: AnyView
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var primaryTitle: LocalizedStringKey? = nil
    var onPrimary: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack { illustration }
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(.horizontal, 32)

            VStack(spacing: 10) {
                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)

            if let primaryTitle, let onPrimary {
                Button(action: onPrimary) {
                    Text(primaryTitle)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 44)
                .padding(.top, 2)
            }

            Spacer()
            Spacer()
        }
        .padding(.bottom, 44)
    }
}

// MARK: - Illustrations

/// A tiny stand-in article row used across tutorial illustrations and loading
/// skeletons: two text bars on a card.
struct MiniArticleCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.5)).frame(width: 74, height: 7)
            RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.22)).frame(width: 52, height: 6)
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }
}

/// The value-proposition scene: article cards drift down into the nest, one
/// after another, then settle — "new posts gather here" said without words.
private struct NestInboxIllustration: View {
    var body: some View {
        ZStack {
            NestAssemblyView(size: 120, assembled: true)
                .offset(y: 44)
            PhaseAnimator([0, 1, 2, 3]) { phase in
                ZStack {
                    ForEach(0..<3, id: \.self) { index in
                        MiniArticleCard()
                            .scaleEffect(0.9)
                            .offset(
                                x: CGFloat(index - 1) * 52,
                                y: phase > index ? 26 : -104
                            )
                            .opacity(phase > index ? (phase == 3 ? 0 : 0.95) : 0)
                    }
                }
                .animation(.spring(response: 0.55, dampingFraction: 0.7), value: phase)
            } animation: { _ in
                .easeInOut(duration: 0.85)
            }
        }
    }
}
