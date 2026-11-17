#if os(macOS)
import SwiftUI

public struct MagazinePreviewSettings: View {
    private let preferences = ArticlePreviewPreferences.shared
    let feeds: [Feed]
    @State private var selectedFeed: Feed.ID?

    public init(feeds: [Feed]) { self.feeds = feeds }

    public var body: some View {
        Section {
            Toggle(isOn: binding(nil, \.enabled)) {
                Text("Prepare visible articles", bundle: .module)
            }
            limits(nil)
                .disabled(!preferences.standard.enabled)
        } header: {
            Text("Magazine previews", bundle: .module)
        } footer: {
            Text("Fetch originals and thumbnails only for visible cards. Cached on this Mac for up to 7 days, within 250 MB. Page and image requests share the same budget.", bundle: .module)
        }

        if !feeds.isEmpty {
            Section {
                Picker(selection: $selectedFeed) {
                    Text("Choose a feed", bundle: .module).tag(Feed.ID?.none)
                    ForEach(feeds.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }) { feed in
                        Text(feed.displayTitle).tag(Optional(feed.id))
                    }
                } label: { Text("Feed", bundle: .module) }
                if let id = selectedFeed, feeds.contains(where: { $0.id == id }) {
                    Toggle(isOn: Binding(get: { preferences.override(for: id) != nil }, set: {
                        preferences.setOverride($0 ? preferences.standard : nil, for: id)
                    })) { Text("Custom preview limits", bundle: .module) }
                    if preferences.override(for: id) != nil {
                        Toggle(isOn: binding(id, \.enabled)) { Text("Prepare articles from this feed", bundle: .module) }
                        limits(id).disabled(!(preferences.override(for: id)?.enabled ?? true))
                    }
                }
            } header: {
                Text("Per-feed limits", bundle: .module)
            } footer: {
                Text("At most 2 requests at once, and 1 per feed or server. Feeds sharing a server also share a ceiling of 30 requests per minute and a 1-second minimum interval. Server cooldowns take priority over these settings.", bundle: .module)
            }
            .disabled(!preferences.standard.enabled)
        }
    }

    @ViewBuilder private func limits(_ id: Feed.ID?) -> some View {
        Stepper(value: binding(id, \.interval), in: 1...120, step: 1) {
            Text("Request interval: \(Int(value(id).interval)) seconds", bundle: .module)
        }
        Stepper(value: binding(id, \.requestsPerMinute), in: 1...30) {
            Text("Up to \(value(id).requestsPerMinute) requests per minute", bundle: .module)
        }
    }

    private func value(_ id: Feed.ID?) -> ArticlePreviewPolicy {
        id.flatMap { preferences.override(for: $0) } ?? preferences.standard
    }

    private func binding<T>(_ id: Feed.ID?, _ key: WritableKeyPath<ArticlePreviewPolicy, T>) -> Binding<T> {
        Binding(get: { value(id)[keyPath: key] }, set: { newValue in
            var policy = value(id)
            policy[keyPath: key] = newValue
            if let id { preferences.setOverride(policy, for: id) }
            else { preferences.setStandard(policy) }
        })
    }
}
#endif
