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
`packages/platform/src/api/platform.zig` and `api/event.zig` (E01.F01.S01.T01);
`init` is in `packages/platform/src/root.zig`.

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
    vtable: *const VTable, // createWindow, destroyWindow, submit, surfaceTarget, cpuPresenter, payload,
                           // native, release, monitors, pollEvents, waitEvents, wake, deinit
    pub fn pollEvents(self: Platform, out: []Event) usize;      // UI thread; never blocks
    pub fn waitEvents(self: Platform, deadline_ns: ?u64) void; // UI thread; blocks on Wake
    pub fn wake(self: Platform) void;                           // any thread
    pub fn submit(self: Platform, cmd: Command) Error!void;     // any thread; non-blocking
    pub fn payload(self: Platform, s: PayloadSlice) []const u8; // event payload bytes
    pub fn fromImpl(comptime T: type, impl: *T) Platform;
};
pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: InitOptions) Error!Platform;          // detected backend, Wayland → X11 fallback
pub fn initBackend(gpa: std.mem.Allocator, io: std.Io, b: Backend, opts: InitOptions) Error!Platform; // exactly `b`
pub fn detectBackend(env: *const std.process.Environ.Map) Backend;
pub fn isForced(opts: InitOptions) bool; // opts.backend or a valid ZG_PLATFORM
// InitOptions.environ_map is `?*std.process.Environ.Map` (mutable: Wayland consumes WAYLAND_SOCKET)
pub const Event = union(enum(u8)) { ... }; // @sizeOf(Event) <= 64, asserted
```

Backend selection: `ZG_PLATFORM` (`wayland`, `x11`, `win32`, `headless`)
forces a backend and disables fallback; otherwise Windows → win32, a
non-empty `WAYLAND_DISPLAY` → wayland, a non-empty `DISPLAY` → x11, else
headless. A detected Wayland backend that cannot connect falls back to
X11 when `DISPLAY` is set. `init` never falls back to headless: the app
does that (apps/zigguro renders `--frames N` headless frames and exits).
Cocoa returns `error.BackendUnavailable` until it lands.

Win32's `surfaceTarget` is `.win32 = .{ hinstance, hwnd }` for a Vulkan
swapchain. Until then `zg_gui.Host` retries the renderer with
`.external = cpuPresenter(win)` when the renderer answers
`error.Unsupported` for a target (the software renderer does for `.win32`).

Frame pacing: request a frame with `Command.request_frame` and render on
`Event.frame`. Until a window's first present, every backend answers the
request at once (Wayland sends no frame callbacks for an unmapped
surface), so frame 0 is what maps the window.

### Threading
`pollEvents` and `waitEvents` are UI-thread only. `submit` and `wake` may
be called from any thread. Wayland and headless own a platform thread
that produces events; X11 dispatches on the UI thread inside
`pollEvents`/`waitEvents` (its connection has one reader). Win32 owns a
platform thread with the message pump; `createWindow`/`destroyWindow`
run there through `SendMessageW`.

### Ownership/lifetime
A `PayloadSlice` in an event stays valid until the next `pollEvents`; one
with `large` set stays valid until passed to `Platform.release`. `submit`
copies every slice in a `Command` before returning.

### Stability
Experimental until PR #1199 merges.

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
`importBuffer` does not take ownership of plane fds; E02 keeps them open
until `releaseBuffer` (the Wayland presenter uses them for implicit
sync). A `CpuBuffer` from `allocCpuBuffer` is owned by the presenter
until `releaseBuffer`. `present` takes ownership of a `.sync_file`
acquire fd and closes it, also on error.

`present` with `ack = null` (E02's software path) answers the newest
pending configure on Wayland. On X11 the newest presented buffer stays
busy (it repaints `Expose` damage) until a newer one is presented, and
MIT-SHM buffers also until their `ShmCompletion`.

### Stability
Experimental. The Wayland presenter imports dmabufs when the compositor
offers zwp_linux_dmabuf_v1 (v3+): `drmDevice()` is the first tranche's
device of the default feedback (or `main_device`), `formats()` lists the
feedback's pairs in tranche order (preferred first), and `syncMode()` is
`.implicit_sync_file`. A `.sync_file` acquire is imported into the
dmabuf with `DMA_BUF_IOCTL_IMPORT_SYNC_FILE`; without the ioctl the
presenter waits on it on the calling thread. A `.syncobj` acquire is
`error.Unsupported` until the contract carries a release point. Shm
`importBuffer` (an E02 memfd) works on Wayland too. Without the global,
and on X11 until DRI3 (E01.F05.S03.T02), presenters are CPU-only
(`.cpu_only`, `importBuffer` → `error.Unsupported`). Per-surface feedback
is not requested yet; a later change of the default feedback is logged
and applies to the next ring E02 builds.

## zg_platform.headless.Headless and .zgtrace

### Defined in
`packages/platform/src/headless/backend.zig` and `headless/trace.zig`
(E01.F01.S02.T01).

### Implemented by
E01.F01.S02.T01.

### Consumed by
E04 and E14 UI tests, E02 software-renderer tests, the `zg` CLI (E10),
and every OS backend's conformance run (`zg_platform.conformance`).

### Signature
```zig
pub fn init(gpa: Allocator, io: std.Io, opts: HeadlessOptions) !*Headless;
pub fn platform(self: *Headless) Platform;
pub fn inject(self: *Headless, ev: Event) !void;
pub fn injectPayload(self: *Headless, ev: Event, bytes: []const u8) !void;
pub fn injectText(self: *Headless, win: WindowId, utf8: []const u8) !void;
pub fn setClipboard(self: *Headless, which: Selection, mime: MimeId, bytes: []const u8) !void;
pub fn lastFrame(self: *Headless, win: WindowId) ?FrameImage; // RGBA8
pub fn tick(self: *Headless, ns: u64) !void;                  // virtual clock, 60 Hz vsync
pub fn replay(self: *Headless, r: *std.Io.Reader) !void;      // .zgtrace
// trace.zig
pub fn writeHeader(w: *std.Io.Writer) !void;
pub fn record(w: *std.Io.Writer, t_ns_rel: u64, ev: Event, payloads: []const []const u8) !void;
pub fn next(r: *std.Io.Reader, gpa: Allocator) !?Record;
// testing/conformance.zig
pub fn runConformance(comptime B: type, harness: *B) !void;
```

### Threading
All methods lock one mutex; `wake` may be called from any thread. Commands
run synchronously inside `submit`.

### Ownership/lifetime
`lastFrame` pixels stay valid until the next present to that window.
`.zgtrace` is little-endian and field-wise, so traces are identical on every
OS; see the format comment in `trace.zig`.

### Stability
Experimental until PR #1199 merges. The trace `version` changes whenever
`Event` changes.

## zg_platform.dbus.Bus

### Defined in
`packages/platform/src/dbus/conn.zig`, with `marshal.zig`, `variant.zig`,
`message.zig`, `signature.zig` and `auth.zig` (E01.F07.S01.T01).

### Implemented by
E01.F07.S01.T01.

### Consumed by
E01 portals (FileChooser, OpenURI, Settings), E13 notifications, E16
Secret Service and E04 AT-SPI discovery. One session `Bus` per process,
shared by all of them.

### Signature
```zig
pub fn connectSession(gpa: Allocator, io: std.Io, env: *const std.process.Environ.Map, opts: Options) !*Bus;
pub fn connectAddress(gpa: Allocator, io: std.Io, address: []const u8, opts: Options) !*Bus;
pub fn call(self: *Bus, dest, path, iface, member: []const u8, comptime sig: []const u8, args: anytype) !Pending;
pub fn callAsync(self: *Bus, dest, path, iface, member: []const u8, comptime sig: []const u8, args: anytype, handler: ReplyHandler) !void;
pub fn emit(self: *Bus, path, iface, member: []const u8, comptime sig: []const u8, args: anytype) !void;
pub fn addMatch(self: *Bus, rule: []const u8, handler: SignalHandler) !MatchId;
pub fn removeMatch(self: *Bus, id: MatchId) void;
pub fn setMethodHandler(self: *Bus, handler: ?MethodHandler) void; // serve calls (services, test fakes)
pub fn replyTo(self: *Bus, in: *const Incoming, comptime sig: []const u8, args: anytype) !void;
pub fn replyError(self: *Bus, in: *const Incoming, name: []const u8, text: []const u8) !void;
pub fn pollFd(self: *const Bus) i32;  // with Options.own_thread = false
pub fn pump(self: *Bus) !void;
// Pending
pub fn wait(self: *Pending, timeout_ns: ?u64) !Reply;  // error replies are Replies; check isError()
// marshal.zig / variant.zig
pub fn encode(e: *Encoder, comptime sig: []const u8, args: anytype) !void;
pub fn decode(d: *Decoder, sig: []const u8) !Value;
```
`connectSession` takes the environment map because zigguro code never reads
the process environment directly; the spec's two-argument form gains `env`
and `opts`. `addMatch` returns a `MatchId` so that each subscriber can
remove its own match.

### Threading
Any thread may call, emit, add or remove matches. Sends are serialised by a
lock. Replies and signals are dispatched on the bus's reader thread (or by
whoever calls `pump`). Handlers run on that reader and must not wait on a
`Pending`.

### Ownership/lifetime
A `Reply` owns its bytes and fds; `deinit` frees them, `takeFd` moves an fd
out. Values decoded from a reply are views into it plus containers in the
caller's arena. An `Incoming` signal is valid only during the handler call.
fds passed to `call`/`emit` stay owned by the caller.

### Stability
Experimental until the E01 PR merges.

## zg_platform.portal

### Defined in
`packages/platform/src/portal/{request,file_chooser,open_uri,settings,window_handle}.zig`;
the test fake is `portal/fake_portal.zig` (E01.F07.S01.T02).

### Implemented by
E01.F07.S01.T02, on `zg_platform.dbus.Bus`.

### Consumed by
The Wayland and X11 backends (E01.F04, E01.F05), which turn responses into
`Event.dialog_result` and `Event.appearance_changed`; E04 falls back to its
built-in picker when a response is `unavailable`.

### Signature
```zig
// request.zig
pub fn Request.begin(gpa: Allocator, bus: *Bus, cb: ?Callback) !*Request; // token() for handle_token
pub fn Request.replyHandler(self: *Request) ReplyHandler;                  // pass to bus.callAsync
pub fn Request.wait(self: *Request, timeout_ns: ?u64) !Response;           // when cb is null
pub const Response = struct { code: Code, unavailable: bool, results: Dict, ... };
pub fn fileUriToPath(out: []u8, uri: []const u8) ?[]const u8;
// file_chooser.zig
pub fn open(gpa: Allocator, bus: *Bus, req: DialogRequest, parent: []const u8, cb: Callback) !*Request;
pub fn paths(resp: *const Response, gpa: Allocator, out: *std.ArrayList(u8)) !usize; // NUL-separated
// open_uri.zig
pub fn open(gpa: Allocator, bus: *Bus, parent: []const u8, uri: []const u8, policy: SchemePolicy, cb: ?Callback) !*Request;
// settings.zig
pub fn read(gpa: Allocator, bus: *Bus, timeout_ns: ?u64) Appearance;     // ReadOne, then Read on old portals
pub const Watcher = struct { bus, current: Appearance, callback: ChangeCallback, ... }; // start/stop
// window_handle.zig
pub fn wayland(out: []u8, handle: []const u8) ![]const u8;               // "wayland:<handle>"
pub fn x11(out: []u8, xid: u32) ![]const u8;                              // "x11:<hex>"
```
`Event.dialog_result` has no `unavailable` field yet: adding one changes
the `.zgtrace` layout, so it lands with the first backend that emits it,
together with a trace version bump.

### Threading
Callbacks run on the bus reader thread. `settings.read` blocks on calls,
so run it off the UI thread.

### Ownership/lifetime
A `Response` owns its results; the callback (or the `wait` caller) must
`deinit` it. Free a `Request` after its response arrived, or to abandon it.

### Stability
Experimental until the E01 PR merges.

## zg_platform.wayland.wire.Connection

### Defined in
`packages/platform/src/wayland/wire/connection.zig`, with `socket.zig`,
`fdqueue.zig`, `marshal.zig`, `objects.zig` and `registry.zig`; the test
compositor is `packages/platform/src/wayland/testing/fake_compositor.zig`
(E01.F03.S01.T02).

### Implemented by
E01.F03.S01.T02. The typed encoders and decoders it carries are generated
into `wl_gen` by zg_build's `wayland_scanner` (E01.F03.S01.T01), which also
emits per-interface `request_fds`, `event_fds`, `event_destructors` and
`event_new_ids` tables for the connection.

### Consumed by
The Wayland backend (E01.F04): windows, input, clipboard, IME and the
presenter. Tests of every Wayland task build on `FakeCompositor`.

### Signature
```zig
pub fn connect(gpa: Allocator, io: std.Io, env: *std.process.Environ.Map) !*Connection; // removes WAYLAND_SOCKET from env
pub fn fromFd(gpa: Allocator, io: std.Io, fd: i32) !*Connection;
pub fn newId(self: *Connection, comptime I: type, handler: ?Handler) !I.Id;          // version I.version
pub fn newIdVersion(self: *Connection, comptime I: type, version: u32, handler: ?Handler) !I.Id;
pub fn setHandler(self: *Connection, obj: u32, handler: ?Handler) void;              // e.g. for objects events create
pub fn send(self: *Connection, obj: u32, opcode: u16, args: anytype, fds: []const i32) !void; // via generated encoders
pub fn flush(self: *Connection) !void;
pub fn readSocket(self: *Connection) !usize;       // non-blocking
pub fn dispatchPending(self: *Connection) !usize;
pub fn roundtrip(self: *Connection) !void;
pub fn roundtripTimeout(self: *Connection, timeout_ns: ?u64) !void;
pub fn pollFd(self: *const Connection) i32;        // `fd` in the design
// Handler: on_event(ctx, conn, obj, opcode, body: []const u32, fds: *FdQueue) anyerror!void
// Registry
pub fn init(conn: *Connection) !*Registry;         // get_registry + roundtrip
pub fn bind(self: *Registry, comptime I: type, min_version: u32, max_version: u32, handler: ?Handler) !?I.Id;
pub fn onGlobalRemove(self: *Registry, cb: ?RemoveCallback) void;
```
Usage: `const cb = try conn.newId(wl.wl_callback, h); try wl.wl_surface.frame(conn, surface, cb);`.
Objects an event creates (server ids, e.g. `wl_data_device.data_offer`) are
registered automatically with no handler; call `setHandler` from the
creating event's handler to receive their events.

### Threading
Reading and dispatching belong to one thread. `send`, `flush`, `newId`,
`setHandler` and `destroyed` lock, so a render thread may send requests
while the platform thread dispatches. Handlers run on the dispatching
thread.

### Ownership/lifetime
`body` views and string/array views decoded from it are valid only during
the handler call. A handler owns the fds it pops; fds it leaves are closed
after it returns. `send` duplicates the fds it is given, so callers keep
(and close) their own. Client ids are reused only after `delete_id`.

### Stability
Experimental until the E01 PR merges.

## zg_platform.x11.Conn

### Defined in
`packages/platform/src/x11/conn.zig`, with `auth.zig` (DISPLAY,
Xauthority), `setup.zig`, `proto.zig` (comptime request serializer, core
requests, replies, errors), `ext.zig` and `atoms.zig`; the test server is
`packages/platform/src/x11/testing/fake_server.zig` (E01.F05.S01.T01).
It reuses `wayland/wire/socket.zig` and `fdqueue.zig` for SCM_RIGHTS.

### Implemented by
E01.F05.S01.T01.

### Consumed by
The X11 backend (E01.F05.S02/S03): windows, input (XKB, XInput2),
selections, and the DRI3/Present presenter.

### Signature
```zig
pub fn connect(gpa: Allocator, io: std.Io, env: *const std.process.Environ.Map, opts: Options) Error!*Conn;
pub fn fromFd(gpa: Allocator, io: std.Io, fd: i32, cookie: ?auth.Cookie, opts: Options) Error!*Conn;
pub fn request(self: *Conn, comptime R: type, req: R, fds: []const i32) Error!Cookie(R);
pub fn reply(self: *Conn, cookie: Cookie(R)) Error!R.Reply;   // error.X11Error sets last_error
pub fn checked(self: *Conn, comptime R: type, req: R, fds: []const i32) Error!void; // request + sync
pub fn sync(self: *Conn) Error!void;                         // GetInputFocus round trip
pub fn flush(self: *Conn) Error!void;
pub fn pollEvent(self: *Conn) Error!?[]const u8;             // 32 bytes, or 32 + 4n for XGE
pub fn waitEvent(self: *Conn) Error![]const u8;
pub fn newXid(self: *Conn) Error!u32;
pub fn extension(self: *const Conn, name: []const u8) ?ext.ExtInfo;
pub fn internAtoms(self: *Conn, comptime names: []const []const u8) Error!AtomTable(names);
pub fn screen(self: *const Conn) *const setup.Screen;
pub fn pollFd(self: *const Conn) i32;
// auth
pub fn parseDisplay(s: []const u8) error{InvalidDisplay}!Display;
pub fn readXauthority(gpa: Allocator, io: std.Io, path: []const u8, display: u32, hostname: []const u8, out_bytes: *?[]u8) !?Cookie;
```
A request type is a struct whose fields are serialized in declaration
order (little-endian, `[]const u8` padded to 4, `ValueList(T)` as mask plus
values); a field named `data` goes in header byte 1. It declares `opcode`,
or `extension` and `minor`, and a `Reply` with
`decode(bytes, *FdQueue) !Reply` when it has one. The spec's
`readXauthority(io, path, display, hostname)` gained `gpa` and `out_bytes`
because the cookie views the file contents.

### Threading
The platform thread owns reading (`reply`, `pollEvent`, `waitEvent`,
`checked`, `sync`). `request`, `flush` and `newXid` lock, so a render
thread may send.

### Ownership/lifetime
Reply and event bytes (and views decoded from them) are valid until the
next `reply` or `pollEvent`/`waitEvent` respectively. `request` duplicates
the fds it is given. Fds the server sends with replies wait in `in_fds`
for the caller to pop. Errors for requests nobody waits on are logged at
debug, counted in `async_errors` and kept in `last_error`. Steady state
allocates nothing per request, reply or event.

### Stability
Experimental until the E01 PR merges. Remote (TCP) displays and the
XC-MISC id range fallback are not implemented (P2).

## zg_platform.win32 (bindings, com, wide)

### Defined in
`packages/platform/src/win32/bindings/{types,user32,kernel32,gdi32,imm32,ole32,shell32,dwmapi,advapi32}.zig`,
`packages/platform/src/win32/com.zig` and `packages/platform/src/win32/wide.zig`
(E01.F02.S01.T01).

### Implemented by
E01.F02.S01.T01.

### Consumed by
The Win32 backend (E01.F02.S01.T02 onward), file dialogs and theme
(E01.F07.S01.T03), and E06's foreground-process lookup (Toolhelp).

### Signature
```zig
// bindings: `pub extern "user32" fn CreateWindowExW(...) callconv(.winapi) ?HWND;` etc.
// types: extern structs with sizes asserted for 64-bit Windows (MSG 48, WNDCLASSEXW 80, POINTER_INFO 96, ...)
pub fn guid(comptime s: []const u8) GUID;                          // "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
pub fn parseGuid(s: []const u8) error{InvalidGuid}!GUID;
pub fn ComObject(comptime Vtbl: type, comptime Impl: type) type;   // create(gpa, impl), iface(), fromIface(p)
// interfaces: IUnknown, IDropTarget, IDropSource, IDataObject, IEnumFORMATETC,
//             IShellItem, IShellItemArray, IFileDialog, IFileOpenDialog (each with Vtbl and Vtbl.iid)
pub const L = std.unicode.utf8ToUtf16LeStringLiteral;
pub fn toWide(buf: []u16, s: []const u8) ![:0]u16;
pub fn toWideAlloc(gpa: Allocator, s: []const u8) ![:0]u16;
pub fn fromWide(buf: []u8, w: []const u16) ![]u8;
pub fn fromWideAlloc(gpa: Allocator, w: []const u16) ![]u8;
```
`Impl` provides each vtable method after IUnknown's by name with `*Impl`
in place of `this`, plus optional `deinit(*Impl)` and
`extra_iids: [_]GUID`. Interface pointers from the OS are `*IFoo`; call
`p.vtbl.Method(p, ...)`.

### Threading
COM objects follow the apartment of the thread that made them (the
platform thread's STA after `OleInitialize`). Refcounts are atomic.

### Ownership/lifetime
A `ComObject` starts with one reference owned by its creator. The last
`Release` calls `Impl.deinit` and frees it with the allocator given to
`create`.

### Stability
Experimental until the E01 PR merges. The DLL bindings exist only on
Windows targets (`zg_platform.win32.user32` is an empty struct
elsewhere); `types`, `com` and `wide` build everywhere; callbacks and COM methods
use `types.winapi`, which is `.winapi` on Windows and `.c` elsewhere
(LLVM has no Windows ARM64 convention on aarch64-linux). Zig links the
import libraries from `extern "dll"` itself, so `build.zig` needs no
`linkSystemLibrary` calls.

## zg_platform.wayland.WaylandBackend

### Defined in
`packages/platform/src/wayland/backend.zig`, with `window.zig`
(configure, state and scale bookkeeping), `output.zig` (`wl_output` to
`MonitorInfo`), `scale.zig` (1/120 scale arithmetic) and `shm.zig` (the
interim CPU presenter); the weston launcher for integration tests is
`wayland/testing/weston.zig` (E01.F04.S01.T01).

### Implemented by
E01.F04.S01.T01.

### Consumed by
`zg_platform.init` on Wayland sessions; E02 presents through the
window's `Presenter`; E04 reads `window_configure` state and
`WmCapabilities`. Input, cursors, data device, IME and decorations
(E01.F04.S01.T02, E01.F04.S02, E01.F04.S03) extend this backend.

### Signature
```zig
pub const InitOptions = struct {
    environ_map: ?*std.process.Environ.Map = null, // WAYLAND_SOCKET / WAYLAND_DISPLAY / XDG_RUNTIME_DIR
    fd: ?i32 = null,                                // a connected socket (tests)
    ack_timeout_ns: u64 = 100 * std.time.ns_per_ms, // bufferless ack when no present arrives
    default_refresh_ns: u32 = 16_666_667,
};
pub fn init(gpa: Allocator, io: std.Io, opts: InitOptions) !*WaylandBackend; // error.MissingGlobal without compositor, xdg_wm_base or shm
pub fn platform(b: *WaylandBackend) Platform;
// window.zig
pub const WmCapabilities = packed struct(u8) { window_menu, maximize, fullscreen, minimize };
// scale.zig
pub fn bufferSize(logical: PxSize, scale120: u32) PxSize;          // round half away from zero
// registry.zig (added)
pub fn onGlobalAdd(r: *Registry, cb: ?AddCallback) void;
```
`window_configure.size` is the buffer size in pixels; pass its `serial`
back in the present's `ConfigureAck`. The present acks that serial and
then attaches and commits in the same flush. With a viewport the buffer
is `round(logical * n / 120)` and the destination is the logical size,
with buffer scale 1; without one the scale rounds up to an integer
buffer scale. `suspended` also sends `window_occluded`.

### Threading
A platform thread reads, dispatches, answers `xdg_wm_base.ping` at once
and acks overdue configures. `createWindow`, `submit` and `present` send
on the calling thread (the connection locks); one backend mutex guards
windows and outputs and is never held while pushing to the event ring.

### Ownership/lifetime
A window's presenter and its buffers die with `destroyWindow`.
`deinit` stops the thread, destroys the windows and closes the
connection.

### Stability
Experimental until the E01 PR merges. dmabuf import and implicit sync
are described under the presenter contract above. With wp_presentation
every present asks for feedback (`InitOptions.presentation_feedback`),
reported as `Event.present_feedback` in the `Io.Clock.awake` timebase;
a discarded frame has `flags = PresentFlags.discarded` and
`presented_ns = 0`. Until the data device lands,
`clipboard_read` answers only from our own `clipboard_write`. Move,
resize, window menu, drag, activation, dialogs and URIs return
`error.Unsupported`.

## zg_platform.x11.X11Backend

### Defined in
`packages/platform/src/x11/backend.zig`, with `present.zig` (the CPU
presenter: MIT-SHM `AttachFd` memfds or core `PutImage`), `keymap.zig`
(core keycode → keysym table) and `dpi.zig` (`ZG_SCALE`, `Xft.dpi`);
requests and event codes are in `proto.zig` (E01.F05.S02.T01, first
part, and the SHM/PutImage half of E01.F05.S03.T02).

### Implemented by
E01.F05.S02.T01 / E01.F05.S03.T02.

### Consumed by
`zg_platform.init` on X11 sessions (and as the fallback from an
unreachable Wayland display); E02's software renderer through
`surfaceTarget` → `.external` presenter.

### Signature
```zig
pub const InitOptions = struct {
    environ_map: ?*const std.process.Environ.Map = null, // DISPLAY, XAUTHORITY, ZG_SCALE, ZG_X11_PRESENT=putimage
    display: ?[]const u8 = null,
    present: ?present.Path = null,                        // .shm or .put_image; null picks MIT-SHM 1.2 when present
    refresh_ns: u32 = 16_666_667,                         // frame timer while frames are requested
};
pub fn init(gpa: Allocator, io: std.Io, opts: InitOptions) !*X11Backend;
pub fn platform(b: *X11Backend) Platform;
pub fn xidOf(b: *X11Backend, win: WindowId) ?u32; // tests
pub const XvfbForTest = struct { pub fn start(seed: u32) !XvfbForTest; pub fn display(*const XvfbForTest) []const u8; pub fn stop(*XvfbForTest) void };
```
Windows map at creation and get `WM_DELETE_WINDOW`, `WM_CLASS =
zigguro/Zigguro`, `_NET_WM_NAME`, `_NET_WM_PID`, `_NET_WM_WINDOW_TYPE_NORMAL`
and `WM_NORMAL_HINTS` (min size). `request_state` sends `_NET_WM_STATE`,
`_NET_ACTIVE_WINDOW` and `WM_CHANGE_STATE` client messages. The first
`window_configure` (serial 0) is staged by `createWindow`. Wheel buttons
4–7 become `scroll` in lines.

### Threading
No platform thread: the UI thread reads and translates X events in
`pollEvents` and `waitEvents`. `submit`, `wake` and presenter calls may
come from any thread (the connection's request queue locks).

### Ownership/lifetime
A window's presenter and its buffers die with `destroyWindow`; `deinit`
destroys every window and closes the connection.

### Stability
Experimental. Not yet: XInput2 and XKB keymaps (E01.F05.S02.T02; keys
use the core mapping, and auto-repeat arrives as release/press pairs),
RandR monitors (one monitor for the screen), `_NET_WM_SYNC_REQUEST`,
`_NET_WM_PING`, cursors, selections (`clipboard_read` answers only from
our own `clipboard_write`), DRI3/Present and XDND. Move, resize, window
menu, drag, activation, dialogs and URIs return `error.Unsupported`.

## zg_platform.win32.Win32Backend

### Defined in
`packages/platform/src/win32/backend.zig`, with `cpu_present.zig` (the
DIB-section presenter), `keys.zig` (set-1 scancode → `Key`, virtual key
→ keysym, modifiers), `dpi.zig` (PMv2 arithmetic) and `msgs.zig`
(message and style constants) (E01.F02.S01.T02 and E01.F02.S05.T01,
first parts; input basics of E01.F02.S02.T01).

### Implemented by
E01.F02.S01.T02 / E01.F02.S05.T01.

### Consumed by
`zg_platform.init` on Windows; E02 through `surfaceTarget` (`.win32`) or,
for the software renderer, `cpuPresenter`; E04 through `zg_gui.Host`.

### Signature
```zig
pub const InitOptions = struct { refresh_ns: u32 = 16_666_667 };
pub fn init(gpa: Allocator, io: std.Io, opts: InitOptions) !*Win32Backend; // spawns the platform thread, waits for its message window
pub fn platform(b: *Win32Backend) Platform;
// cpu_present.zig
// PresenterVTable: allocCpuBuffer → top-down 32 bpp DIB (ARGB8888); present → BitBlt of the damage (> 16 rects: their union)
```
`WindowOptions.size` is the client size in physical pixels. The first
`window_configure` comes from `createWindow`; later ones from `WM_SIZE`
and `WM_DPICHANGED` (scale = DPI / 96). `KeyEvent.text` carries the
key's `WM_CHAR` text (taken from the queue with the key-down); Control
chords carry none. Wheel notches are `scroll` lines with forward
negative.

### Threading
Windows belong to the platform thread. The window procedure stages
events under the backend mutex and signals the UI `Wake`. `present`
blits on the calling thread; `WM_PAINT` replays the newest buffer on the
platform thread (one presenter mutex covers both).

### Ownership/lifetime
A window's presenter and its DIB sections die with `destroyWindow`;
`deinit` stops the thread after it destroys every window.

### Stability
Experimental. Not yet: custom frame and hit-testing (E01.F02.S01.T03),
raw input, pen and touch, IME, the Win32 clipboard (`clipboard_read`
answers only from our own `clipboard_write`), OLE drag and drop, the
modal size-move timer, cursors, DWM refresh timing (the frame timer
assumes 60 Hz) and monitor DPI (monitors report scale 1).

## zg_config.store.SettingsStore and Snapshot

### Defined in
`packages/config/src/store.zig`, `packages/config/src/schema.zig`,
`packages/config/src/layer.zig` (E15.F01.S01, E15.F01.S02). Semantics in
`packages/config/docs/settings-model.md`.

### Implemented by
E15.F01.S01.T01 (schema), E15.F01.S02.T01 (layers and store).

### Consumed by
Every package that has settings (each declares a `settings_schema.zon`):
E04 (theme, fonts), E05 (editor), E06 (terminal), E07 (LSP/DAP server
configuration), E10 (`ai.*`), E11 (`mcp.*`), E16 (trust), the keymap
resolver (`keyboard.*`).

### Signature
```zig
// Each package: packages/<pkg>/src/settings_schema.zon, aggregated at comptime.
pub const SchemaRegistry = struct {
    pub fn comptimeInit(comptime schemas: anytype) SchemaRegistry;
    pub fn lookup(r: *const SchemaRegistry, key: []const u8) ?SettingId;
    pub fn def(r: *const SchemaRegistry, id: SettingId) *const SettingDef;
    pub fn default(r: *const SchemaRegistry, id: SettingId) Value;
};
pub const SettingsStore = struct {
    pub fn init(gpa: Allocator, io: std.Io, reg: *const SchemaRegistry, opts: InitOptions) !*SettingsStore;
    pub fn deinit(s: *SettingsStore) void;
    pub fn current(s: *const SettingsStore) *const Snapshot;          // UI thread
    pub fn acquire(s: *SettingsStore) *const Snapshot;                // other threads
    pub fn release(s: *SettingsStore, snap: *const Snapshot) void;
    pub fn setLayerSource(s: *SettingsStore, src: LayerSource) !usize; // returns error-diag count
    pub fn removeLayer(s: *SettingsStore, kind: LayerKind, folder: ?FolderId) !void;
    pub fn setTrust(s: *SettingsStore, t: TrustPort) !void;
    pub fn publish(s: *SettingsStore) !?Change;                       // UI thread, frame start
    pub fn subscribe(s: *SettingsStore, prefix: []const u8, cb: ChangeCallback, ctx: ?*anyopaque) !SubscriptionId;
    pub fn unsubscribe(s: *SettingsStore, id: SubscriptionId) void;
};
pub const Snapshot = struct {
    pub fn resolve(s: *const Snapshot, id: SettingId, rs: ResourceScope) Value;
    pub fn getByKey(s: *const Snapshot, key: []const u8, rs: ResourceScope) ?Value;
    pub fn inspect(s: *const Snapshot, id: SettingId, rs: ResourceScope) Inspection;
    pub fn section(s: *const Snapshot, arena: Allocator, prefix: []const u8, rs: ResourceScope) !Value;
};
pub const ResourceScope = struct { folder: ?FolderId = null, path: ?[]const u8 = null, lang: ?[]const u8 = null };
// Typed, comptime-checked access:
const S = zg_config.store.Settings(@import("settings_schema.zon"));
var tab_size = S.handle(i64, "editor.tabSize"); // then tab_size.bind(&reg); tab_size.get(snap)
pub const ui_msg_kind: u32 = 0x1500_0001;   // posted when a snapshot is pending
```

### Threading
Layer updates run on any thread (the config worker) and park a pending
snapshot, then post `ui_msg_kind`. `publish` and subscriber callbacks run on
the UI thread. Snapshots are immutable: the UI thread reads `current()`
directly; other threads pin with `acquire`/`release`.

### Ownership/lifetime
The store owns snapshots and layers. `LayerSource.doc` is borrowed only
during `setLayerSource` (values are copied). Values returned by a snapshot
live as long as the snapshot (until the next `publish` on the UI thread, or
until `release` elsewhere). `Change.ids` is valid during the callback.

### Stability
Experimental until the E15 PR (#1208) merges.

## zg_config.commands.CommandRegistry

### Defined in
`packages/config/src/commands/registry.zig` (E15.F03.S01.T01). Guide in
`packages/config/docs/commands.md`.

### Implemented by
E15.F03.S01.T01.

### Consumed by
E04 (keybinding dispatch: `CommandId` == `ActionId`; menus, palette), E05,
E06, E09, E12, E13 register commands; E10 exposes commands as agent tools
(filtered by `agent` and `effects`); E15.F06 registers extension commands
lazily; the `zg` CLI runs commands headless.

### Signature
```zig
pub const CommandId = enum(u32) { none = 0, _ };
pub const Command = struct {
    id: []const u8, title: []const u8, category: ?[]const u8 = null, description: []const u8 = "",
    keywords: []const []const u8 = &.{}, icon: ?[]const u8 = null,
    args: ?*const SettingDef = null,          // args schema; null = no args
    enablement: ?[]const u8 = null,           // when-clause
    palette: enum { visible, hidden } = .visible, palette_when: ?[]const u8 = null,
    agent: enum { never, ask, allow } = .ask, effects: Effects = .{},
    repeat: bool = true,                      // key auto-repeat re-runs it
    source: Source = .{ .builtin = "" }, handler: ?Handler = null,
};
pub const Handler = struct { ctx: ?*anyopaque, run: *const fn (ctx: ?*anyopaque, inv: *Invocation) anyerror!void };
pub const CommandRegistry = struct {
    pub fn init(gpa: Allocator, keys: *ContextKeyService, opts: InitOptions) !*CommandRegistry;
    pub fn register(r: *CommandRegistry, c: Command) RegisterError!CommandId;
    pub fn registerLazy(r: *CommandRegistry, c: Command, activate: Activator) RegisterError!CommandId;
    pub fn setHandler(r: *CommandRegistry, id: CommandId, h: Handler) void;
    pub fn unregisterSource(r: *CommandRegistry, s: Source) void;
    pub fn lookup(r: *const CommandRegistry, id: []const u8) ?CommandId;
    pub fn get(r: *const CommandRegistry, id: CommandId) *const Command;
    pub fn isEnabled(r: *const CommandRegistry, id: CommandId, e: *const EvalEnv) bool;
    pub fn execute(r: *CommandRegistry, id: CommandId, args: ?Value, origin: Origin) ExecuteError!void;
    pub fn executeForResult(r: *CommandRegistry, arena: Allocator, id: CommandId, args: ?Value, origin: Origin) ExecuteError!Result;
    pub fn executeJson(r: *CommandRegistry, arena: Allocator, id: CommandId, json: ?[]const u8, origin: Origin) ExecuteError!Result; // E10 tool calls
    pub fn executeArgText(r: *CommandRegistry, id: CommandId, arg_text: ?[]const u8, origin: Origin) ExecuteError!void; // E04 dispatchAction
    pub fn post(r: *CommandRegistry, id: CommandId, args: ?Value, origin: Origin, done: ?Completion) void; // any thread
    pub fn drainPosted(r: *CommandRegistry) void;                      // UI thread, on ui_msg_kind
};
pub const ui_msg_kind: u32 = 0x1500_0002;
```

### Threading
`execute*` and `drainPosted` run on the UI thread. `post` is safe from any
thread. Registration is allowed from any thread until `freeze`, then only on
the UI thread.

### Ownership/lifetime
The registry copies command metadata. Handler `ctx` is borrowed and must
outlive the registration (`unregisterSource` removes it). `Result` strings
live in the caller's arena. Interned keymap args stay valid until the
keymap that interned them is freed.

### Stability
Experimental until the E15 PR (#1208) merges.

## zg_config.context and when-clauses

### Defined in
`packages/config/src/when/context.zig`, `packages/config/src/when/when.zig`,
`packages/config/src/when/dnf.zig` (E15.F03.S01.T02). Key list in
`packages/config/docs/context-keys.md`.

### Implemented by
E15.F03.S01.T02.

### Consumed by
E04 (focus contexts form the `KeyContext` stack), every package that owns
a context key (E05 `editorTextFocus`, E06 `terminalFocus`, E10
`agentFocus`, E13 `reviewFocus`, ...), the keymap resolver, menus and the
palette.

### Signature
```zig
pub const CtxValue = union(enum) { undef, bool: bool, num: f64, str: []const u8, list: []const []const u8 };
pub const KeyContext = struct { name: []const u8, attrs: []const Attr = &.{} }; // mirrors E04 KeyContext
pub const EvalEnv = struct { global: *const ContextKeyService, stack: []const KeyContext = &.{}, settings: ?*const Snapshot = null };
pub const ContextKeyService = struct {
    pub fn init(gpa: Allocator) ContextKeyService;
    pub fn key(s: *ContextKeyService, name: []const u8) !KeyId;
    pub fn set(s: *ContextKeyService, k: KeyId, v: CtxValue) !void;
    pub fn get(s: *const ContextKeyService, k: KeyId) CtxValue;
    pub fn generation(s: *const ContextKeyService) u64;
};
pub const When = struct {
    pub fn compile(gpa: Allocator, src: []const u8, keys: ?*ContextKeyService, diags: *Diags) error{ OutOfMemory, InvalidWhen }!When;
    pub fn eval(w: *const When, env: *const EvalEnv) bool;   // no allocation
    pub fn deinit(w: *When) void;
};
```

### Threading
UI thread only. `ContextKeyService.set` bumps `generation` on every
effective change so label caches can invalidate.

### Ownership/lifetime
`set` copies string values. A compiled `When` owns its bytecode; `EvalEnv`
borrows everything it points to for the duration of `eval`.

### Stability
Experimental until the E15 PR (#1208) merges. The when-clause grammar is
VS Code compatible and stable.

## zg_config.keymap Resolver

### Defined in
`packages/config/src/keymap/{keys.zig, keyspec.zig, keymap.zig, resolver.zig}`
(E15.F04.S01). Format and semantics in `packages/config/docs/keybindings.md`.

### Implemented by
E15.F04.S01.T01 (keys and specs), E15.F04.S01.T02 (keymap and resolver).
The E04 `KeymapResolver` adapter lands with E04.

### Consumed by
E04 (key routing: `resolve`, `onTimer` from the frame deadline), menus,
the palette and E10/E12 hint text (`labelFor`), the which-key popup
(`continuations`), E05 Vim/Emacs mode layers.

### Signature
```zig
pub const LayerKind = enum(u8) { builtin_default, preset, mode_layer, extension, user };
pub const LayerInput = struct { layer: LayerKind, source_path: ?[]const u8 = null, doc: *const zon_load.Doc, owner: ?[]const u8 = null };
pub const Keymap = struct {
    pub fn build(gpa: Allocator, layers: []const LayerInput, reg: *CommandRegistry, ctx: *ContextKeyService, plat: Platform, diags: *Diags) !*Keymap;
    pub fn deinit(km: *Keymap) void;
};
pub const Resolution = union(enum) {
    none,                                              // pass the key to the focused widget
    pending: []const u8,                               // chord label so far
    action: struct { id: CommandId, arg: ?[]const u8 },// arg: canonical ZON, interned
    swallow: []const u8,                               // consume; status message (E04 adapter: noop)
};
pub const Resolver = struct {
    pub fn init(gpa: Allocator, ctx: *ContextKeyService, layout: *const LayoutInfo, opts: Options) !*Resolver;
    pub fn reload(r: *Resolver, km: *Keymap) void;
    pub fn setOptions(r: *Resolver, opts: Options) void;   // Options.fromSettings(snapshot, platform)
    pub fn setSettings(r: *Resolver, snap: ?*const Snapshot) void;
    pub fn resolve(r: *Resolver, stack: []const KeyContext, ev: KeyInput) Resolution;
    pub fn takeDeferred(r: *Resolver) ?Resolution;          // key re-processed after an early chord fire
    pub fn deadline(r: *const Resolver) ?u64;               // when to call onTimer (monotonic ns)
    pub fn onTimer(r: *Resolver, now_ns: u64) ?Resolution;
    pub fn pendingLabel(r: *const Resolver) ?[]const u8;
    pub fn continuations(r: *const Resolver, arena: Allocator, stack: []const KeyContext, out: *std.ArrayList(Continuation)) !void;
    pub fn labelFor(r: *Resolver, id: CommandId, stack: ?[]const KeyContext) ?[]const u8;
};
// keys.KeyInput mirrors E01 KeyEvent (HID usage, mods, press/repeat/release, codepoint, t_ns)
```

### Threading
UI thread only. `resolve` does not allocate on the key path.

### Ownership/lifetime
The caller owns both the old and new `Keymap` across `reload` and frees the
old one afterwards. `pending` and `swallow` payloads are valid until the
next resolver call; `labelFor` with `stack == null` returns a cached label
valid until the keymap, layout or context generation changes.

### Stability
Experimental until the E15 PR (#1208) merges. `KeyInput` and `KeyContext`
are local mirrors of E01/E04 types and become aliases once those merge.

## ZEP and zg_ext_sdk

### Defined in
`packages/config/src/zep/{protocol.zig, client.zig}` (E15.F06.S02.T01),
published alone as the `zg_ext_sdk` module of `packages/config/build.zig`
and inside zg_config as `zg_config.zep`. Normative spec in
`packages/config/docs/zep.md`.

### Implemented by
E15.F06.S02.T01 (types and SDK). The host side (process supervision,
routing) is E15.F06.S02.T02.

### Consumed by
Extension authors (Zig SDK; any language via the wire protocol), the
extension host in zg_config, E10/E11 for `ai/sample` and the MCP split.

### Signature
```zig
pub const protocol_version = "2026-10";
pub const ErrorCode = enum(i32) { parse_error = -32700, invalid_request = -32600, method_not_found = -32601,
    invalid_params = -32602, internal = -32603, permission_denied = -32001, request_timeout = -32002,
    not_activated = -32003, content_modified = -32801, request_cancelled = -32800, _ };
pub const InitializeParams = struct { protocolVersion, host, extension, workspaceFolders, locale,
    positionEncoding, capabilities: HostCapabilities, grantedPermissions: Permissions };
pub const Extension = struct {
    pub fn init(rt: *zg_core.Runtime, reader: *Io.Reader, writer: *Io.Writer, opts: Options) !*Extension;
    pub fn initStdio(rt: *zg_core.Runtime, opts: Options) !*Extension;
    pub fn onCommand(e: *Extension, id: []const u8, h: CommandFn) !void;
    pub fn onNotification(e: *Extension, method: []const u8, h: NotificationFn) !void;
    pub fn run(e: *Extension) !void;   // until `exit` or the host closes stdin
    pub fn showMessage(e: *Extension, arena: Allocator, sev: Severity, msg: []const u8, actions: []const []const u8) !?[]const u8;
    pub fn applyEdit(e: *Extension, arena: Allocator, label: []const u8, edits: []const FileEdit) !ApplyEditResult;
    pub fn executeCommand(e: *Extension, arena: Allocator, id: []const u8, args: ?std.json.Value) !std.json.Value;
    pub fn deinit(e: *Extension) void;
};
pub const CommandFn = *const fn (e: *Extension, args: ?std.json.Value, arena: Allocator) anyerror!?std.json.Value;
```

### Threading
The endpoint runs reader, writer and timer loops. Each `command/execute`
runs its handler on its own unit of concurrency, so handlers may call the
blocking host methods. Notification handlers run on the reader loop and
must be quick.

### Ownership/lifetime
Handler args and results live in the request arena until the reply is sent.
Host method results are allocated in the caller's arena.

### Stability
Experimental until the E15 PR (#1208) merges; the wire protocol is
versioned by `protocolVersion` and the host keeps the previous version.

## zg_regex.Regex

### Defined in
`packages/regex/src/root.zig`, `packages/regex/src/input.zig` (E05.F03).

### Implemented by
E05.F03.S01.T01 – E05.F03.S03.T01.

### Consumed by
E05.F04 (TextMate-style grammars), E05.F06 (find and replace), E07 (LSP
patterns), E08 (workspace search, globs), E11 (JSON Schema `pattern`), E15
(settings validation).

### Signature
```zig
pub const Options = struct {
    case_insensitive: bool = false, multi_line: bool = false, dot_all: bool = false,
    crlf: bool = false, swap_greed: bool = false, unicode: bool = true,
    ignore_whitespace: bool = false,
    literal: bool = false,      // escape the whole pattern
    whole_word: bool = false,   // wrap in \b{start-half} ... \b{end-half}
    size_limit: usize = 10 << 20,
    dfa_cache_bytes: usize = 2 << 20,
    nest_limit: u32 = 250,
    diag: ?*Error = null,       // filled on error.Syntax
};
pub const CompileError = error{ Syntax, SizeLimitExceeded } || Allocator.Error;
pub const Match = struct { start: u64, end: u64 };
pub const Range = struct { start: u64, end: u64 };
pub const Chunk = struct { base: u64, bytes: []const u8 };
pub const ChunkSource = struct {
    ctx: *const anyopaque,
    chunkAtFn: *const fn (ctx: *const anyopaque, offset: u64) Chunk, // non-empty chunks tiling the haystack
};
pub const Input = struct {
    source: union(enum) { slice: []const u8, chunks: ChunkSource },
    total_len: u64,
    span: Range,            // matches lie inside; context outside it is still read for assertions
    anchored: bool = false,
    earliest: bool = false,
    pub fn fromSlice(s: []const u8) Input;
    pub fn fromChunks(src: ChunkSource, total_len: u64) Input;
    pub fn withSpan(in: Input, span: Range) Input;
    pub fn withAnchored(in: Input, anchored: bool) Input;
};
pub const Regex = struct {
    pub fn compile(gpa: Allocator, pattern: []const u8, o: Options) CompileError!Regex;
    pub fn deinit(re: *Regex, gpa: Allocator) void;
    pub fn newCache(re: *const Regex, gpa: Allocator) Allocator.Error!Cache;
    pub fn newCaptures(re: *const Regex, gpa: Allocator) Allocator.Error!Captures;
    pub fn isMatch(re: *const Regex, cache: *Cache, input: Input) bool;
    pub fn find(re: *const Regex, cache: *Cache, input: Input) ?Match;
    pub fn captures(re: *const Regex, cache: *Cache, input: Input, out: *Captures) bool;
    pub fn findIter(re: *const Regex, cache: *Cache, input: Input) FindIter; // next() ?Match
    pub fn captureNames(re: *const Regex) []const ?[]const u8;
    pub fn groupCount(re: *const Regex) usize;
};
pub const Captures = struct { pub fn len(c) usize; pub fn get(c, i: usize) ?Match; pub fn deinit(c, gpa) void };
pub const RegexSet = struct {
    pub fn compile(gpa: Allocator, patterns: []const []const u8, o: Options) CompileError!RegexSet;
    pub fn newCache(set: *const RegexSet, gpa: Allocator) Allocator.Error!SetCache;
    pub fn matches(set: *const RegexSet, cache: *SetCache, input: Input, out: *std.DynamicBitSetUnmanaged) void;
};
pub fn escape(out: *std.ArrayList(u8), gpa: Allocator, literal: []const u8) Allocator.Error!void;
pub fn smartCaseInsensitive(pattern: []const u8) bool;
pub fn errorMessage(e: Error) []const u8;
pub const simd = struct {
    pub fn memchr(hay: []const u8, b: u8, from: usize) ?usize;
    pub fn memrchr(hay: []const u8, b: u8, to: usize) ?usize;
    pub const Memmem = struct { pub fn init(needle: []const u8) Memmem; pub fn find(f: *const Memmem, hay: []const u8, from: usize) ?usize };
};
```

### Threading
A compiled `Regex` or `RegexSet` is immutable and may be shared across
threads. A `Cache` is per thread (or per concurrent search); searches never
allocate after the cache is created except when the lazy DFA builds states,
which stays within `dfa_cache_bytes`.

### Ownership/lifetime
The caller owns the `Regex`, each `Cache` and each `Captures`, and frees them
with the allocator passed to `compile` / `newCache` / `newCaptures`. A
`ChunkSource` must stay valid and unchanged for the duration of one search
call; chunk slices are only read during that call. Offsets are absolute byte
offsets into the haystack.

### Stability
Experimental until the E05.F03 pull request merges. Semantics follow Rust
`regex` (Unicode by default, leftmost-first, no backreferences or
look-around); see `docs/regex.md`.

## zg_editor.model (PieceTree, ChangeSet, Document, Snapshot)

### Defined in
`packages/editor/src/model/buffer/piece_tree.zig`,
`packages/editor/src/model/edit/change_set.zig`,
`packages/editor/src/model/document.zig`, `packages/editor/src/model/snapshot.zig`,
`packages/editor/src/model/change_log.zig`, `packages/editor/src/model/edit/anchor.zig`
(E05.F01, E05.F02).

### Implemented by
E05.F01.S01.T01, E05.F01.S03.T01, E05.F02.S01.T01.

### Consumed by
E05.F04–F08 (syntax, views, find, diff, registry), E07 (position conversion,
document sync via `toLspChanges`), E12 (ChangeSet, Document).

### Signature
```zig
pub const Range = struct { start: u64, end: u64 };
pub const Point = struct { line: u64, col: u32 };       // col in bytes
pub const PointUtf16 = struct { line: u64, col: u32 };  // col in UTF-16 units
pub const Edit = struct { range: Range, text: []const u8 };
pub const EditError = error{ OutOfMemory, BufferFull, OutOfBounds, Overlap };
pub const PieceTree = struct {   // persistent; every edit returns a new version
    pub fn fromOriginal(pool: *NodePool, bt: *BufferTable) Allocator.Error!PieceTree;
    pub fn clone(t) PieceTree;                       // O(1)
    pub fn deinit(t: *PieceTree, pool: *NodePool) void;
    pub fn len(t) u64; pub fn lineCount(t) u64;
    pub fn insert(t, pool, at: u64, text) EditError!PieceTree;
    pub fn delete(t, pool, range: Range) EditError!PieceTree;
    pub fn replace(t, pool, edits: []const Edit) EditError!PieceTree; // sorted, disjoint, old coords
    pub fn lineOf(t, off) u64; pub fn lineStart(t, line) u64;
    pub fn lineRange(t, line) struct { start: u64, end: u64, eol_len: u2 };
    pub fn offsetToPoint(t, off) Point; pub fn pointToOffset(t, p: Point) u64;
    pub fn offsetToUtf16(t, off) PointUtf16; pub fn utf16ToOffset(t, p: PointUtf16) u64;
    pub fn slice(t, range) ChunkIterator; pub fn chunks(t, from) ChunkIterator;
    pub fn chunksRev(t, from) RevChunkIterator;
    pub fn copyRange(t, gpa, range) Allocator.Error![]u8;
};
pub const Bias = enum { left, right };
pub const MapMode = enum { expand, shrink, delete_if_touched };
pub const ChangeSet = struct {   // sorted replacements in old coordinates
    pub fn identity(gpa, base_len: u64) ChangeSet;
    pub fn fromEdits(gpa, base_len: u64, edits: []const Edit) error{ Overlap, OutOfBounds, OutOfMemory }!ChangeSet;
    pub fn deinit(cs) void; pub fn clone(cs, gpa) !ChangeSet;
    pub fn newLen(cs) u64; pub fn isIdentity(cs) bool;
    pub fn apply(cs, t: PieceTree, pool) EditError!PieceTree;
    pub fn applyToSlice(cs, gpa, text) ![]u8;
    pub fn invert(cs, before: PieceTree, gpa) !ChangeSet;
    pub fn compose(a, b, gpa) !ChangeSet;                    // a then b
    pub fn transform(a, b, a_wins_ties: bool, gpa) !ChangeSet; // a' such that b·a' == a·b' (TP1); sets .conflicted
    pub fn mapPos(cs, pos, bias) u64;
    pub fn mapPosDetail(cs, pos, bias) struct { pos: u64, deleted: bool };
    pub fn mapRange(cs, r: Range, mode: MapMode) ?Range;
    pub fn toLspChanges(cs, before: PieceTree, enc: zg_core.utf8.Encoding, out: *ArrayList(LspChange), gpa) !void; // descending, old coords
};
pub const Snapshot = struct { tree: PieceTree, version: u64, doc_id: DocId, store: *Store,
    pub fn retain(s) Snapshot; pub fn release(s: *Snapshot) void; pub fn len(s) u64 };
pub const Document = struct {
    pub fn initBytes(gpa, id: DocId, bytes) !*Document; pub fn deinit(d) void;
    pub fn snapshot(d) Snapshot; pub fn len(d) u64; pub fn isDirty(d) bool;
    pub fn applyChangeSet(d, cs: *const ChangeSet, origin: EditOrigin) !void;
    pub fn mapForward(d, from_version: u64, range: Range, bias: Bias) ?Range; // null: evicted or deleted
    pub fn subscribe(d, l: Listener) !ListenerId; pub fn unsubscribe(d, id) void;
    pub fn endFrame(d) void;                         // frees nodes released on workers
};
pub const Anchor = struct { offset: u64, version: u64, bias: Bias,
    pub fn at(doc, offset, bias) Anchor };
pub fn resolve(doc, a: Anchor) ?u64; pub fn refresh(doc, a: *Anchor) bool;
```

### Threading
A Document and its edits live on the owner (UI) thread. Snapshots are
immutable and may be retained, read and released on any thread; nodes
released off the owner thread are freed at `endFrame`.

### Ownership/lifetime
The Store (node pool and buffer table) is refcounted; snapshots keep it alive
after the Document is deinitialized. ChangeSets own their inserted text.
Line semantics match `zg_core.LineIndex`.

### Stability
Unstable until E05.F05 views and E12 land.

## zg_editor.model.edit.undo (UndoTree)

### Defined in
`packages/editor/src/model/edit/undo.zig`, `packages/editor/src/model/edit/selection.zig`
(E05.F02.S02).

### Implemented by
E05.F02.S02.T01.

### Consumed by
E05.F08 (AgentEditSession), E05.F09 (Vim `u`/`g-`/`:earlier`), E04/E12 (undo-history
panel, "undo agent change"), E12 checkpoints.

### Signature
```zig
pub const Selection = struct { anchor: u64, head: u64, goal_x: ?f32 = null, id: u32 = 0 };
pub const CoalesceKey = enum { typing_word, typing_space, delete_left, delete_right };
pub const GroupMeta = struct { label: []const u8 = "", origin: EditOrigin, timestamp: std.Io.Timestamp, coalesce_key: ?CoalesceKey = null };
pub const NodeId = enum(u32) { root = 0, none = maxInt(u32), _ };
pub const Limits = struct { max_nodes: u32 = 10_000, max_bytes: usize = 64 << 20, group_ms: u32 = 1000 };
pub const Step = struct { changes: *const ChangeSet, selections: []const Selection };
pub const UndoTree = struct {
    pub fn init(gpa, limits: Limits) UndoTree; pub fn deinit(u) void;
    pub fn record(u, forward: ChangeSet, inverse: ChangeSet, sel_before, sel_after, meta: GroupMeta) !void; // takes both ChangeSets
    pub fn breakGroup(u) void;
    pub fn undo(u) ?Step; pub fn redo(u) ?Step; pub fn canUndo(u) bool; pub fn canRedo(u) bool;
    pub fn older(u) !?[]const Step; pub fn newer(u) !?[]const Step;   // g- / g+
    pub fn travel(u, target: NodeId) ![]const Step;                    // via the LCA
    pub fn nodeAtTime(u, t: std.Io.Timestamp) NodeId;
    pub fn changesTo(u, target: NodeId, base_len: u64, gpa) !PathChange; // revert-to-time as one new step
    pub fn markSaved(u, id: NodeId) void; pub fn isAtSaved(u) bool;
    pub fn selectiveUndo(u, id: NodeId, current: Snapshot) !union(enum) { ok: ChangeSet, conflict: ConflictInfo };
    pub fn nodes(u) []const Node; pub fn selectionsAt(u, id) []const Selection;
};
```

### Threading
Owner (UI) thread only, like the Document it belongs to.

### Ownership/lifetime
`record` takes ownership of both ChangeSets. Steps borrow from the tree and
are valid until the next `record`. Pruning compacts the tree, so NodeIds are
invalidated by a `record` that prunes.

### Stability
Unstable until the persistent undo file (E05.F02.S02.T02) lands.

## zg_editor.model.diff

### Defined in
`packages/editor/src/model/diff.zig` and `packages/editor/src/model/diff/*.zig` (E05.F07).

### Implemented by
E05.F07.S01.T01, E05.F07.S01.T02.

### Consumed by
E05.F07.S02 (DiffModel, diff views), E09 (SCM diffs), E12 (review), the `zg` CLI.

### Signature
```zig
pub const Edit = struct { kind: enum { equal, insert, delete }, a_start: u32, b_start: u32, len: u32 };
pub const Algorithm = enum { myers, minimal, patience, histogram };
pub const WsMode = enum { none, trailing, all, amount };
pub const Deadline = struct { io: std.Io, at: std.Io.Timestamp, pub fn after(io, ns: u64) Deadline };
pub const DiffOptions = struct { algorithm: Algorithm = .histogram, ignore_ws: WsMode = .none, context_lines: u32 = 3,
    indent_heuristic: bool = true, intraline: enum { none, word, char } = .word, detect_moves: bool = false,
    timeout_ns: u64 = 200 ms, io: ?std.Io = null };
pub const LineSource = struct { pub fn fromBytes(gpa, text) !LineSource; pub fn fromTree(gpa, t: PieceTree) !LineSource;
    pub fn line(s, i) []const u8; pub fn count(s) usize; pub fn deinit(s, gpa) void };
pub const LineHunk = struct { old: LineSpan, new: LineSpan, intraline: []const DiffRange = &.{}, moved_from: ?u32 = null };
pub const DiffRange = struct { side: enum { old, new }, range: Range, kind: enum { changed, moved } };
pub const DiffResult = struct { edits: []Edit, hunks: []LineHunk, ranges: []DiffRange, moves: []Move, pub fn deinit(r, gpa) void };
pub fn diffLines(gpa, a: *const LineSource, b: *const LineSource, o: DiffOptions) !DiffResult;
pub fn diffTokens(gpa, a: []const u32, b: []const u32, alg: Algorithm, deadline: ?Deadline) ![]Edit;
pub fn unified.writeUnified(w: *std.Io.Writer, edits, hunks, a, b, names: [2][]const u8) !void;
pub fn intraline.intralineEdits(gpa, edits, a, b, mode: enum { word, char }) ![]DiffRange;
pub fn postprocess.slideHunks(edits: []Edit, ids_a, ids_b, a, b) usize;      // returns the new length
pub fn moves.detectMoves(gpa, edits, a, b, o: struct { min_lines = 3, min_chars = 60 }) ![]Move;
```

### Threading
Pure functions; safe on any thread (snapshots go through `LineSource.fromTree`).

### Ownership/lifetime
Results are owned by the caller (`DiffResult.deinit`). `LineSource.fromBytes`
borrows the text; `fromTree` copies it.

### Stability
Unstable until DiffModel (E05.F07.S02.T01) lands. Unified output matches
`git diff` hunk headers; histogram ties prefer the run nearest the middle of
the region (JGit takes the first).

## zg_vulkan.r2d (DrawList, Renderer, Prim)

### Defined in
`packages/vulkan/src/r2d/` (E02.F06.S01.T01). Full contract: [rendering.md](rendering.md).

### Implemented by
`zg_vulkan.sw.SwRenderer` (E02.F07.S01.T01); the Vulkan backend
(E02.F06.S01.T02) and Metal (E02.F08) later. `zg_vulkan.createRenderer`
picks one.

### Consumed by
E04 (builds a `DrawList` per frame and holds a `Renderer`), E03 (atlas
pages through `createTexture`/`updateTexture`, `GlyphQuad`), E06 (cell
backgrounds as `rect`).

### Signature
```zig
pub const DrawList = struct {
    pub fn init(gpa: Allocator) DrawList;
    pub fn reset(self: *DrawList, extent: Size, scale: f32) void;
    pub fn rect(self: *DrawList, r: RectF, fill: Color, radii: Radii) void;
    pub fn border(self: *DrawList, r: RectF, widths: Insets, color: Color, radii: Radii) void;
    pub fn shadow(self: *DrawList, r: RectF, radii: Radii, sigma: f32, spread: f32, color: Color) void;
    pub fn linearGradient(self: *DrawList, r: RectF, p0: Vec2, p1: Vec2, c0: Color, c1: Color, radii: Radii) void;
    pub fn glyphs(self: *DrawList, run: []const GlyphQuad, color: Color, aa: TextAa) void;
    pub fn image(self: *DrawList, tex: TextureId, dst: RectF, uv: RectF, tint: Color, radii: Radii) void;
    pub fn imageFiltered(self: *DrawList, tex: TextureId, dst: RectF, uv: RectF, tint: Color, radii: Radii, filter: Filter) void;
    pub fn pushClip(self: *DrawList, r: RectF, radii: Radii) void;
    pub fn popClip(self: *DrawList) void;
    pub fn beginLayer(self: *DrawList, id: LayerId, size: Size, content_damage: []const PxRect) bool;
    pub fn endLayer(self: *DrawList) void;
    pub fn drawLayer(self: *DrawList, id: LayerId, dst: RectF, scroll_px: Vec2, opacity: f32) void;
    pub fn addDamage(self: *DrawList, r: PxRect) void;
    pub fn damageAll(self: *DrawList) void;
    pub fn setGlyphPages(self: *DrawList, pages: []const TextureId) void;
};
pub const Renderer = struct { // render, resize, createTexture, updateTexture, destroyTexture, destroyLayer, backend, deinit, layerQuery
    pub fn render(r: Renderer, dl: *const DrawList) RenderError!FrameStats;
};
pub fn createRenderer(gpa: Allocator, io: std.Io, opts: RendererOptions) !Renderer;
```
`RectF`, `Vec2`, `Radii`, `Insets` are logical pixels; `PxRect` and `Size`
are physical. `Color` is `packed struct(u32) { r, g, b, a }`, straight
alpha (premultiplied by the list). `GlyphQuad` is
`extern struct { dst: [4]f32, uv: [4]f32, page: u16, format: AtlasFormat }`.
Deviation from the spec text: `createRenderer` lives in the package root, not
in `r2d/Renderer.zig`, so `r2d` never imports a backend; `imageFiltered`,
`damageAll` and `setGlyphPages` are additions.

### Threading
A `DrawList` is built by one thread (UI) and read by the render thread after
hand-off; a `Renderer` is owned by one thread at a time.

### Ownership/lifetime
The list owns its arrays; `reset` keeps capacity. Texture ids are valid
until `destroyTexture`. Slices passed to `setGlyphPages` must outlive the frame.

### Stability
Stable for E04/E03 consumers; additive changes only.

## zg_gui.paint.Canvas

### Defined in
`packages/gui/src/paint/canvas.zig` (E04.F04; decision in ADR 0009).

### Implemented by
`zg_gui.paint.Recorder` (headless, used by `TestApp` snapshots) and
`zg_gui.paint.DrawListCanvas` (`packages/gui/src/paint/draw_list.zig`),
which forwards to E02's `r2d.DrawList`. Glyph runs pass through without
copying (`GlyphQuad` layouts are asserted equal at compile time); damage
is rounded outwards to physical pixels.

### Consumed by
`zg_gui.Window` paint and present. Widgets never call it directly; they
draw through `PaintCx`, which records ops into a per-node cache that the
window replays into the canvas.

### Signature
```zig
pub const GlyphQuad = zg_text.cache.GlyphQuad;
pub const TextAa = enum(u2) { grayscale, subpixel_rgb, subpixel_bgr, none };
pub const TextureId = enum(u32) { none = 0, _ };
pub const Canvas = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        begin: *const fn (*anyopaque, size: Size, scale: f32) void,
        rect: *const fn (*anyopaque, r: Rect, fill: Color, radii: Radii) void,
        border: *const fn (*anyopaque, r: Rect, widths: Insets, color: Color, radii: Radii) void,
        shadow: *const fn (*anyopaque, r: Rect, radii: Radii, sigma: f32, spread: f32, color: Color) void,
        linearGradient: *const fn (*anyopaque, r: Rect, p0: Vec2, p1: Vec2, c0: Color, c1: Color, radii: Radii) void,
        glyphs: *const fn (*anyopaque, run: []const GlyphQuad, color: Color, aa: TextAa) void,
        image: *const fn (*anyopaque, tex: TextureId, dst: Rect, uv: Rect, tint: Color, radii: Radii) void,
        pushClip: *const fn (*anyopaque, r: Rect, radii: Radii) void,
        popClip: *const fn (*anyopaque) void,
        addDamage: *const fn (*anyopaque, r: Rect) void,
        end: *const fn (*anyopaque) void,
    };
};
```
Coordinates are logical pixels; `begin` passes the scale. Method names and
argument order match `r2d.DrawList` one for one, so the adapter is a
forwarding table.

### Threading
UI thread only. A frame is `begin`, draw calls, `addDamage` (zero or more),
`end`; nothing is retained by the canvas past `end` except what it copied.

### Ownership/lifetime
Slices passed to `glyphs` are valid only for the call.

### Stability
Experimental: E02 additions (`imageFiltered`, layers, `damageAll`) are not
yet exposed through `Canvas`.

## zg_gui.paint.TextSystem

### Defined in
`packages/gui/src/paint/text.zig` (E04.F05).

### Implemented by
`zg_gui.paint.MonoText` (deterministic metrics for tests and headless runs).
E03's shaper and glyph cache implement it once F06–F08 land.

### Consumed by
zg_gui layout (measuring text leaves) and paint (`PaintCx.textLine`,
`textBox`).

### Signature
```zig
pub const FontId = enum(u16) { ui = 0, mono = 1, _ };
pub const TextStyle = struct { font: FontId = .ui, size: f32 = 13, weight: u16 = 400, italic: bool = false };
pub const LineMetrics = struct { ascent: f32, descent: f32, line_h: f32 };
pub const TextSystem = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        metrics: *const fn (*anyopaque, TextStyle) LineMetrics,
        advance: *const fn (*anyopaque, TextStyle, cp: u21) f32,
        glyph: *const fn (*anyopaque, TextStyle, cp: u21, pen: Vec2) ?GlyphQuad, // null: blank glyph
    };
};
```

### Threading
UI thread only.

### Ownership/lifetime
The window borrows the text system for its whole life (`Window.Options.text`).

### Stability
Experimental: per-codepoint advances are a placeholder; shaped runs replace
`advance`/`glyph` when E03.F06 merges (additive `shape` entry first).

## zg_gui.input.KeyHandler

### Defined in
`packages/gui/src/input/keys.zig` (E04.F03).

### Implemented by
E15's keymap resolver adapter (#1077).

### Consumed by
`zg_gui.Window.dispatchKey`: keys not consumed by the focused widget's
bubble path go to `Window.key_handler` before the built-in Tab, Enter,
Space and Escape handling.

### Signature
```zig
pub const KeyHandler = struct {
    ptr: *anyopaque,
    handle: *const fn (ptr: *anyopaque, key: event.KeyPress, contexts: []const []const u8) bool, // true: consumed
};
```
`contexts` lists the `BoxDesc.key_context` strings from the focused node up
to the root, innermost first.

### Threading
UI thread only.

### Ownership/lifetime
`contexts` is valid only for the call.

### Stability
Experimental until the E15 adapter merges.

## zg_vulkan.vk and zg_vulkan.loader (Vulkan bindings and loader)

### Defined in
`packages/vulkan/src/vk/vk.zig`, generated by `tools/vkgen` from
`tools/vkgen/data/vk.xml` (E02.F01.S01); `packages/vulkan/src/loader/`
(E02.F01.S02.T01).

### Implemented by
`tools/vkgen` (XML parser, registry, resolver, emitter); the hand-written
helpers `vk/chain.zig` and `vk/enumerate.zig`; the loader opens
`vulkan-1.dll` (System32 only) or `libvulkan.so.1`.

### Consumed by
E02 only (device bring-up, memory, presentation, the Vulkan 2D backend).
Other packages draw through `zg_vulkan.r2d`.

### Signature
```zig
// vk (generated): Instance, Image, ... handles; Format, ... enums;
// ImageUsageFlags, ... packed structs; ImageCreateInfo, ... extern structs
pub const Command = enum { create_instance, ..., cmd_begin_rendering, ... };
pub fn Dispatch(comptime level: Level, comptime cmds: []const Command) type;
pub fn info(comptime c: Command) CommandInfo; // name, level, aliases, Pfn, provided_by
pub const Error = error{ OutOfHostMemory, ..., OutOfDateKHR, ..., Unknown };
pub fn check(r: Result) Error!Result;
pub fn chain(base: anytype, ext: anytype) void;
pub fn enumerateAlloc(comptime T: type, gpa: Allocator, f: anytype, args: anytype) (Error || error{OutOfMemory})![]T;
// loader
pub const Loader = struct {
    pub fn open(opts: OpenOptions) LoadError!Loader;
    pub fn loadGlobal(self: *const Loader, diag: ?*Diagnostics) LoadError!tables.Global;
    pub fn loadInstance(self: *const Loader, inst: vk.Instance, api: u32, enabled: ExtSet, diag: ?*Diagnostics) LoadError!tables.Instance;
};
pub fn loadDevice(inst: *const tables.Instance, dev: vk.Device, api: u32, enabled: ExtSet, diag: ?*Diagnostics) LoadError!tables.Device;
```
Deviations from the spec text: `vk.zig` is checked in and kept current by
`zig build vkgen` / `check-gen` (as with lspgen) instead of being generated
at build time, so `packages/vulkan` builds on its own; `api` is
`major * 100 + minor`; a `Diagnostics` out-parameter names the missing
command; `Dispatch` tables have no wrapper methods (call the fields:
`dev.create_image(...)`); `Loader.open` needs a libc-linked binary on Linux
(ADR-E02-001) and returns `error.Unsupported` otherwise.

### Threading
The generated code has no state. `Loader` and the tables are plain values:
load once, then share read-only.

### Ownership/lifetime
`Loader.close` unloads the library; tables loaded from it must not be used
afterwards. `enumerateAlloc` results belong to the caller.

### Stability
Internal to E02: regenerated when vk.xml or the allowlist changes.

## zg_vulkan.gpu (device bring-up)

### Defined in
`packages/vulkan/src/gpu/` (E02.F02): `Gpu.zig`, `instance.zig`,
`debug.zig`, `select.zig`, `features.zig`, `device.zig`, `info.zig`,
`lost.zig`, `marker.zig`.

### Implemented by
E02. Selection policy in `select.zig` (pure `choose`/`score` over `Probe`).

### Consumed by
E02's Vulkan backend (memory, presentation, 2D renderer); `zg doctor gpu`
(E10/E17 CLI) through `writeReport`; E17 crash reports through the same
report; E01 supplies `Presenter.drmDevice()` for `CreateOptions.drm_device`.

### Signature
```zig
pub const Gpu = struct {
    loader: Loader, instance: InstanceBundle, pdev: vk.PhysicalDevice, dev: vk.Device, ddisp: tables.Device,
    exts: ExtSet, info: GpuInfo, gfx: Queue, transfer: ?Queue, debug: ?Debug, sink: Sink,
    probes: []Probe, chosen: usize, lost: std.atomic.Value(bool), ...
    pub fn create(gpa: Allocator, io: std.Io, opts: CreateOptions) CreateError!*Gpu;
    pub fn destroy(self: *Gpu) void;
    pub fn name(self: *const Gpu, handle: anytype, label: [:0]const u8) void;
    pub fn checkLost(self: *Gpu, r: vk.Result) error{DeviceLost}!void;
    pub fn checkLostAt(self: *Gpu, r: vk.Result, at: ?Fault.At) error{DeviceLost}!void;
    pub fn report(self: *const Gpu, losses: []const u64) Report;
};
pub const CreateOptions = struct { instance: InstanceOptions, prefer: Preference, drm_device: ?DrmDevice, forced: ?[]const u8,
    need_dmabuf_export: bool, loader_path: ?[]const u8, marker_dir: ?std.Io.Dir, fault: ?[]const u8, log_emit: ?fn };
pub fn choose(probes: []const Probe, opts: SelectOptions) ?usize; // pure
pub fn score(p: *const Probe, opts: SelectOptions) i32;           // pure
pub const Recovery = struct {
    pub fn record(self: *Recovery, now_ns: u64) Outcome;          // pure policy
    pub fn onLost(self: *Recovery, now_ns: u64, hooks: Hooks) anyerror!Outcome;
    pub fn history(self: *const Recovery) []const u64;
};
pub fn writeReport(w: *std.Io.Writer, r: Report, fmt: enum { text, json }) !void;
```
Deviations from the spec text: `choose`/`score` take `SelectOptions` (the
selection-relevant part of `CreateOptions`); `Probe.queues` holds
`VkQueueFamilyProperties` (not the `2` variant) plus a `present_mask`;
CPU devices are never rejected (`cpu_device_not_forced` does not exist),
they score −10000 and are used when forced or alone; `createInstance`
takes the `Sink` so the messenger chained into instance creation can
count; `Recovery.onLost` takes renderer `Hooks` (teardown, recreate,
switch to software) instead of a `*VkRenderer`, which lands with
E02.F06; `writeReport` takes a `Report` value. Win32 presentation support
is checked per family with `vkGetPhysicalDeviceWin32PresentationSupportKHR`,
so no `HWND` is needed at selection. The crash marker
(`~/.cache/zigguro/gpu-init.lock`) forces software for one start, then
Vulkan is tried again. `ZG_VK_FAULT` is honoured only in Debug and test
builds.

### Threading
`create` may run on a worker (it does not touch the UI). The result is
immutable except `lost` (atomic) and the queue mutexes: lock
`Queue.mutex` around submits and presents. The debug callback runs on any
thread and only touches the `Sink` atomics.

### Ownership/lifetime
`Gpu` owns the loader, instance, messenger, device and probes; `destroy`
frees them (waiting for the device only if it was not lost). Recovery
destroys and recreates the whole `Gpu`.

### Stability
Internal to E02 except `writeReport`'s JSON schema (golden-tested) and
`CreateOptions`, which the app fills from `EnvOverrides` and E15 settings.

## zg_vulkan.mem (GPU memory, uploads, textures)

### Defined in
`packages/vulkan/src/mem/` (E02.F03): `tlsf.zig`, `types.zig`,
`DeviceMemory.zig`, `UploadRing.zig`, `Uploader.zig`, `Texture.zig`,
`barriers.zig`.

### Implemented by
E02. `findMemoryType`, `flushRange`, `blockSizeFor` and the ring's `Bump`
are pure and unit-tested; the rest is tested on lavapipe.

### Consumed by
E02's Vulkan backend (instance data, layers, swapchain/dmabuf ring) and,
through `Uploader.writeRegion`, the glyph atlas and image uploads that
E03/E04/E08 feed via the renderer.

### Signature
```zig
pub const DeviceMemory = struct {
    pub fn init(gpu: *Gpu, gpa: Allocator, opts: Options) DeviceMemory;
    pub fn deinit(self: *DeviceMemory) void;                     // logs leaks by name
    pub fn allocFor(self, req: Request, usage: Usage, linear: bool, name: [:0]const u8) Error!Allocation;
    pub fn createBuffer(self, info: vk.BufferCreateInfo, usage: Usage, name: [:0]const u8) Error!Buffer;
    pub fn createImage(self, info: vk.ImageCreateInfo, usage: Usage, name: [:0]const u8, export_dmabuf: bool) Error!Image;
    pub fn free(self, a: Allocation) void;
    pub fn flush(self, a: Allocation, off: u64, len: u64) vk.Error!void;
    pub fn invalidate(self, a: Allocation, off: u64, len: u64) vk.Error!void;
    pub fn budget(self) []const HeapBudget;
    pub fn stats(self) Stats;
    pub fn nextFrame(self) void;                                 // releases blocks empty for 3 frames
    pub fn reportLeaks(self, w: *std.Io.Writer) !usize;
};
pub const UploadRing = struct { init(mem, frames_in_flight: u8, bytes_per_frame: u64), beginFrame(slot: u8), alloc(len, alignment) !Slice,
    endFrame(cb, dd) !void, gpuBuffer() vk.Buffer, resize(bytes_per_frame) !void };
pub const Uploader = struct { init(gpa, mem, ring), writeRegion(tex, Rect16, pixels, row_pitch) !void, writeBuffer(dst, off, bytes) !void,
    record(cb, dd) !void, retire() void, pendingBytes() u64 };
pub const Texture = struct { image: Image, view: vk.ImageView, format: Format, width: u32, height: u32, slot: u32, access: barriers.Access,
    pub fn create(mem, w, h, fmt: Format, use: enum { sampled, render_target }, name) !Texture; pub fn destroy(self, mem) void };
```
Deviations from the spec text: `DeviceMemory.init` cannot fail;
`Allocation` also carries `block`, `linear` and `id`; frames in flight are
`u8`; copies use `vkCmdCopyBufferToImage`/`vkCmdCopyBuffer` (core 1.0,
no `VK_KHR_copy_commands2` needed on 1.2 devices) with all regions of a
texture in one call; ring growth is `resize`, which the owner calls once
every slot has retired (E02.F04 timeline); staging buffers are freed by
`Uploader.retire` when the frame completes; `VK_EXT_memory_priority` is
not used yet (it needs the `memoryPriority` feature); bands of uploads
over 4 MiB and the async transfer queue are not implemented yet.

### Threading
`DeviceMemory` methods lock one `std.Io.Mutex` (render thread plus a
texture worker). `UploadRing` and `Uploader` belong to the render thread.

### Ownership/lifetime
Every allocation is freed through `DeviceMemory.free` (or
`destroyBuffer`/`destroyImage`/`Texture.destroy`) before `deinit`.
Ring slices are valid until their slot is reused.

### Stability
Internal to E02.

## zg_syntax (Language, Registry, Highlighter, Structure)

### Defined in
`packages/syntax/src/root.zig`, `language.zig`, `registry.zig`, `detect.zig`,
`highlight_names.zig`, `lex/*.zig`, `highlight/*.zig`, `langs/*.zig`,
`structure/*.zig` (E05.F04); the document adapter is
`packages/editor/src/model/syntax.zig`.

### Implemented by
E05.F04.S01.T01 (tier-1 framework), E05.F04.S01.T02 (Zig lexer and Zig
structure from `std.zig.Ast`).

### Consumed by
zg_editor (document highlighting and smart editing), E04 (rendering tokens),
E15 (themes resolve `HighlightId` by longest dotted prefix), the language
lexers of E05.F04.S02.

### Signature
```zig
pub const HighlightId = enum(u16) { none, comment, comment_doc, string, ..., invalid, _,
    pub fn name(id) []const u8; pub fn fromName(s) ?HighlightId; pub fn parent(id) ?HighlightId };
pub fn resolve(comptime T: type, table: []const ?T, id: HighlightId) ?T;
pub const Token = packed struct(u64) { start: u32, kind: u16, hl: HighlightId };
pub const LexState = struct { stack: [4]Frame, stack_len: u8, mode: u16, depth: u16, aux: [32]u8, aux_len: u8,
    pub fn push(s, guest: LanguageId) bool; pub fn pop(s) void; pub fn eql(a, b) bool };
pub const Lexer = struct { lexLineFn: *const fn (st: *LexState, s: *Scanner, out: *TokenSink) void };
pub const Language = struct { id: LanguageId, name: []const u8, aliases, extensions, filenames, shebangs: []const []const u8,
    lexer: Lexer, injection_end: ?fn (host_mode: u16, line: []const u8, from: u32) ?u32, resync: ?fn ([]const u8) bool,
    structure: ?ParseFn, context_of: ?fn (kind: u16) ?ContextKind, edit_rules: EditRules, brackets: []const BracketPair, ... };
pub const Registry = struct { pub fn init(gpa) !Registry; pub fn register(r, gpa, l: *const Language) !void;
    pub fn detect(r, path: ?[]const u8, head: []const u8) ?LanguageId; pub fn byName(r, name) ?LanguageId };
pub fn defaultRegistry(gpa) !Registry;
pub const LineSource = struct { ctx: *const anyopaque, lines: u64, getFn: ..., pub fn fromSlice(*const []const []const u8) LineSource };
pub const LineEdit = struct { first: u64, removed: u64, inserted: u64 };
pub const Highlighter = struct {
    pub fn init(gpa, lang: *const Language, reg: *const Registry) !Highlighter;
    pub fn reset(h, src: LineSource) !void;
    pub fn onEdit(h, e: LineEdit, src: LineSource, deadline: ?Deadline) !void; // to convergence, 4096-line cap
    pub fn onEdits(h, edits: []const LineEdit, src: LineSource, deadline: ?Deadline) !void; // multi-cursor, old coords
    pub fn ensure(h, src: LineSource, first: u64, last: u64) !void;          // viewport exact (or approximate after resync)
    pub fn idle(h, src: LineSource, deadline: ?Deadline) !bool;              // true when done
    pub fn tokens(h, line: u64) []const Token;
    pub fn isExact(h, line: u64) bool; pub fn isApprox(h, line: u64) bool;
    pub fn kindAt(h, line: u64, col: u32, line_len: u32) ContextKind;
};
// Tier 2: structure parsed from a whole text (off the UI thread).
pub const ParseFn = *const fn (gpa, text: []const u8, version: u64) (Allocator.Error || error{TooLarge})!Structure;
pub const Structure = struct { version: u64, folds: []const FoldRange, symbols: []const Symbol, scopes: []const Scope, ...,
    pub fn deinit(s) void;
    pub fn outline(s) []const Symbol;                                        // pre-order, `parent` indexes
    pub fn enclosingScopes(s, gpa, pos: u32, out: *ArrayList(Scope)) !void;  // innermost first
    pub fn selectionRanges(s, gpa, pos: u32, out: *ArrayList(ByteRange)) !void; // innermost first
    pub fn indentDepth(s, pos: u32) ?u32;
};
// zg_editor.model.syntax: the document adapter.
pub fn lineSource(tree: *const PieceTree) LineSource;
pub fn lineEdits(gpa, ev: *const ChangeEvent, after: PieceTree, out: *ArrayList(LineEdit)) !?[]const LineEdit;
pub const DocumentSyntax = struct { hl: Highlighter, version: u64,
    pub fn init(gpa, lang, reg, tree: *const PieceTree, version: u64) !DocumentSyntax;
    pub fn onChange(ds, ev: *const ChangeEvent, after: *const PieceTree, deadline: ?Deadline) !void; // from a Listener
    pub fn ensure(ds, tree, first: u64, last: u64) !void; pub fn idle(ds, tree, deadline) !bool };
pub fn parseStructure(gpa, lang: *const Language, snap: *const Snapshot) !?Structure;
```

### Threading
One `Highlighter` (or `DocumentSyntax`) per document, used from one thread
(the UI thread). A `Registry` is read-only after setup and can be shared.
`parseStructure` runs on any thread from a retained `Snapshot`; the result is
immutable and tagged with the snapshot's version, so a stale one is dropped.

### Ownership/lifetime
`Language` definitions and the `Registry` are borrowed and must outlive every
`Highlighter` using them. `tokens(line)` slices are valid until the next
call that mutates the highlighter. `LineSource` text is borrowed per call.

### Stability
Unstable while E05.F04 is in progress. The highlighter speaks lines, not
documents: zg_editor (layer 4) maps its ChangeSets to `LineEdit`s and serves
text through a `LineSource`, because zg_syntax (layer 3) cannot import it.
