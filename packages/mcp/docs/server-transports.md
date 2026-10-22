# Serving an MCP server

A `zg_mcp.server.Server` can be reached three ways (`server/transport/`).

## stdio

```zig
try zg_mcp.server.transport.serveStdio(server, .{ .stdin = Io.File.stdin(), .stdout = Io.File.stdout() });
```

- **Input:** NDJSON on stdin.
- **Output:** only MCP messages go to stdout. `std.log` writes to stderr.
- **Shutdown:** the call returns at stdin EOF. Running calls get two seconds to finish, then they are canceled.

`serveStream` does the same over any reader and sink, which is useful in tests.

## Streamable HTTP

```zig
const l = try zg_mcp.server.transport.listenHttp(server, .{ .bearer_token = token });
defer l.deinit(); // before server.deinit()
// l.port is the bound port, for a discovery file.
```

**Binding.** The listener binds loopback with an ephemeral port by default. Binding anywhere else needs `allow_remote = true`, which logs a warning and also turns off the `Host` check.

**Security checks.** Every request is checked before its body is read:

| Check | Failure |
|---|---|
| `Host` is `127.0.0.1:<port>`, `localhost:<port>` or `[::1]:<port>` | 403 |
| `Origin`, when present, is listed in `allowed_origins` | 403, with a JSON-RPC error body (`id: null`) |
| `Authorization: Bearer <64 hex>` matches `bearer_token`, compared in constant time | 401, with `WWW-Authenticate: Bearer realm="zigguro"` |
| The body fits `max_body_bytes` | 413 |

**Modern clients** (2026-07-28):

- **Routing headers.** `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name` and the tool's `Mcp-Param-*` headers must match the body; base64 sentinels are decoded first. A mismatch gets 400 with `-32020`.
- **Response format.** The answer is plain JSON unless one of these switches it to an SSE stream (with `X-Accel-Buffering: no`):
  - the request carries a `progressToken` or `logLevel`;
  - the handler sends something before its answer;
  - the answer takes longer than `keepalive_interval`.
- **Disconnects.** Because a slow answer becomes a stream with keep-alive comments, a client that goes away is noticed and its handler is canceled.
- **Other methods.** Notifications get 202. An unknown method gets 404 with `-32601`. GET and DELETE get 405.

**Legacy sessions** (2025-03-26 to 2025-11-25):

- **Session ids.** `initialize` mints an `Mcp-Session-Id`. Later requests must carry it: 400 without one, 404 once the session is unknown or ended.
- **Server requests.** Requests the server makes during a call (elicitation, sampling, roots) ride on that call's SSE stream. The client's answers arrive as POST bodies and get 202.
- **GET stream.** GET opens the session's stream for notifications that happen outside any call, such as `list_changed`.
- **Ending a session.** DELETE ends it.
- **Resumability.** Not offered: there are no event ids, and `Last-Event-ID` is ignored.

**Keep-alive.** Long-lived streams get a `:` comment every `keepalive_interval` (15 s by default).

**Not implemented.** The 2024-11-05 HTTP+SSE server mode.

## In-process

`server.serveInProcess(&pair)` serves one end of a `zg_mcp.transport.InProcPair`, and a `Client` connects to the other end. It uses the same NDJSON framing as stdio. A round trip takes about 8 µs, against a budget of 100 µs.
