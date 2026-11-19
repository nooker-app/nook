#if os(macOS)
import Foundation
#if arch(arm64)
import MLX
import MLXEmbedders
import MLXLMCommon
import MLXLLM
import Tokenizers
#endif

actor RecommendationNativeModels {
    static let shared = RecommendationNativeModels()
    private let assets: RecommendationModelAssets
    init(assets: RecommendationModelAssets = .shared) { self.assets = assets }
    // Cache identity includes weights, quantization, input template, and limits.
    static let embeddingID = "Qwen/embedding-0.6B-8bit/407ad232/v1-384-eos"
    static let rerankingID = "Qwen/reranker-4B-4bit/9655b27c/v1-768"
    static let instruction = "Given an article, find another article useful to read next because it discusses the same concrete subject, event, problem, or a closely related alternative. Shared publisher, writing style, broad category, or a word with a different meaning is not enough. Articles may be in different languages."
    #if arch(arm64)
    private var embedder: EmbedderModelContainer?
    private var reranker: ModelContainer?
    #endif

    func embed(_ texts: [String]) async throws -> [[Float]] {
        #if arch(arm64)
        try Task.checkCancellation()
        if embedder == nil {
            Memory.cacheLimit = 128 * 1024 * 1024
            let folder = try await assets.directory("embedding")
            embedder = try await EmbedderModelFactory.shared.loadContainer(from: folder, using: LocalGraphTokenizerLoader())
        }
        guard let embedder else { throw RecommendationModelError.missingAssets }
        return try await embedder.perform { context in
            try Task.checkCancellation()
            let encoded = texts.map { text -> [Int32] in
                // Preserve the final document token when truncating, just as in
                // the validated demo. Pooling a partial word changes the space.
                let tokens = context.tokenizer.encode(text: text, addSpecialTokens: false)
                let eos = context.tokenizer.convertTokenToId("<|endoftext|>") ?? 151643
                return (Array(tokens.prefix(383)) + [eos]).map(Int32.init)
            }
            guard let width = encoded.map(\.count).max() else { return [] }
            let padded = encoded.flatMap { Array(repeating: Int32(0), count: width - $0.count) + $0 }
            let mask = encoded.flatMap { Array(repeating: Int32(0), count: width - $0.count) + Array(repeating: Int32(1), count: $0.count) }
            let input = MLXArray(padded, [encoded.count, width])
            let attention = MLXArray(mask, [encoded.count, width])
            let output = context.model(input, positionIds: nil, tokenTypeIds: nil, attentionMask: attention)
            // Every row is left-padded and ends with the document token. The
            // library's generic `.last` pool uses tokenCount - 1 (right-padding
            // semantics), which picks an earlier word in shorter batch rows.
            guard let hidden = output.hiddenStates else { throw RecommendationModelError.invalidVector }
            let last = hidden[0..., -1, 0...].asType(.float32)
            let pooled = last / MLX.maximum(MLX.sqrt(MLX.sum(last * last, axis: -1, keepDims: true)), MLXArray(Float(1e-12)))
            eval(pooled)
            return (0..<encoded.count).map { pooled[$0].asArray(Float.self) }
        }
        #else
        throw RecommendationModelError.unsupportedDevice
        #endif
    }

    func rerank(query: String, documents: [String]) async throws -> [Double] {
        #if arch(arm64)
        try Task.checkCancellation()
        if reranker == nil {
            let folder = try await assets.directory("reranker")
            reranker = try await LLMModelFactory.shared.loadContainer(from: folder, using: LocalGraphTokenizerLoader())
        }
        guard let reranker else { throw RecommendationModelError.missingAssets }
        var scores: [Double] = []
        // Fixed 768-token prompts in small batches preserve the validated
        // classifier boundary without serial, token-by-token generation.
        for start in stride(from: 0, to: documents.count, by: 4) {
            try Task.checkCancellation()
            let batch = Array(documents[start..<min(start + 4, documents.count)])
            let values = try await reranker.perform { context in
                try Task.checkCancellation()
                let tokenizer = context.tokenizer
                let prefix = tokenizer.encode(text: "<|im_start|>system\nJudge whether the Document meets the requirements based on the Query and the Instruct provided. Note that the answer can only be \"yes\" or \"no\".<|im_end|>\n<|im_start|>user\n", addSpecialTokens: false)
                let suffix = tokenizer.encode(text: "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n", addSpecialTokens: false)
                let budget = 768 - prefix.count - suffix.count
                guard budget > 0, let yes = tokenizer.convertTokenToId("yes"), let no = tokenizer.convertTokenToId("no")
                    else { throw RecommendationModelError.invalidVector }
                let encoded = batch.map { document in
                    let body = tokenizer.encode(text: "<Instruct>: \(Self.instruction)\n<Query>: \(query)\n<Document>: \(document)", addSpecialTokens: false)
                    return prefix + body.prefix(budget) + suffix
                }
                let width = encoded.map(\.count).max() ?? 1
                // Causal attention makes trailing padding invisible to all
                // real tokens. Gather each row's own final classifier position.
                let padded = encoded.flatMap { $0 + Array(repeating: 0, count: width - $0.count) }
                let tokens = MLXArray(padded, [encoded.count, width])
                let positions = MLXArray(encoded.map { Int32($0.count - 1) }, [encoded.count, 1, 1])
                let output = context.model(LMInput.Text(tokens: tokens), cache: nil, state: nil).logits
                let logits = MLX.takeAlong(output, positions, axis: 1)[0..., 0, 0...].asType(.float32)
                let margins = logits[0..., yes] - logits[0..., no]
                eval(margins)
                return margins.asArray(Float.self).map(Double.init)
            }
            scores += values
        }
        return scores
        #else
        throw RecommendationModelError.unsupportedDevice
        #endif
    }

    func unload() {
        #if arch(arm64)
        embedder = nil
        reranker = nil
        Memory.clearCache()
        #endif
    }
}

#if arch(arm64)
private struct LocalGraphTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        LocalGraphTokenizer(base: try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct LocalGraphTokenizer: MLXLMCommon.Tokenizer {
    let base: any Tokenizers.Tokenizer
    var bosToken: String? { base.bosToken }
    var eosToken: String? { base.eosToken }
    var unknownToken: String? { base.unknownToken }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { base.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { base.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        try base.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}
#endif
#endif
