import SwiftUI
import WidgetKit

// Isolated comparison app; B exercises the same optional host bridge as Nook.
struct LabProvider: TimelineProvider {
    func placeholder(in context: Context) -> NookEntry {
        NookEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (NookEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NookEntry>) -> Void) {
        completion(Timeline(entries: [placeholder(in: context)], policy: .never))
    }
}

struct LabContent: View {
    let entry: NookEntry
    let label: String
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NookReadingWidgetContent(entry: entry, collection: .latest,
                                     family: family, renderingMode: renderingMode)
            Text(label + " · " + renderingMode.description)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .widgetURL(URL(string: "nookglasslab://open"))
    }
}

struct PublicMaterialWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GlassLabPublic", provider: LabProvider()) { entry in
            LabContent(entry: entry, label: "A · PUBLIC MATERIAL")
                .containerBackground(for: .widget) {
                    ContainerRelativeShape().fill(.ultraThinMaterial)
                }
        }
        .configurationDisplayName("A · Public Material")
        .description("Control: Nook's current public SwiftUI material background.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct PrivateBlurWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GlassLabBlur", provider: LabProvider()) { entry in
            LabContent(entry: entry, label: "B · HOME BLUR")
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("B · Home Blur")
        .description("Experiment: request the host blur background used by Home.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .nookHostBackground()
    }
}

struct PrivateTransparentWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GlassLabTransparent", provider: LabProvider()) { entry in
            LabContent(entry: entry, label: "C · TRANSPARENT")
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("C · Transparent")
        .description("Experiment: request a transparent host background.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .preferredBackgroundStyle(.transparent)
    }
}

struct StackEntry: TimelineEntry {
    let date: Date
    let expanded: Bool
}

struct StackProvider: TimelineProvider {
    func placeholder(in context: Context) -> StackEntry {
        StackEntry(date: .now, expanded: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (StackEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StackEntry>) -> Void) {
        let now = Date.now
        // One finite demonstration, not a polling loop. WidgetKit owns timing;
        // opening Notification Center does not re-run a widget's onAppear.
        completion(Timeline(entries: [
            StackEntry(date: now, expanded: false),
            StackEntry(date: now.addingTimeInterval(3), expanded: true),
        ], policy: .never))
    }
}

struct StackWidgetContent: View {
    let entry: StackEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        StackedGlassContent(size: family == .systemSmall ? .small : family == .systemLarge ? .large : .medium,
                            expanded: entry.expanded, widgetSurface: true)
            .containerBackground(for: .widget) { Color.clear }
            .widgetURL(URL(string: "nookglasslab://stack"))
    }
}

struct StackedGlassWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GlassLabStacked", provider: StackProvider()) { entry in
            StackWidgetContent(entry: entry)
        }
        .configurationDisplayName("D · Stacked Glass")
        .description("Transparent host with one, two or four individual glass story capsules. Experimental.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
        .preferredBackgroundStyle(.transparent)
        .backgroundStyle(.transparent)
    }
}

@main
struct GlassLabWidgets: WidgetBundle {
    var body: some Widget {
        PublicMaterialWidget()
        PrivateBlurWidget()
        PrivateTransparentWidget()
        StackedGlassWidget()
    }
}
