import SwiftUI
import WidgetKit

// This file belongs to the "NookWidget" widget-extension target.
// Setup in Xcode:
//   • Add this file and Nook/WidgetShared.swift to the NookWidget target.
// No App Group is required: this is a quick-access launcher. Each shortcut
// deep-links into the app via the nook:// URL scheme, launching or
// activating Nook and focusing the chosen smart source.

struct NookEntry: TimelineEntry {
    let date: Date
}

struct NookProvider: TimelineProvider {
    func placeholder(in context: Context) -> NookEntry { NookEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (NookEntry) -> Void) {
        completion(NookEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NookEntry>) -> Void) {
        completion(Timeline(entries: [NookEntry(date: .now)], policy: .never))
    }
}

// The @main WidgetBundle lives in the Xcode-generated NookWidgetBundle.swift,
// which references NookWidget().
struct NookWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShared.widgetKind, provider: NookProvider()) { _ in
            NookWidgetView()
                .containerBackground(.background, for: .widget)
                .widgetURL(WidgetShared.openAppURL)
        }
        .configurationDisplayName("Nook")
        .description("Quick access to your reader.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct NookWidgetView: View {
    @Environment(\.widgetFamily) private var family

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "books.vertical.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                Text("Nook")
                    .font(.headline)
                Spacer(minLength: 0)
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(WidgetSource.allCases) { source in
                    Link(destination: WidgetShared.sourceURL(source)) {
                        shortcut(source)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func shortcut(_ source: WidgetSource) -> some View {
        HStack(spacing: 6) {
            Image(systemName: source.systemImage)
                .font(.callout)
                .foregroundStyle(.tint)
                .frame(width: 18)
            Text(source.title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

// MARK: - Today News Widget

struct TodayNewsEntry: TimelineEntry {
    let date: Date
    let articles: [TodayNewsItem]   // current page of 8
    let pageIndex: Int               // which page (0-based) for footer display
    let totalCount: Int              // total articles across all pages
    var isPlaceholder: Bool = false
}

struct TodayNewsProvider: TimelineProvider {
    /// How many articles to show per page — reduced to fit larger font
    static let pageSize = 5
    /// Rotate every 60 seconds
    static let rotateInterval: TimeInterval = 60

    func placeholder(in context: Context) -> TodayNewsEntry {
        TodayNewsEntry(date: .now, articles: Self.placeholderItems,
                       pageIndex: 0, totalCount: Self.placeholderItems.count, isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayNewsEntry) -> Void) {
        let all = WidgetShared.readTodayNews()
        let items = context.isPreview && all.isEmpty ? Self.placeholderItems : all
        let page = items.isEmpty ? [] : Array(items.prefix(Self.pageSize))
        completion(TodayNewsEntry(date: .now, articles: page,
                                  pageIndex: 0, totalCount: items.count))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayNewsEntry>) -> Void) {
        let all = WidgetShared.readTodayNews()
        guard !all.isEmpty else {
            // No articles: single entry, refresh at midnight
            let midnight = Calendar.current.startOfDay(for: Date().addingTimeInterval(24 * 60 * 60))
            let entry = TodayNewsEntry(date: .now, articles: [],
                                       pageIndex: 0, totalCount: 0)
            completion(Timeline(entries: [entry], policy: .after(midnight)))
            return
        }

        // Build one entry per page, each 60 seconds apart
        let now = Date()
        let pageCount = Int(ceil(Double(all.count) / Double(Self.pageSize)))
        var entries: [TodayNewsEntry] = []
        for i in 0..<pageCount {
            let start = i * Self.pageSize
            let end   = min(start + Self.pageSize, all.count)
            let page  = Array(all[start..<end])
            let entryDate = now.addingTimeInterval(Double(i) * Self.rotateInterval)
            entries.append(TodayNewsEntry(date: entryDate, articles: page,
                                          pageIndex: i, totalCount: all.count))
        }

        // After all pages shown, refresh again (cycle through at the same pace)
        let refreshDate = now.addingTimeInterval(Double(pageCount) * Self.rotateInterval)
        completion(Timeline(entries: entries, policy: .after(refreshDate)))
    }

    private static let placeholderItems: [TodayNewsItem] = (1...5).map { i in
        TodayNewsItem(
            id: "\(i)",
            title: "今日新闻标题示例将显示在这里 \(i)",
            url: URL(string: "https://example.com")!,
            feedTitle: "订阅源名称",
            publishedAt: .now
        )
    }
}

struct TodayNewsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: WidgetShared.todayNewsWidgetKind,
            provider: TodayNewsProvider()
        ) { entry in
            TodayNewsWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("今日新闻")
        .description("一览今天收到的文章标题。")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct TodayNewsWidgetView: View {
    let entry: TodayNewsEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 6)
            if entry.articles.isEmpty {
                emptyState
            } else {
                articleList
            }
            Spacer(minLength: 0)
            footer
        }
        // No widgetURL: each Link() opens the article URL directly in the browser
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "newspaper.fill")
                .font(.footnote)
                .foregroundStyle(.tint)
            Text("今日新闻")
                .font(.headline)
            Spacer(minLength: 0)
            if !entry.articles.isEmpty {
                Text("\(entry.articles.count)条")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        Text("今天暂无新文章。")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var articleList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entry.articles) { item in
                Link(destination: item.url) {
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill(.tint.opacity(0.7))
                            .frame(width: 5, height: 5)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.callout)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(entry.isPlaceholder ? .secondary : .primary)
                            Text(item.feedTitle)
                                .font(.footnote)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)

                if item.id != entry.articles.last?.id {
                    Divider().opacity(0.3)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Image(systemName: "books.vertical.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("Nook")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if entry.totalCount > TodayNewsProvider.pageSize {
                let pages = Int(ceil(Double(entry.totalCount) / Double(TodayNewsProvider.pageSize)))
                Text("\(entry.pageIndex + 1)/\(pages)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Text(entry.date, style: .time)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }
}
