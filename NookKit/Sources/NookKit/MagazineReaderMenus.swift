#if os(macOS)
import SwiftUI

public struct MagazineCategoryMenu: View {
    private let store: ReaderStore
    private let article: Article

    public init(store: ReaderStore, article: Article) {
        self.store = store
        self.article = article
    }

    public var body: some View {
        MagazineMorphingMenu(
            String(localized: "Categories", bundle: .module), systemImage: "tag",
            height: min(352, max(180, CGFloat(store.categories.count) * 42 + 124))
        ) { dismiss in
            CategoryChoices(store: store, article: article, dismiss: dismiss)
        }
    }

    private struct CategoryChoices: View {
        let store: ReaderStore
        let article: Article
        let dismiss: MagazineMenuDismissAction
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let assigned = Set(store.article(withID: article.id)?.categories ?? article.categories)
            VStack(alignment: .leading, spacing: 4) {
                if store.categories.isEmpty {
                    Text("No categories yet. Add some in Settings › Article Rules.", bundle: .module)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10).padding(.bottom, 12)
                } else {
                    Text("Choose topics for this article.", bundle: .module)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.bottom, 8)
                    ForEach(store.categories) { category in
                        Button {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                                store.toggleCategory(category.id, forArticle: article.id)
                            }
                        } label: {
                            MagazineMenuRowLabel(
                                category.name.isEmpty ? String(localized: "Untitled", bundle: .module) : category.name,
                                systemImage: "tag", selected: assigned.contains(category.id)
                            )
                        }
                        .buttonStyle(MagazinePlainButtonStyle())
                    }
                }
                HStack {
                    if !store.categories.isEmpty {
                        Text("You can choose more than one.", bundle: .module)
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button { dismiss() } label: { Text("Done", bundle: .module) }
                        .buttonStyle(MagazineGlassButtonStyle())
                }.padding(.horizontal, 10).padding(.top, 12)
            }.padding(.horizontal, 12)
        }
    }
}

public struct MagazineParserMenu: View {
    private let store: ReaderStore
    private let article: Article

    public init(store: ReaderStore, article: Article) {
        self.store = store
        self.article = article
    }

    public var body: some View {
        MagazineMorphingMenu(
            String(localized: "Parser", bundle: .module), systemImage: "text.viewfinder", width: 352, height: 254
        ) { dismiss in
            ParserChoices(store: store, article: article, dismiss: dismiss)
        }
    }

    private struct ParserChoices: View {
        let store: ReaderStore
        let article: Article
        let dismiss: MagazineMenuDismissAction

        var body: some View {
            let current = store.displayedReaderParser(for: article)
            VStack(alignment: .leading, spacing: 9) {
                Text("Choose how to read this page.", bundle: .module)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 5)
                ForEach(ReaderParserEngine.allCases) { engine in
                    Button {
                        if engine != current { store.setReaderParser(engine, for: article) }
                        dismiss(after: .milliseconds(250))
                    } label: {
                        MagazineMenuRowLabel(
                            engine.label, subtitle: engine.summary,
                            systemImage: engine == .legibility ? "doc.text.magnifyingglass" : "text.alignleft",
                            selected: engine == current
                        )
                    }
                    .buttonStyle(MagazinePlainButtonStyle())
                }
            }.padding(.horizontal, 12)
        }
    }
}
#endif
