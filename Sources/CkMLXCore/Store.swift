import Foundation
import GRDB

// MARK: - Database Records

public struct FileRecord: Codable, FetchableRecord, PersistableRecord {
    public var id: Int64?
    public var path: String
    public var mtime: Double
    public var size: Int64
    public var contentHash: String

    public static let databaseTableName = "files"
    public static let chunks = hasMany(ChunkRecord.self)

    public init(path: String, mtime: Double, size: Int64, contentHash: String) {
        self.path = path
        self.mtime = mtime
        self.size = size
        self.contentHash = contentHash
    }
}

public struct ChunkRecord: Codable, FetchableRecord, PersistableRecord {
    public var id: Int64?
    public var fileId: Int64
    public var startLine: Int
    public var endLine: Int
    public var content: String
    public var contentHash: String

    public static let databaseTableName = "chunks"
    public static let file = belongsTo(FileRecord.self)
    public static let vector = hasOne(VectorRecord.self)

    public init(fileId: Int64, startLine: Int, endLine: Int, content: String, contentHash: String) {
        self.fileId = fileId
        self.startLine = startLine
        self.endLine = endLine
        self.content = content
        self.contentHash = contentHash
    }
}

public struct VectorRecord: Codable, FetchableRecord, PersistableRecord {
    public var chunkId: Int64
    public var vector: Data

    public static let databaseTableName = "vectors"
    public static let chunk = belongsTo(ChunkRecord.self)

    public init(chunkId: Int64, vector: [Float]) {
        self.chunkId = chunkId
        self.vector = vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public func floats() -> [Float] {
        vector.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

public struct MetadataRecord: Codable, FetchableRecord, PersistableRecord {
    public var key: String
    public var value: String

    public static let databaseTableName = "metadata"

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

// MARK: - Index Status

public struct IndexStatus: Sendable {
    public let totalFiles: Int
    public let totalChunks: Int
    public let embeddingModel: String?
    public let embeddingDimension: Int?
    public let lastUpdated: String?
    public let dbSizeBytes: Int64
}

// MARK: - Store

public final class Store: @unchecked Sendable {
    private let dbPath: String
    private var db: DatabaseQueue?

    public var indexDirectoryPath: String {
        (dbPath as NSString).deletingLastPathComponent
    }

    public init(path: String) {
        let dir = (path as NSString).standardizingPath
        self.dbPath = (dir as NSString).appendingPathComponent("index.sqlite")
    }

    public func open() throws {
        let dir = (dbPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys=ON")
        }
        let queue = try DatabaseQueue(path: dbPath, configuration: config)
        try createSchema(in: queue)
        self.db = queue
    }

    public func close() {
        db = nil
    }

    public func indexExists() -> Bool {
        FileManager.default.fileExists(atPath: dbPath)
    }

    // MARK: - Schema

    private func createSchema(in queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.create(table: "metadata", ifNotExists: true) { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }

            try db.create(table: "files", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
                t.column("mtime", .double).notNull()
                t.column("size", .integer).notNull()
                t.column("contentHash", .text).notNull()
            }

            try db.create(table: "chunks", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("fileId", .integer).notNull()
                    .references("files", onDelete: .cascade)
                t.column("startLine", .integer).notNull()
                t.column("endLine", .integer).notNull()
                t.column("content", .text).notNull()
                t.column("contentHash", .text).notNull()
            }

            try db.create(table: "vectors", ifNotExists: true) { t in
                t.column("chunkId", .integer).primaryKey()
                    .references("chunks", onDelete: .cascade)
                t.column("vector", .blob).notNull()
            }

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_chunks_file ON chunks(fileId)")
        }
    }

    // MARK: - Metadata

    public func setMetadata(key: String, value: String) throws {
        guard let db else { throw StoreError.notOpen }
        try db.write { d in
            let record = MetadataRecord(key: key, value: value)
            try record.upsert(d)
        }
    }

    public func getMetadata(key: String) throws -> String? {
        guard let db else { throw StoreError.notOpen }
        return try db.read { d in
            try MetadataRecord.fetchOne(d, key: key)?.value
        }
    }

    // MARK: - Files

    /// Inserts a file row and returns its auto-assigned id.
    public func insertFile(_ record: FileRecord) throws -> Int64 {
        guard let db else { throw StoreError.notOpen }
        return try db.write { d in
            try record.insert(d)
            return d.lastInsertedRowID
        }
    }

    public func fileRecord(forPath path: String) throws -> FileRecord? {
        guard let db else { throw StoreError.notOpen }
        return try db.read { d in
            try FileRecord.filter(Column("path") == path).fetchOne(d)
        }
    }

    public func deleteFile(id: Int64) throws {
        guard let db else { throw StoreError.notOpen }
        try db.write { d in
            try d.execute(sql: "DELETE FROM files WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Chunks + Vectors

    public func insertChunkWithVector(
        fileId: Int64,
        startLine: Int,
        endLine: Int,
        content: String,
        contentHash: String,
        vector: [Float]
    ) throws {
        guard let db else { throw StoreError.notOpen }
        try db.write { d in
            let chunk = ChunkRecord(
                fileId: fileId,
                startLine: startLine,
                endLine: endLine,
                content: content,
                contentHash: contentHash
            )
            try chunk.insert(d)
            let chunkId = d.lastInsertedRowID
            let vec = VectorRecord(chunkId: chunkId, vector: vector)
            try vec.insert(d)
        }
    }

    public func deleteChunksForFile(id: Int64) throws {
        guard let db else { throw StoreError.notOpen }
        try db.write { d in
            try d.execute(sql: "DELETE FROM chunks WHERE fileId = ?", arguments: [id])
        }
    }

    // MARK: - Search

    public typealias ChunkWithVector = (chunk: ChunkRecord, path: String, vector: [Float])

    public func allChunksWithVectors() throws -> [ChunkWithVector] {
        guard let db else { throw StoreError.notOpen }
        return try db.read { d in
            let sql = """
                SELECT chunks.id, chunks.fileId, chunks.startLine, chunks.endLine,
                       chunks.content, chunks.contentHash,
                       files.path, vectors.vector
                FROM chunks
                JOIN files ON files.id = chunks.fileId
                JOIN vectors ON vectors.chunkId = chunks.id
            """
            let rows = try Row.fetchAll(d, sql: sql)
            return rows.map { row -> ChunkWithVector in
                let chunk = ChunkRecord(
                    fileId: row["fileId"],
                    startLine: row["startLine"],
                    endLine: row["endLine"],
                    content: row["content"],
                    contentHash: row["contentHash"]
                )
                let blob: Data = row["vector"]
                let floats = blob.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                return (chunk: chunk, path: row["path"], vector: floats)
            }
        }
    }

    public func searchByContent(pattern: String, limit: Int) throws -> [(chunk: ChunkRecord, path: String)] {
        guard let db else { throw StoreError.notOpen }
        return try db.read { d in
            let sql = """
                SELECT chunks.id, chunks.fileId, chunks.startLine, chunks.endLine,
                       chunks.content, chunks.contentHash, files.path
                FROM chunks
                JOIN files ON files.id = chunks.fileId
                WHERE chunks.content LIKE ? LIMIT ?
            """
            let rows = try Row.fetchAll(d, sql: sql, arguments: ["%\(pattern)%", limit])
            return rows.map { row in
                let chunk = ChunkRecord(
                    fileId: row["fileId"],
                    startLine: row["startLine"],
                    endLine: row["endLine"],
                    content: row["content"],
                    contentHash: row["contentHash"]
                )
                return (chunk: chunk, path: row["path"])
            }
        }
    }

    // MARK: - Status

    public func getStatus() throws -> IndexStatus {
        guard let db else { throw StoreError.notOpen }
        let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath)
        let dbSize = attrs?[.size] as? Int64 ?? 0
        return try db.read { d in
            let fileCount = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM files") ?? 0
            let chunkCount = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM chunks") ?? 0
            let model = try String.fetchOne(d, sql: "SELECT value FROM metadata WHERE key='embedding_model'")
            let dimStr = try String.fetchOne(d, sql: "SELECT value FROM metadata WHERE key='embedding_dimension'")
            let updated = try String.fetchOne(d, sql: "SELECT value FROM metadata WHERE key='last_updated'")
            return IndexStatus(
                totalFiles: fileCount,
                totalChunks: chunkCount,
                embeddingModel: model,
                embeddingDimension: dimStr.flatMap { Int($0) },
                lastUpdated: updated,
                dbSizeBytes: dbSize
            )
        }
    }

}

public enum StoreError: Error {
    case notOpen
}
