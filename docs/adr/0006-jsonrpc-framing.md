# 0006. One JSON-RPC library for LSP, DAP and MCP

Status: Accepted
Date: 2026-10-21

## Context

LSP and DAP frame messages with `Content-Length` headers; the MCP stdio transport sends newline-delimited JSON. LSP and MCP use JSON-RPC 2.0; DAP has its own message shape (`seq`, `type`, `command`) and is not JSON-RPC.

## Decision

- `zg_jsonrpc` provides both framers (Content-Length and NDJSON), the JSON-RPC 2.0 message model (ids, errors, batches) on `std.json`, and an `Endpoint` with a pending-request table, dispatch, timeouts and dialect-specific cancellation (`$/cancelRequest` for LSP, `notifications/cancelled` for MCP).
- DAP (E07) uses only the Content-Length framer and models its own messages.
- Framers enforce size limits and never trust a peer's lengths.

## Consequences

- E07 and E11 share one tested, fuzzed transport layer.
- Protocol semantics beyond JSON-RPC 2.0 stay in the consuming epics.

## References

- [JSON-RPC 2.0 specification](https://www.jsonrpc.org/specification)
- [LSP 3.17 specification (Base Protocol, $/cancelRequest, error codes)](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/)
- [MCP 2026-07-28 stdio transport](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio)
