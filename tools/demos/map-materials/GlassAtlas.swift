import AppKit
import CoreImage

/// Demo-only material sprites. The real canvas still owns depth, LOD and picking.
/// This approximates optical cues; system Liquid Glass is used by the controls.
@MainActor final class DemoGlassAtlas {
    private var cache: [Int: [CGImage]] = [:]
    private let context = CIContext(options: [.cacheIntermediates: false])

    func images(material: DemoMaterial, dark: Bool, sample: Bool = false) -> [CGImage] {
        let key = material.rawValue * 4 + (dark ? 1 : 0) + (sample ? 2 : 0)
        if let images = cache[key] { return images }
        let side = sample ? 384 : RecommendationSphereAtlas.side
        let radius = sample ? 96.0 : RecommendationSphereAtlas.sphereRadius
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let amber = dark ? SIMD3<Double>(0.92, 0.70, 0.42) : SIMD3<Double>(0.58, 0.35, 0.13)
        let pearl = dark ? SIMD3<Double>(1, 0.96, 0.85) : SIMD3<Double>(0.42, 0.29, 0.16)
        for y in 0..<side {
            for x in 0..<side {
                let nx = (Double(x) + 0.5 - Double(side) / 2) / radius
                let ny = (Double(y) + 0.5 - Double(side) / 2) / radius
                let r = hypot(nx, ny)
                guard r < 1.18 else { continue }
                var rgb = SIMD3<Double>.zero, alpha = 0.0
                func layer(_ color: SIMD3<Double>, _ amount: Double) {
                    let a = min(1, max(0, amount))
                    rgb = color * a + rgb * (1 - a)
                    alpha = a + alpha * (1 - a)
                }
                let coverage = min(1, max(0, (1 - r) * radius))
                let halo = material == .halo
                let top = max(0, (-nx * 0.48 - ny * 0.75) / max(0.01, r))
                let bottom = max(0, (nx * 0.45 + ny * 0.78) / max(0.01, r))
                let rim = exp(-pow((r - 0.955) / 0.036, 2))
                let inner = exp(-pow((r - 0.87) / 0.10, 2))
                let wash = exp(-pow((nx + 0.30) / 0.8, 2) - pow((ny + 0.45) / 0.7, 2))
                layer(amber, exp(-pow((r - 0.99) / 0.10, 2)) * (halo ? 0.08 : 0.045))
                layer(amber, coverage * (halo ? 0.025 : 0.065 + max(0, ny) * 0.06))
                layer(pearl, coverage * wash * (halo ? 0.018 : 0.12))
                layer(amber, inner * bottom * (halo ? 0.08 : 0.30) * coverage)
                layer(pearl, rim * (0.11 + top * (halo ? 0.48 : 0.72)))
                layer(amber, rim * bottom * (halo ? 0.33 : 0.55))
                if halo {
                    layer(amber, exp(-r*r / 0.13) * 0.14)
                    layer(amber, min(1, max(0, (0.15 - r) * radius)) * 0.85)
                    layer(pearl, exp(-r*r / 0.004) * 0.5)
                }
                let i = (y * side + x) * 4
                for channel in 0..<3 { bytes[i + channel] = UInt8(min(alpha, max(0, rgb[channel])) * 255) }
                bytes[i + 3] = UInt8(alpha * 255)
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        let input = CIImage(cgImage: image)
        let images = (0..<(sample ? 1 : RecommendationSphereAtlas.levels)).map { level -> CGImage in
            guard level > 0 else { return image }
            let sigma = pow(Double(level) / 11, 1.4) * radius * 0.32
            return context.createCGImage(input.applyingGaussianBlur(sigma: sigma), from: input.extent)!
        }
        cache[key] = images
        return images
    }
}
