import SwiftUI

// Shared verbatim by the native motion preview and the actual widget. Sample
// stories never enter Nook's data store or use its reader URL scheme.
struct StackStory: Identifiable {
    let id: Int
    let title: String
    let source: String
    let time: String

    static let samples = [
        StackStory(id: 0, title: "작은 발견이 새로운 관점을 만드는 순간", source: "Nook Journal", time: "12분 전"),
        StackStory(id: 1, title: "읽는 공간을 더 조용하고 편안하게", source: "Design Notes", time: "28분 전"),
        StackStory(id: 2, title: "기술과 일상 사이, 오래 남는 이야기", source: "The Browser", time: "1시간 전"),
        StackStory(id: 3, title: "오늘의 호기심을 내일의 아이디어로", source: "Another Perspective", time: "2시간 전"),
    ]

    static func replacement(_ sequence: Int) -> Self {
        let titles = ["느리게 읽을 때 비로소 보이는 것들", "좋은 도구는 생각할 공간을 남겨준다", "흩어진 호기심이 하나의 이야기로", "익숙한 일상에서 찾은 새로운 질문"]
        return StackStory(id: 4 + sequence, title: titles[sequence % titles.count], source: "Nook Discoveries", time: "방금 전")
    }
}

enum StackSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: Self { self }
    var count: Int { self == .small ? 1 : self == .medium ? 2 : 4 }
    var title: String { self == .small ? "소형 · 1" : self == .medium ? "중형 · 2" : "대형 · 4" }
    var dimensions: CGSize { CGSize(width: self == .small ? 164 : 344, height: self == .large ? 344 : 164) }
}

struct StackedGlassContent: View {
    let size: StackSize
    var stories = StackStory.samples
    var expanded = true
    var widgetSurface = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let amber = Color(red: 0.85, green: 0.65, blue: 0.38)

    var body: some View {
        GeometryReader { geometry in
            let overlap: CGFloat = 5
            let deckDepth: CGFloat = 16
            let height = (geometry.size.height - 16 - deckDepth + overlap * CGFloat(size.count - 1)) / CGFloat(size.count)
            let lastSlot = CGFloat(size.count - 1) * (height - overlap)
            let deckOrigin = lastSlot + 12
            ZStack(alignment: .top) {
                // Visible reserve cards establish the origin before any update.
                // They are decoration, never duplicate story links or hit areas.
                ForEach(0..<2, id: \.self) { depth in
                    capsuleSurface
                        .frame(height: height)
                        .padding(.horizontal, CGFloat(size.count - 1) * 2 + CGFloat(depth + 1) * 5)
                        .scaleEffect(depth == 0 ? 0.97 : 0.94, anchor: .top)
                        .offset(y: (expanded ? lastSlot : CGFloat(size.count - 1) * 9) + 12 + CGFloat(depth) * 8)
                        .opacity(depth == 0 ? 0.72 : 0.48)
                        .zIndex(-Double(depth + 1))
                        .animation(reduceMotion ? nil : .smooth(duration: 0.48).delay(Double(size.count - 1) * 0.065), value: expanded)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                // The slots own stacking order for their entire lifetime.
                // Only the keyed content inside a slot participates in swaps,
                // so retained outgoing views cannot reorder other capsules.
                ForEach(0..<min(size.count, stories.count), id: \.self) { index in
                    let story = stories[index]
                    ZStack {
                        Link(destination: URL(string: "nookglasslab://story/\(story.id)")!) {
                            card(story, height: height)
                        }
                        .buttonStyle(.plain)
                        .id(story.id)
                        .transition(reduceMotion ? .identity : .asymmetric(
                            insertion: .offset(y: deckOrigin - CGFloat(index) * (height - overlap))
                                .combined(with: .scale(scale: 0.94, anchor: .top)).combined(with: .opacity),
                            removal: .opacity))
                    }
                    .frame(height: height)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.55), value: story.id)
                    .padding(.horizontal, CGFloat(index) * 2)
                    .offset(y: CGFloat(index) * (expanded ? height - overlap : 9))
                    .scaleEffect(expanded ? 1 : 1 - CGFloat(index) * 0.035, anchor: .top)
                    .zIndex(Double(size.count - index))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.48).delay(Double(index) * 0.065), value: expanded)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(8)
            .clipped()
        }
    }

    private func card(_ story: StackStory, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: size == .small ? 9 : 5) {
            HStack(spacing: 5) {
                Circle().fill(amber).frame(width: 4, height: 4)
                Text(story.source).lineLimit(1)
                if size != .small {
                    Spacer(minLength: 3)
                    Text(story.time)
                }
            }
            .font(.system(size: size == .small ? 10 : 9, weight: .medium))
            .foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 8) {
                Text(story.title)
                    .font(.system(size: size == .small ? 17 : 13, weight: .semibold))
                    .lineLimit(size == .small ? 3 : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if size != .small {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            if size == .small {
                HStack {
                    Text(story.time)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, size == .small ? 17 : 19)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background { capsuleSurface }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var capsuleSurface: some View {
        let shape = RoundedRectangle(cornerRadius: size == .small ? 31 : 34, style: .continuous)
        if widgetSurface {
            // WidgetKit's remote display list drops glassEffect content on
            // the tested OS. Keep text outside the material effect.
            shape.fill(.ultraThinMaterial)
                .overlay {
                    shape.fill(LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.025)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay {
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.06), .white.opacity(0.18)],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
                }
        } else {
            shape.fill(.clear)
                .glassEffect(.regular.tint(amber.opacity(0.035)), in: shape)
        }
    }
}
