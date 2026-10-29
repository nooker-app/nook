import SwiftUI

/// Shared macOS/iOS presentation for a translated article-list title. Keeping the
/// observation and styling in one leaf view ensures a progress snapshot
/// invalidates only this row, and both platforms follow the same reveal contract.
public struct ListTitleTranslationBlock: View {
    private let title: String
    private let box: ListTitleTranslator.StateBox
    private let translator: ListTitleTranslator
    private let opensInsertedHeight: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        title: String,
        box: ListTitleTranslator.StateBox,
        translator: ListTitleTranslator = .shared,
        opensInsertedHeight: Bool = false
    ) {
        self.title = title
        self.box = box
        self.translator = translator
        self.opensInsertedHeight = opensInsertedHeight
    }

    public var body: some View {
        let presentation = resolvedPresentation
        let text = presentation?.text ?? ""
        let streaming = presentation?.streaming ?? false
        let provider = presentation?.provider ?? .appleIntelligence
        let usesGemini = provider == .gemini

        HStack(alignment: .top, spacing: 5) {
            Image(systemName: usesGemini ? "sparkles" : "apple.intelligence")
                .symbolEffect(
                    .pulse,
                    options: .repeating,
                    isActive: streaming && !reduceMotion
                )
                .accessibilityLabel(
                    Text(
                        String(
                            localized: usesGemini
                                ? "Translated by Gemini"
                                : "Translated by Apple Intelligence",
                            bundle: .main
                        )
                    )
                )

            if text.isEmpty {
                Text(String(localized: "Translating…", bundle: .main))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(text)
                    .fontWeight(.medium)
                    .lineLimit(2)
            }
        }
        .font(.callout)
        .foregroundStyle(Color.accentColor)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.accentColor.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .padding(.top, 4)
        // Text snapshots must not implicitly animate their intrinsic size. The
        // outer reveal owns the single intentional row expansion.
        .transaction { transaction in
            transaction.animation = nil
        }
        .expandReveal(
            isVisible: presentation != nil,
            animateAppearance: streaming && !reduceMotion,
            opensInsertedHeight: opensInsertedHeight
        )
    }

    private var resolvedPresentation: (
        text: String,
        streaming: Bool,
        provider: TranslationProvider
    )? {
        switch translator.state(for: box, title: title) {
        case .translating(let partial, let provider):
            return (partial, true, provider)
        case .translated(let final, let provider):
            return (final, false, provider)
        case nil:
            return nil
        }
    }
}

/// The macOS list row's translation slot: nothing until the row's title has a
/// translation to show, then the shared block.
///
/// Every row used to build the whole block — symbol effect, two localized
/// lookups, background shape, reveal layout and its three `@State`s — although
/// almost every row never shows one (translation off, or not yet dwelled on).
/// The slot reads the row's own box, so the block appears when the box first gets
/// a state, and stays once it has had one so a hide still collapses smoothly.
/// Inserted while streaming, it takes its full height at once and fades in; the
/// state change that inserts it also advances `layoutRevision`, which the row
/// root hands to the native row-height invalidator.
public struct ListTitleTranslationSlot: View {
    private let title: String
    private let box: ListTitleTranslator.StateBox
    private let translator: ListTitleTranslator

    public init(title: String, box: ListTitleTranslator.StateBox, translator: ListTitleTranslator = .shared) {
        self.title = title
        self.box = box
        self.translator = translator
    }

    public var body: some View {
        if box.layoutRevision > 0 || translator.state(for: box, title: title) != nil {
            ListTitleTranslationBlock(title: title, box: box, translator: translator, opensInsertedHeight: true)
        }
    }
}
