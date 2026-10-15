# steward-mcp

MCP server exposing Steward to agents. Specified by
[doc 11 — Agent SDK and MCP server](../../docs/20-contracts/11-agent-sdk-and-mcp-server.md):
tools §8.1, resources and prompts §8.2, safety rules §8.3, packaging §11.

Node ≥ 20. Depends on `@steward/sdk` and `@modelcontextprotocol/sdk` (added
when the server is implemented). A PyPI launcher of the same name execs this
package.
