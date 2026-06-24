import CkMLXCore
import Foundation

enum MCPTools {
    // MARK: - Index root discovery

    static func findIndexRoot(from cwd: String = FileManager.default.currentDirectoryPath) -> String {
        var url = URL(fileURLWithPath: cwd)
        while true {
            let candidate = url.appendingPathComponent(".ck-mlx")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }  // reached filesystem root
            url = parent
        }
        return cwd + "/.ck-mlx"  // fallback: use cwd even if not indexed
    }

    static func openStore() throws -> Store {
        let indexDir = findIndexRoot()
        let store = Store(path: indexDir)
        guard store.indexExists() else {
            throw MCPError.noIndex(indexDir)
        }
        try store.open()
        return store
    }

    static func embedder(for store: Store) -> any EmbeddingProvider {
        let alias = (try? store.getMetadata(key: "embedding_model")) ?? "nomic-embed-text-v1.5"
        switch alias {
        case "bge-small-en-v1.5", "bge-small", "bge":
            return MLXEmbeddingProvider.bgeSmall()
        default:
            return MLXEmbeddingProvider.nomic()
        }
    }

    // MARK: - Tools

    static func semanticSearch(
        query: String,
        threshold: Float = 0.3,
        limit: Int = 15
    ) async throws -> String {
        let store = try openStore()
        let engine = SearchEngine(store: store, embedder: embedder(for: store))
        let results = try await engine.semanticSearch(query: query, limit: limit)
        let filtered = results.filter { $0.score >= threshold }
        guard !filtered.isEmpty else { return "No matches found above threshold." }
        return formatResults(filtered)
    }

    static func hybridSearch(
        query: String,
        limit: Int = 20,
        snippetLength: Int = 400
    ) async throws -> String {
        let store = try openStore()
        let engine = SearchEngine(store: store, embedder: embedder(for: store))
        let results = try await engine.hybridSearch(query: query, limit: limit)
        guard !results.isEmpty else { return "No matches found." }
        return formatResults(results, snippetLength: snippetLength)
    }

    static func regexSearch(pattern: String, limit: Int = 30) throws -> String {
        let store = try openStore()
        let engine = SearchEngine(store: store, embedder: embedder(for: store))
        let results = try engine.regexSearch(pattern: pattern, limit: limit)
        guard !results.isEmpty else { return "No regex matches found." }
        return formatResults(results)
    }

    static func indexStatus() throws -> String {
        let indexDir = findIndexRoot()
        let store = Store(path: indexDir)
        guard store.indexExists() else {
            return "No index found at \(indexDir). Run: ck-mlx index <path>"
        }
        try store.open()
        let status = try store.getStatus()
        return """
            Index Root: \(store.indexDirectoryPath)
            Files:      \(status.totalFiles)
            Chunks:     \(status.totalChunks)
            Model:      \(status.embeddingModel ?? "unknown")
            Dimension:  \(status.embeddingDimension.map(String.init) ?? "unknown")
            Updated:    \(status.lastUpdated ?? "unknown")
            DB Size:    \(String(format: "%.2f", Double(status.dbSizeBytes) / 1_048_576)) MB
            """
    }

    // MARK: - Formatting

    private static func formatResults(_ results: [SearchResult], snippetLength: Int = 500) -> String {
        results.enumerated().map { i, r in
            let snippet = String(r.content.prefix(snippetLength))
            return "[\(i+1)] File: \(r.filePath) lines \(r.startLine)-\(r.endLine) (Score: \(String(format: "%.4f", r.score)))\n```\n\(snippet)\n```"
        }.joined(separator: "\n\n")
    }
}

enum MCPError: Error, LocalizedError {
    case noIndex(String)

    var errorDescription: String? {
        switch self {
        case .noIndex(let path):
            return "No index found at \(path). Run: ck-mlx index <path>"
        }
    }
}
