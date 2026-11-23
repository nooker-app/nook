import SwiftUI

struct OverviewMap: View {
    var study: Study
    @State private var navigating = false
    var body: some View {
        VStack(spacing: 9) {
            HStack {
                Text("현재 위치").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button { study.control.view?.navigateToFit() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }.buttonStyle(.plain).help("전체 지도").accessibilityLabel("미니맵에서 전체 지도 보기")
            }
            Canvas { context, size in
                let snapshot = study.overview
                func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x*size.width, y: p.y*size.height) }
                for p in snapshot.points {
                    let q = point(p)
                    context.fill(Path(ellipseIn: CGRect(x: q.x-1, y: q.y-1, width: 2, height: 2)),
                                 with: .color(NookTheme.accent.opacity(0.45)))
                }
                let viewport = snapshot.viewport.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                if !viewport.isNull {
                    let rect = CGRect(origin: point(viewport.origin),
                        size: CGSize(width: viewport.width*size.width, height: viewport.height*size.height))
                    context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(NookTheme.accent.opacity(0.10)))
                    context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(NookTheme.accent.opacity(0.8)), lineWidth: 1)
                }
                if let selected = snapshot.selected {
                    let q = point(selected)
                    context.fill(Path(ellipseIn: CGRect(x: q.x-2.5, y: q.y-2.5, width: 5, height: 5)), with: .color(NookTheme.accent))
                }
            }
            .frame(width: 154, height: 94)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                study.control.view?.navigateOverview(to: CGPoint(x: value.location.x/154, y: value.location.y/94), remember: !navigating)
                navigating = true
            }.onEnded { _ in navigating = false })
            .accessibilityLabel("지도 전체 개요. 클릭하거나 드래그하여 이동")
        }
        .frame(width: 154)
        .padding(12).glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

struct NavigationControls: View {
    var study: Study
    var body: some View {
        HStack(spacing: 15) {
            Button { study.control.view?.navigateBack() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!study.overview.canGoBack).help("이전 위치 · Delete").accessibilityLabel("이전 위치")
            Divider().frame(height: 14)
            Button { study.control.view?.navigateToFit() } label: { Label("전체", systemImage: "arrow.up.left.and.arrow.down.right") }
                .help("전체 지도 · 0").accessibilityLabel("전체 지도")
            Button { study.control.view?.focusSelection() } label: { Label("선택한 글", systemImage: "scope") }
                .disabled(study.selectedID == nil).help("선택한 글과 연결 보기 · F").accessibilityLabel("선택한 글에 집중")
            Divider().frame(height: 14)
            Button { study.control.view?.navigateZoom(0.8) } label: { Image(systemName: "minus") }.accessibilityLabel("축소")
            Text("\(study.overview.percent)%").font(.system(size: 11, design: .monospaced)).frame(width: 42)
            Button { study.control.view?.navigateZoom(1.25) } label: { Image(systemName: "plus") }.accessibilityLabel("확대")
            Divider().frame(height: 14)
            Button { study.control.view?.resetDirection() } label: { Image(systemName: "rotate.3d") }
                .help("처음 방향으로").accessibilityLabel("방향 초기화")
        }
        .buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 18).padding(.vertical, 13)
        .glassEffect(.regular, in: .capsule)
    }
}
