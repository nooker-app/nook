import SwiftUI
import WidgetKit

@main
struct GlassLabApp: App {
    var body: some Scene {
        WindowGroup("Nook Glass Lab") {
            VStack(alignment: .leading, spacing: 20) {
                Label("Nook Glass Lab", systemImage: "square.stack.3d.up")
                    .font(.largeTitle.weight(.semibold))
                Text("시스템 설정은 그대로, 실제 위젯에서 비교합니다.")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 12) {
                    Text("1. 알림 센터 → 위젯 편집을 엽니다.")
                    Text("2. Nook Glass Lab을 검색합니다.")
                    Text("3. A와 B를 같은 크기로 추가해 비교합니다.")
                }
                Divider()
                Text("A · Public Material — 현재 Nook 방식\nB · Home Blur — Home의 비공개 배경 요청\nC · Transparent — 비공개 투명 배경 요청")
                    .lineSpacing(8)
                Text("뒤에 밝은 창이나 색이 있는 화면을 두고 비교하세요.\n이 안내 창의 배경은 위젯 렌더링 결과가 아닙니다.")
                    .foregroundStyle(.secondary)
                Text("별도 실험 앱 · 샘플 글만 사용 · Nook 데이터 접근 없음\n비공개 API는 macOS 업데이트 시 동작이 달라질 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(width: 540)
            .task { WidgetCenter.shared.reloadAllTimelines() }
        }
        .windowResizability(.contentSize)
    }
}
