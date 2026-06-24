import CryptoKit
import Foundation

public struct IndexSummary: Sendable {
    public let filesVisited: Int
    public let filesIndexed: Int
    public let filesSkipped: Int
    public let chunksIndexed: Int
    public let errors: [String]
}

public actor Indexer {
    public let root: URL
    private let walker: FileWalker
    private let chunker: Chunker
    private let embedder: any EmbeddingProvider
    private let store: Store

    public init(root: URL, store: Store, embedder: any EmbeddingProvider) {
        self.root = root
        self.walker = FileWalker(root: root)
        self.chunker = Chunker()
        self.embedder = embedder
        self.store = store
    }

    public func index(
        force: Bool = false,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> IndexSummary {
        let files = walker.walk()
        var indexed = 0
        var skipped = 0
        var chunks = 0
        var errors: [String] = []

        for file in files {
            let rel = file.path.replacingOccurrences(of: root.path + "/", with: "")
            do {
                let didIndex = try await indexFile(
                    url: file,
                    relativePath: rel,
                    force: force
                )
                if didIndex {
                    indexed += 1
                    onProgress?("indexed \(rel)")
                } else {
                    skipped += 1
                }
            } catch {
                errors.append("\(rel): \(error)")
            }
        }

        // persist metadata
        let dim = try? await embedder.dimension()
        let now = ISO8601DateFormatter().string(from: Date())
        try? store.setMetadata(key: "embedding_model", value: embedder.modelName())
        if let dim {
            try? store.setMetadata(key: "embedding_dimension", value: String(dim))
        }
        try? store.setMetadata(key: "last_updated", value: now)

        let status = try? store.getStatus()
        chunks = status?.totalChunks ?? 0

        return IndexSummary(
            filesVisited: files.count,
            filesIndexed: indexed,
            filesSkipped: skipped,
            chunksIndexed: chunks,
            errors: errors
        )
    }

    // MARK: - Private

    private func indexFile(url: URL, relativePath: String, force: Bool) async throws -> Bool {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return false // skip binary files silently
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? Int64) ?? 0
        let hash = sha256(content)

        let existing = try store.fileRecord(forPath: relativePath)
        if !force, let existing, existing.contentHash == hash {
            return false // unchanged
        }

        let textChunks = chunker.chunk(content: content)
        guard !textChunks.isEmpty else { return false }

        let texts = textChunks.map(\.content)
        let vectors = try await embedder.embed(texts)

        if let id = existing?.id {
            try store.deleteFile(id: id) // cascades chunks + vectors
        }
        let newRec = FileRecord(
            path: relativePath,
            mtime: mtime,
            size: size,
            contentHash: hash
        )
        let fileId = try store.insertFile(newRec)

        for (i, chunk) in textChunks.enumerated() {
            guard i < vectors.count else { break }
            try store.insertChunkWithVector(
                fileId: fileId,
                startLine: chunk.startLine,
                endLine: chunk.endLine,
                content: chunk.content,
                contentHash: sha256(chunk.content),
                vector: vectors[i]
            )
        }
        return true
    }

    private func sha256(_ text: String) -> String {
        let data = Data(text.utf8)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}
