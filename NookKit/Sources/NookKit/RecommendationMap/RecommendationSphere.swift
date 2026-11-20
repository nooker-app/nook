#if os(macOS)
import AppKit

/// Camera-relative depth cues. World positions and recommendation ranks never
/// change to produce this effect; rotating the camera changes which side is foggy.
struct RecommendationSphereStyle {
    let proximity: Double
    let radius: Double
    let opacity: Double
    let blurLevel: Int

    init(projection: RecommendationOrbit.Projection, sceneRadius: Double, zoom: Double) {
        let depth = min(1, max(0, 0.5 + projection.depth / max(1800, sceneRadius * 0.9)))
        proximity = depth * depth * (3 - 2 * depth)
        radius = min(16, max(1.8, (4 + sqrt(zoom) * 6) * pow(projection.scale, 1.1) * (0.6 + proximity)))
        opacity = 0.18 + proximity * 0.82
        blurLevel = Int(((1 - proximity) * Double(RecommendationSphereAtlas.levels - 1)).rounded())
    }
}

/// Small premultiplied sprites, shared by color and focus level, not by story.
/// Soft tonal depth and Gaussian convolution are baked once. Camera frames only blit
/// images in depth order; they never create gradients, filters or blur layers.
@MainActor
final class RecommendationSphereAtlas {
    nonisolated static let levels = 12
    nonisolated static let side = 96
    nonisolated static let sphereRadius = 24.0
    private var cache: [UInt32: [CGImage]] = [:]

    func palette(_ colors: [NSColor], dark: Bool) -> [[CGImage]] {
        colors.map { color in
            let rgb = color.usingColorSpace(.sRGB) ?? .gray
            let key = UInt32(dark ? 1 : 0) << 24
                | UInt32((rgb.redComponent * 255).rounded()) << 16
                | UInt32((rgb.greenComponent * 255).rounded()) << 8
                | UInt32((rgb.blueComponent * 255).rounded())
            if let images = cache[key] { return images }
            // The map has five topic colors. Bound retained variants as well
            // when the accent or system appearance changes during a session.
            if cache.count >= 16 { cache.removeAll(keepingCapacity: true) }
            let tint = SIMD3<Float>(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent))
            let images = Self.lightMaps.compactMap { map -> CGImage? in
                var pixels = [UInt8](repeating: 0, count: Self.side * Self.side * 4)
                for i in map.indices {
                    let sample = map[i], alpha = sample.x
                    // Content markers use a quiet translucent tint. Broad light
                    // and a fine rim replace the old point reflection and black
                    // hemisphere; neither appearance should resemble a marble.
                    let body = dark ? tint : tint * 0.86
                    let color = body * sample.y + SIMD3<Float>(repeating: sample.z * (dark ? 1 : 0.65))
                    for channel in 0..<3 { pixels[i * 4 + channel] = UInt8(min(alpha, max(0, color[channel])) * 255) }
                    pixels[i * 4 + 3] = UInt8(min(1, max(0, alpha)) * 255)
                }
                guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
                return CGImage(width: Self.side, height: Self.side, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: Self.side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            }
            cache[key] = images
            return images
        }
    }

    // x = opacity, y = premultiplied tint, z = premultiplied soft illumination.
    // Blurring these three channels before tinting is equivalent to blurring
    // each colored sphere, so the expensive work is shared by the entire palette.
    nonisolated private static let lightMaps: [[SIMD3<Float>]] = {
        var sharp = [SIMD3<Float>](repeating: .zero, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let nx = (Double(x) + 0.5 - Double(side) / 2) / sphereRadius
                let ny = (Double(y) + 0.5 - Double(side) / 2) / sphereRadius
                let squared = nx * nx + ny * ny
                guard squared < 1 else { continue }
                let nz = sqrt(1 - squared)
                let coverage = min(1, (1 - sqrt(squared)) * sphereRadius)
                let opacity = coverage * (0.76 + 0.14 * nz)
                let body = 0.78 + 0.12 * nz - 0.035 * nx - 0.055 * ny
                let wash = 0.11 * exp(-((nx + 0.3) * (nx + 0.3) / 0.75 + (ny + 0.38) * (ny + 0.38) / 0.65))
                let rim = 0.19 * pow(1 - nz, 5) * max(0, -0.45 * nx - 0.65 * ny + 0.15)
                let bounce = 0.035 * pow(1 - nz, 3) * max(0, 0.4 * nx + 0.7 * ny)
                sharp[y * side + x] = SIMD3(Float(opacity), Float(opacity * body), Float(opacity * (wash + rim + bounce)))
            }
        }
        return (0..<levels).map { level in
            guard level > 0 else { return sharp }
            let sigma = pow(Double(level) / Double(levels - 1), 1.4) * sphereRadius * 0.32
            let radius = max(1, Int(ceil(sigma * 3)))
            var weights = (-radius...radius).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
            let total = weights.reduce(0, +)
            weights = weights.map { $0 / total }
            var horizontal = sharp, output = sharp
            for y in 0..<side {
                for x in 0..<side {
                    var value = SIMD3<Float>.zero
                    for offset in -radius...radius where (0..<side).contains(x + offset) {
                        value += sharp[y * side + x + offset] * weights[offset + radius]
                    }
                    horizontal[y * side + x] = value
                }
            }
            for y in 0..<side {
                for x in 0..<side {
                    var value = SIMD3<Float>.zero
                    for offset in -radius...radius where (0..<side).contains(y + offset) {
                        value += horizontal[(y + offset) * side + x] * weights[offset + radius]
                    }
                    output[y * side + x] = value
                }
            }
            return output
        }
    }()
}
#endif
