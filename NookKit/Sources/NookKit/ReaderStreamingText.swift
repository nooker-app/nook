#if os(macOS)
import SwiftUI
import QuartzCore

/// Arrival timestamps belong to graphemes, not snapshots. Another snapshot
/// never restarts the animation of text that was already on screen.
struct TranslationArrivalHistory {
    private(set) var characters: [Character] = []
    private(set) var starts: [Double] = []
    private(set) var firstArrival: Double?

    mutating func update(_ value: String, at now: Double) {
        let next = Array(value)
        var prefix = 0
        while prefix < min(next.count, characters.count), next[prefix] == characters[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(next.count, characters.count) - prefix,
              next[next.count - suffix - 1] == characters[characters.count - suffix - 1] { suffix += 1 }
        let count = next.count - prefix - suffix
        var dates = Array(starts.prefix(prefix))
        // A burst can delay its final glyph by at most 120ms. Later snapshots
        // share that horizon instead of adding another animation to a queue.
        let start = max(now, dates.last ?? now)
        let spread = min(0.12, Double(count) * 0.004, max(0, now + 0.12 - start))
        for index in 0..<count {
            dates.append(start + spread * Double(index) / Double(max(1, count - 1)))
        }
        dates.append(contentsOf: starts.suffix(suffix))
        characters = next
        starts = dates
        if !next.isEmpty, firstArrival == nil { firstArrival = now }
    }

    var lastArrival: Double { starts.max() ?? 0 }

    struct RenderSpan: Equatable {
        let range: Range<Int>
        let animated: Bool
    }

    /// Settled glyphs share a native text run, including the suffix following a
    /// corrected word. Only arriving glyphs and the unfinished edge stay split.
    func renderSpans(at now: Double, writing: Bool, duration: Double) -> [RenderSpan] {
        let last = characters.lastIndex(where: { !$0.isWhitespace }) ?? -1
        var spans: [RenderSpan] = []
        var start = 0
        for index in starts.indices {
            let tail = writing && index <= last && index > last - 6
            guard now < starts[index] + duration || tail else { continue }
            if start < index { spans.append(.init(range: start..<index, animated: false)) }
            spans.append(.init(range: index..<(index + 1), animated: true))
            start = index + 1
        }
        if start < starts.count { spans.append(.init(range: start..<starts.count, animated: false)) }
        return spans
    }
}

private struct ArrivalStamp: TextAttribute { let start: Double; let index: Int }
/// Warm refraction applied to new glyphs in reading order. The reader preview
/// defaults to the selected 0.45s duration and minimum 0.3 entrance strength.
private struct StreamRippleRenderer: TextRenderer {
    let now: Double
    let duration: Double
    let strength: Double
    let reduceMotion: Bool
    let writing: Bool
    let lastIndex: Int
    let lastArrival: Double
    var displayPadding: EdgeInsets { .init(top: 10, leading: 10, bottom: 10, trailing: 10) }

    let accent: Color.Resolved

    private func smooth(_ value: Double) -> Double {
        let x = min(1, max(0, value))
        return x * x * (3 - 2 * x)
    }

    private var inkMatrix: ColorMatrix {
        var matrix = ColorMatrix()
        matrix.r1 = 0; matrix.g2 = 0; matrix.b3 = 0
        matrix.r4 = accent.red; matrix.g4 = accent.green; matrix.b4 = accent.blue
        return matrix
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            if line.allSatisfy({ $0[ArrivalStamp.self] == nil }) {
                context.draw(line)
                continue
            }
            for run in line {
                guard let stamp = run[ArrivalStamp.self] else { context.draw(run); continue }
                let progress = min(1, max(0, (now - stamp.start) / duration))
                if progress <= 0 && !reduceMotion { continue }
                var glyph = context
                if !reduceMotion, progress < 1 {
                    let alpha = smooth(progress / 0.24)
                    glyph.opacity *= alpha
                    let delta = (0.48 - progress) * 72
                    let band = exp(-pow(delta / 22, 2))
                    glyph.translateBy(x: sin(delta / 14) * band * 1.1 * strength,
                                      y: sin(delta / 12) * band * 5.2 * strength)
                    glyph.addFilter(.blur(radius: band * 0.6 * strength))
                    glyph.addFilter(.shadow(color: NookTheme.accent.opacity(band * 0.48), radius: band * 3 * strength))
                }

                // Only the unfinished edge stays liquid. Absolute glyph phase
                // preserves the wave's position when another character arrives.
                // On a pause this hands off from the entrance ripple to a small,
                // continuous refraction, rather than replaying the text reveal.
                let distance = lastIndex - stamp.index
                let completion = writing ? 1 : 1 - smooth((now - lastArrival) / duration)
                let tail = distance >= 0 && distance < 6 ? pow(1 - Double(distance) / 6, 1.2) : 0
                let envelope = tail * completion * (reduceMotion ? 0.65 : smooth((progress - 0.2) / 0.8))
                let phase = now * .pi * 2 / 1.25 - Double(stamp.index) * 0.88
                let crest = (sin(phase) + 1) / 2
                let bounds = run.typographicBounds.rect
                if envelope > 0, !reduceMotion {
                    let amplitude = min(2.35, max(1.4, bounds.height * 0.058))
                    glyph.translateBy(x: sin(phase * 0.7) * 0.45 * envelope,
                                      y: sin(phase) * amplitude * envelope)
                    glyph.addFilter(.blur(radius: crest * 0.22 * envelope))
                }
                glyph.draw(run)

                if envelope > 0 {
                    // Recolor the glyph's alpha mask, so the sheen remains
                    // visible on both dark and light reader backgrounds.
                    var glow = glyph
                    glow.opacity *= envelope * (0.28 + crest * 0.6)
                    glow.addFilter(.colorMatrix(inkMatrix))
                    glow.addFilter(.shadow(color: NookTheme.accent.opacity(0.8), radius: (1.5 + crest * 2) * envelope))
                    glow.draw(run)

                    // A narrow highlight crosses the glyph itself. No appended
                    // symbol, extra line, or separate loading indicator is drawn.
                    if !reduceMotion {
                        let phase = now / 1.25 - Double(stamp.index) * 0.14
                        let position = phase - floor(phase)
                        let width = max(3, bounds.width * 0.22)
                        let x = bounds.minX - width + (bounds.width + width * 2) * position
                        var edge = glyph
                        edge.clip(to: Path(CGRect(x: x, y: bounds.minY - 4, width: width, height: bounds.height + 8)))
                        edge.opacity *= envelope * 0.75 * sin(position * .pi)
                        edge.addFilter(.colorMatrix(inkMatrix))
                        edge.addFilter(.shadow(color: NookTheme.accent, radius: 2.5))
                        edge.draw(run)
                    }
                }
            }
        }
    }
}

private struct StreamingBlockLayout: Layout {
    var originalFloor: Double
    var animatableData: Double {
        get { originalFloor }
        set { originalFloor = newValue }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.init(width: proposal.width, height: nil)) }
        return CGSize(width: proposal.width ?? sizes.map(\.width).max() ?? 0,
                      height: max((sizes.first?.height ?? 0) * originalFloor, sizes.last?.height ?? 0))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            view.place(at: bounds.origin, anchor: .topLeading, proposal: .init(width: bounds.width, height: nil))
        }
    }
}

struct ReaderStreamingText: View {
    let original: String
    let text: String
    let complete: Bool
    var selectable = true
    var baseSize: CGFloat = ReaderTypography.platformBodySize
    var bold = false
    var typography: ReaderTypography = .platformDefault
    var markdown = false
    var headline = false
    private let duration = ReaderTranslationMotion.duration
    private let strength = ReaderTranslationMotion.strength
    @State private var history = TranslationArrivalHistory()
    @State private var styled = Text("")
    @State private var attributed = AttributedString()
    @State private var animating = false
    @State private var sourceVisible = true
    @State private var originalFloor = 1.0
    @State private var onScreen = true
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.self) private var environment

    private var reduced: Bool { systemReduceMotion }
    private var size: CGFloat { baseSize }
    private var leading: CGFloat { headline ? size * 0.12 : typography.lineSpacing }
    private var writing: Bool { !text.isEmpty && !complete }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60,
                                paused: (!animating && !writing) || !onScreen || reduced)) { context in
            let now = ProcessInfo.processInfo.systemUptime + context.date.timeIntervalSinceNow
            StreamingBlockLayout(originalFloor: originalFloor) {
                originalText
                    .opacity(sourceVisible ? 1 : 0)
                    .accessibilityHidden(!sourceVisible)
                    .allowsHitTesting(sourceVisible)
                Group {
                    if !onScreen || complete && !animating {
                        if selectable { formattedText.textSelection(.enabled) }
                        else { formattedText.textSelection(.disabled) }
                    } else {
                        formattedText.textSelection(.disabled)
                            .textRenderer(StreamRippleRenderer(now: now, duration: duration, strength: strength,
                                                               reduceMotion: reduced, writing: writing, lastIndex: history.characters.lastIndex(where: { !$0.isWhitespace }) ?? -1,
                                                               lastArrival: history.lastArrival, accent: NookTheme.accent.resolve(in: environment)))
                    }
                }
                    .lineSpacing(leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(sourceVisible)
                    .allowsHitTesting(!sourceVisible)
            }
            .onChange(of: now >= history.lastArrival + duration) { _, settled in
                if settled {
                    animating = false
                    rebuildStyled(at: now)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: text, initial: true) { _, value in accept(value) }
        .onChange(of: complete) { _, value in
            if value, !text.isEmpty { withAnimation(reduced ? nil : .easeOut(duration: 0.24)) { originalFloor = 0 } }
        }
        .onChange(of: typography) { _, _ in accept(text) }
        .onChange(of: baseSize) { _, _ in accept(text) }
        .onChange(of: reduced) { _, value in if value { animating = false } }
        // Eager reader stacks keep off-screen paragraphs mounted, so appearance
        // callbacks do not describe viewport visibility.
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            onScreen = visible
            let now = ProcessInfo.processInfo.systemUptime
            animating = visible && !reduced && now < history.lastArrival + duration
            rebuildStyled(at: now)
        }
        .onDisappear { onScreen = false }
    }

    private var formattedText: Text { styled.kerning(headline ? -0.5 : typography.kern) }

    private var originalText: some View {
        Group {
            if headline { MagazineHeadline.text(original, size: size).lineSpacing(leading) }
            else {
                Text(original)
                    .font(.system(size: size, weight: bold ? .semibold : .regular, design: typography.fontDesign))
                    .kerning(typography.kern).lineSpacing(leading)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func accept(_ value: String) {
        // Parse only when an actual snapshot arrives, never from the 60Hz draw.
        let attributed: AttributedString
        if markdown {
            attributed = StreamingMarkdownFormatter.attributed(value, baseSize: size, baseBold: bold, design: typography.fontDesign)
        } else {
            var plain = AttributedString(value)
            let hasCJK = value.unicodeScalars.contains {
                (0x2E80...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value)
            }
            let design: Font.Design = headline ? (hasCJK ? .default : .serif) : typography.fontDesign
            plain.font = .system(size: size, weight: bold ? .semibold : .regular, design: design)
            attributed = plain
        }
        let plain = String(attributed.characters)
        let now = ProcessInfo.processInfo.systemUptime
        let alreadyComplete = complete && history.characters.isEmpty
        history.update(plain, at: alreadyComplete ? now - duration : now)
        if alreadyComplete, !plain.isEmpty { originalFloor = 0 }
        if plain.isEmpty {
            sourceVisible = true
            originalFloor = 1
        }
        self.attributed = attributed
        rebuildStyled(at: now)
        animating = !plain.isEmpty && !reduced && !alreadyComplete && now < history.lastArrival + duration
        if !plain.isEmpty, sourceVisible {
            withAnimation(reduced || alreadyComplete ? nil : .easeOut(duration: 0.16)) { sourceVisible = false }
        }
    }

    private func rebuildStyled(at now: Double) {
        guard onScreen, !reduced else {
            styled = Text(attributed)
            return
        }
        let spans = history.renderSpans(at: now, writing: writing, duration: duration)
        var result = Text("")
        var index = attributed.characters.startIndex
        for span in spans {
            let end = attributed.characters.index(index, offsetBy: span.range.count)
            let part = Text(AttributedString(attributed[index..<end]))
            if span.animated {
                let stamp = ArrivalStamp(start: history.starts[span.range.lowerBound], index: span.range.lowerBound)
                result = Text("\(result)\(part.customAttribute(stamp))")
            } else {
                result = Text("\(result)\(part)")
            }
            index = end
        }
        styled = result
    }
}

/// Shared by Classic and Beta. A nil translation always shows the current
/// article's original title; changing articles must reset this view's identity.
public struct ReaderTranslatedTitle: View {
    let original: String
    let translated: String?
    let translating: Bool
    let size: CGFloat
    let magazine: Bool
    let selectable: Bool

    public init(original: String, translated: String?, translating: Bool, size: CGFloat = 36, magazine: Bool = true, selectable: Bool = false) {
        self.original = original
        self.translated = translated
        self.translating = translating
        self.size = size
        self.magazine = magazine
        self.selectable = selectable
    }

    public var body: some View {
        ReaderStreamingText(original: original, text: translated ?? "", complete: !translating,
                            selectable: selectable, baseSize: size, bold: true,
                            typography: .init(font: magazine ? .system : .serif, fontSize: size, lineHeightMultiple: 1.12, letterSpacingEM: 0),
                            headline: magazine)
    }
}
#endif
