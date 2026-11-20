#if os(macOS)
import Foundation

/// A bounded local relaxation of real, provisional connections. The full hybrid
/// graph is built only once at completion. Camera coordinates never enter here.
struct RecommendationFormationLayout: Sendable {
    private var positions: [String: CGPoint]
    private var neighbors: [String: Set<String>] = [:]
    private var pending = Set<String>()

    init(positions: [String: CGPoint]) { self.positions = positions }

    mutating func add(_ edges: [RecommendationMapEdge], activated: [String]) {
        pending.formUnion(activated)
        for edge in edges {
            neighbors[edge.a, default: []].insert(edge.b)
            neighbors[edge.b, default: []].insert(edge.a)
            pending.insert(edge.a);pending.insert(edge.b)
        }
    }

    mutating func relax() -> [String: CGPoint] {
        let seeds = pending.sorted().prefix(256)
        pending.subtract(seeds)
        var active = Set(seeds)
        for id in seeds { active.formUnion((neighbors[id] ?? []).sorted().prefix(12)) }
        let moving = active.sorted().filter { positions[$0] != nil && !(neighbors[$0] ?? []).isEmpty }.prefix(512)
        pending.subtract(moving)
        guard !moving.isEmpty, !Task.isCancelled else { return [:] }
        let ids = positions.keys.sorted()
        let indices = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        var points = ids.map { positions[$0]! }
        var grid = RecommendationSpatialGrid(cell: 240)
        for i in points.indices { grid.insert(i, points[i]) }
        let movingIndices = moving.compactMap { indices[$0] }
        let links = Dictionary(uniqueKeysWithValues: movingIndices.map { i in
            (i, (neighbors[ids[i]] ?? []).sorted().prefix(16).compactMap { indices[$0] })
        })
        for _ in 0..<16 {
            if Task.isCancelled { return [:] }
            for i in movingIndices {
                let p = points[i]
                var force = CGPoint.zero
                let adjacent = links[i] ?? []
                for j in adjacent {
                    let dx = points[j].x-p.x, dy = points[j].y-p.y, d = max(1, hypot(dx,dy))
                    let pull = (d-185) * 0.10 / Double(max(1, adjacent.count))
                    force.x += dx/d*pull;force.y += dy/d*pull
                }
                for j in grid.query(CGRect(x:p.x-150,y:p.y-150,width:300,height:300)).sorted() where j != i {
                    let dx=p.x-points[j].x,dy=p.y-points[j].y,d=max(1,hypot(dx,dy))
                    if d<150 { force.x += dx/d*(150-d)*0.15;force.y += dy/d*(150-d)*0.15 }
                }
                let length = hypot(force.x, force.y), scale = length > 90 ? 90/length : 1
                let q = CGPoint(x:p.x+force.x*scale,y:p.y+force.y*scale)
                points[i]=q;grid.move(i,from:p,to:q)
            }
        }
        var changed: [String: CGPoint] = [:]
        for i in movingIndices { positions[ids[i]]=points[i];changed[ids[i]]=points[i] }
        return changed
    }
}
#endif
