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
    var deck = StackDeck()
}

struct StackProvider: TimelineProvider {
    func placeholder(in context: Context) -> StackEntry {
        StackEntry(date: .now, expanded: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (StackEntry) -> Void) {
        let now = Date.now
        guard let start = UserDefaults.standard.object(forKey: startKey(context)) as? Date else {
            completion(placeholder(in: context))
            return
        }
        let current = sequence(start: start, family: context.family).last(where: { $0.date <= now })
            ?? placeholder(in: context)
        completion(StackEntry(date: now, expanded: true, deck: current.deck))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StackEntry>) -> Void) {
        let now = Date.now
        // Static widgets share their timeline by kind/family. Remember the demo
        // start in this extension's sandbox, not the production app or vault.
        // A reload or process restart must never fold already displayed stories.
        let key = startKey(context)
        let start: Date
        if let saved = UserDefaults.standard.object(forKey: key) as? Date {
            start = saved
        } else {
            start = now
            UserDefaults.standard.set(start, forKey: key)
        }
        let steps = sequence(start: start, family: context.family)
        let current = steps.last(where: { $0.date <= now }) ?? steps[0]
        let entries = [StackEntry(date: now, expanded: current.expanded, deck: current.deck)]
            + steps.filter { $0.date > now }
        completion(Timeline(entries: entries, policy: .never))
    }

    private func startKey(_ context: Context) -> String {
        "stacked-story-sequence-start-v1.\(context.family.rawValue)"
    }

    private func sequence(start: Date, family: WidgetFamily) -> [StackEntry] {
        let count = family == .systemSmall ? 1 : family == .systemLarge ? 4 : 2
        var firstUpdate = StackDeck()
        firstUpdate.replaceStory(at: min(1, count - 1))
        var secondUpdate = firstUpdate
        secondUpdate.replaceStory(at: count - 1)
        return [
            StackEntry(date: start, expanded: false),
            StackEntry(date: start.addingTimeInterval(3), expanded: true),
            StackEntry(date: start.addingTimeInterval(12), expanded: true, deck: firstUpdate),
            StackEntry(date: start.addingTimeInterval(21), expanded: true, deck: secondUpdate),
        ]
    }
}

struct StackWidgetContent: View {
    let entry: StackEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        StackedGlassContent(size: family == .systemSmall ? .small : family == .systemLarge ? .large : .medium,
                            deck: entry.deck, expanded: entry.expanded, widgetSurface: true)
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

struct FramedGlassWidget: Widget {
    let design: FrameDesign

    init() { design = .tray }
    init(design: FrameDesign) { self.design = design }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: design.kind, provider: StackProvider()) { entry in
            FramedWidgetContent(design: design, entry: entry)
        }
        .configurationDisplayName(design.code + " · " + design.title)
        .description(design.subtitle)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
        .nookHostBackground()
    }
}

struct FramedWidgetContent: View {
    let design: FrameDesign
    let entry: StackEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        FramedGlassContent(design: design,
                           size: family == .systemSmall ? .small : family == .systemLarge ? .large : .medium,
                           deck: entry.deck, expanded: entry.expanded)
            .containerBackground(for: .widget) { Color.clear }
            .widgetURL(URL(string: "nookglasslab://stack"))
    }
}

@main
struct GlassLabWidgets: WidgetBundle {
    var body: some Widget {
        PublicMaterialWidget()
        PrivateBlurWidget()
        PrivateTransparentWidget()
        StackedGlassWidget()
        FramedGlassWidget(design: .tray)
        FramedGlassWidget(design: .folio)
        FramedGlassWidget(design: .shelf)
    }
}
