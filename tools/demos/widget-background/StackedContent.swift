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

struct StackDeck {
    var stories = StackStory.samples
    private(set) var waiting = [StackStory.replacement(0), StackStory.replacement(1)]
    private var nextSequence = 2

    mutating func replaceStory(at slot: Int) {
        guard stories.indices.contains(slot) else { return }
        stories[slot] = waiting.removeFirst()
        waiting.append(.replacement(nextSequence))
        nextSequence += 1
    }

    func cards(for size: StackSize) -> [StackDeckCard] {
        stories.prefix(size.count).enumerated().map { StackDeckCard(story: $0.element, slot: $0.offset) }
            + waiting.enumerated().map { StackDeckCard(story: $0.element, waitingDepth: $0.offset) }
    }
}

struct StackDeckCard: Identifiable {
    let story: StackStory
    var slot: Int?
    var waitingDepth: Int?
    var id: Int { story.id }
    var isWaiting: Bool { slot == nil }
}

struct StackedGlassContent: View {
    let size: StackSize
    var deck = StackDeck()
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
            let cards = deck.cards(for: size)
            ZStack(alignment: .top) {
                // One identity domain includes both the visible stories and
                // the real waiting cards. Promotion moves the existing view;
                // no copy is inserted over a decorative placeholder.
                ForEach(cards) { item in
                    let index = item.slot ?? size.count - 1
                    let depth = item.waitingDepth ?? 0
                    let waitingInset = CGFloat(size.count - 1) * 2 + CGFloat(depth + 1) * 5
                    let restingScale: CGFloat = item.isWaiting ? (depth == 0 ? 0.97 : 0.94) : 1
                    let foldedScale: CGFloat = item.isWaiting ? 0.84 : 1 - CGFloat(index) * 0.035
                    let restingY = item.isWaiting ? lastSlot + 12 + CGFloat(depth) * 8 : CGFloat(index) * (height - overlap)
                    let foldedY: CGFloat = item.isWaiting ? 0 : CGFloat(index) * 9
                    let restingOpacity = item.isWaiting ? (depth == 0 ? 0.72 : 0.48) : 1
                    let introDelay = Double(index) * 0.065 + (item.isWaiting ? 0.12 + Double(depth) * 0.06 : 0)
                    Link(destination: URL(string: "nookglasslab://story/\(item.id)")!) {
                        card(item.story, height: height, showsContent: !item.isWaiting)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, item.isWaiting ? waitingInset : CGFloat(index) * 2)
                    .scaleEffect(expanded ? restingScale : foldedScale, anchor: .top)
                    .offset(y: expanded ? restingY : foldedY)
                    .opacity(expanded ? restingOpacity : (item.isWaiting ? 0 : 1))
                    // The destination slot owns rank as soon as its card is
                    // picked up. It never stays at a shared "incoming = -1".
                    .zIndex(item.isWaiting ? -Double(depth + 1) : Double(size.count - index))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.48).delay(introDelay), value: expanded)
                    .transition(reduceMotion ? .identity : .asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.25).delay(0.2)),
                        removal: .opacity.animation(.easeOut(duration: 0.16))))
                    .disabled(item.isWaiting)
                    .allowsHitTesting(!item.isWaiting)
                    .accessibilityHidden(item.isWaiting)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(reduceMotion ? nil : .smooth(duration: 0.55), value: cards.map(\.id))
            .padding(8)
            .clipped()
        }
    }

    private func card(_ story: StackStory, height: CGFloat, showsContent: Bool) -> some View {
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
        .opacity(showsContent ? 1 : 0)
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
