#if os(macOS)
import SwiftUI

public extension View {
    func magazineReveal(paused: Bool = false, delay: Double = 0) -> some View {
        modifier(MagazineReveal(paused: paused, delay: delay))
    }
}

private struct MagazineReveal: ViewModifier {
    var paused: Bool
    var delay: Double
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(visible || paused ? 1 : 0)
            .offset(y: reduceMotion || visible || paused ? 0 : 16)
            .onScrollVisibilityChange(threshold: 0.01) { newValue in
                guard !paused else { return }
                if newValue {
                    withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.34).delay(delay)) { visible = true }
                } else {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { visible = false }
                }
            }
    }
}
#endif
