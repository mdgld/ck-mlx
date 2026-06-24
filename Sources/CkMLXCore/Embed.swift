import Foundation
import HuggingFace
import MLX
import MLXEmbedders
import MLXLMCommon
import MLXHuggingFace
import Tokenizers

// MARK: - Embedding Provider Protocol

public protocol EmbeddingProvider: Sendable {
    func embed(_ texts: [String]) async throws -> [[Float]]
    func dimension() async throws -> Int
    func modelName() -> String
    func isAvailable() -> Bool
}

private actor EmbedderContainerStore {
    private var container: EmbedderModelContainer?
    private var loadingTask: Task<EmbedderModelContainer, Error>?

    func getOrCreate(
        _ create: @Sendable @escaping () async throws -> EmbedderModelContainer
    ) async throws -> EmbedderModelContainer {
        if let container {
            return container
        }

        if let loadingTask {
            return try await loadingTask.value
        }

        let task = Task {
            try await create()
        }
        loadingTask = task

        do {
            let loadedContainer = try await task.value
            container = loadedContainer
            loadingTask = nil
            return loadedContainer
        } catch {
            loadingTask = nil
            throw error
        }
    }
}

// MARK: - MLX Embedding Provider

public final class MLXEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    private let modelID: String
    private let configuration: ModelConfiguration
    private var _dimension: Int?
    private let containerStore = EmbedderContainerStore()

    public init(configuration: ModelConfiguration, hubID: String, dimension: Int? = nil) {
        self.configuration = configuration
        self.modelID = hubID
        self._dimension = dimension
    }

    public static func nomic() -> MLXEmbeddingProvider {
        MLXEmbeddingProvider(
            configuration: EmbedderRegistry.nomic_text_v1_5,
            hubID: "nomic-embed-text-v1.5",
            dimension: 768
        )
    }

    public static func bgeSmall() -> MLXEmbeddingProvider {
        MLXEmbeddingProvider(
            configuration: EmbedderRegistry.bge_small,
            hubID: "bge-small-en-v1.5",
            dimension: 384
        )
    }

    public func modelName() -> String { modelID }
    public nonisolated func isAvailable() -> Bool { true }

    public func dimension() async throws -> Int {
        if let d = _dimension { return d }
        let vec = try await embed(["dimension probe"])
        let d = vec[0].count
        _dimension = d
        return d
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        let container = try await getContainer()
        let batchSize = 32
        var results: [[Float]] = []

        for start in stride(from: 0, to: texts.count, by: batchSize) {
            let end = min(start + batchSize, texts.count)
            let batch = Array(texts[start..<end])

            let embeddings = await container.perform { ctx in
                let tokenizer = ctx.tokenizer
                let inputs = batch.map {
                    tokenizer.encode(text: $0, addSpecialTokens: true)
                }

                let maxLength = inputs.reduce(16) { max($0, $1.count) }
                let padded = stacked(
                    inputs.map { elem in
                        MLXArray(
                            elem
                                + Array(
                                    repeating: tokenizer.eosTokenId ?? 0,
                                    count: maxLength - elem.count))
                    })
                let mask = (padded .!= tokenizer.eosTokenId ?? 0)
                let tokenTypes = MLXArray.zeros(like: padded)

                let output = ctx.model(
                    padded,
                    positionIds: nil,
                    tokenTypeIds: tokenTypes,
                    attentionMask: mask
                )

                let result = ctx.pooling(
                    output,
                    normalize: true,
                    applyLayerNorm: true
                )
                result.eval()
                return result.map { $0.asArray(Float.self) }
            }
            results.append(contentsOf: embeddings)
        }

        return results
    }

    private func getContainer() async throws -> EmbedderModelContainer {
        try await containerStore.getOrCreate {
            try await EmbedderModelFactory.shared.loadContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: self.configuration
            )
        }
    }
}
