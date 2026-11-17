#if os(macOS)
import SwiftUI

/// Uses the same opt-in, provider and per-language cache as the Classic list.
/// Keep the original readable while tokens arrive; publish only a final title.
public struct MagazineTranslatedHeadline: View {
    private let title: String
    private let id: String
    private let size: CGFloat
    private let lines: Int?
    private let translator: ListTitleTranslator
    private let box: ListTitleTranslator.StateBox
    @State private var registered = false
    @AppStorage(ReaderStore.translateListTitlesKey) private var enabled = false
    @Environment(\.magazinePreviewVisible) private var visible

    public init(id: Article.ID, title: String, size: CGFloat, lines: Int? = 3,
                translator: ListTitleTranslator = .shared) {
        self.title = title
        // An edited post must not inherit its previous headline's live box.
        self.id = "magazine|\(id)|\(title)"
        self.size = size
        self.lines = lines
        self.translator = translator
        box = translator.box(for: self.id, title: title)
    }

    public var body: some View {
        MagazineHeadline(Self.displayTitle(original: title, state: box.state, enabled: enabled), size: size, lines: lines)
            .help(title)
            .onChange(of: visible && enabled, initial: true) { _, wanted in
                if wanted && !registered {
                    registered = true
                    translator.rowAppeared(id: id, title: title)
                } else if !wanted { unregister() }
            }
            .onDisappear { unregister() }
    }

    static func displayTitle(original: String, state: ListTitleTranslator.TitleState?, enabled: Bool) -> String {
        guard enabled, case .translated(let text, _) = state,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return original }
        return text
    }

    private func unregister() {
        guard registered else { return }
        registered = false
        translator.rowDisappeared(id: id)
    }
}
#endif
