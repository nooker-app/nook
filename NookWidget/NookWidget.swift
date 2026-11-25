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
        .nookHostBackground()
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
        .contentMarginsDisabled()
        .nookHostBackground()
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
        if NookWidgetHostBackground.isAvailable {
            // The host provides blur and tint. A material inside this container
            // would restore the dark plate over that translucent background.
            Color.clear
        } else {
            ContainerRelativeShape().fill(.ultraThinMaterial)
        }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stories: [NookWidgetStory] { entry.snapshot.stories(for: collection) }
    private var isSmall: Bool { family == .systemSmall }
    private var count: Int { family == .systemLarge ? 4 : isSmall ? 1 : 2 }
    private var accent: Color { renderingMode == .fullColor ? NookWidgetStyle.accent : .primary }

    private func url(_ story: NookWidgetStory) -> URL {
        guard let libraryID = entry.snapshot.libraryID else { return WidgetShared.openAppURL }
        return NookReaderLink.url(libraryID: libraryID, articleID: story.id, recommendation: collection == .recommended)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 8) {
            header.frame(height: isSmall ? 18 : 22)
            if stories.isEmpty {
                empty
            } else {
                shelf
                    // Never animate a story from one library into another.
                    .id(entry.snapshot.libraryID)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, isSmall ? 12 : 14)
        .padding(.vertical, family == .systemLarge ? 14 : 12)
        .redacted(reason: entry.isPlaceholder ? .placeholder : [])
        .widgetURL(isSmall ? stories.first.map(url) ?? collection.sourceURL : collection.sourceURL)
    }

    private var shelf: some View {
        GeometryReader { geometry in
            let height = max(0, (geometry.size.height - 10) / CGFloat(count))
            let lastOrigin = CGFloat(count - 1) * height
            // The snapshot already contains up to six actual stories. Keep
            // two waiting candidates in the same identity domain as the rows;
            // an existing candidate can move into its new slot on an update.
            ZStack(alignment: .top) {
                ForEach(Array(stories.prefix(count + 2).enumerated()), id: \.element.id) { index, item in
                    let waiting = index >= count
                    let depth = max(0, index - count)
                    let origin = waiting ? lastOrigin + CGFloat(depth + 1) * 5 : CGFloat(index) * height
                    Group {
                        if isSmall {
                            shelfRow(item, index: index, waiting: waiting, height: height)
                        } else {
                            Link(destination: url(item)) {
                                shelfRow(item, index: index, waiting: waiting, height: height)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(item.title + ", " + item.source))
                            .accessibilityHint(Text("Open in Nook reader"))
                        }
                    }
                    .padding(.horizontal, waiting ? CGFloat(depth + 1) * 6 : 0)
                    .scaleEffect(waiting ? 0.97 - CGFloat(depth) * 0.025 : 1, anchor: .top)
                    .offset(y: origin)
                    .opacity(waiting ? (depth == 0 ? 0.55 : 0.28) : 1)
                    .zIndex(waiting ? -Double(depth + 1) : Double(count - index))
                    .transition(reduceMotion ? .identity : .asymmetric(
                        insertion: .offset(y: max(0, lastOrigin - origin) + 5).combined(with: .opacity),
                        removal: .opacity))
                    .disabled(waiting || entry.isPlaceholder)
                    .allowsHitTesting(!waiting && !entry.isPlaceholder)
                    .accessibilityHidden(waiting)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(reduceMotion ? nil : .smooth(duration: 0.55), value: stories.map(\.id))
            .clipped()
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(includeBrand: true)
            headerRow(includeBrand: false)
        }
    }

    private func headerRow(includeBrand: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: collection.icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(accent)
                .widgetAccentable()
            Text(collection.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                .fixedSize(horizontal: includeBrand, vertical: false)
            Spacer(minLength: 2)
            if includeBrand {
                Text("Nook").font(.system(size: isSmall ? 13 : 15, weight: .bold, design: .serif))
                    .foregroundStyle(.secondary).fixedSize()
            }
        }
    }

    private func shelfRow(_ item: NookWidgetStory, index: Int, waiting: Bool, height: CGFloat) -> some View {
        HStack(spacing: 9) {
            if !isSmall {
                Text(String(format: "%02d", index + 1))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(accent.opacity(0.8)).widgetAccentable()
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: isSmall ? 7 : family == .systemMedium ? 3 : 4) {
                HStack(spacing: 4) {
                    if item.isUnread {
                        Circle().fill(accent).frame(width: 3, height: 3).widgetAccentable()
                    }
                    Text(item.source).lineLimit(1)
                    Spacer(minLength: 2)
                    if !isSmall {
                        Text(item.publishedAt, format: .dateTime.month(.abbreviated).day()).fixedSize()
                    }
                }
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                Text(item.title)
                    .font(.system(size: isSmall ? 17 : family == .systemMedium ? 12 : 13, weight: .semibold))
                    .lineLimit(isSmall ? 3 : 2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isSmall {
                    HStack {
                        Text(item.publishedAt, format: .dateTime.month(.abbreviated).day()).lineLimit(1)
                        Spacer(minLength: 2)
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                }
            }
        }
        .opacity(waiting ? 0 : 1)
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .overlay(alignment: .bottom) {
            Rectangle().fill(waiting ? accent.opacity(0.24) : .primary.opacity(0.12))
                .frame(height: 0.5).padding(.horizontal, 3)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var empty: some View {
        let title = entry.snapshot.libraryID == nil ? String(localized: "Make room for a good read") : collection.emptyTitle
        return VStack(alignment: .leading, spacing: isSmall ? 6 : 8) {
            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: isSmall ? 15 : 20, weight: .semibold, design: NookWidgetStyle.headlineDesign(title)))
                .lineLimit(isSmall ? 2 : 3)
                .minimumScaleFactor(0.9)
            Text(entry.snapshot.libraryID == nil ? String(localized: "Open Nook to connect your library.") : collection.emptyDetail)
                .font(.system(size: isSmall ? 11 : 12)).foregroundStyle(.secondary).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
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
