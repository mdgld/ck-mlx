import CkMLXCore
import Foundation

// MARK: - MCP JSON-RPC types

struct JSONRPCRequest: Decodable {
    let jsonrpc: String
    let id: JSONRPCId?
    let method: String
    let params: JSONValue?
}

enum JSONRPCId: Decodable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "id must be int or string")
    }
}

// Minimal recursive JSON value for params
enum JSONValue: Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    func string(key: String) -> String? {
        guard case .object(let d) = self, case .string(let v) = d[key] else { return nil }
        return v
    }
    func double(key: String) -> Double? {
        guard case .object(let d) = self else { return nil }
        if case .double(let v) = d[key] { return v }
        if case .int(let v) = d[key] { return Double(v) }
        return nil
    }
    func int(key: String) -> Int? {
        guard case .object(let d) = self else { return nil }
        if case .int(let v) = d[key] { return v }
        if case .double(let v) = d[key] { return Int(v) }
        return nil
    }
}

// MARK: - Server

final class MCPServer {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let serverVersion = "0.2.0"
    private let protocolVersion = "2024-11-05"

    private let tools: [ToolDefinition] = [
        ToolDefinition(
            name: "semantic_search",
            description: "Run semantic search on the code index using MLX embeddings.",
            properties: [
                "query": .init(type: "string", description: "Natural language search query"),
                "threshold": .init(type: "number", description: "Minimum similarity score 0-1 (default 0.3)"),
                "page_size": .init(type: "integer", description: "Maximum results (default 15)"),
            ],
            required: ["query"]
        ),
        ToolDefinition(
            name: "hybrid_search",
            description: "Reciprocal Rank Fusion search combining semantic and keyword matching.",
            properties: [
                "query": .init(type: "string", description: "Search query"),
                "page_size": .init(type: "integer", description: "Maximum results (default 20)"),
                "snippet_length": .init(type: "integer", description: "Max chars per snippet (default 400)"),
            ],
            required: ["query"]
        ),
        ToolDefinition(
            name: "regex_search",
            description: "Pattern search across indexed content (no embedding needed).",
            properties: [
                "query": .init(type: "string", description: "Regex or literal pattern"),
                "page_size": .init(type: "integer", description: "Maximum results (default 30)"),
            ],
            required: ["query"]
        ),
        ToolDefinition(
            name: "index_status",
            description: "Get index statistics: file count, chunk count, model, size.",
            properties: [:],
            required: []
        ),
    ]

    func run() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8) else { continue }
            do {
                let req = try decoder.decode(JSONRPCRequest.self, from: data)
                await handle(req)
            } catch {
                writeError(id: nil, code: -32700, message: "Parse error: \(error)")
            }
        }
    }

    // MARK: - Dispatch

    private func handle(_ req: JSONRPCRequest) async {
        switch req.method {
        case "initialize":
            writeResult(id: req.id, value: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "ck-mlx", "version": serverVersion],
            ])

        case "notifications/initialized", "$/cancelRequest":
            break  // no response for notifications

        case "tools/list":
            let toolsList = tools.map { $0.asJSON() }
            writeResult(id: req.id, value: ["tools": toolsList])

        case "tools/call":
            guard let name = req.params?.string(key: "name"),
                  let args = req.params else {
                writeError(id: req.id, code: -32602, message: "Invalid params")
                return
            }
            let arguments = args.nestedObject(key: "arguments")
            let result = await callTool(name: name, arguments: arguments)
            writeResult(id: req.id, value: [
                "content": [["type": "text", "text": result]],
                "isError": false,
            ])

        default:
            writeError(id: req.id, code: -32601, message: "Method not found: \(req.method)")
        }
    }

    // MARK: - Tool dispatch

    private func callTool(name: String, arguments: JSONValue?) async -> String {
        do {
            switch name {
            case "semantic_search":
                let query = arguments?.string(key: "query") ?? ""
                let threshold = Float(arguments?.double(key: "threshold") ?? 0.3)
                let pageSize = arguments?.int(key: "page_size") ?? 15
                return try await MCPTools.semanticSearch(query: query, threshold: threshold, limit: pageSize)
            case "hybrid_search":
                let query = arguments?.string(key: "query") ?? ""
                let pageSize = arguments?.int(key: "page_size") ?? 20
                let snippetLen = arguments?.int(key: "snippet_length") ?? 400
                return try await MCPTools.hybridSearch(query: query, limit: pageSize, snippetLength: snippetLen)
            case "regex_search":
                let query = arguments?.string(key: "query") ?? ""
                let pageSize = arguments?.int(key: "page_size") ?? 30
                return try MCPTools.regexSearch(pattern: query, limit: pageSize)
            case "index_status":
                return try MCPTools.indexStatus()
            default:
                return "Unknown tool: \(name)"
            }
        } catch {
            return "Error: \(error)"
        }
    }

    // MARK: - I/O helpers

    private func writeResult(id: JSONRPCId?, value: Any) {
        var obj: [String: Any] = ["jsonrpc": "2.0", "result": value]
        if let id { obj["id"] = idToAny(id) }
        writeLine(obj)
    }

    private func writeError(id: JSONRPCId?, code: Int, message: String) {
        var obj: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        if let id { obj["id"] = idToAny(id) }
        writeLine(obj)
    }

    private func idToAny(_ id: JSONRPCId) -> Any {
        switch id { case .int(let i): return i; case .string(let s): return s }
    }

    private func writeLine(_ obj: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return }
        print(str)
        fflush(stdout)
    }
}

// MARK: - Tool definition helper

struct ToolDefinition {
    struct Param { let type: String; let description: String }
    let name: String
    let description: String
    let properties: [String: Param]
    let required: [String]

    func asJSON() -> [String: Any] {
        var props: [String: Any] = [:]
        for (k, v) in properties {
            props[k] = ["type": v.type, "description": v.description]
        }
        return [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": props,
                "required": required,
            ],
        ]
    }
}

extension JSONValue {
    func nestedObject(key: String) -> JSONValue? {
        guard case .object(let d) = self else { return nil }
        return d[key]
    }
}
