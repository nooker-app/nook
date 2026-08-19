import SwiftUI

/// The parser choices for one article, as menu items.
///
/// Shared by every surface that offers the switch — the native reader's header on
/// macOS, its overflow menu on iOS, and the in-app browser's chrome on both — so
/// the wording is written once and the check-mark always means the same thing.
///
/// Two direct items rather than a nested `Picker`. A picker earns its extra level
/// with three or more options; for a choice between two it added a submenu whose
/// title repeated its parent's and a third tap that decided nothing. Each item
/// names its engine and says in one line what that engine is for, which is the
/// information the reader needs and the one thing a bare "Legibility /
/// Readability" pair cannot convey.
public struct ReaderParserMenuItems: View {
    /// Which reader is asking. The two surfaces cost different things to re-parse,
    /// so they do different work.
    public enum Surface: Sendable {
        /// The native reader. Re-extracts the article, serving this session's copy
        /// when the engine has already run on it.
        case nativeReader
        /// The in-app browser, which keeps its own copy of the page and re-renders
        /// from it. Nothing is downloaded and the native reader's body is left
        /// alone — running its full re-extraction as a side effect would fetch the
        /// article a second time for a surface that already has it.
        case browser
    }

    private let store: ReaderStore
    private let article: Article
    private let surface: Surface
    private let onChange: (() -> Void)?

    /// `onChange` fires when a different parser is picked, for a platform that wants
    /// to say so — iOS plays a selection haptic, since the new body takes a moment
    /// to arrive and a tap with no response reads as a tap that missed.
    public init(
        store: ReaderStore,
        article: Article,
        surface: Surface = .nativeReader,
        onChange: (() -> Void)? = nil
    ) {
        self.store = store
        self.article = article
        self.surface = surface
        self.onChange = onChange
    }

    private var current: ReaderParserEngine {
        switch surface {
        case .nativeReader: store.displayedReaderParser(for: article)
        case .browser: store.browserParser(for: article)
        }
    }

    private func choose(_ engine: ReaderParserEngine) {
        guard current != engine else { return }
        onChange?()
        switch surface {
        case .nativeReader: store.setReaderParser(engine, for: article)
        case .browser: store.setBrowserParser(engine, for: article)
        }
    }

    public var body: some View {
        ForEach(ReaderParserEngine.allCases) { engine in
            Button {
                choose(engine)
            } label: {
                // A menu item's label takes its parts positionally: the first `Text`
                // is the title, the second is the subtitle, and an `Image` is the
                // icon. Wrapping them in a `VStack` would draw them as one stacked
                // title instead, so they stay loose here on purpose.
                Text(engine.label)
                Text(engine.summary)
                if engine == current {
                    // The checkmark idiom the app already uses for the chosen item in
                    // a menu (see the per-feed reading-view menu).
                    Image(systemName: "checkmark")
                }
            }
        }
    }
}

/// Shown while an article is being re-read with the other parser.
///
/// The body stays on screen underneath: the header and the article share one scroll
/// view, so swapping a full article for a spinner collapses the content height and
/// throws the reader back to the top of something they were halfway through. This is
/// the whole feedback for the wait, so it names the parser it is waiting for.
public struct ReaderReparsingBanner: View {
    private let engine: ReaderParserEngine

    public init(engine: ReaderParserEngine) {
        self.engine = engine
    }

    public var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                #if os(macOS)
                .controlSize(.small)
                #endif
            Text("Re-reading with \(engine.label)…", bundle: .module)
                .font(.subheadline)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Shown in the reader when the parser on screen discarded media the page carried.
///
/// legibility's sanitizer drops `<iframe>`, `<video>` and `<audio>` outright, so a
/// post that *is* a video came out as a caption over a blank space with nothing
/// saying anything had been removed. Readability keeps the allowlisted embeds, and
/// this is the row that says so and offers to switch.
public struct ReaderDroppedEmbedsNotice: View {
    private let count: Int
    private let onUseReadability: () -> Void

    public init(count: Int, onUseReadability: @escaping () -> Void) {
        self.count = count
        self.onUseReadability = onUseReadability
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "play.rectangle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            // Two plain sentences rather than one inflected key: automatic grammar
            // agreement would need plural variations in a catalog whose other three
            // languages have no plural forms at all.
            (count == 1
                ? Text("An embedded video isn't shown here.", bundle: .module)
                : Text("\(count) embedded videos aren't shown here.", bundle: .module))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(action: onUseReadability) {
                Text("Read with \(ReaderParserEngine.readability.label)", bundle: .module)
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
