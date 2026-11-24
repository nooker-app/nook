import SwiftUI
import WidgetKit

// Isolated experiment only. The private declarations live in a temporary SDK
// overlay created by build.py, never in the Nook app or its widget target.
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
                .containerBackground(for: .widget) { NookWidgetBackground() }
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
        .preferredBackgroundStyle(.blur)
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

@main
struct GlassLabWidgets: WidgetBundle {
    var body: some Widget {
        PublicMaterialWidget()
        PrivateBlurWidget()
        PrivateTransparentWidget()
    }
}
