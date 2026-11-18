#if os(macOS)
import SwiftUI

/// Translates the existing RSS excerpt, never the full article or a new AI summary.
/// Sharing the title coordinator preserves its provider, cache, dwell, scrolling
/// pause and concurrency limit instead of starting a second set of requests.
public struct MagazineTranslatedSummary: View {
    private let source: String
    private let id: String
    private let size: CGFloat
    private let translator: ListTitleTranslator
    private let box: ListTitleTranslator.StateBox
    @State private var registeredID: String?
    @AppStorage(ReaderStore.translateListTitlesKey) private var enabled = false
    @Environment(\.magazinePreviewVisible) private var visible

    public init(id: Article.ID, summary: String, size: CGFloat,
                translator: ListTitleTranslator = .shared) {
        source = summary
        self.id = Self.translationID(articleID: id, summary: summary)
        self.size = size
        self.translator = translator
        box = translator.box(for: self.id, title: summary)
    }

    public var body: some View {
        let displayed = Self.displayText(original: source, translation: box.completedText, enabled: enabled)
        Group {
            if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MagazineHeadlineTransition(title: displayed, size: size, lines: 3,
                                           animated: visible && enabled && displayed != source, style: .summary)
                    .help(source)
            }
        }
        .onChange(of: visible && enabled ? id : nil, initial: true) { _, wanted in
            guard wanted != registeredID else { return }
            unregister()
            if let wanted, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                registeredID = wanted
                translator.rowAppeared(id: wanted, title: source)
            }
        }
        .onDisappear { unregister() }
    }

    static func translationID(articleID: Article.ID, summary: String) -> String {
        "magazine-summary|\(articleID)|\(summary)"
    }

    static func displayText(original: String, translation: String?, enabled: Bool) -> String {
        guard enabled, let translation, !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return original }
        return translation
    }

    private func unregister() {
        guard let registeredID else { return }
        translator.rowDisappeared(id: registeredID)
        self.registeredID = nil
    }
}
#endif
