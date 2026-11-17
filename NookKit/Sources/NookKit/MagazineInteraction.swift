#if os(macOS)
import SwiftUI

/// Content cards and navigation get a quiet highlight. Liquid Glass buttons
/// use the system's material interaction instead of a cursor-following overlay.
private struct MagazinePointerSurface<Shape: InsettableShape>: ViewModifier {
    let shape: Shape
    let tint: Color
    @State private var pointerInside = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hovering: Bool { enabled && pointerInside }

    func body(content: Content) -> some View {
        content
            .overlay {
                shape.fill(tint.opacity(hovering ? 0.045 : 0))
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .contentShape(shape)
            .pointerStyle(enabled ? .link : .default)
            .onHover { pointerInside = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}

public extension View {
    func magazinePointer<S: InsettableShape>(in shape: S, tint: Color = NookTheme.accent) -> some View {
        modifier(MagazinePointerSurface(shape: shape, tint: tint))
    }
}

/// A quiet control for toolbars and navigation, without giving each item a
/// second glass container. It shares the pointer and press feedback of buttons.
public struct MagazinePlainButtonStyle: ButtonStyle {
    private let capsule: Bool
    public init(capsule: Bool = false) { self.capsule = capsule }
    public func makeBody(configuration: Configuration) -> some View {
        Group {
            if capsule {
                configuration.label.magazinePointer(in: Capsule())
            } else {
                configuration.label.magazinePointer(in: RoundedRectangle(cornerRadius: 8))
            }
        }.opacity(configuration.isPressed ? 0.65 : 1)
    }
}

public struct MagazineSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.switch)
            .pointerStyle(enabled ? .link : .default)
    }
}

/// Native buttons retain keyboard activation and accessibility. One glass
/// surface groups the choices, with an animated selection beneath the labels.
public struct MagazineGlassSegments<Value: Hashable, Label: View>: View {
    let values: [Value]
    @Binding var selection: Value
    let label: (Value) -> Label
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ values: [Value], selection: Binding<Value>, @ViewBuilder label: @escaping (Value) -> Label) {
        self.values = values
        _selection = selection
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(values, id: \.self) { value in
                Button { selection = value } label: {
                    label(value)
                        .font(.system(size: 12, weight: selection == value ? .semibold : .medium))
                        .foregroundStyle(selection == value ? NookTheme.accent : .secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity).padding(.horizontal, 10).frame(height: 30)
                        .background {
                            if selection == value {
                                Capsule().fill(NookTheme.accent.opacity(0.14))
                                    .overlay { Capsule().strokeBorder(NookTheme.accent.opacity(0.18), lineWidth: 0.5) }
                                    .matchedGeometryEffect(id: "selected", in: highlight)
                            }
                        }
                }
                .buttonStyle(MagazinePlainButtonStyle(capsule: true))
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(4)
        .glassEffect(.regular.tint(NookTheme.accent.opacity(0.05)), in: Capsule())
        .animation(reduceMotion ? nil : .spring(duration: 0.24, bounce: 0.05), value: selection)
        .accessibilityElement(children: .contain)
    }
}

/// Categories are content, so they use tinted chips rather than another glass
/// navigation layer. Stable IDs animate only the classifications that change.
public struct MagazineCategoryLabels: View {
    let categories: [ArticleCategory]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(_ categories: [ArticleCategory]) { self.categories = categories }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            chips
            ScrollView(.horizontal) { chips }.scrollIndicators(.hidden)
        }
        .frame(height: categories.isEmpty ? 0 : 24, alignment: .leading)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.08), value: categories.map(\.id))
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(categories) { category in
                Label(category.name, systemImage: "tag")
                    .font(.system(size: 10, weight: .medium)).lineLimit(1).fixedSize()
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .foregroundStyle(Color(nookHex: category.colorHex))
                    .background(Color(nookHex: category.colorHex).opacity(0.12), in: Capsule())
                    .overlay { Capsule().strokeBorder(Color(nookHex: category.colorHex).opacity(0.22), lineWidth: 0.5) }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 5)))
            }
        }
    }
}
#endif
