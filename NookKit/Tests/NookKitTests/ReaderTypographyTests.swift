import Foundation
import SwiftUI
import Testing
@testable import NookKit

#if canImport(AppKit)
import AppKit
private typealias PlatformFont = NSFont
#elseif canImport(UIKit)
import UIKit
private typealias PlatformFont = UIFont
#endif

/// The native reader's typography contract: settings resolve into one clamped,
/// derived-value struct; both import paths bake the same fonts and kern from
/// it; and the render cache can never serve a stale style.
@Suite("Reader typography")
struct ReaderTypographyTests {
    private func typography(
        font: ReaderFont = .system,
        size: CGFloat = 18,
        lineHeight: Double = 1.7,
        letterSpacing: Double = 0
    ) -> ReaderTypography {
        ReaderTypography(
            font: font, fontSize: size,
            lineHeightMultiple: lineHeight, letterSpacingEM: letterSpacing
        )
    }

    // MARK: - Resolution and stability guarantees

    @Test("Settings resolve to clamped, non-degenerate rendering values")
    func settingsResolve() {
        let resolved = typography(font: .serif, size: 18, lineHeight: 1.7, letterSpacing: 0.05)

        #expect(resolved.bodySize == 18)
        // 1.7 line height at 18pt = (1.7 − 1.2) × 18 = 9pt of leading.
        #expect(resolved.lineSpacing == 9)
        // 0.05em kern at 18pt = 0.9pt.
        #expect(resolved.kern == 0.9)
        #expect(resolved.fontDesign == .serif)
    }

    @Test("Hostile stored values cannot produce overlap or collapsed glyphs")
    func hostileValuesAreClamped() {
        // Line overlap comes from negative leading; glyph collapse from a large
        // negative kern. Neither can escape the clamps, no matter what ends up
        // in UserDefaults.
        let squeezed = typography(size: 400, lineHeight: 0.1, letterSpacing: -9)

        #expect(squeezed.bodySize == ReaderTypography.sizeRange.upperBound)
        #expect(squeezed.lineSpacing >= 0)
        #expect(squeezed.kern >= ReaderTypography.letterSpacingRange.lowerBound * squeezed.bodySize)

        let stretched = typography(size: 1, lineHeight: 99, letterSpacing: 9)
        #expect(stretched.bodySize == ReaderTypography.sizeRange.lowerBound)
        // Max spread stays bounded: ≤ (3.0 − 1.2) × size leading, ≤ 0.3em kern.
        #expect(stretched.lineSpacing <= (ReaderTypography.lineHeightRange.upperBound - 1.2) * stretched.bodySize + 1)
        #expect(stretched.kern <= ReaderTypography.letterSpacingRange.upperBound * stretched.bodySize)
    }

    @Test("The platform default reproduces the reader's historical appearance")
    func platformDefaultIsStable() {
        let historical = ReaderTypography.platformDefault

        #expect(historical.bodySize == ReaderTypography.platformBodySize)
        #expect(historical.lineSpacing == 4)
        #expect(historical.kern == 0)
        #expect(historical.design == .system)
        // …and contributes nothing to cache keys, so pre-existing entries and
        // non-reader surfaces keep their exact keys.
        #expect(historical.attributedCacheToken.isEmpty)
    }

    @Test("Headings keep native proportions at any body size")
    func headingScaling() {
        let baseline = ReaderTypography.platformDefault
        // At the default body size, headings are exactly the platform sizes.
        for level in 1...6 {
            #expect(baseline.headingSize(level) == HTMLContentText.headingSize(level))
        }
        // At a doubled body size, every heading scales by the same factor and
        // the hierarchy stays strictly non-increasing (no level outgrows its
        // parent, which would read as broken structure).
        let doubled = typography(size: baseline.bodySize * 2)
        for level in 1...5 {
            #expect(doubled.headingSize(level) >= doubled.headingSize(level + 1))
            #expect(doubled.headingSize(level) > baseline.headingSize(level))
        }
    }

    // MARK: - Cache correctness

    @Test("Every attributed-string-changing input is in the render cache key")
    func cacheKeyCoversTypography() {
        let html = "<b>x</b>"
        let plain = HTMLTextFlow.cacheKey(html: html, baseSize: 18, bold: false, typography: typography())
        let serif = HTMLTextFlow.cacheKey(html: html, baseSize: 18, bold: false, typography: typography(font: .serif))
        let kerned = HTMLTextFlow.cacheKey(html: html, baseSize: 18, bold: false, typography: typography(letterSpacing: 0.05))

        #expect(plain != serif)
        #expect(plain != kerned)
        #expect(serif != kerned)

        // Line height is a view modifier, never baked into the attributed
        // string — two styles differing only in line height MUST share a key,
        // or every leading tweak would re-import the whole article.
        let airy = HTMLTextFlow.cacheKey(html: html, baseSize: 18, bold: false, typography: typography(lineHeight: 2.4))
        #expect(plain == airy)
    }

    // MARK: - Import parity (both paths must bake the same style)

    private func fonts(of attributed: AttributedString) -> [(text: String, font: PlatformFont)] {
        attributed.runs.compactMap { run in
            #if canImport(AppKit)
            guard let font = run.appKit.font else { return nil }
            #else
            guard let font = run.uiKit.font else { return nil }
            #endif
            return (String(attributed.characters[run.range]), font)
        }
    }

    @Test("The native importer bakes the serif design, the size, and the kern")
    func nativeImportHonorsTypography() throws {
        let style = typography(font: .serif, size: 21, letterSpacing: 0.05)
        let rendered = try #require(NativeInlineHTMLRenderer.importPrepared(
            HTMLTextFlow.preparedHTML("Plain <b>bold</b> and <code>mono()</code>"),
            baseSize: style.bodySize, bold: false, typography: style
        ))

        for (text, font) in fonts(of: rendered) {
            if text.contains("mono") {
                // Code spans never follow the reader family: they stay the shared
                // monospaced code font at the code ratio.
                #expect(font == HTMLContentText.finalCodeFont(baseSize: style.bodySize, bold: false))
            } else {
                #expect(font.pointSize == style.bodySize)
                #if canImport(AppKit)
                let serifFont = HTMLContentText.applying(design: .serif, to: NSFont.systemFont(ofSize: style.bodySize), size: style.bodySize)
                #else
                let serifFont = HTMLContentText.applying(design: .serif, to: UIFont.systemFont(ofSize: style.bodySize), size: style.bodySize)
                #endif
                #expect(font.familyName == serifFont.familyName)
            }
        }

        // Kern is applied across the whole string (0.05em × 21pt ≈ 1.05 → 1.1
        // after the 0.1pt quantization).
        for run in rendered.runs {
            #if canImport(AppKit)
            #expect(run.appKit.kern == style.kern)
            #else
            #expect(run.uiKit.kern == style.kern)
            #endif
        }
    }

    @MainActor
    @Test("Both import paths produce identical typography for the same fragment")
    func importPathsAgree() throws {
        // Headless CI can't run the WebKit importer; skip like the existing
        // differential suite does rather than fail.
        guard HTMLContentText.webKitImport("<b>x</b>", baseSize: 16, bold: false) != nil else { return }

        let style = typography(font: .serif, size: 19, letterSpacing: 0.02)
        let fragment = HTMLTextFlow.preparedHTML("A <em>styled</em> <b>fragment</b> with <code>code()</code>")

        let native = try #require(NativeInlineHTMLRenderer.importPrepared(
            fragment, baseSize: style.bodySize, bold: false, typography: style
        ))
        let webKit = try #require(HTMLContentText.webKitImport(
            fragment, baseSize: style.bodySize, bold: false, typography: style
        ))

        #expect(String(native.characters) == String(webKit.characters))
        let nativeFonts = fonts(of: native).map { "\($0.text)|\($0.font.fontName)|\($0.font.pointSize)" }
        let webKitFonts = fonts(of: webKit).map { "\($0.text)|\($0.font.fontName)|\($0.font.pointSize)" }
        #expect(nativeFonts == webKitFonts)
    }
}
