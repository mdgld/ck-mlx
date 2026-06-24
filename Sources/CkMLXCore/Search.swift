import Foundation

public struct SearchResult: Sendable {
    public let filePath: String
    public let startLine: Int
    public let endLine: Int
    public let content: String
    public let score: Float
}

public struct SearchEngine: Sendable {
    public let store: Store
    public let embedder: any EmbeddingProvider

    public init(store: Store, embedder: any EmbeddingProvider) {
        self.store = store
        self.embedder = embedder
    }

    // MARK: - Semantic

    public func semanticSearch(query: String, limit: Int = 20) async throws -> [SearchResult] {
        let queryVec = try await embedder.embed([query])[0]
        let rows = try store.allChunksWithVectors()

        let scored: [(Float, Store.ChunkWithVector)] = rows.map { row in
            (cosine(queryVec, row.vector), row)
        }
        return scored
            .sorted { $0.0 > $1.0 }
            .prefix(limit)
            .map { score, row in
                SearchResult(
                    filePath: row.path,
                    startLine: row.chunk.startLine,
                    endLine: row.chunk.endLine,
                    content: row.chunk.content,
                    score: score
                )
            }
    }

    // MARK: - Regex / keyword

    public func regexSearch(pattern: String, limit: Int = 30) throws -> [SearchResult] {
        let rows = try store.searchByContent(pattern: pattern, limit: limit)
        return rows.map { row in
            SearchResult(
                filePath: row.path,
                startLine: row.chunk.startLine,
                endLine: row.chunk.endLine,
                content: row.chunk.content,
                score: 1.0
            )
        }
    }

    // MARK: - Hybrid (RRF)

    public func hybridSearch(query: String, limit: Int = 20) async throws -> [SearchResult] {
        async let semanticResults = semanticSearch(query: query, limit: limit * 2)
        let keywordResults = try regexSearch(pattern: query, limit: limit * 2)
        let semResults = try await semanticResults

        // Build rank maps keyed by (path, startLine)
        typealias Key = String
        func key(_ r: SearchResult) -> Key { "\(r.filePath):\(r.startLine)" }

        var rrfScores: [Key: Float] = [:]
        var resultMap: [Key: SearchResult] = [:]

        for (rank, r) in semResults.enumerated() {
            let k = key(r)
            rrfScores[k, default: 0] += 1.0 / (60.0 + Float(rank + 1))
            resultMap[k] = r
        }
        for (rank, r) in keywordResults.enumerated() {
            let k = key(r)
            rrfScores[k, default: 0] += 1.0 / (60.0 + Float(rank + 1))
            if resultMap[k] == nil { resultMap[k] = r }
        }

        return rrfScores
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .compactMap { k, score -> SearchResult? in
                guard let r = resultMap[k] else { return nil }
                return SearchResult(
                    filePath: r.filePath,
                    startLine: r.startLine,
                    endLine: r.endLine,
                    content: r.content,
                    score: score
                )
            }
    }

    // MARK: - Math

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = normA.squareRoot() * normB.squareRoot()
        return denom > 0 ? dot / denom : 0
    }
}
