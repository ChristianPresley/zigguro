# Tracing conventions

How zigguro code names what it traces, which async spans exist, and what a trace may never contain. Every package that emits zones, counters, async spans or flows follows these rules; E10, E11, E07, E08 and E09 tasks cite this page. E16 owns the final privacy policy; this is the minimum.

## Zones and counters

- Zones name synchronous work on one thread: `const z = zg_core.trace.zone(@src(), "editor.view.paint"); defer z.end();`.
- Names are dotted `<pkg>.<area>.<op>`. The first segment is the trace category (`zg_perf.trace.categories.Category`): `gui`, `render`, `gpu`, `platform`, `text`, `editor`, `syntax`, `terminal`, `lsp`, `dap`, `workspace`, `notes`, `scm`, `git`, `ai`, `mcp`, `review`, `agents`, `perf`, `startup`, `mem`, `io`, `net`. Anything else lands in `other`.
- Counters: `zg_core.trace.counter("workspace.index.queue", n)`. zg_perf's own counters use `perf.*` (`perf.key_to_photon_ns`, `perf.frame_cpu_ns`, `perf.gpu_ns`, `perf.ai_chunk_to_photon_ns`, `perf.ai_tool_dispatch_overhead_ns`, `perf.stall_ms`).

## Async spans

Asynchronous work (begin and end possibly on different threads) uses `zg_perf.trace.async_span`:

```zig
const async_span = zg_perf.trace.async_span;
const id = async_span.newId();
async_span.asyncBegin(.ai_request, id);        // on the worker that sends the request
async_span.asyncInstant(.ai_first_token, id, 0);
async_span.asyncEnd(.ai_request, id);          // on the worker that reads the end of the response

const span = async_span.Span.begin(.scm_op); // begin and end in one scope
defer span.end();
```

Ids pair begin and end, so overlapping requests never confuse the exporter, which gives each id its own lane.

| Name | Meaning | Category |
|---|---|---|
| `ai.turn` | one agent turn, from the user's message (or the loop's continuation) to the end of the model's answer and its tool calls | ai |
| `ai.request` | one provider HTTP request, from the first byte written to the end of the response | ai |
| `ai.first_byte` | instant on an `ai.request` lane: first response byte | ai |
| `ai.first_token` | instant on an `ai.request` lane: first decoded token (TTFT, `ai.ttft`, tracked, never gated) | ai |
| `ai.stream` | the SSE body of a streaming response | ai |
| `ai.tool_call` | a whole tool call as the harness sees it (contains `ai.tool_exec`) | ai |
| `ai.tool_exec` | the tool's own run inside `ai.tool_call` | ai |
| `ai.context_build` | assembling the context for a request | ai |
| `mcp.request` | one MCP request to a server, until its response | mcp |
| `lsp.request` | one LSP request, until its response | lsp |
| `dap.request` | one DAP request, until its response | dap |
| `net.http` | any other HTTP exchange | net |
| `workspace.index_job` | one indexing job | workspace |
| `scm.op` | one SCM operation (snapshot, rebase, fetch) | scm |

Adding a name means adding it to `zg_perf.trace.taxonomy.Name` and a row here; a test checks that both agree.

## Flows

Flows tie a cause to the frame that shows its effect. `flowOut(id)` attaches to the innermost open zone on the calling thread; `flowIn(id)` ends the flow in the innermost zone of the consumer.

1. **Input to frame**: E01 assigns `async_span.inputFlowId(input_seq)` (top bit set); E04 calls `flowIn` inside the frame zone that consumed the input.
2. **Stream chunk to frame**: the E10 SSE reader calls `flowOut(chunk_id)` when it parses a chunk; the UI calls `flowIn(chunk_id)` in the frame that applied it.

## Agent latency metrics

- `ai.chunk_to_photon` (budget: < 16.7 ms p99, target 8.33 ms, warn gate until E10 confirms): `zg_perf.frame.stream_latency.StreamLatency`. The network worker calls `onChunkReceived(chunk_id, t_recv_ns)`; the UI thread calls `onChunkApplied(chunk_id, frame_seq)` when the chunk's text enters the view model, and the frame timeline calls `onFramePresented`. Coalesced chunks each count with their own receive time.
- `ai.tool_dispatch_overhead` (< 1 ms p99, target 0.2 ms): E10 calls `stream_latency.toolDispatchOverhead(total_ns, exec_ns)` at the end of each tool call. `exec_ns` is measured inside `ai.tool_exec`; the timing ends before any user-approval wait.

## Privacy rules

- Allowed span labels and args: enums, sizes, counts, durations, ids, the model id, the tool name, MCP/LSP/DAP method names and host names (no path, no query).
- Paths appear only through the exporter's redaction (`redact = .paths` hashes path components).
- Never record prompt or response text, file contents, headers, tokens or keys, or URLs with query strings.
- Labels pass `async_span.checkArg` (at most 128 bytes, no newline, no `?`) before they are attached.
- Nothing leaves the machine. A trace file is written only when the user starts a session or the flight recorder dumps locally; crash reports attach one only with consent (E16, E17).
