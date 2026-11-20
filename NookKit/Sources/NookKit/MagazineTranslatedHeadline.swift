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
        // This surface replaces completed titles. Provider token snapshots must
        // not invalidate its layout while it still displays the original.
        let displayed = Self.displayTitle(original: title, translation: box.completedText, enabled: enabled)
        MagazineHeadlineTransition(title: displayed, size: size, lines: lines,
                                   animated: visible && enabled && displayed != title)
            .help(title)
            .onChange(of: visible && enabled, initial: true) { _, wanted in
                if wanted && !registered {
                    registered = true
                    translator.rowAppeared(id: id, title: title)
                } else if !wanted { unregister() }
            }
            .onDisappear { unregister() }
    }

    static func displayTitle(original: String, translation: String?, enabled: Bool) -> String {
        guard enabled, let translation,
              !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return original }
        return translation
    }

    private func unregister() {
        guard registered else { return }
        registered = false
        translator.rowDisappeared(id: id)
    }
}
#endif
