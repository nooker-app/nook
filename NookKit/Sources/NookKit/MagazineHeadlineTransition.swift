#if os(macOS)
import SwiftUI

/// The approved title ripple: 0.55 seconds, with the demo's vivid (1.5) strength.
/// Only a new completed translation animates. Cached text starts at its final
/// layout, and leaving the viewport or turning translation off settles at once.
/// Summary replacements reserve three lines to keep the card/footer stationary.
struct MagazineHeadlineTransition: View {
    enum Style { case headline, summary }
    let title: String
    let size: CGFloat
    let lines: Int?
    let animated: Bool
    let style: Style
    @State private var current: String
    @State private var previous: String?
    @State private var progress = 1.0
    @State private var width: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: String, size: CGFloat, lines: Int?, animated: Bool, style: Style = .headline) {
        self.title = title
        self.size = size
        self.lines = lines
        self.animated = animated
        self.style = style
        _current = State(initialValue: title)
    }

    private struct Update: Equatable {
        let title: String
        let animated: Bool
        let reduceMotion: Bool
    }

    var body: some View {
        Group {
            if let previous {
                MagazineHeadlineTransitionLayout(progress: reduceMotion ? 1 : progress) {
                    layer(previous, incoming: false)
                    layer(current, incoming: true)
                }
                // Allow the glow to extend past the glyphs, while a longer
                // translation reveals into its growing space above the summary.
                .padding(8).clipped().padding(-8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(current)
            } else {
                if style == .summary { summaryText(current) }
                else { MagazineHeadline(current, size: size, lines: lines) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: Update(title: title, animated: animated, reduceMotion: reduceMotion)) {
            guard title != current, animated else {
                settle()
                return
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                previous = current
                current = title
                progress = 0
            }
            do {
                // Give both text layouts one frame before advancing the renderer.
                try await Task.sleep(for: .milliseconds(16))
                let duration = reduceMotion ? 0.15 : 0.55
                withAnimation(.linear(duration: duration)) { progress = 1 }
                try await Task.sleep(for: .seconds(duration))
                settle()
            } catch { /* A newer title or visibility change owns the next state. */ }
        }
        .onDisappear { settle() }
    }

    private func layer(_ value: String, incoming: Bool) -> some View {
        // Share the normal headline's exact type metrics. Do not wrap this in
        // MagazineHeadline: its hero-transition transaction disables animation.
        Group {
            if style == .summary { summaryText(value) }
            else {
                MagazineHeadline.text(value, size: size)
                    .lineSpacing(size * 0.12)
                    .lineLimit(lines)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
            .textRenderer(MagazineTitleRipple(progress: progress, incoming: incoming,
                                              sweepWidth: width, reduceMotion: reduceMotion))
    }

    private func summaryText(_ value: String) -> some View {
        // reservesSpace omits spacing for missing lines and measures Latin/CJK
        // fallbacks differently. A real three-line font sample fixes both cases.
        Text("Ag한\nAg한\nAg한")
            .font(.system(size: size)).lineSpacing(5)
            .hidden().accessibilityHidden(true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) {
                Text(value)
                    .font(.system(size: size)).lineSpacing(5)
                    .lineLimit(3).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
    }

    private func settle() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            current = title
            previous = nil
            progress = 1
        }
    }
}

/// Measure both endpoints at the same width. Only the container height changes;
/// the text never rewraps through intermediate widths or gains/loses an ellipsis.
struct MagazineHeadlineTransitionLayout: Layout {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposal = ProposedViewSize(width: proposal.width, height: nil)
        let sizes = subviews.map { $0.sizeThatFits(proposal) }
        guard let first = sizes.first, let last = sizes.last else { return .zero }
        let fraction = min(1, max(0, progress))
        return CGSize(width: proposal.width ?? sizes.map(\.width).max() ?? 0,
                      height: first.height + (last.height - first.height) * fraction)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

struct MagazineTitleRipple: TextRenderer {
    var progress: Double
    let incoming: Bool
    var sweepWidth: CGFloat = 0
    var reduceMotion = false
    private let strength = 1.5
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    var displayPadding: EdgeInsets { EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        if progress <= 0 || progress >= 1 || reduceMotion {
            context.opacity *= incoming ? min(1, max(0, progress)) : 1 - min(1, max(0, progress))
            for line in layout { context.draw(line) }
            return
        }
        let bounds = layout.reduce(CGRect.null) { $0.union($1.typographicBounds.rect) }
        let origin = CGPoint(x: bounds.minX - 18, y: bounds.minY + 18)
        // Both languages use one wavefront even when their glyph widths differ.
        // Independent sweeps would draw the new words on top of lingering ones.
        let extent = max(sweepWidth, bounds.width) + 118
        let front = -50 + progress * extent
        for line in layout {
            for run in line {
                for slice in run {
                    let rect = slice.typographicBounds.rect
                    let dx = rect.midX - origin.x
                    let dy = (rect.midY - origin.y) * 0.7
                    let distance = hypot(dx, dy)
                    let delta = distance - front
                    let band = exp(-pow(delta / 34, 2))
                    let fraction = min(1, max(0, (front - distance + 23) / 46))
                    let blend = fraction * fraction * (3 - 2 * fraction)
                    var copy = context
                    copy.opacity *= incoming ? blend : 1 - blend
                    let wave = sin(delta / 13) * band * 3.8 * strength
                    copy.translateBy(x: wave * dx / max(distance, 1), y: wave * dy / max(distance, 1))
                    copy.addFilter(.blur(radius: band * 1.1 * strength))
                    copy.addFilter(.shadow(color: NookTheme.accent.opacity(band * 0.8),
                                          radius: band * 4.5 * strength))
                    copy.draw(slice)
                }
            }
        }
    }
}
#endif
