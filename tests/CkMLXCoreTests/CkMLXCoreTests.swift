import Testing
import Foundation
@testable import CkMLXCore

@Test func fileWalkerExcludesDefaults() async throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ck-mlx-test-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tmpDir.appendingPathComponent(".ck-mlx"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tmpDir.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tmpDir.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let swiftFile = tmpDir.appendingPathComponent("hello.swift")
    try "let x = 1".write(to: swiftFile, atomically: true, encoding: .utf8)
    try "ignored".write(to: tmpDir.appendingPathComponent(".ck-mlx/config.json"), atomically: true, encoding: .utf8)
    try "ignored".write(to: tmpDir.appendingPathComponent("node_modules/pkg.js"), atomically: true, encoding: .utf8)
    try "ignored".write(to: tmpDir.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
    let walker = FileWalker(root: tmpDir)
    let files = walker.walk()
    let paths = files.map { $0.lastPathComponent }
    #expect(paths.contains("hello.swift"))
    #expect(!paths.contains("config.json"))
    #expect(!paths.contains("pkg.js"))
}

@Test func chunkerSplitsContent() {
    let chunker = Chunker(maxLines: 10, overlapLines: 2)
    let lines = (1...35).map { "line \($0)" }
    let content = lines.joined(separator: "\n")
    let chunks = chunker.chunk(content: content)
    #expect(chunks.count >= 3)
    #expect(chunks[0].startLine == 1)
    #expect(chunks[0].endLine == 10)
}

@Test func chunkerEmptyContent() {
    let chunker = Chunker()
    let chunks = chunker.chunk(content: "")
    #expect(chunks.isEmpty)
}

@Test func chunkerSmallContent() {
    let chunker = Chunker(maxLines: 100, overlapLines: 10)
    let chunks = chunker.chunk(content: "single line")
    #expect(chunks.count == 1)
    #expect(chunks[0].startLine == 1)
    #expect(chunks[0].endLine == 1)
}

@Test func storeOpenCreatesIndex() async throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ck-mlx-store-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let store = Store(path: tmpDir.path)
    #expect(!store.indexExists())
    try store.open()
    #expect(store.indexExists())
}

@Test func storeInsertsFileAndRetrievesIt() async throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ck-mlx-ins-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let store = Store(path: tmpDir.path)
    try store.open()

    let fileId = try store.insertFile(FileRecord(
        path: "foo/bar.swift",
        mtime: 1_000_000,
        size: 42,
        contentHash: "abc123"
    ))
    #expect(fileId > 0)

    let fetched = try store.fileRecord(forPath: "foo/bar.swift")
    #expect(fetched?.contentHash == "abc123")
    #expect(fetched?.size == 42)
}

@Test func storeVectorRoundtrip() async throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ck-mlx-vec-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let store = Store(path: tmpDir.path)
    try store.open()

    let original: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
    let fileId = try store.insertFile(FileRecord(
        path: "vec_test.swift", mtime: 0, size: 0, contentHash: "h"
    ))
    try store.insertChunkWithVector(
        fileId: fileId, startLine: 1, endLine: 5,
        content: "let x = 1", contentHash: "ch",
        vector: original
    )

    let rows = try store.allChunksWithVectors()
    #expect(rows.count == 1)
    let retrieved = rows[0].vector
    #expect(retrieved.count == original.count)
    for (a, b) in zip(original, retrieved) {
        #expect(abs(a - b) < 1e-6)
    }
}

@Test func storeStatusReflectsCounts() async throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ck-mlx-stat-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let store = Store(path: tmpDir.path)
    try store.open()

    let fileId = try store.insertFile(FileRecord(
        path: "a.swift", mtime: 0, size: 0, contentHash: "h1"
    ))
    try store.insertChunkWithVector(
        fileId: fileId, startLine: 1, endLine: 10,
        content: "chunk 1", contentHash: "c1", vector: [0.1, 0.2]
    )
    try store.insertChunkWithVector(
        fileId: fileId, startLine: 11, endLine: 20,
        content: "chunk 2", contentHash: "c2", vector: [0.3, 0.4]
    )
    try store.setMetadata(key: "embedding_model", value: "test-model")

    let status = try store.getStatus()
    #expect(status.totalFiles == 1)
    #expect(status.totalChunks == 2)
    #expect(status.embeddingModel == "test-model")
}

@Test func storeSearchByContentFindsMatches() async throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ck-mlx-srch-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let store = Store(path: tmpDir.path)
    try store.open()

    let fileId = try store.insertFile(FileRecord(
        path: "search_test.swift", mtime: 0, size: 0, contentHash: "h"
    ))
    try store.insertChunkWithVector(
        fileId: fileId, startLine: 1, endLine: 5,
        content: "func authenticate(user: String) -> Bool",
        contentHash: "c1", vector: [0.1]
    )
    try store.insertChunkWithVector(
        fileId: fileId, startLine: 6, endLine: 10,
        content: "let x = computeSum(a, b)",
        contentHash: "c2", vector: [0.2]
    )

    let hits = try store.searchByContent(pattern: "authenticate", limit: 10)
    #expect(hits.count == 1)
    #expect(hits[0].chunk.content.contains("authenticate"))

    let noHits = try store.searchByContent(pattern: "nonexistent_xyz", limit: 10)
    #expect(noHits.isEmpty)
}
