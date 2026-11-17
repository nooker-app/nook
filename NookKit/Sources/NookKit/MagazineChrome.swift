#if os(macOS)
import SwiftUI

/// Shared chrome for Beta. Menus and buttons use the same label surface; the
/// Menu itself remains native, including keyboard navigation and menu tracking.
public struct MagazineGlassLabel<Content: View>: View {
    private let content: Content
    private let tint: Color
    private let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    public init(tint: Color = NookTheme.accent, prominent: Bool = false, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.prominent = prominent
        self.content = content()
    }

    public var body: some View {
        content
            .font(.system(size: 13, weight: .medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(tint.opacity(0.035), in: Capsule())
            .glassEffect(.regular.tint(tint.opacity(prominent ? 0.22 : 0.06)).interactive(), in: Capsule())
            .overlay {
                Capsule().strokeBorder(tint.opacity(0.18), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

public struct MagazineGlassButtonStyle: ButtonStyle {
    private let prominent: Bool
    public init(prominent: Bool = false) { self.prominent = prominent }
    public func makeBody(configuration: Configuration) -> some View {
        MagazineGlassLabel(tint: configuration.role == .destructive ? .red : NookTheme.accent, prominent: prominent) { configuration.label }
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

/// A shared input surface for Beta forms. The native text field keeps IME,
/// selection and keyboard behavior; glass and the focus ring are presentation.
public struct MagazineInputSurface: ViewModifier {
    var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    public func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 16).padding(.vertical, 13)
            .glassEffect(.regular.tint(NookTheme.accent.opacity(0.045)), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(focused ? NookTheme.accent.opacity(0.65) : NookTheme.hairline,
                                  lineWidth: focused ? 1.5 : 0.5)
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1 : 0.5)
    }
}

public extension View {
    func magazineInput(focused: Bool = false) -> some View {
        modifier(MagazineInputSurface(focused: focused))
    }
}

public struct MagazineGlassMenu<Content: View, Label: View>: View {
    private let content: Content
    private let label: Label

    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content()
        self.label = label()
    }

    public var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 7) {
                label
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        // The AppKit-backed borderless style reduces its label to text/image,
        // dropping custom surfaces. Button menus preserve the shared SwiftUI
        // button style while retaining native menu tracking and keyboard input.
        .menuStyle(.button)
        .buttonStyle(MagazineGlassButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// CJK uses the platform's modern text face. Its serif fallback is a calligraphic
/// face on macOS, quite different from the editorial Latin typography.
public struct MagazineHeadline: View {
    private let title: String
    private let size: CGFloat
    private let lines: Int?

    public init(_ title: String, size: CGFloat, lines: Int? = nil) {
        self.title = title
        self.size = size
        self.lines = lines
    }

    public var body: some View {
        Text(title)
            .font(.system(size: size, weight: .semibold, design: design))
            .tracking(design == .serif ? -0.4 : -0.6)
            .lineSpacing(size * 0.12)
            .lineLimit(lines)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            // Typography is laid out once at each endpoint. Only its position
            // moves in the surrounding hero transition; text never reflows
            // through a succession of intermediate wrapping widths.
            .transaction { $0.animation = nil }
    }

    private var design: Font.Design {
        title.unicodeScalars.contains {
            (0x2E80...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value)
        } ? .default : .serif
    }
}

public struct MagazineCardStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration)
    }

    private struct CardBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(hovering ? NookTheme.accent.opacity(0.5) : NookTheme.hairline.opacity(0.65), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(hovering ? 0.09 : 0), radius: 14, y: 5)
                .opacity(configuration.isPressed ? 0.8 : 1)
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
        }
    }
}
#endif
