import Foundation
import NaturalLanguage
import CryptoKit
import Accelerate

struct RecommendationVector: Codable, Sendable {
    let model:String
    var values:[Float]
    var fingerprint:String? = nil

    init(model: String, values: [Float], fingerprint: String? = nil) {
        self.model = model; self.values = values; self.fingerprint = fingerprint
    }

    private enum CodingKeys: String, CodingKey { case model, values, fingerprint, float32 }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint)
        if let bytes = try container.decodeIfPresent(Data.self, forKey: .float32) {
            guard bytes.count % 4 == 0 else {
                throw DecodingError.dataCorruptedError(forKey: .float32, in: container, debugDescription: "Invalid float32 vector")
            }
            values = bytes.withUnsafeBytes { buffer in
                stride(from: 0, to: buffer.count, by: 4).map {
                    Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
                }
            }
        } else {
            values = try container.decode([Float].self, forKey: .values)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(fingerprint, forKey: .fingerprint)
        let bits = values.map { $0.bitPattern.littleEndian }
        try container.encode(bits.withUnsafeBytes { Data($0) }, forKey: .float32)
    }
}
struct RecommendationSemanticIndex: Sendable {
    let vectors:[RecommendationVector?]
    func cosine(_ first: Int, _ second: Int) -> Double? {
        guard vectors.indices.contains(first), vectors.indices.contains(second),
              let a = vectors[first], let b = vectors[second], a.model == b.model,
              !a.values.isEmpty, a.values.count == b.values.count,
              a.values.allSatisfy(\.isFinite), b.values.allSatisfy(\.isFinite) else { return nil }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        vDSP_dotpr(a.values, 1, b.values, 1, &dot, vDSP_Length(a.values.count))
        vDSP_svesq(a.values, 1, &normA, vDSP_Length(a.values.count))
        vDSP_svesq(b.values, 1, &normB, vDSP_Length(b.values.count))
        guard normA > 0, normB > 0 else { return nil }
        return Double(dot / sqrt(normA * normB))
    }
    // Mean centering removes the common language/style direction from pooled tokens.
    // Different Apple model IDs are distinct spaces and are never compared.
    func neighbors(limit:Int=24,score:((Int,Int,Double)->Double?)? = nil) -> [[Int:Double]] {
        var answer=Array(repeating:[Int:Double](),count:vectors.count)
        var groups:[String:[Int]]=[:]
        guard limit > 0 else { return answer }
        for i in vectors.indices {
            if let v=vectors[i], !v.values.isEmpty, v.values.allSatisfy(\.isFinite), v.values.contains(where: { $0 != 0 }) {
                groups[v.model + "#" + String(v.values.count),default:[]].append(i)
            }
        }
        for key in groups.keys.sorted() {
            let ids=groups[key]!;guard ids.count>1,let dimension=vectors[ids[0]]?.values.count else{continue}
            var mean=Array(repeating:Float(0),count:dimension)
            for i in ids {let v=vectors[i]!.values;for k in 0..<dimension {mean[k]+=v[k]/Float(ids.count)}}
            var matrix:[Float]=[];matrix.reserveCapacity(ids.count*dimension)
            for i in ids {
                var v=vectors[i]!.values
                // Partial centering avoids unstable directions in tiny corpora.
                let weight:Float=ids.count>=30 && !key.hasPrefix("intfloat/") && !key.hasPrefix("Qwen/") ? 1:0
                for k in 0..<dimension {v[k]-=mean[k]*weight}
                let norm=max(1e-12,sqrt(v.reduce(0){$0+$1*$1}));matrix+=v.map{$0/norm}
            }
            let n=ids.count
            for start in stride(from:0,to:n,by:64) {
                if Task.isCancelled {return answer}
                let count=min(64,n-start)
                var scores=Array(repeating:Float(0),count:count*n)
                matrix.withUnsafeBufferPointer {m in
                    scores.withUnsafeMutableBufferPointer {s in
                        cblas_sgemm(CblasRowMajor,CblasNoTrans,CblasTrans,Int32(count),Int32(n),Int32(dimension),1,m.baseAddress!+start*dimension,Int32(dimension),m.baseAddress!,Int32(dimension),0,s.baseAddress!,Int32(n))
                    }
                }
                for offset in 0..<count {
                    let row=start+offset;var best:[(Int,Float)]=[]
                    for j in 0..<n where row != j {
                        let raw=Double(scores[offset*n+j])
                        let value:Float
                        if let score {guard let adjusted=score(ids[row],ids[j],raw) else{continue};value=Float(adjusted)}
                        else {guard raw>0.16 else{continue};value=Float(raw)}
                        let p=best.firstIndex {value>$0.1 || (value==$0.1 && ids[j]<$0.0)} ?? best.count
                        if p<limit {best.insert((ids[j],value),at:p);if best.count>limit {best.removeLast()}}
                    }
                    answer[ids[row]]=Dictionary(uniqueKeysWithValues:best.map {($0.0,Double($0.1))})
                }
            }
        }
        return answer
    }
}
