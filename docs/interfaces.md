# Cross-package interfaces

The contracts below cross epic boundaries. Each one names where it is
defined, who implements and consumes it, its signature, its threading and
ownership rules, and how stable it is. Package names use underscores
(`zg_core`, `zg_net`), matching the `.name` in each `build.zig.zon`.

Signatures are copied from merged code where it exists. A signature marked
"(spec, not yet merged)" is the task issue's interface and becomes binding
when that task merges; update this file in the same PR.

**Stability rule.** A change to any listed signature requires an `api-change` issue, an ADR if more than one epic is affected, and a `cross-package` PR reviewed by every consuming epic's CODEOWNERS team. Additive changes (new optional fields with defaults, new functions) need only the `cross-package` label.

## zg_core.runtime.Waker

### Defined in
`packages/core/src/runtime/waker.zig` (E00.F04).

### Implemented by
E01.F01.S01.T02 (platform wakers: Win32 `PostMessageW`, Wayland/X11 eventfd
or self-pipe). zg_core ships `Waker.noop`, `EventWaker` and `TestWaker`.

### Consumed by
`zg_core.Runtime` mailbox; every UI loop (E01, E02).

### Signature
```zig
pub const Waker = struct {
    ctx: ?*anyopaque,
    wakeFn: *const fn (?*anyopaque) void,
    pub const noop: Waker;
    pub fn wake(w: Waker) void;
};
```

### Threading
`wakeFn` is called from any thread. It must be thread-safe, must not block
and may be called spuriously.

### Ownership/lifetime
`ctx` is borrowed; its owner keeps it alive until the Runtime is deinitialised.

### Stability
Stable.

## zg_core.Runtime.post / drain and UiMsg

### Defined in
`packages/core/src/runtime/Runtime.zig`, `packages/core/src/runtime/mailbox.zig` (E00.F04).

### Implemented by
E00.F04 (zg_core).

### Consumed by
Every subsystem that reports to the UI thread (E02 onwards); the UI loop drains.

### Signature
```zig
pub const UiMsg = extern struct { // 40 bytes
    kind: u32,
    source: u32 = 0,
    a: u64 = 0,
    b: u64 = 0,
    c: u64 = 0,
    d: u64 = 0,
};
pub const PostError = error{ Closed, Full };
pub fn post(rt: *Runtime, msg: UiMsg) PostError!void;
pub fn drain(rt: *Runtime, out: []UiMsg) usize;
pub inline fn assertNotUi(rt: *const Runtime) void;
```

### Threading
`post` from any thread; never blocks or allocates and wakes the UI thread
only on the first post after a drain. `drain` on the UI thread only.

### Ownership/lifetime
Messages are plain data. Anything referenced by payload words (`SlotMap`
handles, `Pool` pointers) transfers to the UI thread when `drain` returns
the message. On `error.Full` the sender keeps ownership and should coalesce.

### Stability
Stable. The 40-byte size is asserted at compile time.

## zg_core.report crash hook

### Defined in
`packages/core/src/report.zig` (E00.F04).

### Implemented by
E17 (crash reporter: minidump-style capture and upload consent).

### Consumed by
Both apps install `panicHandler` via `std.debug.FullPanic`.

### Signature
```zig
pub const CrashHook = *const fn (msg: []const u8, ret_addr: ?usize) void;
pub fn setCrashHook(h: ?CrashHook) void;
pub fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn;
```

### Threading
The hook runs on the panicking thread, possibly while other threads still
run. It must not take locks that the panicking thread may hold, and must not
allocate from the general allocator.

### Ownership/lifetime
The hook is a static function pointer; `msg` is valid only during the call.

### Stability
Stable.

## zg_core.trace events

### Defined in
`packages/core/src/trace.zig` (E00.F04).

### Implemented by
E00.F04 (zg_core).

### Consumed by
E14.F02 (profiler UI and trace export).

### Signature
```zig
pub const Event = extern struct { ts: u64, site_or_name: usize, kind: u8, tid: u32, value: i64 };
pub fn collect(gpa: std.mem.Allocator, out: *std.ArrayList(Event)) !void;
pub fn writeChromeJson(events: []const Event, w: *std.Io.Writer) !void;
pub fn droppedCount() u64;
```

### Threading
Producers write to a per-thread SPSC ring without locks. `collect` may run on
any single thread at a time.

### Ownership/lifetime
`site_or_name` points at static `Site` data that lives for the program.
`out` is owned by the caller.

### Stability
Experimental until E14.F02 merges; the Chrome JSON output is stable.

## Bench JSON schema

### Defined in
`docs/bench-format.md`, `packages/core/src/bench.zig` (E00.F04).

### Implemented by
E00.F04 (`zg_core.bench`); every package's `bench/main.zig`.

### Consumed by
E14.F06 (bench regression tracking in CI).

### Signature
```zig
pub const Result = struct {
    name: []const u8,
    iters: u64,
    ns_per_op: f64,
    p50_ns: f64,
    p99_ns: f64,
    bytes_per_op: ?f64 = null,
    allocs_per_op: f64,
    bytes_alloc_per_op: f64,
};
pub fn mainFromArgs(min: std.process.Init.Minimal, comptime register: fn (*Bench) anyerror!void) !u8;
```

### Threading
Benches run single-threaded unless the bench spawns its own workers.

### Ownership/lifetime
The JSON file at `bench-results/<package>.json` is rewritten on every run.

### Stability
Stable; adding fields is additive.

## zg_jsonrpc framers and Endpoint

### Defined in
`packages/jsonrpc/src/{framing.zig, message.zig, Endpoint.zig}` (E00.F05).

### Implemented by
E00.F05.S01.T01, E00.F05.S01.T02, E00.F05.S02.T01.

### Consumed by
E07 (LSP and DAP clients), E11 (MCP client and server SDK).

### Signature
(spec, not yet merged)
```zig
pub const Options = struct { max_message_bytes: usize = 64 << 20, max_header_bytes: usize = 8 << 10 };
pub const ContentLengthReader = struct {
    pub fn init(r: *std.Io.Reader, opts: Options) ContentLengthReader;
    pub fn next(self: *ContentLengthReader, gpa: std.mem.Allocator) Error![]const u8;
};
pub fn writeContentLength(w: *std.Io.Writer, body: []const u8) Error!void;
pub const NdjsonReader = struct {
    pub fn init(r: *std.Io.Reader, opts: Options) NdjsonReader;
    pub fn next(self: *NdjsonReader, gpa: std.mem.Allocator) Error![]const u8;
};
pub fn writeNdjson(w: *std.Io.Writer, body: []const u8) Error!void;

pub const Dialect = enum { plain, lsp, mcp };
pub fn respond(self: *Endpoint, id: message.Id, result: anytype) !void;
pub fn respondError(self: *Endpoint, id: message.Id, code: i32, msg: []const u8) !void;
pub fn onClose(self: *Endpoint, cb: Callback) void;
```

### Threading
The Endpoint runs a reader loop and a writer loop on the Runtime's Io. Sync
`request` must not be called on the UI thread. Callbacks run on the reader
thread; use `Runtime.post` to reach the UI.

### Ownership/lifetime
Frame bodies returned by `next` are valid until the next call. Request
handlers get a per-request arena freed after the reply is written.

### Stability
Experimental until E00.F05 merges.

## zg_net.http, sse and websocket

### Defined in
`packages/net/src/{http.zig, sse.zig, websocket.zig}` (E00.F06).

### Implemented by
E00.F06.S01.T01, E00.F06.S02.T01, E00.F06.S02.T02.

### Consumed by
E10 (AI providers), E11 (MCP HTTP transport), E16 (account services).

### Signature
(spec, not yet merged)
```zig
pub fn init(rt: *zg_core.Runtime, cfg: Config) !*Client;
pub fn send(self: *Client, gpa: Allocator, req: Request) !Response;
pub fn stream(self: *Client, req: Request, sink: BodySink) !Head;

pub const Event = struct { type: []const u8, data: []const u8, id: ?[]const u8, retry_ms: ?u64 };
pub const Parser = struct {
    pub fn feed(self: *Parser, chunk: []const u8, sink: anytype) !void;
    pub fn finish(self: *Parser) void;
};

pub fn connect(client: *http.Client, gpa: Allocator, url: []const u8, opts: Options) !*WebSocket;
pub fn send(self: *WebSocket, kind: enum { text, binary }, data: []const u8) !void;
```

### Threading
`Client` is thread-safe. Blocking calls must not run on the UI thread.
`WebSocket.send` is thread-safe; `recv` has a single reader.

### Ownership/lifetime
`Response.body` is owned by the caller (`deinit`). SSE event slices are valid
only during the `onEvent` callback.

### Stability
Experimental until E00.F06 merges.

## zg_net.oauth.TokenStore

### Defined in
`packages/net/src/oauth/token_store.zig` (E00.F06.S03.T02).

### Implemented by
E16.F06 (OS keychain-backed store). zg_net ships `MemoryTokenStore`.

### Consumed by
`zg_net.oauth.Session` (E11 MCP auth, AI providers using OAuth).

### Signature
(spec, not yet merged)
```zig
pub const TokenStore = struct { ctx: ?*anyopaque, vtable: *const struct {
    load: *const fn (?*anyopaque, gpa: Allocator, issuer: []const u8, resource: []const u8) anyerror!?TokenSet,
    save: *const fn (?*anyopaque, issuer: []const u8, resource: []const u8, t: TokenSet) anyerror!void,
    remove: *const fn (?*anyopaque, issuer: []const u8, resource: []const u8) anyerror!void,
} };
```

### Threading
Called from worker threads, never the UI thread. Implementations must be
thread-safe.

### Ownership/lifetime
`load` returns memory allocated with `gpa`, owned by the caller. `save`
copies what it keeps. Tokens are never logged.

### Stability
Experimental until E00.F06.S03.T02 merges.

## zg_net.oauth.OpenUrlFn

### Defined in
`packages/net/src/oauth/flow.zig` (E00.F06.S03.T01).

### Implemented by
E01.F07 (open the system browser).

### Consumed by
`zg_net.oauth.Session.authorize`.

### Signature
(spec, not yet merged)
```zig
pub const OpenUrlFn = *const fn (ctx: ?*anyopaque, url: []const u8) anyerror!void;
```

### Threading
Called from a worker thread. Must return promptly once the browser has been
asked to open; it does not wait for the user.

### Ownership/lifetime
`url` is valid only during the call; `ctx` is borrowed.

### Stability
Experimental until E00.F06.S03.T01 merges.
