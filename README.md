# ck-mlx

`ck-mlx` is a **Swift** rewrite of the [`ck-search`](https://github.com/...) code search tool, with two embedding backends for Apple Silicon:

- `local` (default) — runs MLX embedding models directly via `MLXEmbedders` from `mlx-swift-lm`.
- `api` (fallback) — talks to an OpenAI-compatible oMLX server.

Two binaries, both built from this package:

| Binary | Purpose |
| --- | --- |
| `ck-mlx` | CLI: `status`, `index`, `search`, `models`, `clean` |
| `ck-mlx-mcp` | MCP server over stdio JSON-RPC 2.0 |

The earlier Python prototype is preserved on branch `python-prototype` (tag `python-prototype`); the active code lives in `Sources/CkMLXCore`, `Sources/CkMLXCLI`, `Sources/CkMLXMCPServer`. Don't edit `ck_mlx/` from main.

## Install

```bash
make install
```

This runs `swift build -c release` and copies `ck-mlx` and `ck-mlx-mcp` into `~/.local/bin/`. Verify with:

```bash
which ck-mlx && ck-mlx --version
```

Override the install location:

```bash
make install INSTALL_DIR=/opt/homebrew/bin
```

Other targets:

```bash
make test        # swift test
make uninstall   # removes the installed copies
make clean       # swift package clean
```

## Quick start

```bash
ck-mlx status                          # show active backend, model, and index metadata
ck-mlx index . --force                 # index the current directory
ck-mlx search "embedding provider" \
    --mode hybrid --rerank             # semantic + BM25 with reranking
```

Indexes are stored under `.ck-mlx/index.sqlite` (per working directory).

## MCP server

`ck-mlx-mcp` exposes four tools over JSON-RPC 2.0 on stdio:

| Tool | Best for |
| --- | --- |
| `semantic_search` | Pure meaning queries (`threshold`, `page_size`) |
| `hybrid_search`   | Default — semantic + BM25 RRF fusion (`page_size`, `snippet_length`) |
| `regex_search`    | Exact structural patterns (`page_size`) |
| `index_status`    | Backend, model, file/chunk counts, DB size |

Opencode example (`opencode.jsonc`):

```jsonc
"ck-mlx": {
  "type": "local",
  "command": ["ck-mlx-mcp"],
  "enabled": true
}
```

The MCP process's `cwd` determines which `.ck-mlx/` index is queried — start the editor from the project root, or set `command` to a wrapper that `cd`s first.

## Backend selection

Backend selection is automatic:

- `api` when `OMLX_API_KEY` is set
- otherwise `local`

Override with either:

- `CK_BACKEND=api|local`
- `--backend api|local` (Python wrapper only)

## Local mode

Local mode downloads Hugging Face MLX models on first use. No running server is required.

Default local models:

| Role | Default |
| --- | --- |
| Embedding | `mlx-community/bge-small-en-v1.5-6bit` |
| Reranking | `mlx-community/jina-reranker-v3-4bit-mxfp4` |

Useful local embedding alternatives:

| Model | Dimensions | Notes |
| --- | --- | --- |
| `mlx-community/bge-small-en-v1.5-6bit` | 384 | Default — general mixed codebases |
| `mlx-community/nomic-embed-text-v1.5-mlx` | 768 | Long-context files and prose-heavy docs |
| `mlx-community/jina-embeddings-v2-base-code-mlx` | 768 | Code-specialized |
| `mlx-community/bge-m3-mlx` | 1024 | Highest recall, multilingual |
| `mlx-community/all-MiniLM-L6-v2-4bit` | 384 | ~1.3ms/query — ideal for low-latency classification |

## API mode

API mode preserves the oMLX path:

```bash
export CK_BACKEND=api
export OMLX_BASE_URL=http://127.0.0.1:8000/v1
export OMLX_API_KEY=<your-key>
export OMLX_MODEL=zembed-1-embedding-mlx-6Bit
ck-mlx index . --force
```

## Environment variables

| Variable | Purpose | Default |
| --- | --- | --- |
| `CK_BACKEND` | `api` or `local` | `api` if `OMLX_API_KEY` is set, else `local` |
| `CK_LOCAL_MODEL` | local embedding model | `mlx-community/bge-small-en-v1.5-6bit` |
| `CK_LOCAL_RERANK_MODEL` | local reranker model | `mlx-community/jina-reranker-v3-4bit-mxfp4` |
| `OMLX_BASE_URL` | API backend base URL | `http://127.0.0.1:8000/v1` |
| `OMLX_API_KEY` | API backend key | unset |
| `OMLX_MODEL` | API embedding model | `zembed-1-embedding-mlx-6Bit` |
| `OMLX_RERANK_MODEL` | API rerank model | `zerank-2-reranker-oQ6` |

## Beyond code search: low-latency classification

The local MLX backend isn't limited to code search. Cosine-similarity classification over a small set of reference vectors is fast enough to use on the hot path of a request router.

Pattern: pre-compute one reference embedding per class from a prose description, then at runtime embed the input and pick the nearest class. If the top score is below a confidence threshold (e.g. `0.30`) or the margin over second place is too small (e.g. `0.05`), fall back to a slower authoritative classifier.

```python
import mlx_embeddings as mx
import mlx.core as mxc
import numpy as np

model, tokenizer = mx.load("mlx-community/all-MiniLM-L6-v2-4bit")

# Pre-compute reference embeddings once
class_texts = ["simple tasks and quick questions", "complex multi-step reasoning"]
out = mx.generate(model, tokenizer, class_texts)
mxc.eval(out.text_embeds)
refs = np.array(out.text_embeds)
refs /= np.linalg.norm(refs, axis=1, keepdims=True) + 1e-9

# Classify at ~1.3ms per query (after warmup)
query_out = mx.generate(model, tokenizer, ["help me refactor this function"])
mxc.eval(query_out.text_embeds)
v = np.array(query_out.text_embeds)[0]
v /= np.linalg.norm(v) + 1e-9
scores = refs @ v  # cosine similarities
```

`all-MiniLM-L6-v2-4bit` is the recommended model for this use case: ~12 MB, 384 dims, 1024-token context, quantized for the Neural Engine.

## Notes

- Vector width is discovered from the active embedding model when the index is created.
- Semantic and hybrid search fail fast if the active backend does not match the stored index metadata.
- MCP server returns a friendly `Run: ck-mlx index <path>` message when no index exists — no crash, no special handling needed in clients.
