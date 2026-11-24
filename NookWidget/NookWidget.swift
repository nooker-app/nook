import SwiftUI
import WidgetKit
import Darwin
import os

struct NookEntry: TimelineEntry {
    let date: Date
    let snapshot: NookWidgetSnapshot
    var isPlaceholder = false
}

struct NookProvider: TimelineProvider {
    func placeholder(in context: Context) -> NookEntry {
        retireReplacedExecutable()
        return NookEntry(date: .now, snapshot: .preview, isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (NookEntry) -> Void) {
        retireReplacedExecutable()
        completion(NookEntry(date: .now, snapshot: context.isPreview ? .preview : load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NookEntry>) -> Void) {
        retireReplacedExecutable()
        completion(Timeline(entries: [NookEntry(date: .now, snapshot: load())],
                            policy: .after(Date.now.addingTimeInterval(15 * 60))))
    }

    private func load() -> NookWidgetSnapshot {
        NookWidgetStorage.read(from: NookWidgetStorage.fileURL) ?? NookWidgetSnapshot()
    }

    private func retireReplacedExecutable() {
        // chronod restarts this read-only extension. Do not signal another
        // process, reset WidgetKit's database, or touch the library/container.
        guard Bundle.main.bundleIdentifier == "com.tim.nook.NookWidget" else { return }
        if NookWidgetRuntime.executableWasReplaced() {
            Logger(subsystem: "com.tim.nook", category: "widgets")
                .notice("Installed widget executable changed; restarting the extension")
            exit(EXIT_SUCCESS)
        }
    }
}

/// Keep the existing kind so installed launcher widgets survive the update.
struct NookWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShared.widgetKind, provider: NookProvider()) { entry in
            NookShortcutsView(snapshot: entry.snapshot)
                .containerBackground(for: .widget) { NookWidgetBackground() }
                .widgetURL(WidgetShared.sourceURL(.unread))
        }
        .configurationDisplayName("Reading shortcuts")
        .description("Your unread count and a shortcut to every collection.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct NookLatestWidget: Widget {
    var body: some WidgetConfiguration { NookReadingConfiguration(collection: .latest).body }
}

struct NookRecommendedWidget: Widget {
    var body: some WidgetConfiguration { NookReadingConfiguration(collection: .recommended).body }
}

struct NookRecentlyReadWidget: Widget {
    var body: some WidgetConfiguration { NookReadingConfiguration(collection: .recent).body }
}

@MainActor
private struct NookReadingConfiguration {
    let collection: NookWidgetCollection

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: collection.kind, provider: NookProvider()) { entry in
            NookReadingWidgetView(entry: entry, collection: collection)
                .containerBackground(for: .widget) { NookWidgetBackground() }
        }
        .configurationDisplayName(collection.title)
        .description(collection.detail)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

extension NookWidgetCollection {
    var title: String {
        switch self {
        case .latest: String(localized: "Latest stories")
        case .recommended: String(localized: "For you")
        case .recent: String(localized: "Recently Read")
        }
    }

    var detail: String {
        switch self {
        case .latest: String(localized: "New stories from your feeds. Open any story straight in Nook.")
        case .recommended: String(localized: "Unread stories picked for your interests, using Nook’s local recommendations.")
        case .recent: String(localized: "Return to the stories you recently opened.")
        }
    }

    var icon: String {
        switch self {
        case .latest: "newspaper"
        case .recommended: "bookmark"
        case .recent: "clock.arrow.circlepath"
        }
    }

    var emptyTitle: String {
        switch self {
        case .latest: String(localized: "A new perspective awaits")
        case .recommended: String(localized: "You're all caught up")
        case .recent: String(localized: "Pick up where you left off")
        }
    }

    var emptyDetail: String {
        switch self {
        case .latest: String(localized: "Add a feed in Nook to see its latest stories here.")
        case .recommended: String(localized: "Your next unread discoveries will appear here.")
        case .recent: String(localized: "Stories you open in Nook will be waiting here.")
        }
    }

    var sourceURL: URL {
        WidgetShared.sourceURL(self == .recent ? .recent : self == .recommended ? .unread : .all)
    }
}

struct NookWidgetBackground: View {
    var body: some View {
        // No opaque brand plate: full-color widgets use native glass too.
        // In Clear/Tinted mode WidgetKit replaces this removable background
        // with its own system material and recolors the content groups.
        Color.clear
            .glassEffect(.regular.tint(NookWidgetStyle.accent.opacity(0.035)), in: ContainerRelativeShape())
    }
}

enum NookWidgetStyle {
    static let accent = Color(red: 0.83, green: 0.64, blue: 0.39)

    static func headlineDesign(_ text: String) -> Font.Design {
        text.unicodeScalars.contains {
            (0x2E80...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value)
        } ? .default : .serif
    }
}

struct NookReadingWidgetView: View {
    let entry: NookEntry
    let collection: NookWidgetCollection
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        NookReadingWidgetContent(entry: entry, collection: collection, family: family, renderingMode: renderingMode)
    }
}

struct NookReadingWidgetContent: View {
    let entry: NookEntry
    let collection: NookWidgetCollection
    let family: WidgetFamily
    let renderingMode: WidgetRenderingMode

    private var stories: [NookWidgetStory] { entry.snapshot.stories(for: collection) }
    private var isSmall: Bool { family == .systemSmall }
    private var count: Int { family == .systemLarge ? 4 : isSmall ? 1 : 2 }

    private func url(_ story: NookWidgetStory) -> URL {
        guard let libraryID = entry.snapshot.libraryID else { return WidgetShared.openAppURL }
        return NookReaderLink.url(libraryID: libraryID, articleID: story.id, recommendation: collection == .recommended)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 8) {
            header
            if stories.isEmpty {
                empty
            } else if isSmall, let first = stories.first {
                story(first, prominent: true)
                Spacer(minLength: 0)
                HStack {
                    Text(first.publishedAt, format: .dateTime.month(.abbreviated).day())
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(Array(stories.prefix(count).enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Rectangle().fill(.primary.opacity(0.09)).frame(height: 0.5) }
                    Link(destination: url(item)) {
                        story(item, prominent: family == .systemLarge && index == 0)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(item.title + ", " + item.source))
                    .accessibilityHint(Text("Open in Nook reader"))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .redacted(reason: entry.isPlaceholder ? .placeholder : [])
        .widgetURL(isSmall ? stories.first.map(url) ?? collection.sourceURL : collection.sourceURL)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: collection.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(renderingMode == .fullColor ? NookWidgetStyle.accent : .primary)
                .widgetAccentable()
            Text(collection.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 2)
            if !isSmall {
                Text("Nook").font(.system(size: 14, weight: .semibold, design: .serif))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func story(_ item: NookWidgetStory, prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: prominent ? 7 : 5) {
            Text(item.title)
                .font(.system(size: prominent ? (isSmall ? 17 : 21) : 14,
                              weight: .semibold, design: prominent ? NookWidgetStyle.headlineDesign(item.title) : .default))
                .lineLimit(isSmall ? 3 : 2)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
            HStack(spacing: 5) {
                if item.isUnread {
                    Circle().fill(renderingMode == .fullColor ? NookWidgetStyle.accent : .primary)
                        .frame(width: 4, height: 4).widgetAccentable()
                }
                Text(item.source).lineLimit(1)
                if !isSmall {
                    Spacer(minLength: 4)
                    Text(item.publishedAt, format: .dateTime.month(.abbreviated).day()).lineLimit(1)
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .medium))
                }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private var empty: some View {
        let title = entry.snapshot.libraryID == nil ? String(localized: "Make room for a good read") : collection.emptyTitle
        return VStack(alignment: .leading, spacing: 8) {
            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: isSmall ? 17 : 20, weight: .semibold, design: NookWidgetStyle.headlineDesign(title)))
                .lineLimit(3)
            Text(entry.snapshot.libraryID == nil ? String(localized: "Open Nook to connect your library.") : collection.emptyDetail)
                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            Spacer(minLength: 0)
            Label("Open Nook", systemImage: "arrow.up.right").font(.caption.weight(.medium))
                .foregroundStyle(renderingMode == .fullColor ? NookWidgetStyle.accent : .primary)
                .widgetAccentable()
        }
    }
}

struct NookShortcutsView: View {
    let snapshot: NookWidgetSnapshot
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        NookShortcutsContent(snapshot: snapshot, family: family, renderingMode: renderingMode)
    }
}

struct NookShortcutsContent: View {
    let snapshot: NookWidgetSnapshot
    let family: WidgetFamily
    let renderingMode: WidgetRenderingMode

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nook").font(.system(size: 20, weight: .semibold, design: .serif))
                Spacer(minLength: 8)
                Text(snapshot.unreadCount, format: .number)
                    .font(.system(size: 40, weight: .light, design: .rounded)).minimumScaleFactor(0.65)
                    .foregroundStyle(renderingMode == .fullColor ? NookWidgetStyle.accent : .primary)
                    .widgetAccentable()
                Text("Unread stories").font(.caption).foregroundStyle(.secondary)
            }
            if family != .systemSmall {
                VStack(spacing: 7) {
                    ForEach([WidgetSource.today, .starred, .recent], id: \.self) { source in
                        Link(destination: WidgetShared.sourceURL(source)) {
                            HStack(spacing: 7) {
                                Image(systemName: source.systemImage).frame(width: 15).widgetAccentable()
                                Text(LocalizedStringKey(source.title)).lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                            }
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(.primary.opacity(0.045), in: Capsule())
                            .overlay(Capsule().strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

extension NookWidgetSnapshot {
    /// Widget gallery and redacted placeholders only. Timelines always use disk.
    static var preview: Self {
        let titles = [String(localized: "Small discoveries, new perspectives"),
                      String(localized: "A quieter way to keep up with the world"),
                      String(localized: "The ideas worth coming back to"),
                      String(localized: "What will you read next?")]
        let rows = titles.enumerated().map { index, title in
            NookWidgetStory(id: "preview-\(index)", title: title, source: "Nook Journal",
                            publishedAt: .now.addingTimeInterval(-Double(index) * 3600), isUnread: true)
        }
        return Self(unreadCount: 24, latest: rows, recommended: rows, recent: rows)
    }
}

#Preview(as: .systemSmall) {
    NookRecommendedWidget()
} timeline: {
    NookEntry(date: .now, snapshot: .preview)
}

#Preview(as: .systemMedium) {
    NookLatestWidget()
} timeline: {
    NookEntry(date: .now, snapshot: .preview)
}

#Preview(as: .systemLarge) {
    NookRecentlyReadWidget()
} timeline: {
    NookEntry(date: .now, snapshot: .preview)
}
