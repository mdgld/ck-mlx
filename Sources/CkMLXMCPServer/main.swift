// ck-mlx-mcp: MCP server exposing semantic_search, hybrid_search, regex_search, index_status
// Communicates via newline-delimited JSON-RPC 2.0 over stdio.
let server = MCPServer()
await server.run()
