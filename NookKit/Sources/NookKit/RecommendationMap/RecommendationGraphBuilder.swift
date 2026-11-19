import Foundation

enum RecommendationGraphBuilder {
    static func build(articles:[Article],ranks:[String:Int],library:ReaderLibrary,semantic:RecommendationSemanticIndex? = nil, originalIDs:Set<String> = []) -> RecommendationGraph {
        guard !articles.isEmpty else{return RecommendationGraph()}
        let features=RecommendationContentFeatures(articles,originalIDs:originalIDs)
        var pairs:[(Int,Int,Double,[String])]=[]
        let ranked:[[Int:Double]]
        if let semantic {
            var previous = -1
            var lexical:[Int:Double]=[:]
            ranked=semantic.neighbors(limit:24) {i,j,raw in
                if previous != i {lexical=features.related(i);previous=i}
                let lex=lexical[j] ?? 0
                let model=semantic.vectors[i]?.model ?? ""
                if model.hasPrefix("Qwen/") {
                    // Keep the broader top-24 retrieval pool for the classifier.
                    // Apply the conservative fast-map threshold separately.
                    return 0.72*raw+0.28*min(1,lex*2)
                }
                if model.hasPrefix("intfloat/") {
                    guard raw>=0.80 || (raw>=0.76 && lex>=0.08) else{return nil}
                    return 0.78*max(0,(raw-0.65)/0.35)+0.22*min(1,lex*2)
                }
                guard lex>=0.16 else{return nil}
                return 0.65*min(1,lex*2)+0.35*max(0,raw)
            }
        } else {ranked=Array(repeating:[:],count:articles.count)}
        for i in articles.indices {
            if Task.isCancelled {return RecommendationGraph()}
            var best=ranked[i]
            if let semantic, semantic.vectors[i]?.model.hasPrefix("Qwen/") == true {
                best = best.filter { j, adjusted in
                    guard let raw = semantic.cosine(i, j) else { return false }
                    return raw >= 0.40 || (raw >= 0.25 && adjusted - 0.72 * raw >= 0.28 * 0.32)
                }
            }
            // A missing or invalidated vector uses the deterministic content index.
            if semantic == nil || semantic?.vectors[i] == nil {
                best=features.related(i).filter {j,score in
                    score>=0.29 || (score>=0.12 && features.evidence(i,j).filter{$0.1>=0.008}.count>=2)
                }
            }
            let sorted=best.keys.sorted {best[$0]==best[$1] ? articles[$0].id<articles[$1].id:best[$0]!>best[$1]!}
            // Independent outgoing top-three prevents popular nodes consuming
            // every edge budget before unlabeled articles get a connection.
            var duplicateKeys=Set([RecommendationContentText.duplicateKey(articles[i])])
            var picked=0
            for j in sorted {
                guard duplicateKeys.insert(RecommendationContentText.duplicateKey(articles[j])).inserted else {continue}
                if picked==3 {break};picked+=1
                let terms=Array(features.evidence(i,j).prefix(3).map(\.0))
                pairs.append((min(i,j),max(i,j),best[j]!,terms.isEmpty ? [String(localized: "Related subject and context", bundle: .module)]:terms))
            }
        }
        pairs.sort {$0.2 == $1.2 ? ($0.0,$0.1)<($1.0,$1.1):$0.2>$1.2}
        var seen=Set<String>();var edges:[RecommendationMapEdge]=[]
        for (i,j,score,terms) in pairs {
            let key="\(i):\(j)";guard seen.insert(key).inserted else{continue}
            edges.append(RecommendationMapEdge(a:articles[i].id,b:articles[j].id,strength:score,terms:terms))
        }
        // Content communities determine geometry; user categories only determine
        // color/filter. Bound component size to preserve readable sparse layouts.
        var parent=Array(articles.indices),size=Array(repeating:1,count:articles.count)
        func root(_ i:Int)->Int {var n=i;while parent[n] != n {n=parent[n]};return n}
        for (i,j,score,_) in pairs where score >= (semantic == nil ? 0.16:0.25) {
            let a=root(i),b=root(j)
            if a != b && size[a]+size[b]<=64 {parent[b]=a;size[a]+=size[b]}
        }
        var groups:[Int:[Int]]=[:]
        for i in articles.indices {groups[root(i),default:[]].append(i)}
        let ordered=groups.keys.sorted {groups[$0]!.count == groups[$1]!.count ? articles[$0].id<articles[$1].id:groups[$0]!.count>groups[$1]!.count}
        let radii=Dictionary(uniqueKeysWithValues:ordered.map {($0,max(90,sqrt(Double(groups[$0]!.count))*105+70))})
        var centers:[Int:CGPoint]=[:]
        var buckets:[String:Set<Int>]=[:]
        var freeAttempt = 0
        var groupLinks:[Int:[Int:Double]]=[:]
        for (i,j,score,_) in pairs {let a=root(i),b=root(j);if a != b {groupLinks[a,default:[:]][b,default:0]+=score;groupLinks[b,default:[:]][a,default:0]+=score}}
        func cells(_ point:CGPoint,_ radius:Double)->[String] {
            var keys:[String]=[]
            for x in Int(floor((point.x-radius)/1000))...Int(floor((point.x+radius)/1000)) {
                for y in Int(floor((point.y-radius)/1000))...Int(floor((point.y+radius)/1000)) {keys.append("\(x):\(y)")}
            }
            return keys
        }
        for group in ordered {
            var target=CGPoint.zero,total=0.0
            for other in (groupLinks[group] ?? [:]).keys.sorted() {
                guard let p=centers[other],let weight=groupLinks[group]?[other] else {continue}
                target.x+=p.x*weight;target.y+=p.y*weight;total+=weight
            }
            if total>0 {target.x/=total;target.y/=total}
            let radius=radii[group]!
            var chosen=target
            // Disconnected communities share an origin. Restarting their
            // spiral at zero makes placement quadratic in isolated stories.
            let firstAttempt = total == 0 ? freeAttempt : 0
            for offset in 0..<20000 {
                let attempt = firstAttempt + offset
                let angle=Double(attempt)*2.399963,reach=sqrt(Double(attempt))*155
                let point=CGPoint(x:target.x+cos(angle)*reach,y:target.y+sin(angle)*reach)
                let nearby=Set(cells(point,radius+80).flatMap {buckets[$0] ?? []})
                if nearby.allSatisfy({other in let p=centers[other]!;return hypot(p.x-point.x,p.y-point.y)>=radius+radii[other]!+160}) {
                    chosen=point
                    if total == 0 { freeAttempt = attempt + 1 }
                    break
                }
                if offset==19999 {chosen=CGPoint(x:Double(group)*5000,y:50000)}
            }
            centers[group]=chosen
            for cell in cells(chosen,radius+80) {buckets[cell,default:[]].insert(group)}
        }
        var positions=Array(repeating:CGPoint.zero,count:articles.count)
        var labels:[Int:String]=[:]
        for group in ordered {
            let members=groups[group]!,center=centers[group]!
            var terms:[Int:Double]=[:]
            for i in members {for (term,value) in features.vectors[i] {terms[term,default:0]+=value}}
            labels[group]=terms.keys.sorted {terms[$0] == terms[$1] ? $0<$1:terms[$0]!>terms[$1]!}.prefix(2).map {features.words[$0]}.joined(separator:" · ")
            for (n,i) in members.enumerated() {
                let angle=Double(n)*2.399963,radius=sqrt(Double(n))*105
                positions[i]=CGPoint(x:center.x+cos(angle)*radius,y:center.y+sin(angle)*radius)
            }
        }
        let names=Dictionary(uniqueKeysWithValues:library.categories.map {($0.id,$0.name)})
        let sources=Dictionary(uniqueKeysWithValues:library.feeds.map {($0.id,$0.displayTitle)})
        let nodes: [RecommendationMapNode] = articles.indices.map { i in
            let article = articles[i]
            let rank = article.isRead ? Int.max : (ranks[article.id] ?? i + 1)
            let topic = article.categories.compactMap { names[$0] }.first ?? String(localized: "Uncategorized", bundle: .module)
            let source = sources[article.feedID] ?? article.url.host() ?? "RSS"
            var node = RecommendationMapNode(article: article, rank: rank, topic: topic, source: source, position: positions[i])
            node.clusterID = articles[root(i)].id
            node.clusterLabel = labels[root(i)] ?? ""
            return node
        }
        var candidates: [String: [RecommendationCandidate]] = [:]
        for i in articles.indices {
            let values = ranked[i].map { RecommendationCandidate(id: articles[$0.key].id, score: $0.value) }
            candidates[articles[i].id] = values.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        }
        return RecommendationGraph(nodes: nodes, edges: edges, candidates: candidates)
    }
}
