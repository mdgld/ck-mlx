# Swift-first `ck-mlx` Rewrite Plan

## Summary

Rewrite `ck-mlx` as a **SwiftPM-native Apple Silicon CLI and MCP-capable code search tool**, rather than a Rust upstream PR or Python fork. The target artifact is a compiled `ck-mlx` binary that uses official Apple/MLX Swift packages for local embeddings and keeps all core app logic in Swift.

Grounding:
- MLX has official Python, C++, C, and Swift APIs: https://github.com/ml-explore/mlx
- `MLXEmbedders` is available from `mlx-swift-lm`: https://github.com/ml-explore/mlx-swift-lm
- `swift-argument-parser` is the right CLI layer: https://github.com/apple/swift-argument-parser
- GRDB is the chosen SQLite layer: https://github.com/groue/GRDB.swift

## Key Architecture

- Replace the current Python package with a SwiftPM package that builds one executable:
  - command: `ck-mlx`
  - package products: `ck-mlx` executable plus internal library targets
  - minimum platform: macOS on Apple Silicon
- Use these Swift dependencies:
  - `mlx-swift-lm` product `MLXEmbedders` for embedding models
  - `swift-argument-parser` for CLI
  - `GRDB.swift` for SQLite-backed index storage
- Default embedding model:
  - use MLXEmbedders’ supported Nomic path, equivalent to `nomic-embed-text-v1.5`
  - expose aliases like `nomic-v1.5`, `qwen3`, and `embedding-gemma` only when verified against `MLXEmbedders`
- Store indexes under `.ck-mlx/index.sqlite` to avoid corrupting or colliding with upstream `ck`’s `.ck` format.
- Do not keep a Rust client. No Rust code remains in the primary local tool.

## Public CLI / Behavior

Implement these v1 commands:

```bash
ck-mlx status
ck-mlx index <path> --force
ck-mlx search <query> --mode semantic|regex|hybrid --limit 20
ck-mlx models
ck-mlx clean <path>
```

Public options:

- `--model <alias-or-hf-id>` for indexing and query embedding
- `--index-dir <path>` for custom index location
- `--json` and `--jsonl` for agent/tool output
- `--include <glob>` and `--exclude <glob>` for file selection
- `--snippet-length <n>` for output shaping

Behavior rules:

- `status` reports index path, indexed file count, chunk count, embedding model, vector dimension, and last updated time.
- `index` walks source files, chunks them, embeds chunks with MLX Swift, and writes chunks/vectors/metadata to SQLite.
- `search --mode semantic` embeds the query and ranks chunks by cosine similarity.
- `search --mode regex` does direct source-file regex search without needing an index.
- `search --mode hybrid` combines regex/lexical signal with semantic rank using reciprocal-rank fusion.
- Model mismatch fails fast: if the index was built with model A and search requests model B, print a reindex instruction.

## Implementation Steps

1. Preserve current Python work before rewrite:
   - tag or branch the current Python implementation as `python-prototype`
   - keep PR #160 closed/superseded
2. Scaffold SwiftPM:
   - `Package.swift`
   - `Sources/CkMLXCore`
   - `Sources/CkMLXCLI`
   - `Tests/CkMLXCoreTests`
3. Implement indexing primitives:
   - file walker with default excludes
   - text/code chunker
   - SQLite schema for files, chunks, vectors, and index metadata
4. Implement MLX embedding layer:
   - `EmbeddingProvider` protocol
   - `MLXEmbeddingProvider` backed by `MLXEmbedders`
   - lazy model loading and batch embedding
   - dimension discovery from first embedding
5. Implement search:
   - cosine similarity over stored vectors
   - regex search over files
   - hybrid rank fusion
   - JSON/JSONL output
6. Implement CLI:
   - ArgumentParser command tree
   - user-facing errors
   - status/model/clean/index/search commands
7. Rewrite README:
   - Swift install/build instructions
   - Apple Silicon requirement
   - model defaults
   - CLI examples
   - explicit note that this is no longer an upstream `ck` PR

## Test Plan

- Unit tests:
  - chunking produces stable spans
  - index metadata stores model + dimensions
  - model mismatch fails before search
  - cosine ranking orders expected vectors
  - hybrid ranking combines regex and semantic hits
- CLI tests:
  - `ck-mlx --help`
  - `ck-mlx status` with no index
  - `ck-mlx index <tempdir> --force`
  - `ck-mlx search "query" --mode regex`
  - `ck-mlx search "query" --mode semantic` using a fake embedding provider
- Manual QA:
  - build with `swift build -c release`
  - run `ck-mlx index . --force`
  - run `ck-mlx search "embedding provider" --mode semantic`
  - confirm `.ck-mlx/index.sqlite` exists and status reports model metadata

## Assumptions

- This is a **Swift-first local tool**, not an upstream `BeaconBay/ck` PR.
- Native Swift/MLX is preferred over Rust, Python, or sidecar architecture.
- v1 can omit reranking unless `MLXEmbedders` exposes a stable reranker path; semantic + regex + hybrid search are the required search modes.
- v1 optimizes for correctness and local Apple Silicon usability before matching every feature of the old Rust `ck` CLI.
