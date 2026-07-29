import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// The surfaces Plus screens are drawn on.
///
/// Defined here rather than read from an asset catalogue because these views
/// live in a package: `Color("ListBackground")` resolves against `Bundle.main`,
/// so it happens to work inside the app and silently falls back to nothing in a
/// preview or any other host.
///
/// The values match `NookiOS/Assets.xcassets/ListBackground.colorset` and
/// `AccentColor.colorset`. They exist because the Plus screens were the only
/// ones in the app drawn on the cool system grouped background, which made a
/// feature that is part of Nook look bolted on.
enum PlusTheme {
    /// The page behind everything, matching the reader's own list background.
    static let canvas = Color(
        light: (0.984, 0.960, 0.898),
        dark: (0.106, 0.090, 0.063)
    )

    /// Raised content sitting on ``canvas``: cards, fields, rows.
    ///
    /// Warm rather than the system's grey, and only slightly separated from the
    /// canvas, because a hard contrast reads as a dialog rather than as part of
    /// the page.
    static let card = Color(
        light: (1.000, 0.992, 0.965),
        dark: (0.161, 0.141, 0.106)
    )

    /// The brown the rest of the app tints controls with.
    static let accent = Color(
        light: (0.545, 0.353, 0.176),
        dark: (0.835, 0.639, 0.400)
    )

    /// A hairline between rows, warm enough not to read as grey against `card`.
    static let hairline = Color(
        light: (0.878, 0.839, 0.757),
        dark: (0.267, 0.235, 0.180)
    )
}

extension Color {
    /// Builds a colour that follows the light and dark appearance.
    ///
    /// Hand-rolled because a package with no asset catalogue has no other way to
    /// express an appearance-dependent colour, and committing to one value makes
    /// dark mode either glare or vanish.
    fileprivate init(light: (Double, Double, Double), dark: (Double, Double, Double)) {
        #if canImport(UIKit)
            self = Color(
                uiColor: UIColor { traits in
                    let (r, g, b) = traits.userInterfaceStyle == .dark ? dark : light
                    return UIColor(red: r, green: g, blue: b, alpha: 1)
                })
        #elseif canImport(AppKit)
            self = Color(
                nsColor: NSColor(name: nil) { appearance in
                    let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    let (r, g, b) = isDark ? dark : light
                    return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
                })
        #else
            self = Color(red: light.0, green: light.1, blue: light.2)
        #endif
    }
}
