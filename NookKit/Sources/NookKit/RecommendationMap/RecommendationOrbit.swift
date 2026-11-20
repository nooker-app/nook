import Foundation

/// Perspective geometry shared by drawing, selection and focus. There is still
/// one native surface, never an entity or SwiftUI view for every story.
struct RecommendationOrbit {
    struct Projection {
        let point: CGPoint
        let depth: Double
        let scale: Double
    }

    var yaw = -0.38
    var pitch = 0.28

    mutating func rotate(x: Double, y: Double) {
        yaw = (yaw + x).truncatingRemainder(dividingBy: .pi * 2)
        pitch = min(.pi * 0.46, max(-.pi * 0.46, pitch + y))
    }

    /// Stable content communities share a depth, with local spread inside them.
    /// Filters, read flags and recommendation rank never enter this function.
    static func depthSeed(id: String, community: String) -> (Double, Double) {
        func unit(_ value: String) -> Double {
            let hash = value.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
            return Double(hash % 65_521) / 65_520 * 2 - 1
        }
        return (unit(community.isEmpty ? id : community), unit(id + "depth"))
    }

    static func depth(at point: CGPoint, seed: (Double, Double)) -> Double {
        seed.0 * max(900, hypot(point.x, point.y) * 0.75) + seed.1 * 220
    }

    func project(_ points: [CGPoint], seeds: [(Double, Double)], center: CGPoint, radius: Double, centerDepth: Double = 0) -> [Projection] {
        let cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch)
        let distance = max(1800, radius * 3.2)
        return points.indices.map { i in
            let x = points[i].x - center.x, y = points[i].y - center.y
            let z = Self.depth(at: points[i], seed: seeds[i]) - centerDepth
            let rx = cy * x + sy * z, rz = -sy * x + cy * z
            let ry = cp * y - sp * rz, depth = sp * y + cp * rz
            let scale = distance / max(distance * 0.15, distance - depth)
            return Projection(point: CGPoint(x: center.x + rx * scale, y: center.y + ry * scale),
                              depth: depth, scale: scale)
        }
    }
}
