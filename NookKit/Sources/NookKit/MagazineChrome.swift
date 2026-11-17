#if os(macOS)
import SwiftUI

/// Keep the platform's own lighting, hover, focus and press behavior. This
/// wrapper adds Nook's tint and pointer without painting a simulated reflection.
public struct MagazineGlassButtonStyle: PrimitiveButtonStyle {
    private let prominent: Bool
    @Environment(\.isEnabled) private var enabled
    public init(prominent: Bool = false) { self.prominent = prominent }

    public func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
        .buttonStyle(.glass(.regular.tint(NookTheme.accent.opacity(prominent ? 0.12 : 0.025))))
        // A button tint fills native Glass with opaque accent color. Tint the
        // material instead so both primary and secondary actions stay subtle.
        .tint(nil as Color?)
        .foregroundStyle(configuration.role == .destructive ? Color.red : (prominent ? NookTheme.accent : .primary))
        .font(.system(size: 13, weight: .medium))
        .labelStyle(.titleAndIcon)
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .pointerStyle(enabled ? .link : .default)
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

    /// Menus need a label-based ButtonStyle; native PrimitiveButtonStyle bodies
    /// are ignored by macOS menu controls, including composite share menus.
    func magazineGlassMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(MagazineMenuButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
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
        .magazineGlassMenu()
    }
}

// Menu does not render a PrimitiveButtonStyle's body on macOS. Keep its native
// menu behavior, and give the label the same understated interactive material.
private struct MagazineMenuButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.primary)
            // Match the native large Glass button's 28pt control height.
            .padding(.horizontal, 12).frame(height: 28)
            .glassEffect(.regular.tint(NookTheme.accent.opacity(0.025)).interactive(), in: Capsule())
            .contentShape(Capsule())
            .pointerStyle(enabled ? .link : .default)
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
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
        Self.text(title, size: size)
            .lineSpacing(size * 0.12)
            .lineLimit(lines)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            // Typography is laid out once at each endpoint. Only its position
            // moves in the surrounding hero transition; text never reflows
            // through a succession of intermediate wrapping widths.
            .transaction { $0.animation = nil }
    }

    static func text(_ title: String, size: CGFloat) -> Text {
        let design: Font.Design = title.unicodeScalars.contains {
            (0x2E80...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value)
        } ? .default : .serif
        return Text(title)
            .font(.system(size: size, weight: .semibold, design: design))
            .tracking(design == .serif ? -0.4 : -0.6)
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
                .magazinePointer(in: RoundedRectangle(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(hovering ? NookTheme.accent.opacity(0.3) : NookTheme.hairline.opacity(0.65), lineWidth: 1)
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
