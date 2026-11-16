import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Nook's paper, walnut, and amber palette, shared by the reader and publishing.
/// Accent values also match the app asset catalogues for native system controls.
public enum NookTheme {
    public static let canvas = Color(
        light: (0.984, 0.960, 0.898),
        dark: (0.106, 0.090, 0.063)
    )

    public static let card = Color(
        light: (1.000, 0.992, 0.965),
        dark: (0.161, 0.141, 0.106)
    )

    /// Brown in light appearance, brighter amber in dark appearance.
    public static let accent = Color(
        light: (0.545, 0.353, 0.176),
        dark: (0.835, 0.639, 0.400)
    )

    public static let hairline = Color(
        light: (0.878, 0.839, 0.757),
        dark: (0.267, 0.235, 0.180)
    )
}

extension Color {
    fileprivate init(light: (Double, Double, Double), dark: (Double, Double, Double)) {
        #if canImport(UIKit)
        self = Color(uiColor: UIColor { traits in
            let (r, g, b) = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
        #elseif canImport(AppKit)
        self = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (r, g, b) = isDark ? dark : light
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        })
        #else
        self = Color(red: light.0, green: light.1, blue: light.2)
        #endif
    }
}
