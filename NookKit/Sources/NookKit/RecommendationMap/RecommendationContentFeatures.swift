import Foundation
import NaturalLanguage

struct RecommendationContentFeatures: Sendable {
    let vectors: [[Int:Double]]
    let words: [String]
    let postings: [[(Int,Double)]]
    static let stop: Set<String> = Set("announcing introducing announcement introduce show hn gn ask github https http www com org html amp nbsp article submitted comments comment link points read more click here post share reddit source original author posted edit update would could should also just like using used use new one two get can will may about into out these those their them they there then than some any all not but you your our his her its it's how what why when where who which with from this that are was were has have had does did been being and for the a an of to in on as at by it is we i be or an ai llm 대한 위한 있는 하는 통해 있다 위해 것으로 없는 에서 것을 하지만 기존 이후 이런 있습니다 있음 것이 새로운 하며 이번 모두 경우 때문 관련 여러 매우 가장 다른 같은 함께 해당 지금 제공 사용 통해 각각 다양한 기반 이제 보고 하는 새로운 사람 많은 모든 있는 등을 등은 대한 것을 또한 아닌 없는 것은 있다 없다 가능 것이다 이를 이런 저런 그냥 직접 대해 된다 되는 것을 그럼 그래서 그리고 또는 때문에 실제 특히 보다 통해 이미 합니다 됐다 있도록 아니라 위한 있는 합니다 했습니다 있습니다 됩니다 제목 내용 기사 댓글 원문 보기 작성 수정 기자 뉴스 무단 전재 재배포 금지 출처 입력 링크 공유 바랍니다 됩니다 되는 하고 했다 하다 하지 됨 수 것 이 그 저 및 등 더 한 중 로 을 를 은 는 에 의 와 과 도 만".split(separator:" ").map(String.init))
    static let endings = ["으로부터","에서부터","에서는","으로는","에게는","이라는","이라고","이라고","에서도","까지는","부터는","하고는","하려는","한다는","입니다","합니다","이라고","으로써","으로서","에서","으로","에게","처럼","보다","까지","부터","하는","되는","에는","에도","이며","이란","라고","이고","들은","들이","들을","했다","한다","된다","은","는","이","가","을","를","의","와","과","도","에"]
    static func tokenize(_ text:String) -> [String] {
        let lower=text.lowercased()
        let tokenizer=NLTokenizer(unit:.word);tokenizer.string=lower
        var result:[String]=[]
        tokenizer.enumerateTokens(in:lower.startIndex..<lower.endIndex) { range,_ in
            var word=String(lower[range])
            guard word.count>1,word.count<45,!stop.contains(word),word.unicodeScalars.contains(where:CharacterSet.letters.contains) else{return true}
            if word.unicodeScalars.allSatisfy({(0xAC00...0xD7A3).contains($0.value)}) {
                for end in endings where word.hasSuffix(end) && word.count-end.count>=2 {word=String(word.dropLast(end.count));break}
            } else if word.count>5,word.hasSuffix("s"),!word.hasSuffix("ss") {word.removeLast()}
            if !stop.contains(word) {result.append(word)}
            return true
        }
        return result
    }
    static func body(_ article:Article) -> String {
        let paragraphs=article.bodyParagraphs.filter {$0.count>25 && $0.count<12000}
        guard !paragraphs.isEmpty else{return ""}
        // Include beginning, middle, and end; late paragraphs must remain discoverable.
        if paragraphs.joined().count<=9000 {return paragraphs.joined(separator:" ")}
        let slices=[paragraphs.prefix(6).joined(separator:" "),paragraphs.dropFirst(paragraphs.count/2).prefix(4).joined(separator:" "),paragraphs.suffix(4).joined(separator:" ")]
        return slices.map {String($0.prefix(3000))}.joined(separator:" ")
    }
    init(_ articles:[Article], originalIDs:Set<String> = []) {
        var docs:[[String:Double]]=[];var df:[String:Int]=[:]
        for article in articles {
            var document:[String:Double]=[:]
            for (text,weight) in [(RecommendationContentText.title(article.title),2.6),(originalIDs.contains(article.id) ? "" : RecommendationContentText.clean(String(article.summary.prefix(3000))),1.35),(RecommendationContentText.clean(Self.body(article)),1.25)] {
                var counts:[String:Int]=[:]
                for word in Self.tokenize(text) {counts[word,default:0]+=1}
                // Length normalization prevents a long body overwhelming its title.
                let scale=weight / sqrt(max(1,Double(counts.count)/32))
                for (word,count) in counts {document[word,default:0]+=scale*(1+log(Double(min(count,5))))}
            }
            docs.append(document)
            for word in document.keys {df[word,default:0]+=1}
        }
        words=df.keys.sorted()
        let ids=Dictionary(uniqueKeysWithValues:words.enumerated().map {($0.element,$0.offset)})
        var vectors:[[Int:Double]]=[];var postings=Array(repeating:[(Int,Double)](),count:words.count)
        for (i,doc) in docs.enumerated() {
            var vector:[Int:Double]=[:]
            for word in doc.keys.sorted() {
                let frequency=Double(df[word]!),n=Double(articles.count)
                // Ubiquitous site boilerplate carries no discriminative evidence.
                guard n<20 || frequency/n<0.24 else {continue}
                let idf=log(1+(n-frequency+0.5)/(frequency+0.5))
                vector[ids[word]!]=doc[word]!*idf
            }
            let norm=max(1e-12,sqrt(vector.keys.sorted().reduce(0){$0+vector[$1]!*vector[$1]!}))
            for term in vector.keys.sorted() {vector[term]! /= norm;postings[term].append((i,vector[term]!))}
            vectors.append(vector)
        }
        self.vectors=vectors;self.postings=postings
    }
    func cosine(_ i:Int,_ j:Int)->Double {
        vectors[i].keys.sorted().reduce(0) {$0+vectors[i][$1]!*(vectors[j][$1] ?? 0)}
    }
    func related(_ i:Int)->[Int:Double] {
        var scores:[Int:Double]=[:]
        for term in vectors[i].keys.sorted() {let value=vectors[i][term]!;for (j,w) in postings[term] where j != i {scores[j,default:0]+=value*w}}
        return scores
    }
    func evidence(_ i:Int,_ j:Int)->[(String,Double)] {
        vectors[i].compactMap {term,value -> (String,Double)? in
            guard let w=vectors[j][term] else{return nil};return (words[term],w*value)
        }.sorted {$0.1 == $1.1 ? $0.0<$1.0:$0.1>$1.1}
    }
}
