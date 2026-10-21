# 0007. HTTP stack on std.http.Client

Status: Accepted
Date: 2026-10-21

## Context

LLM providers, remote MCP servers and OAuth all need HTTPS. Zig 0.16's `std.http.Client` speaks HTTP/1.1 with TLS 1.2/1.3 from std and loads system roots through `std.crypto.Certificate.Bundle.rescan`. It does not implement `NO_PROXY`, server-sent events, WebSocket or OAuth.

## Decision

- `zg_net` wraps `std.http.Client`: lazy CA loading on a worker (never on the startup path), extra CA files, `HTTPS_PROXY`/`HTTP_PROXY` with our own `NO_PROXY` matching, timeouts and retries.
- No HTTP/2 or HTTP/3: every provider and MCP endpoint we target accepts HTTP/1.1.
- LLM token streaming uses our incremental WHATWG SSE parser; realtime APIs use our RFC 6455 WebSocket client over std's connections.
- OAuth 2.1 (PKCE, loopback redirect per RFC 8252, RFC 8414/9728 discovery) is ours; tokens go through a `TokenStore` interface that E16 implements, and the browser opens through an injected `openUrl` (E01).

## Consequences

- One HTTP layer and one SSE parser serve E10 and E11.
- We own correctness of SSE, WebSocket and OAuth, so each has fuzz targets and RFC test vectors.

## References

- [WHATWG HTML: Server-sent events](https://html.spec.whatwg.org/multipage/server-sent-events.html)
- [RFC 6455: The WebSocket Protocol](https://www.rfc-editor.org/rfc/rfc6455)
- [RFC 7636: PKCE](https://www.rfc-editor.org/rfc/rfc7636)
- [RFC 8252: OAuth 2.0 for Native Apps](https://www.rfc-editor.org/rfc/rfc8252)
