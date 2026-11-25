import SwiftUI
import WidgetKit

@main
struct GlassLabApp: App {
    var body: some Scene {
        WindowGroup("Nook Glass Lab") {
            StackPreview()
        }
        .windowResizability(.contentSize)
    }
}

struct StackPreview: View {
    @State private var size: StackSize = .large
    @State private var expanded = true
    @State private var blueBackground = true
    @State private var replay = 0
    @State private var reloadRequested = false
    @State private var selectedStory: String?
    @State private var widgetSurface = true
    @State private var stories = StackStory.samples
    @State private var nextStory = 0
    @State private var nextSlot = 1
    @State private var incomingStoryID: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Label("Nook Glass Lab", systemImage: "square.stack.3d.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("A little stack.\nA new perspective.")
                    .font(.system(size: 31, weight: .semibold, design: .serif))
                Text("글마다 하나의 Glass.\n배경은 비워두고, 읽을거리만 겹겹이.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .lineSpacing(5)
                Picker("크기", selection: $size) {
                    ForEach(StackSize.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("위젯용 재질 미리보기", isOn: $widgetSurface)
                    .font(.system(size: 12))
                HStack {
                    Button("첫 표시 재현", systemImage: "arrow.counterclockwise") { replay += 1 }
                        .buttonStyle(.glass)
                    Button("글 하나 교체", systemImage: "rectangle.stack.badge.plus") {
                        let slot = nextSlot % size.count
                        stories[slot] = .replacement(nextStory)
                        incomingStoryID = stories[slot].id
                        nextStory += 1
                        nextSlot = (slot + 1) % size.count
                    }
                    .disabled(!expanded)
                    .buttonStyle(.glass)
                }
                HStack {
                    Text("유지되는 글은 그대로, 새 글만 아래에서.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("배경 바꾸기", systemImage: "circle.lefthalf.filled") { blueBackground.toggle() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                }
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    Text("실제 위젯에서도 비교하기").font(.headline)
                    Text("위젯 편집 → Nook Glass Lab\nD · Stacked Glass를 추가하세요.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                    Button(reloadRequested ? "갱신 요청됨 · 다시 요청" : "위젯 갱신 요청", systemImage: "arrow.clockwise") {
                        WidgetCenter.shared.reloadTimelines(ofKind: "GlassLabStacked")
                        reloadRequested = true
                    }
                    .buttonStyle(.glass)
                    Text("현재 실제 위젯에는 시스템 외곽 테두리가 남습니다.\n갱신·전환 시점은 macOS가 결정합니다.\n오른쪽은 외곽 프레임을 제외한 움직임 미리보기입니다.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
                }
                Spacer(minLength: 0)
                Text(selectedStory ?? "별도 데모 · 샘플 글 · Nook 데이터 접근 없음")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(width: 350, height: 680)
            ZStack {
                backdrop
                StackedGlassContent(size: size, stories: stories, incomingStoryID: incomingStoryID,
                                    expanded: expanded, widgetSurface: widgetSurface)
                    .frame(width: size.dimensions.width, height: size.dimensions.height)
                    .id(size)
            }
            .frame(width: 424, height: 680)
            .clipped()
            .overlay(alignment: .bottom) {
                Text("MOTION PREVIEW · \(size.count) \(size.count == 1 ? "STORY" : "STORIES")")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(20)
            }
        }
        .task(id: replay) {
            // Explicit first-display rehearsal only. Data updates never change
            // `expanded` or replace the identity of the entire stack.
            var reset = Transaction(animation: nil)
            reset.disablesAnimations = true
            withTransaction(reset) {
                stories = StackStory.samples
                nextStory = 0
                nextSlot = 1
                incomingStoryID = nil
                expanded = reduceMotion
            }
            guard !reduceMotion else { expanded = true; return }
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            expanded = true
        }
        .onOpenURL { url in
            if url.scheme == "nookglasslab", url.host == "story" {
                selectedStory = "샘플 글 선택: \(url.lastPathComponent) · 실제 글은 열지 않습니다."
            }
        }
    }

    private var backdrop: some View {
        ZStack {
            LinearGradient(colors: blueBackground
                           ? [Color(red: 0.16, green: 0.40, blue: 0.57), Color(red: 0.24, green: 0.51, blue: 0.49), Color(red: 0.08, green: 0.20, blue: 0.23)]
                           : [Color(red: 0.65, green: 0.45, blue: 0.29), Color(red: 0.30, green: 0.24, blue: 0.35), Color(red: 0.13, green: 0.14, blue: 0.22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Ellipse().fill(.white.opacity(0.26)).frame(width: 310, height: 85)
                .rotationEffect(.degrees(-35)).blur(radius: 24).offset(x: 100, y: -125)
            Ellipse().fill(Color.black.opacity(0.26)).frame(width: 260, height: 520)
                .rotationEffect(.degrees(26)).blur(radius: 14).offset(x: -175, y: 150)
            Ellipse().fill(Color(red: 0.82, green: 0.74, blue: 0.49).opacity(0.55))
                .frame(width: 150, height: 260).blur(radius: 42).offset(x: 90, y: 190)
        }
        .animation(.easeInOut(duration: 0.45), value: blueBackground)
    }
}
