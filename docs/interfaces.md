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
`packages/jsonrpc/src/{framing.zig, message.zig, dialect.zig, Endpoint.zig, testing.zig}` (E00.F05).

### Implemented by
E00.F05.S01.T01, E00.F05.S01.T02, E00.F05.S02.T01.

### Consumed by
E07 (LSP and DAP clients), E11 (MCP client and server SDK).

### Signature
```zig
// framing.zig
pub const Options = struct { max_message_bytes: usize = 64 << 20, max_header_bytes: usize = 8 << 10 };
pub const Framing = enum { content_length, ndjson };
pub const ContentLengthReader = struct {
    pub fn init(r: *std.Io.Reader, opts: Options) ContentLengthReader;
    pub fn next(self: *ContentLengthReader, gpa: std.mem.Allocator) Error![]const u8;
    pub fn deinit(self: *ContentLengthReader, gpa: std.mem.Allocator) void;
};
pub const NdjsonReader = struct { // same shape as ContentLengthReader
    pub fn init(r: *std.Io.Reader, opts: Options) NdjsonReader;
    pub fn next(self: *NdjsonReader, gpa: std.mem.Allocator) Error![]const u8;
    pub fn deinit(self: *NdjsonReader, gpa: std.mem.Allocator) void;
};
pub fn writeContentLength(w: *std.Io.Writer, body: []const u8) Error!void;
pub fn writeNdjson(w: *std.Io.Writer, body: []const u8) Error!void;
pub fn isFatal(err: Error) bool;

// message.zig
pub const Id = union(enum) { int: i64, str: []const u8, null };
pub const RawJson = struct { bytes: []const u8 };
pub const Message = union(enum) { request: Request, notification: Notification, response: Response };
pub const Parsed = union(enum) { single: Message, batch: []BatchEntry, invalid: ErrorObject };
pub fn parse(arena: Allocator, body: []const u8) Parsed;

// Endpoint.zig
pub fn init(rt: *zg_core.Runtime, cfg: Config, reader: *std.Io.Reader, writer: *std.Io.Writer) !*Endpoint;
pub fn onRequest(self: *Endpoint, method: []const u8, h: Handler) !void;
pub fn onNotification(self: *Endpoint, method: []const u8, h: NotificationHandler) !void;
pub fn onClose(self: *Endpoint, cb: Callback) void;
pub fn start(self: *Endpoint) !void;
pub fn request(self: *Endpoint, method: []const u8, params: anytype, opts: CallOptions) !OwnedResponse;
pub fn requestAsync(self: *Endpoint, method: []const u8, params: anytype, opts: CallOptions, cb: Callback) !i64;
pub fn notify(self: *Endpoint, method: []const u8, params: anytype) !void;
pub fn cancel(self: *Endpoint, id: i64) void;
pub fn respond(self: *Endpoint, id: message.Id, result: anytype) !void;
pub fn respondError(self: *Endpoint, id: message.Id, code: i32, msg: []const u8) !void;
pub fn isCanceled(self: *Endpoint, id: message.Id) bool;
pub fn close(self: *Endpoint) void;
pub fn deinit(self: *Endpoint) void;
```

### Threading
The Endpoint runs reader, writer and timer loops on the Runtime's Io; any
thread may send. Sync `request` must not be called on the UI thread.
Request handlers run as Subsystem tasks; notification handlers and
callbacks run on the reader or timer loop and must use `Runtime.post` to
reach the UI. Incoming cancellation is cooperative (`isCanceled`).

### Ownership/lifetime
Frame bodies returned by `next` are valid until the next call. A handler's
`RawJson` lives in a per-request arena freed after the reply is written. An
`OwnedResponse` owns its memory; call `deinit`.

### Stability
Stable as merged in E00.F05; changes follow the rule above.

## zg_net.http, sse and websocket

### Defined in
`packages/net/src/{http.zig, sse.zig, websocket.zig}` (E00.F06).

### Implemented by
E00.F06.S01.T01, E00.F06.S02.T01, E00.F06.S02.T02.

### Consumed by
E10 (AI providers), E11 (MCP HTTP transport), E16 (account services).

### Signature
```zig
// http.zig
pub fn init(rt: *zg_core.Runtime, cfg: Config) !*Client;
pub fn deinit(self: *Client) void;
pub fn send(self: *Client, gpa: Allocator, req: Request) !Response;
pub fn stream(self: *Client, req: Request, sink: BodySink) !Head;
pub fn getJson(self: *Client, comptime T: type, gpa: Allocator, url: []const u8, headers: []const std.http.Header) !std.json.Parsed(T);
pub fn connectRaw(self: *Client, host: Io.net.HostName, port: u16, protocol: std.http.Client.Protocol) !Raw;
pub fn releaseRaw(self: *Client, raw: Raw) void;

// sse.zig
pub const Event = struct { type: []const u8, data: []const u8, id: ?[]const u8, retry_ms: ?u64 };
pub const Parser = struct {
    pub fn init(gpa: Allocator, opts: Options) Parser;
    pub fn feed(self: *Parser, chunk: []const u8, sink: anytype) !void; // sink.onEvent(Event)
    pub fn finish(self: *Parser) void;
};

// websocket.zig
pub fn connect(client: *http.Client, gpa: Allocator, url: []const u8, opts: Options) !*WebSocket;
pub fn send(self: *WebSocket, kind: Kind, data: []const u8) !void;
pub fn ping(self: *WebSocket, payload: []const u8) !void;
pub fn recv(self: *WebSocket, gpa: Allocator) !Received; // .message or .closed
pub fn close(self: *WebSocket, code: u16, reason: []const u8) !void;
```

Credentials (`Authorization`, `x-api-key`) are sent by zg_net itself and
dropped on redirects to another origin: std 0.16 accepts
`privileged_headers` but never writes them.

### Threading
`Client` is thread-safe. Blocking calls must not run on the UI thread.
`WebSocket.send` is thread-safe; `recv` has a single reader.

### Ownership/lifetime
`Response.body` is owned by the caller (`deinit`). SSE event slices are valid
only during the `onEvent` callback.

### Stability
Experimental until PR #1199 merges.

## zg_net.oauth.TokenStore

### Defined in
`packages/net/src/oauth/token_store.zig` (E00.F06.S03.T02).

### Implemented by
E16.F06 (OS keychain-backed store). zg_net ships `MemoryTokenStore`.

### Consumed by
`zg_net.oauth.Session` (E11 MCP auth, AI providers using OAuth).

### Signature
```zig
pub const TokenStore = struct {
    ctx: ?*anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        load: *const fn (?*anyopaque, gpa: Allocator, issuer: []const u8, resource: []const u8) anyerror!?TokenSet,
        save: *const fn (?*anyopaque, issuer: []const u8, resource: []const u8, t: TokenSet) anyerror!void,
        remove: *const fn (?*anyopaque, issuer: []const u8, resource: []const u8) anyerror!void,
    };
};
pub const TokenSet = struct { access_token: []const u8, token_type: []const u8, expires_at: ?i64,
    refresh_token: ?[]const u8, scope: ?[]const u8 }; // expires_at in Unix seconds
pub const MemoryTokenStore = struct {
    pub fn init(gpa: Allocator, io: std.Io) MemoryTokenStore;
    pub fn store(self: *MemoryTokenStore) TokenStore;
};
```

### Threading
Called from worker threads, never the UI thread. Implementations must be
thread-safe.

### Ownership/lifetime
`load` returns memory allocated with `gpa`, owned by the caller. `save`
copies what it keeps. Tokens are never logged.

### Stability
Experimental until PR #1199 merges.

## zg_net.oauth.OpenUrlFn

### Defined in
`packages/net/src/oauth/flow.zig` (E00.F06.S03.T01).

### Implemented by
E01.F07 (open the system browser).

### Consumed by
`zg_net.oauth.Session.authorize`.

### Signature
```zig
pub const OpenUrlFn = *const fn (ctx: ?*anyopaque, url: []const u8) anyerror!void;
```

### Threading
Called from a worker thread. Must return promptly once the browser has been
asked to open; it does not wait for the user.

### Ownership/lifetime
`url` is valid only during the call; `ctx` is borrowed.

### Stability
Experimental until PR #1199 merges.

## zg_net.oauth.Session

### Defined in
`packages/net/src/oauth/session.zig` (E00.F06.S03.T02).

### Implemented by
E00.F06.S03.T01, E00.F06.S03.T02.

### Consumed by
E11 (MCP authorization), E10 (providers using OAuth).

### Signature
```zig
pub const ClientRegistration = union(enum) {
    preregistered: []const u8,
    metadata_document_url: []const u8, // falls back to dynamic registration where unsupported
    dynamic: struct { client_name: []const u8 },
};
pub fn init(c: *http.Client, store: TokenStore, open_url: OpenUrlFn, open_ctx: ?*anyopaque, client: ClientRegistration) Session;
pub fn deinit(self: *Session) void;
pub fn authorize(self: *Session, gpa: Allocator, resource: []const u8, challenge: []const u8) !TokenSet;
pub fn refresh(self: *Session, gpa: Allocator, issuer: []const u8, resource: []const u8) !TokenSet;
pub fn bearer(self: *Session, gpa: Allocator, resource: []const u8) !?[]u8; // refreshes within 60 s of expiry
pub fn send(self: *Session, gpa: Allocator, resource: []const u8, req: http.Request) !http.Response;
pub fn remember(self: *Session, resource: []const u8, issuer: []const u8) !void;
```

### Threading
Blocking; worker threads only. Internal maps are mutex-protected, so one
session can serve several tasks.

### Ownership/lifetime
Returned token sets and bearer strings are owned by `gpa`. The
`ClientRegistration` strings and the `TokenStore` must outlive the session.
On an `iss` mismatch the code is not redeemed and the callback's error
fields are not surfaced (`error.IssuerMismatch`).

### Stability
Experimental until PR #1199 merges.

## zg_platform.Platform and Event

### Defined in
`packages/platform/src/api/platform.zig` and `api/event.zig` (E01.F01.S01.T01).

### Implemented by
The headless backend (E01.F01.S02.T01), Win32 (E01.F02), Wayland (E01.F04)
and X11 (E01.F05). Each runs `zg_platform.conformance`.

### Consumed by
E04 (GUI toolkit), E02 (renderer, through `surfaceTarget`/`cpuPresenter`),
E05, E06, E12, E13.

### Signature
```zig
pub const Platform = struct {
    ptr: *anyopaque,
    vtable: *const VTable, // createWindow, destroyWindow, submit, surfaceTarget, cpuPresenter,
                           // native, release, monitors, pollEvents, waitEvents, wake, deinit
    pub fn pollEvents(self: Platform, out: []Event) usize;      // UI thread; never blocks
    pub fn waitEvents(self: Platform, deadline_ns: ?u64) void; // UI thread; blocks on Wake
    pub fn wake(self: Platform) void;                           // any thread
    pub fn submit(self: Platform, cmd: Command) Error!void;     // any thread; non-blocking
    pub fn fromImpl(comptime T: type, impl: *T) Platform;
};
pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: InitOptions) Error!Platform;
pub fn detectBackend(env: *const std.process.Environ.Map) Backend;
pub const Event = union(enum(u8)) { ... }; // @sizeOf(Event) <= 64, asserted
```

### Threading
`pollEvents` and `waitEvents` are UI-thread only. `submit` and `wake` may
be called from any thread. Backends own a platform thread that produces
events and runs commands.

### Ownership/lifetime
A `PayloadSlice` in an event stays valid until the next `pollEvents`; one
with `large` set stays valid until passed to `Platform.release`. `submit`
copies every slice in a `Command` before returning.

### Stability
Experimental until the headless backend (E01.F01.S02.T01) merges.

## zg_platform.surface.Presenter

### Defined in
`packages/platform/src/api/surface.zig` (types from the E01.F04 design,
declared in E01.F01.S01.T01).

### Implemented by
Wayland (E01.F04.S04), X11 (E01.F05.S03.T02), the Win32 CPU presenter
(E01.F02.S05.T01) and headless (E01.F01.S02.T01).

### Consumed by
E02 (exportable image ring, software renderer).

### Signature
```zig
pub const PresenterVTable = struct {
    drmDevice: *const fn (*anyopaque) ?DrmDevice,
    formats: *const fn (*anyopaque, out: []FormatModifier) usize,
    syncMode: *const fn (*anyopaque) SyncMode,
    importBuffer: *const fn (*anyopaque, desc: *const BufferDesc) anyerror!BufferHandle,
    present: *const fn (*anyopaque, buf: BufferHandle, damage: []const PxRect, acquire: SyncPoint, ack: ?ConfigureAck) anyerror!void,
    releaseBuffer: *const fn (*anyopaque, buf: BufferHandle) void,
    pollReleased: *const fn (*anyopaque, out: []BufferHandle) usize, // any thread
    allocCpuBuffer: *const fn (*anyopaque, w: u32, h: u32, fourcc: u32) anyerror!CpuBuffer,
};
```

### Threading
`pollReleased` may be called from any thread; the rest from E02's render
thread for that window.

### Ownership/lifetime
`importBuffer` does not take ownership of plane fds. A `CpuBuffer` from
`allocCpuBuffer` is owned by the presenter until `releaseBuffer`.

### Stability
Experimental until the first OS presenter merges.
