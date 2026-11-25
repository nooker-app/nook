import SwiftUI
import WidgetKit

struct FrameComparisonPreview: View {
    @State private var size: StackSize = .large
    @State private var deck = StackDeck()
    @State private var expanded = false
    @State private var replay = 0
    @State private var nextSlot = 1
    @State private var warmBackground = false
    @State private var showsOriginal = false
    @State private var selectedStory: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let amber = Color(red: 0.85, green: 0.65, blue: 0.38)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("NOOK GLASS LAB  /  DESIGN STUDIES")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(2).foregroundStyle(amber)
                    Text("읽을거리를 담는 세 가지 방식.")
                        .font(.system(size: 28, weight: .semibold, design: .serif))
                }
                Spacer()
                Button("기존 D 보기", systemImage: "square.stack.3d.up") { showsOriginal = true }
                    .buttonStyle(.glass)
                Button("배경 바꾸기", systemImage: "circle.lefthalf.filled") { warmBackground.toggle() }
                    .buttonStyle(.glass)
            }
            HStack {
                Picker("위젯 크기", selection: $size) {
                    ForEach(StackSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 320)
                Spacer()
                Button("첫 표시 재현", systemImage: "arrow.counterclockwise") { replay += 1 }
                    .buttonStyle(.glass)
                Button("글 하나 교체", systemImage: "rectangle.stack.badge.plus") {
                    deck.replaceStory(at: nextSlot % size.count)
                    nextSlot = (nextSlot + 1) % size.count
                }
                .buttonStyle(.glass).disabled(!expanded)
            }
            HStack(alignment: .top, spacing: 24) {
                ForEach(FrameDesign.allCases) { design in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 9) {
                            Text(design.code)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(amber).frame(width: 24, height: 24)
                                .background(amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                            Text(design.title).font(.system(size: 19, weight: .semibold, design: .serif))
                            if design == .tray {
                                Text("추천").font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(amber).padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(amber.opacity(0.10), in: Capsule())
                            }
                        }
                        Text(design.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        FramedGlassContent(design: design, size: size, deck: deck, expanded: expanded)
                            .frame(width: size.dimensions.width, height: size.dimensions.height)
                            .background { previewHost }
                            .id(size)
                            .frame(width: 344, height: 360)
                        Text(design.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                            .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                            .frame(height: 58, alignment: .topLeading)
                    }
                    .frame(width: 344, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedStory ?? "외곽 프레임을 포함한 네이티브 미리보기 · 샘플 글")
                        .font(.system(size: 11, weight: .medium))
                    Text("실제 위젯은 위젯 편집 → Nook Glass Lab → E / F / G에서 비교할 수 있습니다. 블러와 갱신 시점은 macOS가 결정합니다.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("위젯 갱신", systemImage: "arrow.clockwise") {
                    for design in FrameDesign.allCases { WidgetCenter.shared.reloadTimelines(ofKind: design.kind) }
                }
                .buttonStyle(.glass)
            }
        }
        .padding(28)
        .frame(width: 1136, height: 720)
        .background { backdrop }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsOriginal) {
            VStack(spacing: 0) {
                HStack {
                    Text("D · Stacked Glass").font(.headline)
                    Spacer()
                    Button("비교로 돌아가기") { showsOriginal = false }.buttonStyle(.glass)
                }
                .padding(16)
                StackPreview()
            }
        }
        .task(id: replay) {
            var reset = Transaction(animation: nil)
            reset.disablesAnimations = true
            withTransaction(reset) {
                deck = StackDeck()
                nextSlot = 1
                expanded = reduceMotion
            }
            guard !reduceMotion else { return }
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            expanded = true
        }
        .onOpenURL { url in
            if url.scheme == "nookglasslab", url.host == "story" {
                selectedStory = "샘플 글 선택: \(url.lastPathComponent) · 실제 글은 열지 않습니다."
            }
        }
    }

    private var previewHost: some View {
        // A visible frame approximation for comparing layout, never evidence
        // about Notification Center's actual backdrop compositing.
        RoundedRectangle(cornerRadius: 32, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.07), .white.opacity(0.24)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
    }

    private var backdrop: some View {
        ZStack {
            Color(red: 0.08, green: 0.10, blue: 0.11)
            LinearGradient(colors: warmBackground
                           ? [Color(red: 0.40, green: 0.25, blue: 0.15), Color(red: 0.18, green: 0.16, blue: 0.25), .clear]
                           : [Color(red: 0.13, green: 0.30, blue: 0.34), Color(red: 0.14, green: 0.22, blue: 0.30), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Ellipse().fill(amber.opacity(0.16)).frame(width: 650, height: 210)
                .blur(radius: 80).rotationEffect(.degrees(-18)).offset(x: 250, y: 80)
        }
        .animation(.easeInOut(duration: 0.45), value: warmBackground)
    }
}
