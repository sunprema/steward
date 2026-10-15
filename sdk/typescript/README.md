# @steward/sdk (TypeScript)

Agent SDK for Steward. Specified by
[doc 11 — Agent SDK and MCP server](../../docs/20-contracts/11-agent-sdk-and-mcp-server.md):
the core workflow is §2.2, error mapping §4, packaging §11.

Node ≥ 20 (global `fetch`), ESM only, no runtime dependencies; `pg` is an
optional peer for `poolConfig()` typing.
