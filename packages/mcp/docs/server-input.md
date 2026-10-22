# Asking the user from an MCP server handler

A zg_mcp tool, resource or prompt handler gets a `CallCtx`. Through it the
handler can ask for user input, report progress, log, and notice
cancellation. The same handler code works for modern (2026-07-28) and
legacy (2024-11-05 to 2025-11-25) clients.

## Input

```zig
fn deploy(_: ?*anyopaque, cc: *Server.CallCtx, args: Value) anyerror!CallToolResult {
    const ok = try cc.elicit("confirm", .{ .message = "Deploy to production?" });
    if (ok.action != .accept) return Server.toolError(cc.arena, "not confirmed", .{});
    if (!cc.once(args.object.get("nonce").?.string)) return Server.toolError(cc.arena, "already done", .{});
    // ... the side effect ...
}
```

`elicit`, `sample` and `roots` behave the same way:

- If this invocation already carries the answer, they return it.
- Otherwise they record the request and return `error.InputRequired`.
  The dispatcher then gets the answer and calls the handler again:
  - **Modern clients:** the call ends with an `input_required` result. The client retries with `inputResponses`, and the answers from earlier rounds come back inside the sealed `requestState`.
  - **Legacy clients:** the server sends `elicitation/create`, `sampling/createMessage` or `roots/list` on the session and waits for the answer. Earlier answers stay in memory.

Because a handler can run several times, it must have no side effects up to its last input request. Use `cc.once(nonce)` for anything that must happen at most once: a sealed state can be replayed until it expires.

`setState(bytes)` carries private state to the next round, and `state()` reads it back.

### Capabilities and limits

- If the client did not declare a capability the handler needs, the input call returns `error.CapabilityMissing`. Uncaught, it becomes `-32021` with `requiredCapabilities`.
- A request gets at most `Options.max_input_rounds` rounds (8).
- For a 2025-11-25 URL elicitation, create an id with `cc.newElicitationId()` and keep it with `setState`. When the out-of-band step is done, call `cc.completeElicitation(id)` to send the completion notification.

## requestState

The `requestState` is sealed with XChaCha20-Poly1305 (`server/mrtr_seal.zig`).

- **What it binds:** the principal, an expiry (`Options.request_state_ttl_ms`, 10 minutes by default), the method and canonical params, the handler state and the round.
- **Rejection:** any mismatch is rejected with `-32602` "invalid or expired requestState".
- **Key:** random per process by default. Servers behind a load balancer must share one key: set `Options.seal_key` to the same 32 bytes on every instance, loaded from a secret store, never from the repository.

## Progress, logs and cancellation

- **`cc.progress`:** sends only when the request carried a `progressToken`. It drops values that do not increase, and sends at most 20 updates a second.
- **`cc.log`:** modern clients receive logs only when the request asked for them with `io.modelcontextprotocol/logLevel`; legacy clients use `logging/setLevel`. Members whose names look secret (`password`, `token`, `apiKey`, ...) are redacted.
- **Cancellation:** `cc.isCanceled()` turns true on `notifications/cancelled` or when the connection closes. Nothing is sent for a canceled request.
