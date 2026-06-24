import ArgumentParser
import CkMLXCore
import Foundation

func resolveEmbedder(alias: String) throws -> any EmbeddingProvider {
    switch alias {
    case "nomic-v1.5", "nomic":
        return MLXEmbeddingProvider.nomic()
    case "bge-small", "bge":
        return MLXEmbeddingProvider.bgeSmall()
    default:
        throw ValidationError("Unknown model alias '\(alias)'. Run 'ck-mlx models' to list supported aliases.")
    }
}

@main
struct CkMLX: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ck-mlx",
        abstract: "Metal-accelerated local code search tool for Apple Silicon",
        version: "0.2.0",
        subcommands: [
            StatusCmd.self,
            IndexCmd.self,
            SearchCmd.self,
            ModelsCmd.self,
            CleanCmd.self,
        ]
    )
}

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Embedding model alias or HuggingFace hub ID")
    var model: String?

    @Option(name: .long, help: "Custom index directory (default: .ck-mlx in root)")
    var indexDir: String?

    @Flag(name: .long, help: "JSON output format")
    var json: Bool = false

    @Flag(name: .long, help: "JSON Lines output format")
    var jsonl: Bool = false

    @Option(name: .long, help: "Glob patterns to include (comma-separated)")
    var includes: String?

    @Option(name: .long, help: "Glob patterns to exclude (comma-separated)")
    var excludes: String?

    @Option(name: .long, help: "Maximum snippet length in output")
    var snippetLength: Int = 300
}

struct StatusCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show index status and metadata"
    )
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let indexDir = resolveIndexDir()
        let store = Store(path: indexDir)
        guard store.indexExists() else {
            if global.json {
                print("{\"status\":\"no_index\",\"path\":\"\(indexDir)\"}")
            } else {
                print("No index found at \(indexDir)")
            }
            return
        }
        try store.open()
        let status = try store.getStatus()
        if global.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let payload: [String: String] = [
                "path": indexDir,
                "files": String(status.totalFiles),
                "chunks": String(status.totalChunks),
                "model": status.embeddingModel ?? "unknown",
                "dimension": status.embeddingDimension.map(String.init) ?? "unknown",
                "lastUpdated": status.lastUpdated ?? "unknown",
                "dbSizeMB": String(format: "%.2f", Double(status.dbSizeBytes) / 1_048_576),
            ]
            let data = try encoder.encode(payload)
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("Index Path:  \(indexDir)")
            print("Files:       \(status.totalFiles)")
            print("Chunks:      \(status.totalChunks)")
            print("Model:       \(status.embeddingModel ?? "unknown")")
            print("Dimension:   \(status.embeddingDimension.map(String.init) ?? "unknown")")
            print("Last Updated:\(status.lastUpdated ?? "unknown")")
            print("DB Size:     \(String(format: "%.2f", Double(status.dbSizeBytes) / 1_048_576)) MB")
        }
    }

    private func resolveIndexDir() -> String {
        global.indexDir ?? FileManager.default.currentDirectoryPath + "/.ck-mlx"
    }
}

struct IndexCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Index a directory for semantic search"
    )
    @Argument(help: "Directory to index (default: current directory)")
    var path: String = "."
    @Flag(name: .long, help: "Force full reindex")
    var force: Bool = false
    @Flag(name: .long, help: "Suppress per-file progress output")
    var quiet: Bool = false
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let root = URL(fileURLWithPath: (path as NSString).standardizingPath).standardized
        let indexDir = global.indexDir ?? root.appendingPathComponent(".ck-mlx").path
        let store = Store(path: indexDir)
        try store.open()

        let modelAlias = global.model ?? "nomic-v1.5"
        let embedder = try resolveEmbedder(alias: modelAlias)

        let indexer = Indexer(root: root, store: store, embedder: embedder)
        print("Indexing \(root.path) with model \(modelAlias)...")
        let summary = try await indexer.index(force: force) { msg in
            if !quiet { print("  \(msg)") }
        }
        print("Done: \(summary.filesIndexed) indexed, \(summary.filesSkipped) skipped, \(summary.chunksIndexed) chunks total")
        if !summary.errors.isEmpty {
            print("Errors (\(summary.errors.count)):")
            for e in summary.errors { print("  \(e)") }
        }
    }
}

struct SearchCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search indexed code"
    )
    @Argument(help: "Search query")
    var query: String
    @Option(name: .long, help: "Search mode: semantic, regex, or hybrid")
    var mode: SearchMode = .hybrid
    @Option(name: .long, help: "Maximum results to return")
    var limit: Int = 20
    @Option(name: .long, help: "Minimum semantic score threshold (0-1)")
    var threshold: Float = 0.3
    @OptionGroup var global: GlobalOptions

    enum SearchMode: String, ExpressibleByArgument { case semantic, regex, hybrid }

    func run() async throws {
        let cwd = FileManager.default.currentDirectoryPath
        let indexDir = global.indexDir ?? cwd + "/.ck-mlx"
        let store = Store(path: indexDir)
        guard store.indexExists() else {
            print("No index found at \(indexDir). Run: ck-mlx index <path>")
            throw ExitCode.failure
        }
        try store.open()

        let modelAlias = global.model ?? "nomic-v1.5"
        let embedder = try resolveEmbedder(alias: modelAlias)
        let engine = SearchEngine(store: store, embedder: embedder)

        let results: [SearchResult]
        switch mode {
        case .semantic:
            results = try await engine.semanticSearch(query: query, limit: limit)
        case .regex:
            results = try engine.regexSearch(pattern: query, limit: limit)
        case .hybrid:
            results = try await engine.hybridSearch(query: query, limit: limit)
        }

        let filtered = mode == .semantic
            ? results.filter { $0.score >= threshold }
            : results

        if filtered.isEmpty {
            print("No matches found.")
            return
        }

        if global.jsonl {
            let encoder = JSONEncoder()
            for r in filtered {
                let obj: [String: String] = [
                    "path": r.filePath,
                    "startLine": String(r.startLine),
                    "endLine": String(r.endLine),
                    "score": String(format: "%.4f", r.score),
                    "content": String(r.content.prefix(global.snippetLength)),
                ]
                if let data = try? encoder.encode(obj) {
                    print(String(decoding: data, as: UTF8.self))
                }
            }
            return
        }

        for (i, r) in filtered.enumerated() {
            let snippet = r.content.prefix(global.snippetLength)
            print("[\(i+1)] \(r.filePath) L\(r.startLine)-\(r.endLine) (score: \(String(format: "%.4f", r.score)))")
            print("```")
            print(snippet)
            print("```")
            print()
        }
    }
}

struct CleanCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Remove the index for a directory"
    )
    @Argument(help: "Directory whose index to clean (default: current directory)")
    var path: String = "."

    func run() async throws {
        let root = URL(fileURLWithPath: (path as NSString).standardizingPath)
        let indexDir = root.appendingPathComponent(".ck-mlx")
        let indexFile = indexDir.appendingPathComponent("index.sqlite")
        if FileManager.default.fileExists(atPath: indexFile.path) {
            try FileManager.default.removeItem(at: indexFile)
            print("Removed index at \(indexFile.path)")
        } else {
            print("No index found at \(indexDir.path)")
        }
    }
}

struct ModelsCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "List supported embedding model aliases"
    )
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let supportedModels = [
            ("nomic-v1.5", "nomic-ai/nomic-embed-text-v1.5"),
            ("bge-small", "BAAI/bge-small-en-v1.5"),
        ]

        if global.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let allModels = supportedModels.map { ["alias": $0.0, "hubID": $0.1] }
            let data = try encoder.encode(allModels)
            print(String(decoding: data, as: UTF8.self))
            return
        }

        if global.jsonl {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for (alias, hubID) in supportedModels {
                let payload = ["alias": alias, "hubID": hubID]
                let data = try encoder.encode(payload)
                print(String(decoding: data, as: UTF8.self))
            }
            return
        }

        for (alias, hubID) in supportedModels {
            print("\(alias)\t\(hubID)")
        }
    }
}
