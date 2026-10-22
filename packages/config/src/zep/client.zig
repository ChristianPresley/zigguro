//! The author-facing side of ZEP: an `Extension` speaks the protocol over a
//! `zg_jsonrpc` endpoint (Content-Length framing, LSP-style cancellation),
//! answers the lifecycle requests, dispatches `command/execute` to the
//! handlers registered with `onCommand`, and offers typed wrappers for the
//! host methods.
//!
//! ```zig
//! pub fn main(init: std.process.Init) !void {
//!     var rt: zg_core.Runtime = undefined;
//!     try rt.init(init.minimal, .{});
//!     const ext = try Extension.initStdio(&rt, .{});
//!     defer ext.deinit();
//!     try ext.onCommand("hello.say", say);
//!     try ext.run();
//! }
//! ```
//!
//! Threads: request handlers run as endpoint tasks, so a command handler may
//! call blocking host methods (`showMessage`, `applyEdit`). Notification
//! handlers run on the reader loop.

const std = @import("std");
const zg_core = @import("zg_core");
const jsonrpc = @import("zg_jsonrpc");
const protocol = @import("protocol.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Endpoint = jsonrpc.Endpoint;
const message = jsonrpc.message;
const methods = protocol.methods;

/// Handles `command/execute` for one id. Allocate the result in `arena`.
pub const CommandFn = *const fn (e: *Extension, args: ?std.json.Value, arena: Allocator) anyerror!?std.json.Value;

/// Handles a notification the SDK does not handle itself.
pub const NotificationFn = *const fn (e: *Extension, params: ?std.json.Value, arena: Allocator) void;

/// Options of `Extension.init`.
pub const Options = struct {
    capabilities: protocol.ExtCapabilities = .{},
    /// Timeout of requests to the host.
    timeout: ?Io.Duration = .fromSeconds(30),
};

/// Re-export for handlers.
pub const Severity = protocol.Severity;

/// One running extension.
pub const Extension = struct {
    rt: *zg_core.Runtime,
    gpa: Allocator,
    ep: *Endpoint,
    opts: Options,
    mutex: Io.Mutex = .init,
    commands: std.StringHashMapUnmanaged(CommandFn) = .empty,
    notifications: std.StringHashMapUnmanaged(NotificationFn) = .empty,
    requests: std.StringHashMapUnmanaged(CommandFn) = .empty,
    /// Copy of the host's `initialize` params (valid after `initialized`).
    host: ?protocol.InitializeParams = null,
    host_arena: std.heap.ArenaAllocator,
    initialized: Io.Event = .unset,
    done: Io.Event = .unset,
    shutdown_requested: std.atomic.Value(bool) = .init(false),
    /// Activation events received, in order (for tests and diagnostics).
    activations: std.atomic.Value(u32) = .init(0),
    stdio: ?*Stdio = null,
    /// Running command handlers.
    workers: Io.Group = .init,

    const Stdio = struct {
        in_buf: [64 * 1024]u8,
        out_buf: [64 * 1024]u8,
        in: Io.File.Reader,
        out: Io.File.Writer,
    };

    /// An extension on `reader`/`writer` (tests, embedding).
    pub fn init(rt: *zg_core.Runtime, reader: *Io.Reader, writer: *Io.Writer, opts: Options) !*Extension {
        const e = try rt.gpa.create(Extension);
        errdefer rt.gpa.destroy(e);
        const ep = try Endpoint.init(rt, .{
            .framing = .content_length,
            .dialect = .lsp,
            .default_timeout = opts.timeout,
            .opts = .{ .max_message_bytes = protocol.limits.max_message_bytes },
        }, reader, writer);
        e.* = .{ .rt = rt, .gpa = rt.gpa, .ep = ep, .opts = opts, .host_arena = .init(rt.gpa) };
        try ep.onRequest(methods.initialize, .{ .ctx = e, .func = onInitialize });
        try ep.onRequest(methods.shutdown, .{ .ctx = e, .func = onShutdown });
        try ep.onRequest(methods.command_execute, .{ .ctx = e, .func = onExecute });
        try ep.onNotification(methods.initialized, .{ .ctx = e, .func = onInitialized });
        try ep.onNotification(methods.exit, .{ .ctx = e, .func = onExit });
        try ep.onNotification(methods.activate, .{ .ctx = e, .func = onActivate });
        ep.onClose(.{ .ctx = e, .func = onClosed });
        return e;
    }

    /// An extension on the process's stdin/stdout (the normal case).
    pub fn initStdio(rt: *zg_core.Runtime, opts: Options) !*Extension {
        const s = try rt.gpa.create(Stdio);
        errdefer rt.gpa.destroy(s);
        s.in = Io.File.stdin().reader(rt.io, &s.in_buf);
        s.out = Io.File.stdout().writer(rt.io, &s.out_buf);
        const e = try init(rt, &s.in.interface, &s.out.interface, opts);
        e.stdio = s;
        return e;
    }

    /// Stops and frees the extension.
    pub fn deinit(e: *Extension) void {
        e.workers.cancel(e.rt.io);
        e.ep.close();
        e.ep.deinit();
        e.commands.deinit(e.gpa);
        e.notifications.deinit(e.gpa);
        e.requests.deinit(e.gpa);
        e.host_arena.deinit();
        if (e.stdio) |s| e.gpa.destroy(s);
        e.gpa.destroy(e);
    }

    /// Registers the handler of command `id`. Call before `run`/`start`.
    pub fn onCommand(e: *Extension, id: []const u8, h: CommandFn) !void {
        e.mutex.lockUncancelable(e.rt.io);
        defer e.mutex.unlock(e.rt.io);
        try e.commands.put(e.gpa, id, h);
    }

    /// Registers a handler for another host notification (e.g.
    /// `settings/didChange`, `document/didOpen`). Call before `run`/`start`.
    pub fn onNotification(e: *Extension, method: []const u8, h: NotificationFn) !void {
        try e.notifications.put(e.gpa, method, h);
        try e.ep.onNotification(method, .{ .ctx = e, .func = onOther });
    }

    /// Registers a handler for another host request (`view/resolve`,
    /// `view/resolveChildren`, `decorations/provide`). It runs like a command
    /// handler; `params` is the request's params. Call before `run`/`start`.
    pub fn onRequest(e: *Extension, method: []const u8, h: CommandFn) !void {
        try e.requests.put(e.gpa, method, h);
        try e.ep.onRequest(method, .{ .ctx = e, .func = onGeneric });
    }

    /// Starts the message loops without blocking.
    pub fn start(e: *Extension) !void {
        try e.ep.start();
    }

    /// Runs until the host sends `exit` or closes the connection.
    pub fn run(e: *Extension) !void {
        try e.start();
        e.done.waitUncancelable(e.rt.io);
    }

    /// Blocks until the host sent `initialized`.
    pub fn waitInitialized(e: *Extension, timeout: Io.Timeout) !void {
        try e.initialized.waitTimeout(e.rt.io, timeout);
    }

    // -------------------------------------------------------- host methods

    /// `window/showMessage`; returns the chosen action (owned by `arena`) or null.
    pub fn showMessage(e: *Extension, arena: Allocator, sev: Severity, msg: []const u8, actions: []const []const u8) !?[]const u8 {
        const r = try e.ep.request(methods.window_show_message, protocol.ShowMessageParams{ .severity = sev, .message = msg, .actions = actions }, .{});
        defer r.deinit();
        const res = try resultOf(r);
        const v = try res.parseLeaky(?[]const u8, arena, .{});
        return v;
    }

    /// `window/setStatusItem`.
    pub fn setStatusItem(e: *Extension, item: protocol.StatusItemParams) !void {
        try e.ep.notify(methods.window_set_status_item, item);
    }

    /// `workspace/applyEdit`. The result is owned by `arena`.
    pub fn applyEdit(e: *Extension, arena: Allocator, label: []const u8, edits: []const protocol.FileEdit) !protocol.ApplyEditResult {
        const r = try e.ep.request(methods.workspace_apply_edit, protocol.ApplyEditParams{ .label = label, .edits = edits }, .{});
        defer r.deinit();
        return (try resultOf(r)).parseLeaky(protocol.ApplyEditResult, arena, .{});
    }

    /// `workspace/readFile`. The result is owned by `arena`.
    pub fn readFile(e: *Extension, arena: Allocator, uri: []const u8) !protocol.ReadFileResult {
        const r = try e.ep.request(methods.workspace_read_file, protocol.ReadFileParams{ .uri = uri }, .{});
        defer r.deinit();
        return (try resultOf(r)).parseLeaky(protocol.ReadFileResult, arena, .{});
    }

    /// `settings/get`. The value is owned by `arena`.
    pub fn getSetting(e: *Extension, arena: Allocator, section: []const u8) !std.json.Value {
        const r = try e.ep.request(methods.settings_get, protocol.SettingsGetParams{ .section = section }, .{});
        defer r.deinit();
        return (try resultOf(r)).parseLeaky(std.json.Value, arena, .{});
    }

    /// `commands/execute`: runs a host command. The result is owned by `arena`.
    pub fn executeCommand(e: *Extension, arena: Allocator, id: []const u8, args: ?std.json.Value) !std.json.Value {
        const r = try e.ep.request(methods.commands_execute, protocol.ExecuteCommandParams{ .id = id, .args = args }, .{});
        defer r.deinit();
        return (try resultOf(r)).parseLeaky(std.json.Value, arena, .{});
    }

    /// `commands/register`: commands added at runtime (beyond the manifest).
    pub fn registerCommands(e: *Extension, decls: []const protocol.CommandDecl) !void {
        try e.ep.notify(methods.commands_register, protocol.RegisterCommandsParams{ .commands = decls });
    }

    /// `log`.
    pub fn log(e: *Extension, level: protocol.LogLevel, msg: []const u8) !void {
        try e.ep.notify(methods.log, protocol.LogParams{ .level = level, .message = msg });
    }

    /// `view/update`.
    pub fn updateView(e: *Extension, view_id: []const u8, patch: std.json.Value) !void {
        try e.ep.notify(methods.view_update, protocol.ViewUpdateParams{ .viewId = view_id, .patch = patch });
    }

    // ------------------------------------------------------------ handlers

    fn self(ctx: ?*anyopaque) *Extension {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn onInitialize(ctx: ?*anyopaque, _: *Endpoint, req: message.Request, arena: Allocator) Endpoint.HandlerResult {
        const e = self(ctx);
        const raw = req.params orelse return err(.invalid_params, "initialize needs params");
        const p = raw.parseLeaky(protocol.InitializeParams, arena, .{}) catch return err(.invalid_params, "malformed initialize params");
        if (!protocol.isSupported(p.protocolVersion)) return err(.invalid_request, "unsupported protocolVersion");
        // Keep a copy that outlives the request arena.
        const copy = std.json.parseFromSliceLeaky(protocol.InitializeParams, e.host_arena.allocator(), raw.bytes, .{ .ignore_unknown_fields = true }) catch return err(.internal, "out of memory");
        e.host = copy;
        const result: protocol.InitializeResult = .{ .capabilities = e.opts.capabilities };
        return .{ .result = Endpoint.raw(arena, result) catch return err(.internal, "out of memory") };
    }

    fn onInitialized(ctx: ?*anyopaque, _: *Endpoint, _: message.Notification, _: Allocator) void {
        self(ctx).initialized.set(self(ctx).rt.io);
    }

    fn onActivate(ctx: ?*anyopaque, _: *Endpoint, _: message.Notification, _: Allocator) void {
        _ = self(ctx).activations.fetchAdd(1, .monotonic);
    }

    fn onShutdown(ctx: ?*anyopaque, _: *Endpoint, _: message.Request, arena: Allocator) Endpoint.HandlerResult {
        self(ctx).shutdown_requested.store(true, .release);
        return .{ .result = Endpoint.raw(arena, null) catch return err(.internal, "out of memory") };
    }

    fn onExit(ctx: ?*anyopaque, _: *Endpoint, _: message.Notification, _: Allocator) void {
        self(ctx).done.set(self(ctx).rt.io);
    }

    fn onClosed(ctx: ?*anyopaque, _: Endpoint.Result) void {
        self(ctx).done.set(self(ctx).rt.io);
    }

    fn onOther(ctx: ?*anyopaque, _: *Endpoint, n: message.Notification, arena: Allocator) void {
        const e = self(ctx);
        const h = e.notifications.get(n.method) orelse return;
        const params: ?std.json.Value = if (n.params) |p| p.parseLeaky(std.json.Value, arena, .{}) catch null else null;
        h(e, params, arena);
    }

    fn onExecute(ctx: ?*anyopaque, _: *Endpoint, req: message.Request, arena: Allocator) Endpoint.HandlerResult {
        const e = self(ctx);
        if (!e.initialized.isSet()) return err(.not_activated, "command before initialized");
        const raw = req.params orelse return err(.invalid_params, "command/execute needs params");
        const p = raw.parseLeaky(protocol.ExecuteCommandParams, arena, .{}) catch return err(.invalid_params, "malformed command/execute params");
        e.mutex.lockUncancelable(e.rt.io);
        const h = e.commands.get(p.id);
        e.mutex.unlock(e.rt.io);
        const handler = h orelse return err(.method_not_found, "unknown command");
        const what = std.fmt.allocPrint(arena, "command '{s}'", .{p.id}) catch p.id;
        return e.dispatch(req.id, handler, p.args, what, arena);
    }

    fn onGeneric(ctx: ?*anyopaque, _: *Endpoint, req: message.Request, arena: Allocator) Endpoint.HandlerResult {
        const e = self(ctx);
        if (!e.initialized.isSet()) return err(.not_activated, "request before initialized");
        const handler = e.requests.get(req.method) orelse return err(.method_not_found, "no handler");
        const params: ?std.json.Value = if (req.params) |p| p.parseLeaky(std.json.Value, arena, .{}) catch return err(.invalid_params, "malformed params") else null;
        return e.dispatch(req.id, handler, params, req.method, arena);
    }

    /// Runs `handler` on its own unit of concurrency: handlers may call
    /// blocking host methods, whose responses arrive on the reader loop. The
    /// request arena lives until the deferred reply is sent.
    fn dispatch(e: *Extension, id: message.Id, handler: CommandFn, args: ?std.json.Value, what: []const u8, arena: Allocator) Endpoint.HandlerResult {
        e.workers.concurrent(e.rt.io, runDeferred, .{ e, id, handler, args, what, arena }) catch {
            return runOnce(e, handler, args, what, arena);
        };
        return .deferred;
    }

    fn runOnce(e: *Extension, handler: CommandFn, args: ?std.json.Value, what: []const u8, arena: Allocator) Endpoint.HandlerResult {
        const out = handler(e, args, arena) catch |x| {
            const msg = std.fmt.allocPrint(arena, "{s} failed: {t}", .{ what, x }) catch "request failed";
            return err(.internal, msg);
        };
        return .{ .result = Endpoint.raw(arena, out) catch return err(.internal, "out of memory") };
    }

    fn runDeferred(e: *Extension, id: message.Id, handler: CommandFn, args: ?std.json.Value, what: []const u8, arena: Allocator) Io.Cancelable!void {
        switch (runOnce(e, handler, args, what, arena)) {
            .result => |r| e.ep.respond(id, r) catch {},
            .err => |x| e.ep.respondError(id, x.code, x.message) catch {},
            .deferred => unreachable,
        }
    }
};

fn err(code: protocol.ErrorCode, msg: []const u8) Endpoint.HandlerResult {
    return .{ .err = .{ .code = code.int(), .message = msg } };
}

/// The host's error, mapped to a Zig error.
pub const HostError = error{ HostError, PermissionDenied, MethodNotFound, NoResult };

fn resultOf(r: Endpoint.OwnedResponse) HostError!message.RawJson {
    if (r.response.err) |e| return switch (@as(protocol.ErrorCode, @enumFromInt(e.code))) {
        .permission_denied => error.PermissionDenied,
        .method_not_found => error.MethodNotFound,
        else => error.HostError,
    };
    return r.response.result orelse error.NoResult;
}
