#if os(macOS)
import SwiftUI

/// Camera snapshots only invalidate these leaves, not the graph, search or reader.
struct RecommendationMapMinimap: View {
    var control: RecommendationCanvasControl
    @State private var navigating = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let snapshot = control.overview
        VStack(spacing: 9) {
            HStack {
                Text("Map overview", bundle: .module)
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button { control.fit() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10))
                }
                .buttonStyle(MagazinePlainButtonStyle(capsule: true))
                .help(Text("Fit map · 0", bundle: .module))
                .accessibilityLabel(Text("Fit map", bundle: .module))
            }
            Canvas { context, size in
                func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x*size.width, y: p.y*size.height) }
                var dots = Path()
                for p in snapshot.points {
                    let q = point(p)
                    dots.addEllipse(in: CGRect(x: q.x-1, y: q.y-1, width: 2, height: 2))
                }
                context.fill(dots, with: .color(NookTheme.accent.opacity(0.45)))
                let viewport = snapshot.viewport.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                if !viewport.isNull {
                    let rect = CGRect(origin: point(viewport.origin),
                        size: CGSize(width: viewport.width*size.width, height: viewport.height*size.height))
                    let path = Path(roundedRect: rect, cornerRadius: 3)
                    context.fill(path, with: .color(NookTheme.accent.opacity(0.10)))
                    context.stroke(path, with: .color(NookTheme.accent.opacity(0.8)), lineWidth: 1)
                }
                if let selected = snapshot.selected {
                    let q = point(selected)
                    context.fill(Path(ellipseIn: CGRect(x: q.x-2.5, y: q.y-2.5, width: 5, height: 5)), with: .color(NookTheme.accent))
                }
            }
            .frame(width: 154, height: 94)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard enabled else { return }
                control.view?.navigateOverview(to: CGPoint(x: value.location.x/154, y: value.location.y/94), remember: !navigating)
                navigating = true
            }.onEnded { _ in navigating = false })
            .onChange(of: enabled) { _, active in if !active { navigating = false } }
            .onHover { inside in if enabled { (inside ? NSCursor.pointingHand : NSCursor.arrow).set() } }
            .accessibilityElement()
            .accessibilityLabel(Text("Map overview. Click or drag to navigate.", bundle: .module))
            .accessibilityAction(named: Text("Fit map", bundle: .module)) { control.fit() }
        }
        .frame(width: 154)
        .padding(12).glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

struct RecommendationMapNavigation: View {
    var model: RecommendationMapController
    var control: RecommendationCanvasControl
    @Binding var spatial: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button { spatial.toggle() } label: {
                Text(verbatim: spatial ? "3D" : "2D").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(spatial ? NookTheme.accent : .secondary)
            }
            .accessibilityValue(Text(verbatim: spatial ? "3D" : "2D"))
            .help(Text("Switch between 2D and 3D", bundle: .module))
            .accessibilityLabel(Text("Switch between 2D and 3D", bundle: .module))
            Divider().frame(height: 14)
            Button { control.back() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!control.overview.canGoBack)
                .help(Text("Previous position · Delete", bundle: .module))
                .accessibilityLabel(Text("Previous map position", bundle: .module))
            Button { control.fit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help(Text("Fit map · 0", bundle: .module)).accessibilityLabel(Text("Fit map", bundle: .module))
            Divider().frame(height: 14)
            Button { control.zoom(0.8) } label: { Image(systemName: "minus") }
                .accessibilityLabel(Text("Zoom out", bundle: .module))
            Text(verbatim: "\(control.overview.percent)%")
                .font(.system(size: 10, design: .monospaced)).frame(width: 40).foregroundStyle(.secondary)
            Button { control.zoom(1.25) } label: { Image(systemName: "plus") }
                .accessibilityLabel(Text("Zoom in", bundle: .module))
            Divider().frame(height: 14)
            Button { control.focus() } label: { Image(systemName: "location") }
                .disabled(model.selectedID == nil)
                .help(Text("Focus selected story · F", bundle: .module)).accessibilityLabel(Text("Focus selected story", bundle: .module))
            Button { model.focus.toggle() } label: {
                Image(systemName: "scope").foregroundStyle(model.focus ? NookTheme.accent : .secondary)
            }
            .help(Text("Focus on connections", bundle: .module)).accessibilityLabel(Text("Focus on connections", bundle: .module))
            .accessibilityAddTraits(model.focus ? .isSelected : [])
            if spatial {
                Button { control.resetDirection() } label: { Image(systemName: "rotate.3d") }
                    .help(Text("Reset map orientation", bundle: .module))
                    .accessibilityLabel(Text("Reset map orientation", bundle: .module))
            }
        }
        .font(.system(size: 12)).buttonStyle(MagazinePlainButtonStyle(capsule: true))
        .padding(.horizontal, 18).padding(.vertical, 13).glassEffect(.regular, in: .capsule)
    }
}
#endif
