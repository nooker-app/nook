import SwiftUI

/// A live specimen of the reader's typography, for the settings screens: a
/// heading plus two body lines rendered with exactly the values the native
/// reader will use, updating as the user drags the controls.
///
/// Drawn with plain SwiftUI `Text` — not the HTML pipeline — deliberately:
/// the pipeline re-imports an attributed string per style change, which is
/// wasteful while a stepper is being tapped repeatedly, whereas plain `Text`
/// with the same system font design, size, kern, and leading has identical
/// metrics (it is the same styling the reader's own placeholder path uses),
/// so what you see is what the article body renders.
public struct ReaderTypographyPreview: View {
    private let typography: ReaderTypography

    public init(_ typography: ReaderTypography) {
        self.typography = typography
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "The Quiet Craft of Reading", bundle: .module))
                .font(.system(size: typography.headingSize(3), weight: .semibold, design: typography.fontDesign))
                .kerning(typography.kern)
            Text(String(
                localized: "Good typography disappears: the right size, spacing, and rhythm let you forget the letters and follow the story. Adjust the controls and watch this paragraph take the shape your articles will have.",
                bundle: .module
            ))
            .font(.system(size: typography.bodySize, design: typography.fontDesign))
            .kerning(typography.kern)
            .lineSpacing(typography.lineSpacing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(String(localized: "Typography preview", bundle: .module)))
        // The specimen demonstrates the reader's own type scale; the control
        // labels around it stay on Dynamic Type as usual.
        .animation(.smooth(duration: 0.18), value: typography)
    }
}
