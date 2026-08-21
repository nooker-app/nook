#if os(macOS)
import AppKit
import SwiftUI
import Testing

@testable import NookKit

/// What the reader draws an image at.
///
/// `resizable()` means "fill whatever you are given", and the article column gives an
/// image the full width — so a small icon or diagram was drawn six hundred points
/// wide. The rule is a ceiling rather than a target, and these measure it at the two
/// sizes that matter: smaller than the column, and larger.
@Suite("Article image fit", .serialized)
@MainActor
struct ArticleImageFitTests {
    /// An opaque image of an exact pixel size, at scale 1 — so its natural size in
    /// points is its size in pixels, which is what an image fetched from a page is.
    static func image(width: Int, height: Int) -> SwiftUI.Image {
        let nsImage = NSImage(size: NSSize(width: width, height: height))
        nsImage.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        nsImage.unlockFocus()
        return SwiftUI.Image(nsImage: nsImage)
    }

    /// The size the image is *drawn* at inside a column, read off the rendered
    /// pixels rather than off a frame.
    ///
    /// A frame is not the answer to this question: the view can legitimately occupy a
    /// box wider than the picture it draws in it, and the complaint being tested is
    /// about the picture. So the view is rendered at scale 1 into a bitmap and the
    /// opaque region measured — which is what a reader actually sees.
    static func drawnSize(
        pixels: (width: Int, height: Int), column: CGFloat = 600,
        aspectRatio: CGFloat? = nil, declaredWidth: CGFloat? = nil
    ) -> CGSize {
        let view = FittedArticleImage(
            image: image(width: pixels.width, height: pixels.height),
            aspectRatio: aspectRatio, declaredWidth: declaredWidth)
        let renderer = ImageRenderer(
            content: HStack(spacing: 0) {
                view
                Spacer(minLength: 0)
            }
            .frame(width: column)
            .background(Color.clear))
        renderer.scale = 1
        guard let rendered = renderer.nsImage,
              let tiff = rendered.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return .zero }

        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y), colour.alphaComponent > 0.5
                else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return .zero }
        return CGSize(width: maxX - minX + 1, height: maxY - minY + 1)
    }

    @Test("an image smaller than the column is drawn at its own size")
    func smallImageIsNotStretched() {
        let drawn = Self.drawnSize(pixels: (64, 32))
        #expect(drawn.width == 64, "drawn \(Int(drawn.width))pt wide for a 64px image")
        #expect(drawn.height == 32)
    }

    @Test("an image wider than the column is scaled down to it")
    func largeImageIsScaledDown() {
        let drawn = Self.drawnSize(pixels: (1200, 600))
        #expect(drawn.width == 600)
        #expect(drawn.height == 300, "aspect ratio kept: \(drawn)")
    }

    @Test("the declared width is a ceiling, and never a size to grow to")
    func declaredWidthOnlyLimits() {
        // Declared narrower than the column: the ceiling applies.
        let limited = Self.drawnSize(pixels: (1200, 600), declaredWidth: 300)
        #expect(limited.width == 300)
        #expect(limited.height == 150)

        // Declared wider than the image: still drawn at its own size, not grown.
        let small = Self.drawnSize(pixels: (64, 32), declaredWidth: 500)
        #expect(small.width == 64, "a declared width must not upscale: \(small)")
        #expect(small.height == 32)
    }

    /// The parse side of the ceiling: a numeric `width` is kept, a relative one is not.
    @Test("a numeric width attribute is kept and a relative one ignored")
    func declaredWidthIsParsed() {
        func media(_ tag: String) -> HTMLMedia? {
            let blocks = HTMLContentParser.parse(
                "<p>before</p>\(tag)<p>after</p>", baseURL: URL(string: "https://example.com"))
            for block in blocks {
                if case .image(let media) = block { return media }
            }
            return nil
        }
        #expect(media(#"<img src="/a.png" width="64" height="32">"#)?.declaredWidth == 64)
        #expect(media(#"<img src="/a.png" width="100%">"#)?.declaredWidth == nil)
        #expect(media(#"<img src="/a.png" width="0" height="0">"#)?.declaredWidth == nil)
        #expect(media(#"<img src="/a.png">"#)?.declaredWidth == nil)
    }
}
#endif
