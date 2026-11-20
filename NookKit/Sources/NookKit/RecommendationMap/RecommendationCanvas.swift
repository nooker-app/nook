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
@MainActor @Observable final class RecommendationCanvasControl {
    weak var view: RecommendationCanvasView?
    var zoomText="100%"
    func zoom(_ factor:Double){view?.zoomBy(factor,anchor:CGPoint(x:(view?.bounds.width ?? 0)/2,y:(view?.bounds.height ?? 0)/2),animated:true)}
    func fit(){view?.fit(animated:true)}
    func focus(){view?.focusSelection()}
}
struct RecommendationCanvasHost:NSViewRepresentable {
    var model:RecommendationMapController
    var control:RecommendationCanvasControl
    var reduceMotion:Bool
    func makeNSView(context:Context)->RecommendationCanvasView {
        let view=RecommendationCanvasView();control.view=view
        view.onSelect={id in model.select(id)}
        view.onOpen={model.openSelected()}
        view.onZoom={text in if control.zoomText != text {control.zoomText=text}}
        return view
    }
    func updateNSView(_ view:RecommendationCanvasView,context:Context){
        view.reduceMotion=reduceMotion;view.interactionEnabled=model.isInteractive
        let changedCollection = view.collection != model.collection
        view.collection = model.collection
        if view.revision != model.graphRevision {view.install(model.graph,revision:model.graphRevision,layoutRevision:model.layoutRevision)}
        view.updateSelection(model.selectedID)
        if changedCollection { view.fit(animated: true) }
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
    var onZoom:((String)->Void)?
    var reduceMotion=false
    var interactionEnabled=true {
        didSet {
            if !interactionEnabled {
                timer?.invalidate();timer=nil;cameraAnimation=nil;momentum = .zero
                activePhysics.removeAll();dragIndex=nil;hovered=nil
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
    override init(frame:NSRect){super.init(frame:frame);wantsLayer=true;layer?.masksToBounds=true;setAccessibilityElement(true);setAccessibilityRole(.group);setAccessibilityLabel(String(localized: "Recommendation map. Scroll to pan, pinch to zoom, and select a story to preview it.", bundle: .module))}
    required init?(coder:NSCoder){fatalError()}
    override func updateTrackingAreas(){super.updateTrackingAreas();if let tracking {removeTrackingArea(tracking)};let area=NSTrackingArea(rect:bounds,options:[.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self);addTrackingArea(area);tracking=area}
    override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();labelImages.removeAll();pendingLabels.removeAll();needsDisplay=true}
    override func viewWillMove(toWindow newWindow:NSWindow?){if newWindow == nil {timer?.invalidate();timer=nil;cameraAnimation=nil;momentum = .zero;activePhysics.removeAll()};super.viewWillMove(toWindow:newWindow)}
    override func resetCursorRects(){addCursorRect(bounds,cursor:.openHand)}
    override func layout(){super.layout();if !firstFit && !nodes.isEmpty && bounds.width>10 {firstFit=true;fit(animated:false)}}
    func install(_ graph:RecommendationGraph,revision:Int,layoutRevision:Int){
        self.revision=revision
        let changesLayout=self.layoutRevision != layoutRevision
        self.layoutRevision=layoutRevision
        if changesLayout {focusedInitialSelection=false}
        if graph.nodes.isEmpty {firstFit=false;focusedInitialSelection=false;timer?.invalidate();timer=nil;cameraAnimation=nil;momentum = .zero;lod.removeAll()}
        let old=Dictionary(uniqueKeysWithValues:(changesLayout ? []:Array(zip(nodes,positions))).map {($0.0.id,$0.1)})
        nodes=graph.nodes;edges=graph.edges;lookup=Dictionary(uniqueKeysWithValues:nodes.enumerated().map {($0.element.id,$0.offset)})
        positions=nodes.map {old[$0.id] ?? $0.position};colors=nodes.map {NSColor(recommendationTopicColor($0.topic))}
        index=RecommendationSpatialGrid(cell:240);adjacency=Array(repeating:[],count:nodes.count)
        for i in nodes.indices {index.insert(i,positions[i])}
        for e in edges.indices {if let a=lookup[edges[e].a],let b=lookup[edges[e].b]{adjacency[a].append(e);adjacency[b].append(e)}}
        labelImages.removeAll();pendingLabels.removeAll();labelAccess.removeAll()
        rebuildLOD();selected=nil;hovered=nil;activePhysics.removeAll();velocity.removeAll()
        if !firstFit && !nodes.isEmpty && bounds.width>10 {firstFit=true;fit(animated:false)}
        needsDisplay=true
    }
    private func rebuildLOD(){
        guard !positions.isEmpty else{return}
        let minX=positions.map(\.x).min()!-180,maxX=positions.map(\.x).max()!+180,minY=positions.map(\.y).min()!-180,maxY=positions.map(\.y).max()!+180
        contentBounds=CGRect(x:minX,y:minY,width:maxX-minX,height:maxY-minY)
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
        let next=id.flatMap {lookup[$0]};guard next != selected else{return};let previous=selected;selected=next;updateNeighbors()
        if !focusedInitialSelection && next != nil {
            focusedInitialSelection=true;focusSelection()
        } else if previous != nil && dragIndex == nil {focusSelection()};needsDisplay=true
    }
    private func updateNeighbors(){neighbors=[];if let active=hovered ?? selected {neighbors.insert(active);for e in adjacency[active]{if let a=lookup[edges[e].a],let b=lookup[edges[e].b]{neighbors.insert(a);neighbors.insert(b)}}}}
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
        let began=CACurrentMediaTime();drawTick+=1
        guard let context=NSGraphicsContext.current?.cgContext else{return}
        context.setFillColor(NSColor(NookTheme.canvas).cgColor);context.fill(bounds)
        let spacing=max(18,min(42,72*zoom)),dx=pan.x.truncatingRemainder(dividingBy:spacing),dy=pan.y.truncatingRemainder(dividingBy:spacing)
        context.setFillColor(NSColor.labelColor.withAlphaComponent(0.07).cgColor)
        for x in stride(from:dx,through:bounds.width,by:spacing){for y in stride(from:dy,through:bounds.height,by:spacing){context.fillEllipse(in:CGRect(x:x,y:y,width:1,height:1))}}
        drawnEdges=0;bucketCount=0;labelRects.removeAll(keepingCapacity:true)
        if lodCell != nil {
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
        if let selected,positions.indices.contains(selected),lodCell != nil {drawNode(selected,context:context,force:true)}
        let elapsed=(CACurrentMediaTime()-began)*1000;drawSamples.append(elapsed);if drawSamples.count>600{drawSamples.removeFirst(drawSamples.count-600)}
    }
    private func strokeEdge(_ a:Int,_ b:Int,context:CGContext,highlighted:Bool,overview:Bool){
        let p=screen(positions[a]),q=screen(positions[b])
        let opacity=(highlighted ? 0.62 : overview ? 0.10:0.18)*min(alpha(a),alpha(b))
        let color=highlighted ? NSColor(NookTheme.accent):NSColor.labelColor
        context.setStrokeColor(color.withAlphaComponent(opacity).cgColor);context.setLineWidth(highlighted ? 1.2:0.6)
        context.beginPath();context.move(to:p);context.addQuadCurve(to:q,control:CGPoint(x:(p.x+q.x)/2-(q.y-p.y)*0.035,y:(p.y+q.y)/2+(q.x-p.x)*0.035));context.strokePath()
    }
    private func drawNode(_ i:Int,context:CGContext,force:Bool=false){
        let p=screen(positions[i]);guard bounds.insetBy(dx:-100,dy:-100).contains(p) else{return}
        let active=i==selected,over=i==hovered
        let r=force ? 8:max(4,min(24,(16+Double(max(0,24-nodes[i].rank))*0.3)*sqrt(zoom)))
        let opacity=alpha(i);context.setFillColor(colors[i].withAlphaComponent((active ? 0.30:0.15)*opacity).cgColor);context.fillEllipse(in:CGRect(x:p.x-r,y:p.y-r,width:2*r,height:2*r))
        context.setStrokeColor(colors[i].withAlphaComponent((active || over ? 0.95:0.65)*opacity).cgColor);context.setLineWidth(active ? 1.7:0.9);context.strokeEllipse(in:CGRect(x:p.x-r,y:p.y-r,width:2*r,height:2*r))
        if active {context.setStrokeColor(NSColor(NookTheme.accent).withAlphaComponent(0.25).cgColor);context.strokeEllipse(in:CGRect(x:p.x-r-5,y:p.y-r-5,width:2*r+10,height:2*r+10))}
        if zoom>=0.55 || over || active && !force {
            context.saveGState();context.setAlpha(opacity)
            let number=(nodes[i].article.isRead ? "✓" : "\(nodes[i].rank)") as NSString
            let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedDigitSystemFont(ofSize:9,weight:active ? .semibold:.regular),.foregroundColor:colors[i]]
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
        if lodCell != nil{return nil}
        let w=world(p);let radius=100/zoom
        return index.query(CGRect(x:w.x-radius,y:w.y-radius,width:radius*2,height:radius*2)).filter {i in
            let q=screen(positions[i]);return alpha(i)>0.2 && (hypot(p.x-q.x,p.y-q.y)<max(18,24*sqrt(zoom)) || zoom>=0.55 && CGRect(x:q.x-80,y:q.y+12,width:160,height:53).contains(p))
        }.min {hypot(positions[$0].x-w.x,positions[$0].y-w.y)<hypot(positions[$1].x-w.x,positions[$1].y-w.y)}
    }
    override func mouseMoved(with event:NSEvent){guard interactionEnabled else{return};let p=convert(event.locationInWindow,from:nil);let next=hit(p);if next != hovered {hovered=next;updateNeighbors();needsDisplay=true};(next == nil ? NSCursor.openHand:NSCursor.pointingHand).set()}
    override func mouseExited(with event:NSEvent){hovered=nil;updateNeighbors();needsDisplay=true}
    override func mouseDown(with event:NSEvent){guard interactionEnabled else{return};window?.makeFirstResponder(self);cameraAnimation=nil;momentum = .zero;lastMouse=convert(event.locationInWindow,from:nil);dragIndex=hit(lastMouse);mouseMovedDistance=0;dragHistory=[(CACurrentMediaTime(),lastMouse)];if let i=dragIndex {beginPhysics(i)};NSCursor.closedHand.set()}
    override func mouseDragged(with event:NSEvent){guard interactionEnabled else{return};let p=convert(event.locationInWindow,from:nil);let dx=p.x-lastMouse.x,dy=p.y-lastMouse.y;mouseMovedDistance+=hypot(dx,dy)
        if let i=dragIndex {move(i,to:CGPoint(x:positions[i].x+dx/zoom,y:positions[i].y+dy/zoom));velocity[i] = .zero;startTimer()}
        else {pan.x+=dx;pan.y+=dy}
        lastMouse=p;dragHistory.append((CACurrentMediaTime(),p));dragHistory=Array(dragHistory.suffix(5));needsDisplay=true
    }
    override func mouseUp(with event:NSEvent){guard interactionEnabled else{return};let p=convert(event.locationInWindow,from:nil)
        if mouseMovedDistance<4 {
            if let i=dragIndex {onSelect?(nodes[i].id);if event.clickCount==2 {onOpen?()}}
            else if lodCell != nil,let closest=buckets().min(by:{hypot(screen($0.center).x-p.x,screen($0.center).y-p.y)<hypot(screen($1.center).x-p.x,screen($1.center).y-p.y)}),hypot(screen(closest.center).x-p.x,screen(closest.center).y-p.y)<35 {
                animateCamera(to:0.85,center:closest.center);onSelect?(nodes[closest.first].id)
            } else if event.clickCount==2 {zoomBy(1.7,anchor:p,animated:true)}
        } else if let i=dragIndex {resting[i]=positions[i]} else if let start=dragHistory.first {
            let dt=max(0.016,CACurrentMediaTime()-start.0);momentum=CGPoint(x:(p.x-start.1.x)/dt/60,y:(p.y-start.1.y)/dt/60);if !reduceMotion {startTimer()}
        }
        dragIndex=nil;NSCursor.openHand.set();needsDisplay=true
    }
    override func scrollWheel(with event:NSEvent){guard interactionEnabled else{super.scrollWheel(with:event);return};cameraAnimation=nil;momentum = .zero
        let p=convert(event.locationInWindow,from:nil)
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) || !event.hasPreciseScrollingDeltas {zoomBy(exp(event.scrollingDeltaY*(event.hasPreciseScrollingDeltas ? 0.008:0.07)),anchor:p,animated:false)}
        else {pan.x+=event.scrollingDeltaX;pan.y+=event.scrollingDeltaY;needsDisplay=true}
    }
    override func magnify(with event:NSEvent){guard interactionEnabled else{return};zoomBy(1+event.magnification,anchor:convert(event.locationInWindow,from:nil),animated:false)}
    override func smartMagnify(with event:NSEvent){guard interactionEnabled else{return};if zoom>0.4 {fit(animated:true)} else {zoomBy(4,anchor:convert(event.locationInWindow,from:nil),animated:true)}}
    override func keyDown(with event:NSEvent){guard interactionEnabled else{super.keyDown(with:event);return};switch event.keyCode {case 123:pan.x+=70;case 124:pan.x-=70;case 125:pan.y-=70;case 126:pan.y+=70;case 36:onOpen?();case 53:fit(animated:true);default:super.keyDown(with:event)};needsDisplay=true}
    func zoomBy(_ factor:Double,anchor:CGPoint,animated:Bool){let target=min(2.5,max(0.018,zoom*factor));let w=world(anchor);let next=CGPoint(x:anchor.x-w.x*target,y:anchor.y-w.y*target);setCamera(zoom:target,pan:next,animated:animated)}
    func fit(animated:Bool){guard !nodes.isEmpty else{return};let scale=min((bounds.width-100)/contentBounds.width,(bounds.height-150)/contentBounds.height);animateCamera(to:max(0.018,min(1.1,scale)),center:CGPoint(x:contentBounds.midX,y:contentBounds.midY),animated:animated)}
    func focusSelection(){guard let selected else{return};animateCamera(to:max(0.85,zoom),center:positions[selected])}
    private func animateCamera(to scale:Double,center:CGPoint,animated:Bool=true){setCamera(zoom:scale,pan:CGPoint(x:bounds.midX-center.x*scale,y:bounds.midY-center.y*scale),animated:animated)}
    private func setCamera(zoom next:Double,pan point:CGPoint,animated:Bool){
        if next>=0.5 {let rect=CGRect(x:-point.x/next,y:-point.y/next,width:bounds.width/next,height:bounds.height/next).insetBy(dx:-180,dy:-120);requestLabels(Array(index.query(rect).prefix(180)))}
        momentum = .zero;if animated && !reduceMotion {cameraAnimation=(zoom,pan,next,point,CACurrentMediaTime());startTimer()} else {cameraAnimation=nil;zoom=next;pan=point;needsDisplay=true;onZoom?("\(Int(zoom*100))%")}}
    private func move(_ i:Int,to p:CGPoint){let old=positions[i];positions[i]=p;index.move(i,from:old,to:p)}
    private func beginPhysics(_ i:Int){
        guard !reduceMotion else{return}
        activePhysics=[i]
        for e in adjacency[i].prefix(32) {if let a=lookup[edges[e].a],let b=lookup[edges[e].b]{activePhysics.insert(a);activePhysics.insert(b)}}
        let p=positions[i];for j in index.query(CGRect(x:p.x-450,y:p.y-450,width:900,height:900)).prefix(50){activePhysics.insert(j)}
        resting=Dictionary(uniqueKeysWithValues:activePhysics.map {($0,positions[$0])});velocity=Dictionary(uniqueKeysWithValues:activePhysics.map {($0,CGPoint.zero)});simulationTicks=0
    }
    private func startTimer(){guard timer==nil else{return};timer=Timer(timeInterval:1/60,repeats:true){[weak self] _ in MainActor.assumeIsolated {self?.tick()}};RunLoop.main.add(timer!,forMode:.common)}
    private func tick(){
        var live=false
        if let (startZ,startP,endZ,endP,start)=cameraAnimation {
            let t=min(1,(CACurrentMediaTime()-start)/0.42),ease=1-pow(1-t,3)
            zoom=startZ+(endZ-startZ)*ease;pan=CGPoint(x:startP.x+(endP.x-startP.x)*ease,y:startP.y+(endP.y-startP.y)*ease)
            onZoom?("\(Int(zoom*100))%");if t>=1{cameraAnimation=nil}else{live=true}
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
#endif
