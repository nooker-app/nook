import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Reader configuration

/// Whether links tapped inside the reader open in Nook's in-app browser or the
/// system browser.
public enum ReaderLinkBehavior: String, CaseIterable, Identifiable, Sendable {
    case inApp
    case external
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .inApp: String(localized: "Open in Nook", bundle: Bundle.module)
        case .external: String(localized: "Open in Browser", bundle: Bundle.module)
        }
    }
}

public enum ReaderFont: String, CaseIterable, Identifiable, Sendable {
    case system
    case serif
    case monospaced
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .system: String(localized: "System", bundle: Bundle.module)
        case .serif: String(localized: "Serif", bundle: Bundle.module)
        case .monospaced: String(localized: "Monospaced", bundle: Bundle.module)
        }
    }
    public var cssFamily: String {
        switch self {
        case .system: "-apple-system, system-ui, sans-serif"
        case .serif: "ui-serif, Georgia, 'Times New Roman', serif"
        case .monospaced: "ui-monospace, SFMono-Regular, Menlo, monospace"
        }
    }

    /// The SwiftUI design equivalent, for text drawn with `Font.system` rather
    /// than a baked platform font.
    public var fontDesign: Font.Design {
        switch self {
        case .system: .default
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }
}

/// The resolved typography the NATIVE reader renders with — the single choke
/// point between the user's typography settings and every native text run.
///
/// Values are clamped at construction, so no combination of stored settings can
/// produce overlapping lines (negative leading), collapsed glyphs (negative
/// kern beyond a safe floor), or absurd sizes: downstream code renders whatever
/// this struct says without re-validating. Derived values are precomputed
/// points, not CSS-style multiples, so call sites never repeat the conversion
/// math (and cannot disagree about it).
///
/// `platformDefault` reproduces the reader's historical appearance exactly —
/// system face at the platform body size with 4pt leading and no kern — so
/// every surface that doesn't pass a typography (tests, notices, previews)
/// renders byte-identical to before this type existed.
public struct ReaderTypography: Equatable, Sendable {
    /// Hard bounds. Wider than the settings UI offers, so future UI changes
    /// stay safe, but tight enough that the extremes still lay out cleanly.
    public static let sizeRange: ClosedRange<CGFloat> = 10...40
    public static let lineHeightRange: ClosedRange<Double> = 1.0...3.0
    public static let letterSpacingRange: ClosedRange<Double> = -0.03...0.3

    /// Type family for body/heading text. Code spans always stay monospaced.
    public var design: ReaderFont
    /// Body point size; headings scale from it (see `headingSize(_:)`).
    public var bodySize: CGFloat
    /// Extra leading between lines, in points, never negative — this is what
    /// makes line overlap structurally impossible.
    public var lineSpacing: CGFloat
    /// Kern in points (settings store em units; this is em × bodySize).
    public var kern: CGFloat

    /// Nominal glyph-line-to-body-size ratio used to convert the CSS-style
    /// line-height multiple from settings into SwiftUI's between-lines spacing.
    private static let nominalLineHeightFactor = 1.2

    public init(
        font: ReaderFont,
        fontSize: CGFloat,
        lineHeightMultiple: Double,
        letterSpacingEM: Double
    ) {
        design = font
        bodySize = fontSize.rounded().clamped(to: Self.sizeRange)
        let multiple = lineHeightMultiple.clamped(to: Self.lineHeightRange)
        lineSpacing = max(0, (multiple - Self.nominalLineHeightFactor) * bodySize).rounded()
        let em = letterSpacingEM.clamped(to: Self.letterSpacingRange)
        // Quantized to 0.1pt so float noise from settings can't mint distinct
        // cache keys for visually identical renders.
        kern = (em * bodySize * 10).rounded() / 10
    }

    private init(design: ReaderFont, bodySize: CGFloat, lineSpacing: CGFloat, kern: CGFloat) {
        self.design = design
        self.bodySize = bodySize
        self.lineSpacing = lineSpacing
        self.kern = kern
    }

    /// The reader's pre-settings appearance: system face, platform body size,
    /// the historical 4pt leading, no kern.
    public static var platformDefault: ReaderTypography {
        ReaderTypography(design: .system, bodySize: platformBodySize, lineSpacing: 4, kern: 0)
    }

    /// The typography currently stored in settings — for non-view code (cache
    /// warming) that must agree with what the views will render.
    public static func current(_ defaults: UserDefaults = .standard) -> ReaderTypography {
        ReaderTypography(
            font: (defaults.string(forKey: "readerFont")).flatMap(ReaderFont.init(rawValue:)) ?? .system,
            fontSize: defaults.object(forKey: "readerFontSize") as? CGFloat ?? 18,
            lineHeightMultiple: defaults.object(forKey: "readerLineHeight") as? Double ?? 1.7,
            letterSpacingEM: defaults.object(forKey: "readerLetterSpacing") as? Double ?? 0
        )
    }

    /// Heading size for h1…h6: the platform's standard text-style size scaled
    /// by how far the body size diverges from the platform body size, so
    /// heading hierarchy keeps its native proportions at any body size (and is
    /// exactly the platform sizes at the default).
    public func headingSize(_ level: Int) -> CGFloat {
        (platformHeadingSize(level) * bodySize / Self.platformBodySize).rounded()
    }

    /// Code spans and blocks track the body size at the reader's historical
    /// mono ratio.
    public var codeSize: CGFloat { (bodySize * 0.92).rounded() }

    /// The piece of this typography that changes an *imported attributed
    /// string* (fonts + kern) — folded into the render cache key. Line spacing
    /// is deliberately absent: it is applied as a view modifier, never baked
    /// into the attributed string.
    public var attributedCacheToken: String {
        design == .system && kern == 0 ? "" : "-\(design.rawValue)-\(kern)"
    }

    public static var platformBodySize: CGFloat {
        #if canImport(AppKit)
        NSFont.preferredFont(forTextStyle: .body).pointSize
        #else
        UIFont.preferredFont(forTextStyle: .body).pointSize
        #endif
    }

    private func platformHeadingSize(_ level: Int) -> CGFloat {
        #if canImport(AppKit)
        let style: NSFont.TextStyle
        switch level {
        case 1: style = .title1
        case 2: style = .title2
        case 3: style = .title3
        case 4: style = .headline
        case 5: style = .body
        default: style = .subheadline
        }
        return NSFont.preferredFont(forTextStyle: style).pointSize
        #else
        let style: UIFont.TextStyle
        switch level {
        case 1: style = .title1
        case 2: style = .title2
        case 3: style = .title3
        case 4: style = .headline
        case 5: style = .body
        default: style = .subheadline
        }
        return UIFont.preferredFont(forTextStyle: style).pointSize
        #endif
    }

    /// SwiftUI design for placeholder/streaming text, matching the platform
    /// font the importers bake (see `HTMLContentText.finalBodyFont`).
    public var fontDesign: Font.Design { design.fontDesign }
}

extension ReaderStyle {
    /// The typography half of this style, resolved for the native reader.
    public var typography: ReaderTypography {
        ReaderTypography(
            font: font,
            fontSize: CGFloat(fontSize),
            lineHeightMultiple: lineHeight,
            letterSpacingEM: letterSpacing
        )
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

public enum ReaderColorOption: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case custom
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .automatic: String(localized: "Match Appearance", bundle: Bundle.module)
        case .custom: String(localized: "Custom", bundle: Bundle.module)
        }
    }
}

/// The typography/appearance used when rendering an article in reader mode.
public struct ReaderStyle: Equatable, Sendable {
    public var font: ReaderFont
    public var fontSize: Int
    public var lineHeight: Double
    public var letterSpacing: Double
    public var backgroundOption: ReaderColorOption
    public var backgroundHex: String
    public var textOption: ReaderColorOption
    public var textHex: String

    public init(
        font: ReaderFont = .system,
        fontSize: Int = 18,
        lineHeight: Double = 1.7,
        letterSpacing: Double = 0,
        backgroundOption: ReaderColorOption = .automatic,
        backgroundHex: String = "#FFFFFF",
        textOption: ReaderColorOption = .automatic,
        textHex: String = "#1A1A1A"
    ) {
        self.font = font
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.letterSpacing = letterSpacing
        self.backgroundOption = backgroundOption
        self.backgroundHex = backgroundHex
        self.textOption = textOption
        self.textHex = textHex
    }

    /// A stable key so the web view is recreated when the style changes.
    public var identity: String {
        "\(font.rawValue)-\(fontSize)-\(lineHeight)-\(letterSpacing)-\(backgroundOption.rawValue)-\(backgroundHex)-\(textOption.rawValue)-\(textHex)"
    }

    public var backgroundCSS: String { backgroundOption == .automatic ? "Canvas" : backgroundHex }
    public var textCSS: String { textOption == .automatic ? "CanvasText" : textHex }
    public var secondaryTextCSS: String {
        textOption == .automatic
            ? "color-mix(in srgb, CanvasText 65%, transparent)"
            : "color-mix(in srgb, \(textHex) 65%, transparent)"
    }
}

// MARK: - Color hex helpers

extension Color {
    public init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b: Double
        if cleaned.count == 6 {
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
        } else {
            r = 1; g = 1; b = 1
        }
        self = Color(.sRGB, red: r, green: g, blue: b)
    }

    public var hexString: String {
        #if canImport(AppKit)
        let native = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let r = Int((native.redComponent * 255).rounded())
        let g = Int((native.greenComponent * 255).rounded())
        let b = Int((native.blueComponent * 255).rounded())
        #else
        var rc: CGFloat = 0, gc: CGFloat = 0, bc: CGFloat = 0, ac: CGFloat = 0
        UIColor(self).getRed(&rc, green: &gc, blue: &bc, alpha: &ac)
        let r = Int((rc * 255).rounded())
        let g = Int((gc * 255).rounded())
        let b = Int((bc * 255).rounded())
        #endif
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
