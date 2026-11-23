#if os(macOS)
import AppKit
import SwiftUI
import QuartzCore
import CoreText

struct RecommendationGridKey: Hashable { let x:Int;let y:Int }
struct RecommendationSpatialGrid {
    var cells:[RecommendationGridKey:Set<Int>]=[:]
    let cell:Double
    func key(_ p:CGPoint)->RecommendationGridKey {RecommendationGridKey(x:Int(floor(p.x/cell)),y:Int(floor(p.y/cell)))}
    mutating func insert(_ i:Int,_ p:CGPoint){cells[key(p),default:[]].insert(i)}
    mutating func move(_ i:Int,from:CGPoint,to:CGPoint){let a=key(from),b=key(to);if a != b {cells[a]?.remove(i);cells[b,default:[]].insert(i)}}
    func query(_ r:CGRect)->[Int] {
        let a=key(r.origin),b=key(CGPoint(x:r.maxX,y:r.maxY))
        if (b.x-a.x+1)*(b.y-a.y+1)>cells.count*3 {return cells.flatMap { cell,items in
            let box=CGRect(x:Double(cell.x)*self.cell,y:Double(cell.y)*self.cell,width:self.cell,height:self.cell)
            return box.intersects(r) ? Array(items):[]
        }}
        var result:[Int]=[]
        for x in a.x...b.x {for y in a.y...b.y {if let items=cells[RecommendationGridKey(x:x,y:y)]{result.append(contentsOf:items)}}}
        return result
    }
}
struct RecommendationMapBucket {var center:CGPoint;var count:Int;var first:Int;var bounds:CGRect}
struct RecommendationMapOverview: Equatable {
    var points: [CGPoint] = []
    var viewport = CGRect(x: 0, y: 0, width: 1, height: 1)
    var selected: CGPoint?
    var canGoBack = false
    var percent = 100
}
private struct RecommendationCameraPosition {
    var zoom: Double
    var pan: CGPoint
    var orbit: RecommendationOrbit
    var center: CGPoint
    var centerDepth: Double
}
@MainActor @Observable final class RecommendationCanvasControl {
    weak var view: RecommendationCanvasView?
    var overview = RecommendationMapOverview()
    func zoom(_ factor:Double){view?.navigateZoom(factor)}
    func fit(){view?.navigateToFit()}
    func focus(){view?.focusSelection()}
    func back(){view?.navigateBack()}
    func resetDirection(){view?.resetDirection()}
}
struct RecommendationCanvasHost:NSViewRepresentable {
    var model:RecommendationMapController
    var control:RecommendationCanvasControl
    var reduceMotion:Bool
    var spatial = true
    func makeNSView(context:Context)->RecommendationCanvasView {
        let view=RecommendationCanvasView();control.view=view
        view.onSelect={id in model.select(id)}
        view.onOpen={model.openSelected()}
        view.onOverview={snapshot in if control.overview != snapshot {control.overview=snapshot}}
        return view
    }
    func updateNSView(_ view:RecommendationCanvasView,context:Context){
        view.reduceMotion=reduceMotion;view.interactionEnabled=model.isInteractive
        guard model.isInteractive else { return }
        view.setSpatial(spatial)
        let changedCollection = view.collection != model.collection
        view.collection = model.collection
        if view.revision != model.graphRevision {view.install(model.graph,revision:model.graphRevision,layoutRevision:model.layoutRevision,forming:model.formation.active)}
        view.updateFormation(model.formation, revision: model.formationRevision)
        view.updateSelection(model.selectedID)
        if changedCollection { view.clearCameraHistory(); view.fit(animated: true) }
        if view.topic != model.topic || view.focusOnly != model.focus {view.topic=model.topic;view.focusOnly=model.focus;view.needsDisplay=true}
    }
}

/// One native drawing surface. A world-space index virtualizes hit testing and
/// visible geometry; multiresolution buckets cap the zoomed-out draw workload.
@MainActor final class RecommendationCanvasView:NSView {
    override var isFlipped:Bool {true}
    override var acceptsFirstResponder:Bool {true}
    var onSelect:((String)->Void)?
    var onOpen:(()->Void)?
    var onOverview:((RecommendationMapOverview)->Void)?
    var reduceMotion=false {
        didSet { if reduceMotion { momentum = .zero; orbitVelocity = .zero } }
    }
    var interactionEnabled=true {
        didSet {
            if !interactionEnabled {
                timer?.invalidate();timer=nil;cameraAnimation=nil;momentum = .zero
                activePhysics.removeAll();dragIndex=nil;hovered=nil;orbitVelocity = .zero
            }
        }
    }
    var revision = -1
    private var layoutRevision = -1
    var collection:SmartSource?
    var topic:String?
    var focusOnly=false
    private var nodes:[RecommendationMapNode]=[]
    private var edges:[RecommendationMapEdge]=[]
    private var lookup:[String:Int]=[:]
    private var positions:[CGPoint]=[]
    private var spatial = false
    private var orbit = RecommendationOrbit()
    private var orbitVelocity = CGPoint.zero
    private var orbitPanning = false
    private var depthSeeds: [(Double, Double)] = []
    private var projected: [RecommendationOrbit.Projection] = []
    private var projectedIndex = RecommendationSpatialGrid(cell: 240)
    private var projectionDirty = true
    private var projectionRadius = 1800.0
    private var projectionCenter = CGPoint.zero
    private var projectionCenterDepth = 0.0
    private var spatialDrawnNodes = 0
    private var colors:[NSColor]=[]
    private var labelImages:[Int:NSImage]=[:]
    private var pendingLabels=Set<Int>()
    private var labelAccess:[Int:Int]=[:]
    private var drawTick=0
    private var adjacency:[[Int]]=[]
    private var index=RecommendationSpatialGrid(cell:240)
    private var lod:[Double:[RecommendationGridKey:RecommendationMapBucket]]=[:]
    private var contentBounds=CGRect(x:0,y:0,width:1100,height:760)
    private var selected:Int?
    private var hovered:Int?
    private var neighbors=Set<Int>()
    private var zoom=0.8
    private var pan=CGPoint.zero
    private var tracking:NSTrackingArea?
    private var lastMouse=CGPoint.zero
    private var dragIndex:Int?
    private var mouseMovedDistance=0.0
    private var dragHistory:[(Double,CGPoint)]=[]
    private var timer:Timer?
    private var cameraAnimation:(Double,CGPoint,Double,CGPoint,Double)?
    private var momentum=CGPoint.zero
    private var activePhysics=Set<Int>()
    private var velocity:[Int:CGPoint]=[:]
    private var resting:[Int:CGPoint]=[:]
    private var simulationTicks=0
    private var drawSamples:[Double]=[]
    private var visibleCount=0
    private var drawnEdges=0
    private var bucketCount=0
    private var labelRects:[CGRect]=[]
    private var firstFit=false
    private var focusedInitialSelection=false
    private var formationRevision = -1
    private var formationActive = false
    private var formationEdgeCount = 0
    private var formationLayoutRevision = -1
    private var analyzed = Set<Int>()
    private var pulses: [(Int, Int, Double)] = []
    private var lastActivated: [Int] = []
    private var morph: (from: [CGPoint], start: Double)?
    private var dissolvingEdges: [(Int, Int)] = []
    private var restingEdges: [RecommendationMapEdge] = []
    private var formationCameraAdjusted = false
    private var colorGroups: [Int] = []
    private var groupColors: [NSColor] = []
    private let sphereAtlas = RecommendationSphereAtlas()
    private var sphereSprites: [[CGImage]] = []
    private var navigationBounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    private var overviewPoints: [CGPoint] = []
    private var overviewQueued = false
    private var overviewPublished = 0.0
    private var lastWheel = 0.0
    private var cameraHistory: [RecommendationCameraPosition] = []
    private var lastCanvasSize = CGSize.zero
    override init(frame:NSRect){super.init(frame:frame);wantsLayer=true;layer?.masksToBounds=true;setAccessibilityElement(true);setAccessibilityRole(.group);setAccessibilityLabel(String(localized: "Recommendation map. Scroll to pan, pinch to zoom, and select a story to preview it.", bundle: .module))}
    required init?(coder:NSCoder){fatalError()}
    override func updateTrackingAreas(){super.updateTrackingAreas();if let tracking {removeTrackingArea(tracking)};let area=NSTrackingArea(rect:bounds,options:[.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self);addTrackingArea(area);tracking=area}
    override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();labelImages.removeAll();pendingLabels.removeAll();sphereSprites.removeAll();needsDisplay=true}
    override func viewWillMove(toWindow newWindow:NSWindow?){if newWindow == nil {timer?.invalidate();timer=nil;cameraAnimation=nil;momentum = .zero;activePhysics.removeAll()};super.viewWillMove(toWindow:newWindow)}
    override func resetCursorRects(){addCursorRect(bounds,cursor:.openHand)}
    override func layout(){
        super.layout()
        if !firstFit && !nodes.isEmpty && bounds.width>10 {firstFit=true;fit(animated:false)}
        else if lastCanvasSize != bounds.size, interactionEnabled {constrainNavigation()}
        lastCanvasSize=bounds.size;publishOverview()
    }
    func install(_ graph:RecommendationGraph,revision:Int,layoutRevision:Int,forming:Bool=false){
        let selectedID = selected.flatMap { nodes.indices.contains($0) ? nodes[$0].id : nil }
        let finishFormation = formationActive && !forming && self.layoutRevision != layoutRevision
        let before = Dictionary(uniqueKeysWithValues: nodes.indices.map { (nodes[$0].id, displayPosition($0)) })
        formationRevision = -1;formationActive = false;formationEdgeCount = 0
        analyzed.removeAll();pulses.removeAll();lastActivated.removeAll();morph = nil;dissolvingEdges.removeAll()
        self.revision=revision
        let changesLayout=self.layoutRevision != layoutRevision
        self.layoutRevision=layoutRevision
        if changesLayout {focusedInitialSelection=false;clearCameraHistory()}
        if graph.nodes.isEmpty {firstFit=false;focusedInitialSelection=false;timer?.invalidate();timer=nil;cameraAnimation=nil;momentum = .zero;lod.removeAll();clearCameraHistory()}
        let old=Dictionary(uniqueKeysWithValues:(changesLayout || finishFormation ? []:Array(zip(nodes,positions))).map {($0.0.id,$0.1)})
        nodes=graph.nodes;depthSeeds=nodes.map { RecommendationOrbit.depthSeed(id: $0.id, community: $0.clusterID) };projectionDirty=true
        edges=graph.edges;lookup=Dictionary(uniqueKeysWithValues:nodes.enumerated().map {($0.element.id,$0.offset)})
        restingEdges = graph.edges
        positions=nodes.map {old[$0.id] ?? $0.position};colors=nodes.map {NSColor(recommendationTopicColor($0.topic))}
        var topicGroups: [String: Int] = [:]
        groupColors.removeAll();colorGroups.removeAll()
        for i in nodes.indices {
            if topicGroups[nodes[i].topic] == nil { topicGroups[nodes[i].topic] = groupColors.count;groupColors.append(colors[i]) }
            colorGroups.append(topicGroups[nodes[i].topic]!)
        }
        index=RecommendationSpatialGrid(cell:240);adjacency=Array(repeating:[],count:nodes.count)
        for i in nodes.indices {index.insert(i,positions[i])}
        for e in edges.indices {if let a=lookup[edges[e].a],let b=lookup[edges[e].b]{adjacency[a].append(e);adjacency[b].append(e)}}
        labelImages.removeAll();pendingLabels.removeAll();labelAccess.removeAll()
        rebuildLOD()
        if changesLayout && !finishFormation {
            projectionCenter = CGPoint(x: contentBounds.midX, y: contentBounds.midY)
            projectionRadius = max(1800, hypot(contentBounds.width, contentBounds.height) * 0.65)
        }
        selected=selectedID.flatMap { lookup[$0] };hovered=nil;dragIndex=nil;activePhysics.removeAll();velocity.removeAll()
        updateNeighbors()
        if !firstFit && !nodes.isEmpty && bounds.width>10 {firstFit=true;fit(animated:false)}
        if finishFormation && !reduceMotion {
            morph = (nodes.map { before[$0.id] ?? $0.position }, CACurrentMediaTime())
            focusedInitialSelection = true
            startTimer()
        }
        if finishFormation && !formationCameraAdjusted { fit(animated: !reduceMotion) }
        needsDisplay=true
    }

    func updateFormation(_ state: RecommendationMapFormation, revision: Int) {
        guard formationRevision != revision else { return }
        formationRevision = revision
        guard state.active else {
            if formationActive {
                install(RecommendationGraph(nodes: nodes, edges: restingEdges), revision: self.revision, layoutRevision: layoutRevision)
                formationRevision = revision
            }
            return
        }
        if !formationActive {
            formationActive = true;formationEdgeCount = 0
            formationLayoutRevision = state.layoutRevision
            formationCameraAdjusted = false
            dissolvingEdges = edges.prefix(350).compactMap { edge in
                guard let a = lookup[edge.a], let b = lookup[edge.b] else { return nil }
                return (a, b)
            }
            let before = positions
            // Stable article identities determine a uniform open field, independent
            // of categories. Existing filters, camera and hit testing stay native.
            for i in nodes.indices { positions[i] = state.positions[nodes[i].id] ?? positions[i] }
            edges.removeAll();adjacency = Array(repeating: [], count: nodes.count)
            analyzed.removeAll();pulses.removeAll();lastActivated.removeAll()
            activePhysics.removeAll();velocity.removeAll()
            morph = reduceMotion ? nil : (before, CACurrentMediaTime())
            rebuildPositionIndex()
            focusedInitialSelection = true
            fit(animated: !reduceMotion)
        }
        if formationLayoutRevision != state.layoutRevision {
            let before = positions.indices.map { displayPosition($0) }
            for i in nodes.indices where i != dragIndex {
                if let point = state.positions[nodes[i].id] { positions[i] = point }
            }
            morph = reduceMotion ? nil : (before, CACurrentMediaTime())
            dissolvingEdges.removeAll()
            formationLayoutRevision = state.layoutRevision
            rebuildPositionIndex()
        }
        let nextAnalyzed = Set(state.analyzed.compactMap { lookup[$0] })
        let arrived = nextAnalyzed.subtracting(analyzed)
        if !arrived.isEmpty { lastActivated = Array(arrived.sorted().prefix(32)) }
        analyzed = nextAnalyzed
        let now = CACurrentMediaTime()
        for edge in state.edges.dropFirst(formationEdgeCount) {
            guard let a = lookup[edge.a], let b = lookup[edge.b] else { continue }
            adjacency[a].append(edges.count);adjacency[b].append(edges.count);edges.append(edge)
            if !reduceMotion { pulses.append((a, b, now)) }
        }
        formationEdgeCount = state.edges.count
        pulses = Array(pulses.filter { now - $0.2 < 2.4 }.suffix(72))
        updateNeighbors()
        if !reduceMotion { startTimer() }
        needsDisplay = true
    }

    private func rebuildPositionIndex() {
        projectionDirty = true
        index = RecommendationSpatialGrid(cell: 240)
        for i in positions.indices { index.insert(i, positions[i]) }
        rebuildLOD()
    }

    private func displayPosition(_ i: Int) -> CGPoint {
        guard let morph, morph.from.indices.contains(i) else { return positions[i] }
        let t = min(1, max(0, (CACurrentMediaTime() - morph.start) / 0.9))
        let ease = t * t * (3 - 2 * t), p = morph.from[i], q = positions[i]
        return CGPoint(x: p.x + (q.x - p.x) * ease, y: p.y + (q.y - p.y) * ease)
    }

    private func drawFormingMap(_ context: CGContext) {
        let now = CACurrentMediaTime()
        let visible = (morph == nil ? index.query(viewport) : Array(nodes.indices)).filter {
            bounds.insetBy(dx: -30, dy: -30).contains(screen(displayPosition($0)))
        }
        visibleCount = visible.count
        if let morph, !dissolvingEdges.isEmpty {
            context.saveGState()
            context.setAlpha(max(0, 1 - (now - morph.start) / 0.65))
            for (a, b) in dissolvingEdges { strokeEdge(a, b, context: context, highlighted: false, overview: true) }
            context.restoreGState()
        }
        var edgePaths: [Int: CGMutablePath] = [:]
        for edge in edges {
            if drawnEdges >= 600 { break }
            guard let a = lookup[edge.a], let b = lookup[edge.b] else { continue }
            let p = screen(displayPosition(a)), q = screen(displayPosition(b))
            guard bounds.contains(p) || bounds.contains(q) else { continue }
            if a == selected || b == selected { strokeEdge(a, b, context: context, highlighted: true, overview: zoom < 0.25) }
            else {
                let key = Int(min(alpha(a), alpha(b)) * 10)
                let path = edgePaths[key] ?? CGMutablePath()
                path.move(to: p);path.addQuadCurve(to: q, control: CGPoint(x: (p.x+q.x)/2-(q.y-p.y)*0.035, y: (p.y+q.y)/2+(q.x-p.x)*0.035))
                edgePaths[key] = path
            }
            drawnEdges += 1
        }
        context.setLineWidth(0.6)
        for (alpha, path) in edgePaths {
            context.setStrokeColor(NSColor.labelColor.withAlphaComponent(Double(alpha) * (zoom < 0.25 ? 0.008 : 0.018)).cgColor)
            context.addPath(path);context.strokePath()
        }
        var nodePaths: [Int: CGMutablePath] = [:]
        for i in visible {
            let p = screen(displayPosition(i))
            let ready = !formationActive || analyzed.contains(i)
            let radius = min(5, max(1.5, 9 * sqrt(zoom)))
            let key = colorGroups[i] * 32 + Int((ready ? 0.8 : 0.23) * alpha(i) * 20)
            let path = nodePaths[key] ?? CGMutablePath()
            path.addEllipse(in: CGRect(x: p.x-radius, y: p.y-radius, width: radius*2, height: radius*2))
            nodePaths[key] = path
        }
        for (key, path) in nodePaths {
            context.setFillColor(groupColors[key / 32].withAlphaComponent(Double(key % 32) / 20).cgColor)
            context.addPath(path);context.fillPath()
        }
        guard formationActive, !reduceMotion else { return }
        let accent = NSColor(NookTheme.accent)
        // Bounded light signals follow actual new semantic edges. No timers
        // invent connections; a quiet breath keeps the last analyzed batch alive.
        for (a, b, began) in pulses {
            let age = now - began
            guard age < 2.4 else { continue }
            let p = screen(displayPosition(a)), q = screen(displayPosition(b))
            guard bounds.contains(p) || bounds.contains(q) else { continue }
            let t = min(1, age / 0.4), fade = min(1, max(0, (2.4-age)/1.8))
            let c = CGPoint(x: (p.x+q.x)/2-(q.y-p.y)*0.035, y: (p.y+q.y)/2+(q.x-p.x)*0.035)
            let point = CGPoint(x:(1-t)*(1-t)*p.x+2*(1-t)*t*c.x+t*t*q.x,
                                y:(1-t)*(1-t)*p.y+2*(1-t)*t*c.y+t*t*q.y)
            let control = CGPoint(x:p.x+(c.x-p.x)*t,y:p.y+(c.y-p.y)*t)
            for (width, opacity) in [(6.0,0.035),(2.8,0.10),(0.9,0.75)] {
                context.setStrokeColor(accent.withAlphaComponent(opacity*fade).cgColor)
                context.setLineWidth(width);context.beginPath();context.move(to:p);context.addQuadCurve(to:point,control:control);context.strokePath()
            }
        }
        let breath = 0.5 + 0.5 * sin(now * 2.6)
        for i in lastActivated {
            let p = screen(displayPosition(i))
            guard bounds.contains(p) else { continue }
            let r = 5 + breath * 5
            context.setStrokeColor(accent.withAlphaComponent(0.15 + breath*0.25).cgColor)
            context.setLineWidth(0.8);context.strokeEllipse(in:CGRect(x:p.x-r,y:p.y-r,width:r*2,height:r*2))
        }
    }
    private func rebuildLOD(){
        guard !positions.isEmpty else{return}
        let minX=positions.map(\.x).min()!-180,maxX=positions.map(\.x).max()!+180,minY=positions.map(\.y).min()!-180,maxY=positions.map(\.y).max()!+180
        contentBounds=CGRect(x:minX,y:minY,width:maxX-minX,height:maxY-minY)
        projectionDirty = true
        // Keep the orbit pivot when flags or arrivals update the graph. It only
        // resets for the first fit or an explicit layout, preserving orientation.
        if !firstFit {
            projectionCenter = CGPoint(x: contentBounds.midX, y: contentBounds.midY)
            projectionRadius = max(1800, hypot(contentBounds.width, contentBounds.height) * 0.65)
        }
        lod.removeAll(keepingCapacity:true)
        for cell in [240.0,480,960,1920,3840] {
            var buckets:[RecommendationGridKey:RecommendationMapBucket]=[:]
            for i in positions.indices {
                let p=positions[i],key=RecommendationGridKey(x:Int(floor(p.x/cell)),y:Int(floor(p.y/cell)))
                if var b=buckets[key] {b.center.x=(b.center.x*Double(b.count)+p.x)/Double(b.count+1);b.center.y=(b.center.y*Double(b.count)+p.y)/Double(b.count+1);b.count+=1;b.bounds=b.bounds.union(CGRect(x:p.x,y:p.y,width:1,height:1));if nodes[i].rank<nodes[b.first].rank{b.first=i};buckets[key]=b}
                else {buckets[key]=RecommendationMapBucket(center:p,count:1,first:i,bounds:CGRect(x:p.x,y:p.y,width:1,height:1))}
            }
            lod[cell]=buckets
        }
    }
    func updateSelection(_ id:String?){
        let next=id.flatMap {lookup[$0]};guard next != selected else{return};selected=next;updateNeighbors()
        if formationActive { needsDisplay = true;return }
        if !focusedInitialSelection && next != nil {
            focusedInitialSelection=true
            if spatial { fit(animated: false) } else { focusSelection() }
        };needsDisplay=true
    }
    private func updateNeighbors(){neighbors=[];if let active=hovered ?? selected {neighbors.insert(active);for e in adjacency[active]{if let a=lookup[edges[e].a],let b=lookup[edges[e].b]{neighbors.insert(a);neighbors.insert(b)}}}}

    #if DEBUG
    var inspection: (positions: [String: CGPoint], pan: CGPoint, zoom: Double, forming: Bool) {
        (Dictionary(uniqueKeysWithValues: nodes.indices.map { (nodes[$0].id, positions[$0]) }), pan, zoom, formationActive)
    }
    #endif
    private func world(_ point:CGPoint)->CGPoint{CGPoint(x:(point.x-pan.x)/zoom,y:(point.y-pan.y)/zoom)}
    private func screen(_ point:CGPoint)->CGPoint{CGPoint(x:point.x*zoom+pan.x,y:point.y*zoom+pan.y)}
    private var viewport:CGRect {let p=world(.zero);return CGRect(x:p.x,y:p.y,width:bounds.width/zoom,height:bounds.height/zoom).insetBy(dx:-200,dy:-140)}
    private var lodCell:Double? {guard zoom<0.25 else{return nil};return [240.0,480,960,1920,3840].first { $0*zoom>=25 } ?? 3840}
    private func buckets()->[RecommendationMapBucket] {guard let cell=lodCell,let source=lod[cell] else{return []};let box=viewport;return source.values.filter {$0.bounds.intersects(box)}}
    private func alpha(_ i:Int)->Double {
        let readOpacity=nodes[i].article.isRead && i != selected && i != hovered ? 0.45:1.0
        if let topic,topic != nodes[i].topic{return 0.10*readOpacity}
        if focusOnly && !neighbors.contains(i){return 0.08*readOpacity}
        if hovered != nil && !neighbors.contains(i){return 0.55*readOpacity}
        return readOpacity
    }
    override func draw(_ dirtyRect:NSRect){
        defer { publishOverview() }
        let began=CACurrentMediaTime();drawTick+=1
        guard let context=NSGraphicsContext.current?.cgContext else{return}
        context.setFillColor(NSColor(NookTheme.canvas).cgColor);context.fill(bounds)
        let spacing=max(18,min(42,72*zoom)),dx=pan.x.truncatingRemainder(dividingBy:spacing),dy=pan.y.truncatingRemainder(dividingBy:spacing)
        context.setFillColor(NSColor.labelColor.withAlphaComponent(0.07).cgColor)
        if !spatial { for x in stride(from:dx,through:bounds.width,by:spacing){for y in stride(from:dy,through:bounds.height,by:spacing){context.fillEllipse(in:CGRect(x:x,y:y,width:1,height:1))}} }
        drawnEdges=0;bucketCount=0;labelRects.removeAll(keepingCapacity:true)
        if spatial {
            drawSpatialMap(context)
        } else if formationActive || morph != nil {
            drawFormingMap(context)
        } else if lodCell != nil {
            let groups=buckets();visibleCount=groups.reduce(0){$0+$1.count};bucketCount=groups.count
            // Level of detail: article groups, never thousands of tiny labels.
            for b in groups {let p=screen(b.center),r=min(9,2.6+sqrt(Double(b.count))*0.65);context.setFillColor(colors[b.first].withAlphaComponent(0.65*alpha(b.first)).cgColor);context.fillEllipse(in:CGRect(x:p.x-r,y:p.y-r,width:r*2,height:r*2))}
            // Sparse overview skeleton: strongest connections, selected links always.
            var drawn=0
            for e in edges.indices where drawn<350 {
                guard let a=lookup[edges[e].a],let b=lookup[edges[e].b],viewport.contains(positions[a]) || viewport.contains(positions[b]) else{continue}
                if e%13 != 0 && a != selected && b != selected {continue}
                strokeEdge(a,b,context:context,highlighted:a==selected || b==selected,overview:true);drawn+=1
            }
            drawnEdges=drawn
            drawTopicLabels()
        } else {
            let visible=index.query(viewport).filter {viewport.contains(positions[$0])};visibleCount=visible.count
            let visibleSet=Set(visible);var edgesToDraw=Set<Int>()
            labelRects=visible.map {i in let p=screen(positions[i]);let r=max(4,min(24,(16+Double(max(0,24-nodes[i].rank))*0.3)*sqrt(zoom)))+3;return CGRect(x:p.x-r,y:p.y-r,width:2*r,height:2*r)}
            if zoom>=0.55 {requestLabels(Array(visible.prefix(160)))}
            for i in visible {edgesToDraw.formUnion(adjacency[i])}
            for e in edgesToDraw.sorted() {
                guard let a=lookup[edges[e].a],let b=lookup[edges[e].b] else{continue}
                let active=a==(hovered ?? selected) || b==(hovered ?? selected)
                if drawnEdges>=1600 && !active {continue}
                if focusOnly && !active {continue}
                if (!visibleSet.contains(a) || !visibleSet.contains(b)) && !active {continue}
                strokeEdge(a,b,context:context,highlighted:active,overview:false);drawnEdges+=1
            }
            for i in visible.sorted(by:{ a,b in
                let ap=a==selected || a==hovered,bp=b==selected || b==hovered
                if ap != bp {return ap};return nodes[a].rank == nodes[b].rank ? a<b:nodes[a].rank<nodes[b].rank
            }) {drawNode(i,context:context)}
        }
        if !spatial, let selected,positions.indices.contains(selected),lodCell != nil {drawNode(selected,context:context,force:true)}
        let elapsed=(CACurrentMediaTime()-began)*1000;drawSamples.append(elapsed);if drawSamples.count>600{drawSamples.removeFirst(drawSamples.count-600)}
    }
    private func strokeEdge(_ a:Int,_ b:Int,context:CGContext,highlighted:Bool,overview:Bool){
        let p=screenPosition(a),q=screenPosition(b)
        let opacity=(highlighted ? 0.62 : overview ? 0.10:0.18)*min(alpha(a),alpha(b))
        let color=highlighted ? NSColor(NookTheme.accent):NSColor.labelColor
        context.setStrokeColor(color.withAlphaComponent(opacity).cgColor);context.setLineWidth(highlighted ? 1.2:0.6)
        context.beginPath();context.move(to:p);context.addQuadCurve(to:q,control:CGPoint(x:(p.x+q.x)/2-(q.y-p.y)*0.035,y:(p.y+q.y)/2+(q.x-p.x)*0.035));context.strokePath()
    }
    private func drawNode(_ i:Int,context:CGContext,force:Bool=false){
        let p=screenPosition(i);guard bounds.insetBy(dx:-100,dy:-100).contains(p) else{return}
        let active=i==selected,over=i==hovered
        let markerColor = spatial ? NSColor(NookTheme.accent) : colors[i]
        let r = spatial ? sphereStyle(i).radius : (force ? 8:max(4,min(24,(16+Double(max(0,24-nodes[i].rank))*0.3)*sqrt(zoom))))
        let opacity = alpha(i) * (spatial && !active && !over ? sphereStyle(i).opacity : 1)
        if !spatial {
            context.setFillColor(colors[i].withAlphaComponent((active ? 0.30:0.15)*opacity).cgColor);context.fillEllipse(in:CGRect(x:p.x-r,y:p.y-r,width:2*r,height:2*r))
        }
        if !spatial || active || over {
            context.setStrokeColor(markerColor.withAlphaComponent((active || over ? 0.95:0.65)*opacity).cgColor);context.setLineWidth(active ? 1.7:0.9);context.strokeEllipse(in:CGRect(x:p.x-r,y:p.y-r,width:2*r,height:2*r))
        }
        if active {context.setStrokeColor(NSColor(NookTheme.accent).withAlphaComponent(0.25).cgColor);context.strokeEllipse(in:CGRect(x:p.x-r-5,y:p.y-r-5,width:2*r+10,height:2*r+10))}
        if (spatial ? zoom >= fitZoom * 2.5 : zoom >= 0.55) || over || active && !force {
            context.saveGState();context.setAlpha(opacity)
            let number=(nodes[i].article.isRead ? "✓" : "\(nodes[i].rank)") as NSString
            let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedDigitSystemFont(ofSize:9,weight:active ? .semibold:.regular),.foregroundColor:spatial ? NSColor.labelColor.withAlphaComponent(0.9):colors[i]]
            let size=number.size(withAttributes:attrs);number.draw(at:CGPoint(x:p.x-size.width/2,y:p.y-size.height/2),withAttributes:attrs)
            let width=165.0
            let candidates=[CGRect(x:p.x-width/2,y:p.y+r+8,width:width,height:36),CGRect(x:p.x-width/2,y:p.y-r-44,width:width,height:36),CGRect(x:p.x+r+10,y:p.y-18,width:width,height:36),CGRect(x:p.x-r-width-10,y:p.y-18,width:width,height:36)]
            let fitting=candidates.first {rect in !labelRects.contains(where:{$0.intersects(rect)})}
            let labelRect=fitting ?? candidates[0]
            if active || over || fitting != nil {
                if let image=labelImages[i] {
                    image.draw(in:labelRect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil);labelAccess[i]=drawTick
                } else {requestLabels([i])}
                labelRects.append(labelRect.insetBy(dx:-5,dy:-3))
            }
            context.restoreGState()
        }
    }
    private func requestLabels(_ ids:[Int]) {
        let missing=ids.filter {labelImages[$0]==nil && !pendingLabels.contains($0)}
        guard !missing.isEmpty else{return}
        pendingLabels.formUnion(missing)
        let labelColor=(NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .labelColor).withAlphaComponent(0.85)
        let entries=missing.map {($0,nodes[$0].article.title)};let expected=revision
        Task { [weak self] in
            let rendered=await Task.detached(priority:.userInitiated) {
                entries.compactMap { index,text -> (Int,CGImage)? in
                    let width=165.0,height=36.0
                    guard let context=CGContext(data:nil,width:Int(width*2),height:Int(height*2),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return nil}
                    context.scaleBy(x:2,y:2)
                    let style=NSMutableParagraphStyle();style.alignment = .center;style.lineSpacing=3;style.lineBreakMode = .byWordWrapping
                    let string=NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:12,weight:.medium),.foregroundColor:labelColor,.paragraphStyle:style])
                    let setter=CTFramesetterCreateWithAttributedString(string)
                    let path=CGPath(rect:CGRect(x:0,y:0,width:width,height:height),transform:nil)
                    let frame=CTFramesetterCreateFrame(setter,CFRange(location:0,length:0),path,nil)
                    CTFrameDraw(frame,context)
                    guard let image=context.makeImage() else{return nil};return (index,image)
                }
            }.value
            guard let self,self.revision==expected else{return}
            for (index,image) in rendered {self.labelImages[index]=NSImage(cgImage:image,size:CGSize(width:165,height:36));self.pendingLabels.remove(index);self.labelAccess[index]=self.drawTick}
            if self.labelImages.count>256 {
                for (i,_) in self.labelAccess.sorted(by:{$0.value<$1.value}).prefix(self.labelImages.count-256) {self.labelImages.removeValue(forKey:i);self.labelAccess.removeValue(forKey:i)}
            }
            self.needsDisplay=true
        }
    }
    private func drawTopicLabels(){
        var grouped:[String:(Double,Double,Int,String)]=[:]
        for i in nodes.indices {
            let node=nodes[i],key=node.clusterID.isEmpty ? node.topic:node.clusterID
            let old=grouped[key] ?? (0,0,0,node.clusterLabel.isEmpty ? node.topic:node.clusterLabel)
            grouped[key]=(old.0+positions[i].x,old.1+positions[i].y,old.2+1,old.3)
        }
        var occupied:[CGRect]=[]
        for key in grouped.keys.sorted(by:{grouped[$0]!.2==grouped[$1]!.2 ? $0<$1:grouped[$0]!.2>grouped[$1]!.2}) {
            let value=grouped[key]!;guard value.2>=8 else {continue}
            let p=screen(CGPoint(x:value.0/Double(value.2),y:value.1/Double(value.2)))
            let text="\(value.3)  ·  \(value.2)" as NSString
            let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:11,weight:.medium),.foregroundColor:NSColor.labelColor.withAlphaComponent(0.75)]
            let s=text.size(withAttributes:attrs),rect=CGRect(x:p.x-s.width/2-8,y:p.y-10,width:s.width+16,height:s.height+10)
            guard bounds.intersects(rect),!occupied.contains(where:{$0.intersects(rect.insetBy(dx:-12,dy:-12))}) else {continue}
            occupied.append(rect);if occupied.count>28 {break}
            NSColor(NookTheme.card).withAlphaComponent(0.95).setFill();NSBezierPath(roundedRect:rect,xRadius:8,yRadius:8).fill()
            text.draw(at:CGPoint(x:rect.minX+8,y:rect.minY+5),withAttributes:attrs)
        }
    }
    private func hit(_ p:CGPoint)->Int? {
        if spatial {
            updateProjection()
            let w = world(p), radius = 26 / zoom
            let candidates = projectedIndex.query(CGRect(x: w.x-radius, y: w.y-radius, width: radius*2, height: radius*2))
                .filter { alpha($0) > 0.2 && hypot(screenPosition($0).x-p.x, screenPosition($0).y-p.y) < max(9, sphereStyle($0).radius + 4) }
                .map { i in (index: i, distance: hypot(screenPosition(i).x-p.x, screenPosition(i).y-p.y)) }
            // A nearby sphere can cover the center of a distant one. Match the
            // painter's depth order before considering the larger click target.
            if let front = candidates.filter({ $0.distance <= sphereStyle($0.index).radius })
                .max(by: { projected[$0.index].depth < projected[$1.index].depth }) { return front.index }
            guard let nearest = candidates.map(\.distance).min() else { return nil }
            return candidates.filter { $0.distance < nearest + 3 }
                .max { a, b in projected[a.index].depth < projected[b.index].depth }?.index
        }
        if morph != nil || formationActive && lodCell != nil {
            return nodes.indices.filter { i in let q = screen(displayPosition(i));return hypot(q.x-p.x,q.y-p.y)<12 }
                .min { a,b in let x=screen(displayPosition(a)),y=screen(displayPosition(b));return hypot(x.x-p.x,x.y-p.y)<hypot(y.x-p.x,y.y-p.y) }
        }
        if lodCell != nil{return nil}
        let w=world(p);let radius=100/zoom
        return index.query(CGRect(x:w.x-radius,y:w.y-radius,width:radius*2,height:radius*2)).filter {i in
            let q=screen(positions[i]);return alpha(i)>0.2 && (hypot(p.x-q.x,p.y-q.y)<max(18,24*sqrt(zoom)) || zoom>=0.55 && CGRect(x:q.x-80,y:q.y+12,width:160,height:53).contains(p))
        }.min {hypot(positions[$0].x-w.x,positions[$0].y-w.y)<hypot(positions[$1].x-w.x,positions[$1].y-w.y)}
    }
    override func mouseMoved(with event:NSEvent){guard interactionEnabled else{return};let p=convert(event.locationInWindow,from:nil);let next=hit(p);if next != hovered {hovered=next;updateNeighbors();needsDisplay=true};(next == nil ? NSCursor.openHand:NSCursor.pointingHand).set()}
    override func mouseExited(with event:NSEvent){hovered=nil;updateNeighbors();needsDisplay=true}
    override func mouseDown(with event:NSEvent){guard interactionEnabled else{return};rememberCamera();if formationActive {formationCameraAdjusted=true};window?.makeFirstResponder(self);cameraAnimation=nil;momentum = .zero;lastMouse=convert(event.locationInWindow,from:nil);dragIndex=hit(lastMouse);mouseMovedDistance=0;dragHistory=[(CACurrentMediaTime(),lastMouse)];orbitVelocity = .zero;orbitPanning=event.modifierFlags.contains(.shift);if !spatial, let i=dragIndex {beginPhysics(i)};NSCursor.closedHand.set()}
    override func mouseDragged(with event:NSEvent){guard interactionEnabled else{return};defer {constrainNavigation()};let p=convert(event.locationInWindow,from:nil);let dx=p.x-lastMouse.x,dy=p.y-lastMouse.y;mouseMovedDistance+=hypot(dx,dy)
        if spatial && !orbitPanning { orbit.rotate(x: dx*0.006, y: -dy*0.006);projectionDirty=true }
        else if spatial { pan.x+=dx;pan.y+=dy }
        else if let i=dragIndex {move(i,to:CGPoint(x:positions[i].x+dx/zoom,y:positions[i].y+dy/zoom));velocity[i] = .zero;startTimer()}
        else {pan.x+=dx;pan.y+=dy}
        lastMouse=p;dragHistory.append((CACurrentMediaTime(),p));dragHistory=Array(dragHistory.suffix(5));needsDisplay=true
    }
    override func mouseUp(with event:NSEvent){guard interactionEnabled else{return};defer {constrainNavigation()};let p=convert(event.locationInWindow,from:nil)
        if mouseMovedDistance<4 {
            if let i=dragIndex {onSelect?(nodes[i].id);if event.clickCount==2 {onOpen?()}}
            else if !spatial, lodCell != nil,let closest=buckets().min(by:{hypot(screen($0.center).x-p.x,screen($0.center).y-p.y)<hypot(screen($1.center).x-p.x,screen($1.center).y-p.y)}),hypot(screen(closest.center).x-p.x,screen(closest.center).y-p.y)<35 {
                animateCamera(to:0.85,center:closest.center);onSelect?(nodes[closest.first].id)
            } else if event.clickCount==2 {zoomBy(1.7,anchor:p,animated:true)}
        } else if spatial {
            if !reduceMotion, let start=dragHistory.first {
                let dt=max(0.016,CACurrentMediaTime()-start.0)
                if orbitPanning { momentum=CGPoint(x:(p.x-start.1.x)/dt/60,y:(p.y-start.1.y)/dt/60) }
                else { orbitVelocity=CGPoint(x:(p.x-start.1.x)/dt/60*0.006,y:-(p.y-start.1.y)/dt/60*0.006) }
                startTimer()
            }
        } else if let i=dragIndex {resting[i]=positions[i]} else if let start=dragHistory.first {
            let dt=max(0.016,CACurrentMediaTime()-start.0);momentum=CGPoint(x:(p.x-start.1.x)/dt/60,y:(p.y-start.1.y)/dt/60);if !reduceMotion {startTimer()}
        }
        dragIndex=nil;NSCursor.openHand.set();needsDisplay=true
    }
    override func scrollWheel(with event:NSEvent){
        guard interactionEnabled else{return}
        defer {constrainNavigation();publishOverview()}
        let now=CACurrentMediaTime()
        if event.phase == .began || event.phase.isEmpty && event.momentumPhase.isEmpty && now-lastWheel>0.35 {rememberCamera()}
        lastWheel=now
        cameraAnimation=nil;momentum = .zero
        if formationActive {formationCameraAdjusted=true}
        orbitVelocity = .zero
        let p=convert(event.locationInWindow,from:nil)
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) || !event.hasPreciseScrollingDeltas {zoomBy(exp(event.scrollingDeltaY*(event.hasPreciseScrollingDeltas ? 0.008:0.07)),anchor:p,animated:false)}
        else {pan.x+=event.scrollingDeltaX;pan.y+=event.scrollingDeltaY;needsDisplay=true}
    }
    override func magnify(with event:NSEvent){
        guard interactionEnabled else{return}
        if event.phase == .began {rememberCamera()}
        orbitVelocity = .zero
        zoomBy(1+event.magnification,anchor:convert(event.locationInWindow,from:nil),animated:false)
    }
    override func smartMagnify(with event:NSEvent){
        guard interactionEnabled else{return}
        rememberCamera()
        if zoom > (spatial ? fitZoom*2 : 0.4) {fit(animated:true)}
        else {zoomBy(4,anchor:convert(event.locationInWindow,from:nil),animated:true)}
    }
    override func keyDown(with event:NSEvent){
        guard interactionEnabled else{return}
        // Only the canvas responder handles these keys. Search fields (including
        // marked IME text) keep their normal routing and Command shortcuts.
        guard event.modifierFlags.intersection([.command,.control,.option]).isEmpty else {super.keyDown(with:event);return}
        switch event.keyCode {
        case 123...126:
            if !event.isARepeat {rememberCamera()}
            cameraAnimation=nil;momentum = .zero;orbitVelocity = .zero
            switch event.keyCode {case 123:pan.x+=70;case 124:pan.x-=70;case 125:pan.y-=70;default:pan.y+=70}
            constrainNavigation()
        case 36:onOpen?()
        case 53,29,115:navigateToFit()
        case 3:focusSelection()
        case 51:navigateBack()
        default:super.keyDown(with:event)
        }
        needsDisplay=true;publishOverview()
    }
    func zoomBy(_ factor:Double,anchor:CGPoint,animated:Bool){
        guard interactionEnabled, factor.isFinite, factor>0, !nodes.isEmpty else{return}
        if formationActive {formationCameraAdjusted=true}
        updateProjection()
        let target=spatial ? min(maximumZoom,max(minimumZoom,zoom*factor)) : min(2.5,max(0.018,zoom*factor))
        let w=world(anchor),next=CGPoint(x:anchor.x-w.x*target,y:anchor.y-w.y*target)
        setCamera(zoom:target,pan:next,animated:animated)
        if !animated || reduceMotion {constrainNavigation()}
    }
    func fit(animated:Bool){guard !nodes.isEmpty else{return}
        if spatial {
            projectionCenter = CGPoint(x: contentBounds.midX,y: contentBounds.midY)
            projectionCenterDepth = 0;projectionDirty = true
            updateProjection()
            let box = projectedBounds
            let scale = fitZoom
            animateCamera(to:max(0.018,min(1.1,scale)),center:CGPoint(x:box.midX,y:box.midY),animated:animated)
            return
        }
        let scale=min((bounds.width-100)/contentBounds.width,(bounds.height-150)/contentBounds.height);animateCamera(to:max(0.018,min(1.1,scale)),center:CGPoint(x:contentBounds.midX,y:contentBounds.midY),animated:animated)}
    func focusSelection(){
        guard interactionEnabled,let selected else{return}
        rememberCamera();markCameraInteraction()
        if spatial {
            updateProjection()
            // Frame real neighbors without moving the orbit pivot. Hovering a
            // different story must not change the selected story's focus target.
            var box=CGRect(origin:projected[selected].point,size:.zero)
            for e in adjacency[selected].prefix(12) {
                for id in [edges[e].a,edges[e].b] {
                    if let i=lookup[id] {box=box.union(CGRect(origin:projected[i].point,size:.zero))}
                }
            }
            let padding=max(180,75/max(0.02,fitZoom*3))
            box=box.insetBy(dx:-padding,dy:-padding)
            let scale=min(max(100,bounds.width-180)/box.width,max(100,bounds.height-180)/box.height)
            animateCamera(to:max(fitZoom,min(maximumZoom,fitZoom*4,scale)),center:CGPoint(x:box.midX,y:box.midY))
        } else {
            animateCamera(to:max(0.85,zoom),center:positions[selected])
        }
    }
    private func animateCamera(to scale:Double,center:CGPoint,animated:Bool=true){setCamera(zoom:scale,pan:CGPoint(x:bounds.midX-center.x*scale,y:bounds.midY-center.y*scale),animated:animated)}
    private func setCamera(zoom next:Double,pan point:CGPoint,animated:Bool){
        if !spatial && next>=0.5 {let rect=CGRect(x:-point.x/next,y:-point.y/next,width:bounds.width/next,height:bounds.height/next).insetBy(dx:-180,dy:-120);requestLabels(Array(index.query(rect).prefix(180)))}
        momentum = .zero;if animated && !reduceMotion {cameraAnimation=(zoom,pan,next,point,CACurrentMediaTime());startTimer()} else {cameraAnimation=nil;zoom=next;pan=point;needsDisplay=true;publishOverview()}}
    private func move(_ i:Int,to p:CGPoint){let old=positions[i];positions[i]=p;index.move(i,from:old,to:p)}
    private func beginPhysics(_ i:Int){
        guard !reduceMotion else{return}
        activePhysics=[i]
        for e in adjacency[i].prefix(32) {if let a=lookup[edges[e].a],let b=lookup[edges[e].b]{activePhysics.insert(a);activePhysics.insert(b)}}
        let p=positions[i];for j in index.query(CGRect(x:p.x-450,y:p.y-450,width:900,height:900)).prefix(50){activePhysics.insert(j)}
        resting=Dictionary(uniqueKeysWithValues:activePhysics.map {($0,positions[$0])});velocity=Dictionary(uniqueKeysWithValues:activePhysics.map {($0,CGPoint.zero)});simulationTicks=0
    }
    private func startTimer(){guard timer==nil,interactionEnabled else{return};timer=Timer(timeInterval:1/60,repeats:true){[weak self] _ in MainActor.assumeIsolated {self?.tick()}};RunLoop.main.add(timer!,forMode:.common)}
    private func tick(){
        let navigating=cameraAnimation != nil || hypot(momentum.x,momentum.y)>0.12 || hypot(orbitVelocity.x,orbitVelocity.y)>0.0002
        defer {if navigating {constrainNavigation()};publishOverview()}
        var live=false
        if spatial && !reduceMotion && hypot(orbitVelocity.x, orbitVelocity.y) > 0.0002 {
            orbit.rotate(x: orbitVelocity.x, y: orbitVelocity.y)
            orbitVelocity.x *= 0.90;orbitVelocity.y *= 0.90
            projectionDirty = true;live = true
        }
        if let morph {
            projectionDirty = true
            if CACurrentMediaTime() - morph.start >= 0.9 { self.morph = nil;dissolvingEdges.removeAll() }
            else { live = true }
        }
        if formationActive && !reduceMotion && interactionEnabled { live = true }
        if let (startZ,startP,endZ,endP,start)=cameraAnimation {
            let t=min(1,(CACurrentMediaTime()-start)/0.42),ease=1-pow(1-t,3)
            zoom=startZ+(endZ-startZ)*ease;pan=CGPoint(x:startP.x+(endP.x-startP.x)*ease,y:startP.y+(endP.y-startP.y)*ease)
            if t>=1{cameraAnimation=nil}else{live=true}
        }
        if hypot(momentum.x,momentum.y)>0.12 {pan.x+=momentum.x;pan.y+=momentum.y;momentum.x*=0.90;momentum.y*=0.90;live=true}
        if !activePhysics.isEmpty && !reduceMotion {
            simulationTicks+=1;var speed=0.0
            for i in activePhysics where i != dragIndex {
                let p=positions[i],home=resting[i] ?? p
                var force=CGPoint(x:(home.x-p.x)*0.012,y:(home.y-p.y)*0.012)
                for e in adjacency[i].prefix(16) {
                    guard let a=lookup[edges[e].a],let b=lookup[edges[e].b] else{continue};let j=a==i ? b:a
                    guard activePhysics.contains(j) else{continue}
                    let q=positions[j],dx=q.x-p.x,dy=q.y-p.y,d=max(1,hypot(dx,dy))
                    let h=resting[j] ?? q,rest=max(130,hypot(h.x-home.x,h.y-home.y));let pull=(d-rest)*0.008
                    force.x+=dx/d*pull;force.y+=dy/d*pull
                }
                for j in index.query(CGRect(x:p.x-180,y:p.y-110,width:360,height:220)) where j != i {
                    let dx=p.x-positions[j].x,dy=p.y-positions[j].y
                    if abs(dx)<170 && abs(dy)<100 {let d=max(1,hypot(dx,dy));let strength=(170-d)*0.01;force.x+=dx/d*strength;force.y+=dy/d*strength}
                }
                let v=velocity[i] ?? .zero;let next=CGPoint(x:(v.x+force.x)*0.84,y:(v.y+force.y)*0.84);velocity[i]=next;move(i,to:CGPoint(x:p.x+next.x,y:p.y+next.y));speed+=hypot(next.x,next.y)
            }
            if dragIndex != nil || speed>0.25 && simulationTicks<240 {live=true} else {activePhysics.removeAll();rebuildLOD()}
        }
        needsDisplay=true
        if !live {timer?.invalidate();timer=nil}
    }
}

extension RecommendationCanvasView {
    func setSpatial(_ enabled: Bool) {
        guard spatial != enabled else { return }
        spatial = enabled;orbit = RecommendationOrbit();orbitVelocity = .zero;clearCameraHistory()
        activePhysics.removeAll();momentum = .zero;projectionDirty = true
        setAccessibilityLabel(enabled ? String(localized: "Story map. Drag to rotate in 3D, Shift-drag or scroll to pan, pinch to zoom. Select a story to preview it.", bundle: .module) : String(localized: "Recommendation map. Scroll to pan, pinch to zoom, and select a story to preview it.", bundle: .module))
        if !nodes.isEmpty { fit(animated: false) }
        needsDisplay = true
    }

    private func updateProjection() {
        guard spatial, projectionDirty || projected.count != positions.count else { return }
        let points = morph == nil ? positions : positions.indices.map { displayPosition($0) }
        projected = orbit.project(points, seeds: depthSeeds, center: projectionCenter, radius: projectionRadius, centerDepth: projectionCenterDepth)
        projectedIndex = RecommendationSpatialGrid(cell: 240)
        for i in projected.indices { projectedIndex.insert(i, projected[i].point) }
        projectionDirty = false
        refreshNavigationGeometry()
    }

    private var projectedBounds: CGRect {
        guard let first = projected.first else { return contentBounds }
        var minX = first.point.x, maxX = minX, minY = first.point.y, maxY = minY
        for item in projected {
            minX = min(minX, item.point.x);maxX = max(maxX, item.point.x)
            minY = min(minY, item.point.y);maxY = max(maxY, item.point.y)
        }
        return CGRect(x: minX-120, y: minY-120, width: maxX-minX+240, height: maxY-minY+240)
    }

    private func screenPosition(_ i: Int) -> CGPoint {
        screen(spatial && projected.indices.contains(i) ? projected[i].point : displayPosition(i))
    }

    private func sphereStyle(_ i: Int) -> RecommendationSphereStyle {
        RecommendationSphereStyle(projection: projected[i], sceneRadius: projectionRadius, zoom: zoom)
    }

    private func material(_ i: Int) -> RecommendationSphereAtlas.Material {
        adjacency[i].isEmpty ? .amberLens : .lightHalo
    }

    private func drawSpatialMap(_ context: CGContext) {
        updateProjection()
        if sphereSprites.isEmpty {
            let dark=effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua
            sphereSprites=[sphereAtlas.images(material:.amberLens,dark:dark),sphereAtlas.images(material:.lightHalo,dark:dark)]
        }
        if let morph, !dissolvingEdges.isEmpty {
            context.saveGState()
            context.setAlpha(max(0,1-(CACurrentMediaTime()-morph.start)/0.65))
            for (a,b) in dissolvingEdges { strokeEdge(a,b,context:context,highlighted:false,overview:true) }
            context.restoreGState()
        }
        let visible = projectedIndex.query(viewport).filter { viewport.contains(projected[$0].point) }
        visibleCount = visible.count
        // Screen-space LOD: close points share one marker in overview, but every
        // actual story stays in the projection index for precise picking.
        var buckets: [RecommendationGridKey: Int] = [:]
        let cell = zoom < 0.3 ? 12.0 : 7.0
        for i in visible {
            let p = screenPosition(i), key = RecommendationGridKey(x: Int(floor(p.x/cell)), y: Int(floor(p.y/cell)))
            if let old = buckets[key], projected[old].depth > projected[i].depth { continue }
            buckets[key] = i
        }
        bucketCount = buckets.count
        var drawn = Set(buckets.values.sorted { nodes[$0].rank < nodes[$1].rank }.prefix(2400))
        if let selected { drawn.insert(selected);drawn.formUnion(neighbors.prefix(64)) }
        if let hovered { drawn.insert(hovered) }
        spatialDrawnNodes = drawn.count
        var edgeIDs = Set<Int>()
        for i in drawn { edgeIDs.formUnion(adjacency[i]) }
        let active = hovered ?? selected
        // Selected links precede the bounded overview; no all-pairs work during
        // camera motion and no per-story retained drawing objects.
        let activeEdges = active.map { Set(adjacency[$0]) } ?? []
        let orderedEdges = edgeIDs.sorted { a, b in
            let ap = activeEdges.contains(a)
            let bp = activeEdges.contains(b)
            return ap == bp ? a < b : ap
        }
        var paths: [Int: CGMutablePath] = [:]
        for e in orderedEdges.prefix(1600) {
            guard let a=lookup[edges[e].a], let b=lookup[edges[e].b] else { continue }
            let highlighted = a == active || b == active
            if focusOnly && !highlighted { continue }
            let p=screenPosition(a), q=screenPosition(b)
            let box=CGRect(x:min(p.x,q.x)-1,y:min(p.y,q.y)-1,width:abs(p.x-q.x)+2,height:abs(p.y-q.y)+2)
            guard box.intersects(bounds) else { continue }
            let fog = min(sphereStyle(a).opacity, sphereStyle(b).opacity)
            let key = (highlighted ? 64 : 0) + Int(min(alpha(a),alpha(b)) * fog * 32)
            let path=paths[key] ?? CGMutablePath();path.move(to:p);path.addLine(to:q);paths[key]=path
            drawnEdges += 1
        }
        for (key,path) in paths {
            let highlighted = key >= 64, depth = Double(key % 64) / 32
            context.setStrokeColor((highlighted ? NSColor(NookTheme.accent).withAlphaComponent(0.25 + depth * 0.4)
                : NSColor.labelColor.withAlphaComponent(depth * 0.18)).cgColor)
            context.setLineWidth(highlighted ? 1.1 : 0.45 + depth * 0.4);context.addPath(path);context.strokePath()
        }
        let sorted = drawn.sorted { projected[$0].depth < projected[$1].depth }
        context.saveGState()
        context.interpolationQuality = .medium
        // AppKit's canvas is flipped. Flip this entire image pass once so the
        // baked light stays at the upper left instead of lighting from below.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        for i in sorted {
            let p = screenPosition(i), style = sphereStyle(i)
            guard bounds.insetBy(dx:-40,dy:-40).contains(p) else { continue }
            let ready = !formationActive || analyzed.contains(i)
            let images = sphereSprites[material(i).rawValue]
            guard images.indices.contains(style.blurLevel) else { continue }
            // Sprite padding includes the complete Gaussian halo. Draw far to
            // near so close spheres naturally cover distant ones at crossings.
            let half = style.radius * Double(RecommendationSphereAtlas.side) / (2 * RecommendationSphereAtlas.sphereRadius)
            context.setAlpha(alpha(i) * style.opacity * (ready ? 1 : 0.18))
            context.draw(images[style.blurLevel], in: CGRect(x:p.x-half,y:bounds.height-p.y-half,width:half*2,height:half*2))
        }
        context.restoreGState()
        // Text work is bounded separately from geometry. Rasterized labels are
        // reused as the camera moves, and only the selected neighborhood is named.
        var labels = zoom >= fitZoom * 2.5 ? Array(sorted.reversed().filter { sphereStyle($0).proximity > 0.5 }.prefix(36)) : []
        if let selected { labels.removeAll { $0 == selected };labels.insert(selected,at:0) }
        if let hovered, hovered != selected { labels.removeAll { $0 == hovered };labels.insert(hovered,at:0) }
        requestLabels(labels)
        for i in labels { drawNode(i,context:context) }
        if formationActive && !reduceMotion {
            let now=CACurrentMediaTime(), accent=NSColor(NookTheme.accent)
            let breath = 0.5+0.5*sin(now*2.6)
            for i in lastActivated {
                let p=screenPosition(i), radius=5+breath*5
                guard bounds.contains(p) else { continue }
                context.setStrokeColor(accent.withAlphaComponent(0.15+breath*0.25).cgColor)
                context.setLineWidth(0.8);context.strokeEllipse(in:CGRect(x:p.x-radius,y:p.y-radius,width:radius*2,height:radius*2))
            }
            for (a,b,start) in pulses where now-start < 2.4 {
                let p=screenPosition(a),q=screenPosition(b),fade=min(1,max(0,(2.4-(now-start))/1.8))
                guard bounds.contains(p) || bounds.contains(q) else { continue }
                let t=min(1,(now-start)/0.4),end=CGPoint(x:p.x+(q.x-p.x)*t,y:p.y+(q.y-p.y)*t)
                for (width,opacity) in [(5.0,0.06),(1.1,0.8)] {
                    context.setStrokeColor(accent.withAlphaComponent(fade*opacity).cgColor);context.setLineWidth(width)
                    context.beginPath();context.move(to:p);context.addLine(to:end);context.strokePath()
                }
            }
        }
    }

    #if DEBUG
    func advanceOrbit(x: Double, y: Double) {
        orbit.rotate(x:x,y:y);projectionDirty = true;needsDisplay = true
    }
    var renderTimes: [Double] { drawSamples }
    var spatialDrawInspection: (nodes: Int, edges: Int, labels: Int) { (spatialDrawnNodes,drawnEdges,labelRects.count) }

    func inspectOrbit(x: Double = 0, y: Double = 0) -> (points: [String: CGPoint], yaw: Double, pitch: Double) {
        orbit.rotate(x: x,y: y);projectionDirty = true;updateProjection()
        return (Dictionary(uniqueKeysWithValues:nodes.indices.map { (nodes[$0].id,projected[$0].point) }),orbit.yaw,orbit.pitch)
    }
    #endif
}

extension RecommendationCanvasView {
    private var fitZoom: Double {
        let box = navigationBounds
        return max(0.018, min(1.1, min(max(100, bounds.width - 140) / max(1, box.width),
                                    max(100, bounds.height - 180) / max(1, box.height))))
    }
    private var minimumZoom: Double { fitZoom * 0.8 }
    private var maximumZoom: Double { min(2.5, fitZoom * 12) }
    private var cameraPosition: RecommendationCameraPosition {
        RecommendationCameraPosition(zoom: zoom, pan: pan, orbit: orbit,
                                     center: projectionCenter, centerDepth: projectionCenterDepth)
    }
    func clearCameraHistory() {
        cameraHistory.removeAll();publishOverview()
    }
    private func markCameraInteraction() {
        if formationActive { formationCameraAdjusted = true }
        orbitVelocity = .zero;momentum = .zero;cameraAnimation = nil
    }
    private func rememberCamera() {
        guard interactionEnabled, firstFit, !nodes.isEmpty else { return }
        let current = cameraPosition
        if let last = cameraHistory.last,
           abs(last.zoom - current.zoom) < 0.0001,
           hypot(last.pan.x-current.pan.x, last.pan.y-current.pan.y) < 2,
           abs(last.orbit.yaw-current.orbit.yaw) < 0.001,
           abs(last.orbit.pitch-current.orbit.pitch) < 0.001,
           last.center == current.center, last.centerDepth == current.centerDepth { return }
        cameraHistory.append(current)
        if cameraHistory.count > 20 { cameraHistory.removeFirst() }
        publishOverview()
    }
    func navigateBack() {
        guard interactionEnabled, !nodes.isEmpty, let saved = cameraHistory.popLast() else { return }
        markCameraInteraction()
        orbit = saved.orbit;projectionCenter = saved.center;projectionCenterDepth = saved.centerDepth
        projectionDirty = true;updateProjection()
        setCamera(zoom: saved.zoom, pan: saved.pan, animated: false)
        constrainNavigation();publishOverview()
        needsDisplay = true
    }
    func navigateToFit() {
        guard interactionEnabled else { return }
        rememberCamera();markCameraInteraction();fit(animated: true)
    }
    func resetDirection() {
        guard interactionEnabled, spatial else { return }
        rememberCamera();markCameraInteraction()
        orbit = RecommendationOrbit();projectionDirty = true
        fit(animated: true)
    }
    func navigateZoom(_ factor: Double) {
        guard interactionEnabled else { return }
        rememberCamera();markCameraInteraction()
        zoomBy(factor, anchor: CGPoint(x: bounds.midX, y: bounds.midY), animated: true)
    }
    func navigateOverview(to normalized: CGPoint, remember: Bool) {
        guard interactionEnabled, spatial, !nodes.isEmpty,
              normalized.x.isFinite, normalized.y.isFinite else { return }
        if remember { rememberCamera();window?.makeFirstResponder(self) }
        markCameraInteraction();updateProjection()
        let box = navigationBounds
        let requested = CGPoint(x: box.minX + min(1, max(0, normalized.x)) * box.width,
                                y: box.minY + min(1, max(0, normalized.y)) * box.height)
        // A click between clusters lands on a real overview story, not empty
        // space. Both navigation and drawing reuse this bounded sample.
        let point = overviewPoints.min { a, b in
            hypot(a.x-requested.x, a.y-requested.y) < hypot(b.x-requested.x, b.y-requested.y)
        } ?? requested
        setCamera(zoom: zoom, pan: CGPoint(x: bounds.midX-point.x*zoom, y: bounds.midY-point.y*zoom), animated: false)
        constrainNavigation()
    }
    private func refreshNavigationGeometry() {
        navigationBounds = projectedBounds
        let step = max(1, Int(ceil(Double(projected.count) / 600)))
        overviewPoints = stride(from: 0, to: projected.count, by: step).map { projected[$0].point }
    }
    private func constrainNavigation() {
        guard interactionEnabled, spatial, !nodes.isEmpty, bounds.width > 0, bounds.height > 0 else { return }
        updateProjection()
        let previous = pan
        let nextZoom = min(maximumZoom, max(minimumZoom, zoom))
        if nextZoom != zoom {
            let center = world(CGPoint(x: bounds.midX, y: bounds.midY))
            zoom = nextZoom;pan = CGPoint(x: bounds.midX-center.x*zoom, y: bounds.midY-center.y*zoom)
        }
        let box = navigationBounds
        let inset = min(90, min(bounds.width, bounds.height) * 0.15)
        pan.x = min(bounds.width - inset - box.minX * zoom, max(inset - box.maxX * zoom, pan.x))
        pan.y = min(bounds.height - inset - box.minY * zoom, max(inset - box.maxY * zoom, pan.y))
        let visible = CGRect(x: (inset-pan.x)/zoom, y: (inset-pan.y)/zoom, width: (bounds.width-2*inset)/zoom, height: (bounds.height-2*inset)/zoom)
        let hasContent = overviewPoints.contains { visible.contains($0) }
            || projectedIndex.query(visible).contains { visible.contains(projected[$0].point) }
        let currentScale = zoom, offset = pan, canvasSize = bounds.size
        if !hasContent, let closest = overviewPoints.min(by: { a, b in
            func distance(_ p: CGPoint) -> Double {
                let q = CGPoint(x: p.x*currentScale+offset.x, y: p.y*currentScale+offset.y)
                let dx = max(inset-q.x, 0, q.x-(canvasSize.width-inset))
                let dy = max(inset-q.y, 0, q.y-(canvasSize.height-inset))
                return dx*dx+dy*dy
            }
            return distance(a) < distance(b)
        }) {
            let q = screen(closest)
            pan.x += min(bounds.width-inset, max(inset, q.x)) - q.x
            pan.y += min(bounds.height-inset, max(inset, q.y)) - q.y
        }
        if abs(pan.x-previous.x) > 0.5 { momentum.x = 0 }
        if abs(pan.y-previous.y) > 0.5 { momentum.y = 0 }
    }
    private var overviewSnapshot: RecommendationMapOverview {
        guard !nodes.isEmpty else { return RecommendationMapOverview() }
        guard spatial else {
            return RecommendationMapOverview(canGoBack: !cameraHistory.isEmpty, percent: Int((zoom*100).rounded()))
        }
        let box = navigationBounds
        func normalize(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x-box.minX)/box.width, y: (p.y-box.minY)/box.height)
        }
        let viewport = CGRect(x: -pan.x/zoom, y: -pan.y/zoom, width: bounds.width/zoom, height: bounds.height/zoom)
        return RecommendationMapOverview(points: overviewPoints.map(normalize),
            viewport: CGRect(origin: normalize(viewport.origin), size: CGSize(width: viewport.width/box.width, height: viewport.height/box.height)),
            selected: selected.flatMap { projected.indices.contains($0) ? normalize(projected[$0].point) : nil },
            canGoBack: !cameraHistory.isEmpty, percent: Int((zoom/fitZoom*100).rounded()))
    }
    private func publishOverview() {
        guard onOverview != nil, !overviewQueued else { return }
        overviewQueued = true
        let delay = max(0, 0.05 - (CACurrentMediaTime() - overviewPublished))
        // Defer outside AppKit drawing/SwiftUI updates; only the minimap leaf
        // observes this snapshot. Graph and inspector never update per frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.overviewQueued = false
            guard self.interactionEnabled else { return }
            self.overviewPublished = CACurrentMediaTime()
            self.updateProjection()
            self.onOverview?(self.overviewSnapshot)
        }
    }

    #if DEBUG
    var navigationInspection: (overview: RecommendationMapOverview, minimumZoom: Double, maximumZoom: Double, visible: Int, history: Int) {
        updateProjection()
        let visible = projected.filter { bounds.insetBy(dx: 2, dy: 2).contains(screen($0.point)) }.count
        return (overviewSnapshot, minimumZoom, maximumZoom, visible, cameraHistory.count)
    }
    func materialForStory(_ id: String) -> RecommendationSphereAtlas.Material? {
        lookup[id].map { material($0) }
    }
    #endif
}

#endif
