import SwiftUI

enum FrameDesign: String, CaseIterable, Identifiable {
    case tray, folio, shelf

    var id: Self { self }
    var code: String { self == .tray ? "E" : self == .folio ? "F" : "G" }
    var title: String { self == .tray ? "Glass Tray" : self == .folio ? "Reading Folio" : "Quiet Shelf" }
    var subtitle: String { self == .tray ? "읽을거리를 담는 작은 트레이" : self == .folio ? "한 편을 먼저 만나는 매거진" : "글에 집중하는 조용한 서가" }
    var detail: String {
        switch self {
        case .tray: "Glass 프레임 안에 카드를 여유 있게 담았습니다. 대기 카드가 올라오는 움직임이 가장 자연스럽습니다."
        case .folio: "첫 글은 표지처럼 크게, 나머지는 짧게. 오늘 읽을 한 편을 먼저 발견하는 구성입니다."
        case .shelf: "카드 테두리는 덜고, 가는 구분선과 앰버 표시만. 한눈에 여러 글을 훑기 좋은 구성입니다."
        }
    }
    var kind: String { "GlassLabFrame" + rawValue.capitalized }
}

// Shared with the actual widget. The host owns the outer plate; this view
// draws only its contents, so the native preview cannot add a second frame.
struct FramedGlassContent: View {
    let design: FrameDesign
    let size: StackSize
    var deck = StackDeck()
    var expanded = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let amber = Color(red: 0.85, green: 0.65, blue: 0.38)

    var body: some View {
        VStack(spacing: size == .small ? 8 : 10) {
            header.frame(height: size == .small ? 18 : 22)
            GeometryReader { geometry in
                let metrics = FrameDeckMetrics(design: design, count: size.count, height: geometry.size.height)
                let cards = deck.cards(for: size)
                ZStack(alignment: .top) {
                    ForEach(cards) { item in
                        let slot = item.slot ?? size.count - 1
                        let depth = item.waitingDepth ?? 0
                        let isLead = slot == 0
                        let showsText = !item.isWaiting && (expanded || isLead)
                        Link(destination: URL(string: "nookglasslab://story/\(item.id)")!) {
                            storyContent(item.story, slot: slot)
                                .opacity(showsText ? 1 : 0)
                                .padding(.horizontal, design == .shelf ? 3 : 12)
                                .frame(maxWidth: .infinity)
                                .frame(height: metrics.heights[slot])
                                .background { surface(isLead: isLead, waiting: item.isWaiting) }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, item.isWaiting ? CGFloat(depth + 1) * 6 : 0)
                        .scaleEffect(expanded ? (item.isWaiting ? 0.97 - CGFloat(depth) * 0.025 : 1)
                                     : (item.isWaiting ? 0.85 : 1 - CGFloat(slot) * 0.025), anchor: .top)
                        .offset(y: expanded ? metrics.origins[slot] + (item.isWaiting ? CGFloat(depth + 1) * 5 : 0)
                                : (item.isWaiting ? 0 : CGFloat(slot) * 3))
                        .opacity(item.isWaiting ? (expanded ? (depth == 0 ? 0.55 : 0.28) : 0) : 1)
                        .zIndex(item.isWaiting ? -Double(depth + 1) : Double(size.count - slot))
                        .animation(reduceMotion ? nil : .smooth(duration: 0.48)
                            .delay(Double(slot) * 0.065 + (item.isWaiting ? 0.14 : 0)), value: expanded)
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
                .clipped()
            }
        }
        .padding(size == .small ? 12 : 14)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if design == .folio {
                Text("Nook").font(.system(size: size == .small ? 17 : 21, weight: .bold, design: .serif))
                Spacer(minLength: 3)
                Text("추천 글").font(.system(size: 10, weight: .medium)).foregroundStyle(amber)
            } else {
                Image(systemName: design == .tray ? "rectangle.stack" : "books.vertical")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(amber)
                Text("추천 글").font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 3)
                Text("Nook").font(.system(size: 15, weight: .bold, design: .serif)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func storyContent(_ story: StackStory, slot: Int) -> some View {
        if design == .folio && slot == 0 {
            VStack(alignment: .leading, spacing: size == .medium ? 4 : 7) {
                Text(story.source).font(.system(size: 9, weight: .medium)).foregroundStyle(amber).lineLimit(1)
                Text(story.title)
                    .font(.system(size: size == .large ? 21 : size == .small ? 17 : 16, weight: .semibold, design: .serif))
                    .lineLimit(size == .small ? 3 : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if size != .medium {
                    HStack {
                        Text(story.time)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            HStack(alignment: .center, spacing: 9) {
                if design == .shelf && size != .small {
                    Text(String(format: "%02d", slot + 1))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(amber.opacity(0.8))
                }
                VStack(alignment: .leading, spacing: size == .small ? 7 : 4) {
                    HStack(spacing: 4) {
                        Text(story.source).lineLimit(1)
                        Spacer(minLength: 2)
                        if size != .small { Text(story.time).fixedSize() }
                    }
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    Text(story.title)
                        .font(.system(size: size == .small ? 17 : 13, weight: .semibold))
                        .lineLimit(size == .small ? 3 : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if size == .small {
                        HStack {
                            Text(story.time)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private func surface(isLead: Bool, waiting: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: size == .small ? 19 : 16, style: .continuous)
        if design == .tray {
            shape.fill(.white.opacity(0.055))
                .overlay {
                    shape.fill(LinearGradient(colors: [.white.opacity(0.06), .clear],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay {
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.26), .white.opacity(0.025), .white.opacity(0.09)],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.55)
                }
        } else if design == .folio && isLead {
            shape.fill(LinearGradient(colors: [amber.opacity(0.12), .white.opacity(0.025)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(alignment: .topLeading) {
                    Capsule().fill(amber.opacity(0.7)).frame(width: 22, height: 2).padding(.leading, 12)
                }
        } else {
            Color.clear
                .overlay(alignment: .bottom) {
                    Rectangle().fill(waiting ? amber.opacity(0.24) : Color.white.opacity(0.12))
                        .frame(height: 0.5)
                        .padding(.horizontal, design == .shelf ? 3 : 12)
                }
        }
    }
}

private struct FrameDeckMetrics {
    let heights: [CGFloat]
    let origins: [CGFloat]

    init(design: FrameDesign, count: Int, height: CGFloat) {
        let gap: CGFloat = design == .tray ? 5 : design == .folio ? 3 : 0
        let usable = max(1, height - 10 - gap * CGFloat(count - 1))
        if design == .folio && count > 1 {
            let lead = usable * (count == 4 ? 0.40 : 0.58)
            heights = [lead] + Array(repeating: (usable - lead) / CGFloat(count - 1), count: count - 1)
        } else {
            heights = Array(repeating: usable / CGFloat(count), count: count)
        }
        var next: CGFloat = 0
        origins = heights.map { item in
            defer { next += item + gap }
            return next
        }
    }
}
