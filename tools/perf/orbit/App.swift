import AppKit
import QuartzCore
@main struct Harness {
    @MainActor static func main() {
        let delegate=Delegate();NSApplication.shared.delegate=delegate
        NSApplication.shared.run()
    }
}
@MainActor final class Delegate:NSObject,NSApplicationDelegate {
    var window:NSWindow!;var view:RecommendationCanvasView!;var link:CADisplayLink?;var tick=0;var last=0.0;var intervals:[Double]=[]
    func applicationDidFinishLaunching(_ note:Notification) {
        NSApp.setActivationPolicy(.regular)
        window=NSWindow(contentRect:CGRect(x:0,y:0,width:1200,height:800),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="Nook · 20,000-story orbit benchmark"
        view=RecommendationCanvasView(frame:CGRect(x:0,y:0,width:1200,height:800));window.contentView=view
        let nodes:[RecommendationMapNode]=(0..<20_000).map { i in
            let angle=Double(i)*2.399, radius=sqrt(Double(i))*110
            return RecommendationMapNode(article:Article(id:"story-\(i)",title:"Story \(i)"),rank:i+1,position:CGPoint(x:sin(angle)*radius,y:cos(angle)*radius),clusterID:"cluster-\(i/32)")
        }
        let edges=(1..<nodes.count).map {RecommendationMapEdge(a:nodes[$0-1].id,b:nodes[$0].id)}
        view.setSpatial(true);view.install(RecommendationGraph(nodes:nodes,edges:edges),revision:1,layoutRevision:1)
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        DispatchQueue.main.asyncAfter(deadline:.now()+1) {self.start()}
    }
    func start() {let link=view.displayLink(target:self,selector:#selector(frame(_:)));link.add(to:.main,forMode:.common);self.link=link}
    @objc func frame(_ link:CADisplayLink) {
        tick+=1
        if tick>20 && last>0 {intervals.append((link.timestamp-last)*1000)}
        last=link.timestamp
        view.advanceOrbit(x:0.012,y:0.002)
        if tick==260 {
            link.invalidate()
            let frames=intervals.sorted(), draws=Array(view.renderTimes.suffix(240)).sorted()
            print("frames=\(frames.count) p99=\(frames[Int(Double(frames.count)*0.99)])ms worst=\(frames.last!)ms over25ms=\(frames.filter{$0>25}.count)")
            print("draws=\(draws.count) median=\(draws[draws.count/2])ms p95=\(draws[Int(Double(draws.count)*0.95)])ms \(view.spatialDrawInspection)")
            NSApp.terminate(nil)
        }
    }
}
