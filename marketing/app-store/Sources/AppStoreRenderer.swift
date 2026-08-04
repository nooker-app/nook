#!/usr/bin/env swift

import AppKit
import CoreText
import Foundation

struct Configuration: Decodable {
    let locales: [String]
    let iphone: Platform
    /// The same slides drawn again at another size.
    ///
    /// App Store Connect has a slot per display class and each accepts only its own
    /// dimensions: the 6.9-inch slot takes 1290×2796, the 6.5-inch one refuses it and
    /// asks for 1284×2778. One set cannot satisfy both, and resampling a finished
    /// screenshot to fit would resize the text with it. Re-rendering lays the frame
    /// and the copy out at the target size instead.
    let iphoneExtraSizes: [ExtraSize]?
    let ipad: Platform
    let macos: Platform
}

/// An additional canvas for slides that are already defined, so the definitions are
/// not duplicated per size — five slides in four languages is not something to keep
/// in two places.
struct ExtraSize: Decodable {
    let name: String
    let width: Int
    let height: Int
}

struct Platform: Decodable {
    let width: Int
    let height: Int
    let slides: [Slide]
}

struct Slide: Decodable {
    let id: String
    let source: String
    let localizedSources: [String: String]?
    let crop: Crop?
    let localized: [String: Copy]
}

struct Crop: Decodable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

struct Copy: Decodable {
    let title: String
    let subtitle: String
}

enum RenderError: LocalizedError {
    case usage
    case missingCopy(slide: String, locale: String)
    case missingImage(String)
    case invalidImage(String)
    case invalidCrop(String)
    case cannotCreateCanvas
    case cannotEncode(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: AppStoreRenderer.swift <config.json> <output-directory>"
        case let .missingCopy(slide, locale):
            return "Missing copy for locale '\(locale)' in slide '\(slide)'"
        case let .missingImage(path):
            return "Screenshot not found: \(path)"
        case let .invalidImage(path):
            return "Could not decode screenshot: \(path)"
        case let .invalidCrop(slide):
            return "Crop must stay inside the source image for slide '\(slide)'"
        case .cannotCreateCanvas:
            return "Could not create a bitmap canvas"
        case let .cannotEncode(path):
            return "Could not encode PNG: \(path)"
        }
    }
}

private let arguments = CommandLine.arguments
guard arguments.count == 3 else { throw RenderError.usage }

let configURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
let repositoryURL = configURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

let configuration = try JSONDecoder().decode(
    Configuration.self,
    from: Data(contentsOf: configURL)
)

let renderer = Renderer(repositoryURL: repositoryURL, outputURL: outputURL)
try renderer.render(configuration: configuration)

final class Renderer {
    private let repositoryURL: URL
    private let outputURL: URL
    private let fileManager = FileManager.default

    private let ink = NSColor(hex: 0xFFF8EA)
    private let mutedInk = NSColor(hex: 0xD6C6AA)
    private let gold = NSColor(hex: 0xE5AA61)
    private let border = NSColor(hex: 0xE5AA61, alpha: 0.34)

    init(repositoryURL: URL, outputURL: URL) {
        self.repositoryURL = repositoryURL
        self.outputURL = outputURL
    }

    func render(configuration: Configuration) throws {
        try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

        for locale in configuration.locales {
            try render(
                platform: configuration.iphone,
                platformName: "iphone-6.9",
                locale: locale,
                style: .iphone
            )
            for extra in configuration.iphoneExtraSizes ?? [] {
                try render(
                    platform: Platform(
                        width: extra.width,
                        height: extra.height,
                        slides: configuration.iphone.slides
                    ),
                    platformName: extra.name,
                    locale: locale,
                    style: .iphone
                )
            }
            try render(
                platform: configuration.ipad,
                platformName: "ipad-13",
                locale: locale,
                style: .ipad
            )
            try render(
                platform: configuration.macos,
                platformName: "mac",
                locale: locale,
                style: .mac
            )
        }
    }

    private func render(
        platform: Platform,
        platformName: String,
        locale: String,
        style: Style
    ) throws {
        let directory = outputURL
            .appendingPathComponent(locale, isDirectory: true)
            .appendingPathComponent(platformName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        for slide in platform.slides {
            guard let copy = slide.localized[locale] else {
                throw RenderError.missingCopy(slide: slide.id, locale: locale)
            }
            if let crop = slide.crop,
               crop.x < 0 || crop.y < 0 || crop.width <= 0 || crop.height <= 0 ||
               crop.x + crop.width > 1 || crop.y + crop.height > 1 {
                throw RenderError.invalidCrop(slide.id)
            }

            let sourcePath = slide.localizedSources?[locale] ?? slide.source
            let sourceURL = repositoryURL.appendingPathComponent(sourcePath)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw RenderError.missingImage(sourceURL.path)
            }
            guard let image = NSImage(contentsOf: sourceURL) else {
                throw RenderError.invalidImage(sourceURL.path)
            }

            let bitmapContext = try makeCanvas(width: platform.width, height: platform.height)
            let context = NSGraphicsContext(cgContext: bitmapContext, flipped: false)
            guard bitmapContext.width == platform.width, bitmapContext.height == platform.height else {
                throw RenderError.cannotCreateCanvas
            }

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            drawBackground(width: platform.width, height: platform.height)
            switch style {
            case .iphone:
                drawIPhone(image: image, crop: slide.crop, copy: copy, width: platform.width, height: platform.height)
            case .ipad:
                drawIPad(image: image, crop: slide.crop, copy: copy, width: platform.width, height: platform.height)
            case .mac:
                drawMac(image: image, crop: slide.crop, copy: copy, width: platform.width, height: platform.height)
            }
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()

            let destination = directory.appendingPathComponent("\(slide.id).png")
            guard let cgImage = bitmapContext.makeImage() else {
                throw RenderError.cannotCreateCanvas
            }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let data = bitmap.representation(using: .png, properties: [.compressionFactor: 0.9]) else {
                throw RenderError.cannotEncode(destination.path)
            }
            try data.write(to: destination, options: .atomic)
            print("Rendered \(destination.path)")
        }
    }

    private func makeCanvas(width: Int, height: Int) throws -> CGContext {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw RenderError.cannotCreateCanvas
        }
        return context
    }

    private func drawBackground(width: Int, height: Int) {
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        NSGradient(
            starting: NSColor(hex: 0x17130E),
            ending: NSColor(hex: 0x2C2116)
        )?.draw(in: bounds, angle: 72)

        let glow = NSBezierPath(ovalIn: NSRect(
            x: CGFloat(width) * 0.58,
            y: CGFloat(height) * 0.60,
            width: CGFloat(width) * 0.62,
            height: CGFloat(width) * 0.62
        ))
        NSColor(hex: 0xD9974B, alpha: 0.08).setFill()
        glow.fill()

        let line = NSBezierPath()
        line.move(to: NSPoint(x: CGFloat(width) * 0.08, y: CGFloat(height) * 0.91))
        line.line(to: NSPoint(x: CGFloat(width) * 0.92, y: CGFloat(height) * 0.91))
        line.lineWidth = 2
        NSColor(hex: 0xE5AA61, alpha: 0.16).setStroke()
        line.stroke()
    }

    private func drawIPhone(image: NSImage, crop: Crop?, copy: Copy, width: Int, height: Int) {
        drawBrand(at: NSPoint(x: 112, y: topY(132, height: height)), fontSize: 33)

        drawText(
            copy.title,
            rect: topRect(x: 112, y: 220, width: 1066, height: 220, canvasHeight: height),
            font: .systemFont(ofSize: 78, weight: .bold),
            color: ink,
            lineHeight: 1.03
        )
        drawText(
            copy.subtitle,
            rect: topRect(x: 112, y: 468, width: 1066, height: 105, canvasHeight: height),
            font: .systemFont(ofSize: 35, weight: .medium),
            color: mutedInk,
            lineHeight: 1.12
        )

        let screenshotRect = topRect(
            x: 118,
            y: 650,
            width: 1054,
            height: 2285,
            canvasHeight: height
        )
        drawScreenshot(image, crop: crop, in: screenshotRect, cornerRadius: 70, shadowBlur: 42)
    }

    private func drawMac(image: NSImage, crop: Crop?, copy: Copy, width: Int, height: Int) {
        drawBrand(at: NSPoint(x: 150, y: topY(142, height: height)), fontSize: 38)

        drawText(
            copy.title,
            rect: topRect(x: 150, y: 295, width: 690, height: 440, canvasHeight: height),
            font: .systemFont(ofSize: 102, weight: .bold),
            color: ink,
            lineHeight: 0.98
        )
        drawText(
            copy.subtitle,
            rect: topRect(x: 150, y: 810, width: 650, height: 220, canvasHeight: height),
            font: .systemFont(ofSize: 42, weight: .medium),
            color: mutedInk,
            lineHeight: 1.18
        )

        let screenshotRect = topRect(
            x: 875,
            y: 235,
            width: 1885,
            height: 1288,
            canvasHeight: height
        )
        drawScreenshot(image, crop: crop, in: screenshotRect, cornerRadius: 54, shadowBlur: 46)
    }

    private func drawIPad(image: NSImage, crop: Crop?, copy: Copy, width: Int, height: Int) {
        drawBrand(at: NSPoint(x: 128, y: topY(128, height: height)), fontSize: 31)

        drawText(
            copy.title,
            rect: topRect(x: 128, y: 210, width: 1792, height: 210, canvasHeight: height),
            font: .systemFont(ofSize: 82, weight: .bold),
            color: ink,
            lineHeight: 1.02
        )
        drawText(
            copy.subtitle,
            rect: topRect(x: 128, y: 445, width: 1792, height: 96, canvasHeight: height),
            font: .systemFont(ofSize: 36, weight: .medium),
            color: mutedInk,
            lineHeight: 1.12
        )

        let screenshotRect = topRect(
            x: 32,
            y: 720,
            width: 1984,
            height: 2646,
            canvasHeight: height
        )
        drawScreenshot(image, crop: crop, in: screenshotRect, cornerRadius: 48, shadowBlur: 42)
    }

    private func drawBrand(at point: NSPoint, fontSize: CGFloat) {
        let dot = NSBezierPath(ovalIn: NSRect(
            x: point.x,
            y: point.y - fontSize * 0.14,
            width: fontSize * 0.42,
            height: fontSize * 0.42
        ))
        gold.setFill()
        dot.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: mutedInk,
            .kern: fontSize * 0.08
        ]
        NSString(string: "NOOK").draw(at: NSPoint(x: point.x + fontSize * 0.72, y: point.y - fontSize * 0.43), withAttributes: attributes)
    }

    private func drawText(
        _ text: String,
        rect: NSRect,
        font: NSFont,
        color: NSColor,
        lineHeight: CGFloat
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.minimumLineHeight = font.pointSize * lineHeight
        paragraph.maximumLineHeight = font.pointSize * lineHeight
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .kern: -font.pointSize * 0.018
        ]
        guard let cgContext = NSGraphicsContext.current?.cgContext else { return }
        cgContext.saveGState()
        cgContext.textMatrix = .identity
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
        CTFrameDraw(frame, cgContext)
        cgContext.restoreGState()
    }

    private func drawScreenshot(
        _ image: NSImage,
        crop: Crop?,
        in rect: NSRect,
        cornerRadius: CGFloat,
        shadowBlur: CGFloat
    ) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.56)
        shadow.shadowBlurRadius = shadowBlur
        shadow.shadowOffset = NSSize(width: 0, height: -18)
        shadow.set()
        NSColor(hex: 0x0B0907).setFill()
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
        let sourceRect = sourceRect(for: image, crop: crop)
        image.draw(in: rect, from: sourceRect, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()

        border.setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: cornerRadius, yRadius: cornerRadius)
        outline.lineWidth = 3
        outline.stroke()
    }

    private func sourceRect(for image: NSImage, crop: Crop?) -> NSRect {
        guard let crop else {
            return NSRect(origin: .zero, size: image.size)
        }
        return NSRect(
            x: crop.x * image.size.width,
            y: (1 - crop.y - crop.height) * image.size.height,
            width: crop.width * image.size.width,
            height: crop.height * image.size.height
        )
    }

    private func topRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, canvasHeight: Int) -> NSRect {
        NSRect(x: x, y: CGFloat(canvasHeight) - y - height, width: width, height: height)
    }

    private func topY(_ y: CGFloat, height: Int) -> CGFloat {
        CGFloat(height) - y
    }
}

enum Style {
    case iphone
    case ipad
    case mac
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
