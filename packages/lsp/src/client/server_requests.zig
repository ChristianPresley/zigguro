//! Everything a language server sends to the client outside feature
//! results, bridged into zigguro:
//!
//! - `client/registerCapability` / `unregisterCapability` update
//!   `ServerCaps`. Watched-file registrations go to the watch bridge, and
//!   a `workspace/didChangeConfiguration` registration switches the client
//!   to push mode (`Client.settingsChanged` then sends
//!   `didChangeConfiguration { settings: null }` and the server pulls).
//! - `workspace/configuration` asks `ClientHost.getConfiguration` per item;
//!   `workspace/workspaceFolders` answers the current folders.
//! - `window/showMessage` (errors at most once per 5 s per server; the rest
//!   go to the log), `logMessage`, `showMessageRequest` (null on dismiss or
//!   after 60 s) and `showDocument` go to the `ClientHost`.
//! - `window/workDoneProgress/create` and `$/progress` go to the
//!   `ProgressTracker`.
//! - The `workspace/*/refresh` requests emit a `RefreshEvent` and are
//!   answered at once.
//! - `$/logTrace` goes to the trace ring. `telemetry/event` is logged at
//!   debug level and never forwarded anywhere.
//!
//! Unknown requests get -32601 from the endpoint; unknown notifications
//! are ignored. Request handlers run as endpoint tasks, so the deferred
//! host answers wait there; notification handlers run on the reader loop.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_jsonrpc = @import("zg_jsonrpc");
const Endpoint = zg_jsonrpc.Endpoint;
const message = zg_jsonrpc.message;
const protocol = @import("../gen/protocol.zig");
const Client = @import("Client.zig");
const host_mod = @import("host.zig");
const progress_mod = @import("progress.zig");
const ServerId = host_mod.ServerId;

const log = std.log.scoped(.lsp);

pub const Options = struct {
    /// This server's id towards the host and the progress tracker.
    server: ServerId = 0,
    host: host_mod.ClientHost = host_mod.null_host,
    /// Shared by all clients; null drops work-done progress.
    progress: ?*progress_mod.ProgressTracker = null,
    refresh: ?host_mod.RefreshListener = null,
    watch: ?host_mod.WatchBridge = null,
    /// How long `showMessageRequest` and `showDocument` wait for the host.
    reply_timeout: Io.Duration = .fromSeconds(60),
    /// At most one error toast per interval; the rest go to the log.
    error_toast_interval: Io.Duration = .fromSeconds(5),
};

/// How `Client.setWorkspaceFolders` applied a change.
pub const FolderChange = enum {
    unchanged,
    /// Sent `workspace/didChangeWorkspaceFolders`.
    notified,
    /// The server cannot take folder changes: restart it with the new set.
    restart_required,
};

pub const Services = struct {
    opts: Options,
    mutex: Io.Mutex = .init,
    /// Owns the folder strings.
    folder_arena: std.heap.ArenaAllocator,
    folders: []const protocol.WorkspaceFolder = &.{},
    /// A `workspace/didChangeConfiguration` registration is live.
    push_config: std.atomic.Value(bool) = .init(false),
    /// A dynamic `workspace/didChangeWorkspaceFolders` registration is live.
    folder_notifications: std.atomic.Value(bool) = .init(false),
    last_error_toast_ns: std.atomic.Value(i64) = .init(std.math.minInt(i64)),

    pub fn init(gpa: Allocator, opts: Options, folders: []const protocol.WorkspaceFolder) !Services {
        var s: Services = .{ .opts = opts, .folder_arena = .init(gpa) };
        errdefer s.folder_arena.deinit();
        s.folders = try dupeFolders(s.folder_arena.allocator(), folders);
        return s;
    }

    pub fn deinit(s: *Services) void {
        s.folder_arena.deinit();
    }
};

fn dupeFolders(a: Allocator, folders: []const protocol.WorkspaceFolder) ![]const protocol.WorkspaceFolder {
    const out = try a.alloc(protocol.WorkspaceFolder, folders.len);
    for (folders, out) |f, *o| o.* = .{ .uri = try a.dupe(u8, f.uri), .name = try a.dupe(u8, f.name) };
    return out;
}

/// Registers every handler on `c`'s endpoint (before `start`).
pub fn register(c: *Client) !void {
    const ep = c.ep;
    const reqs = .{
        .{ "client/registerCapability", onRegister },
        .{ "client/unregisterCapability", onUnregister },
        .{ "workspace/configuration", onConfiguration },
        .{ "workspace/workspaceFolders", onWorkspaceFolders },
        .{ "window/workDoneProgress/create", onProgressCreate },
        .{ "window/showMessageRequest", onShowMessageRequest },
        .{ "window/showDocument", onShowDocument },
    };
    inline for (reqs) |r| try ep.onRequest(r[0], .{ .ctx = c, .func = r[1] });
    inline for (refresh_methods) |r| try ep.onRequest(r[0], .{ .ctx = c, .func = Refresh(r[1]).handle });
    const notes = .{
        .{ "window/showMessage", onShowMessage },
        .{ "window/logMessage", onLogMessage },
        .{ "$/progress", onProgress },
        .{ "$/logTrace", onLogTrace },
        .{ "telemetry/event", onTelemetry },
    };
    inline for (notes) |n| try ep.onNotification(n[0], .{ .ctx = c, .func = n[1] });
    if (c.services.opts.progress) |t| try t.addServer(c.services.opts.server, .{ .ctx = c, .func = sendProgressCancel });
}

/// The client stopped or crashed: its progress ends.
pub fn onStopped(c: *Client) void {
    if (c.services.opts.progress) |t| t.removeServer(c.services.opts.server);
}

fn sendProgressCancel(ctx: ?*anyopaque, token: protocol.ProgressToken) void {
    const c: *Client = @ptrCast(@alignCast(ctx.?));
    c.notify(.@"window/workDoneProgress/cancel", .{ .token = token }) catch |err| log.debug("workDoneProgress/cancel: {t}", .{err});
}

fn client(ctx: ?*anyopaque) *Client {
    return @ptrCast(@alignCast(ctx.?));
}

// ------------------------------------------------------------- registration

fn onRegister(ctx: ?*anyopaque, _: *Endpoint, req: message.Request, arena: Allocator) Endpoint.HandlerResult {
    const c = client(ctx);
    const p = req.params orelse return invalidParams();
    const params = p.parseLeaky(protocol.RegistrationParams, arena, .{ .ignore_unknown_fields = true }) catch return invalidParams();
    {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        const cp = if (c.caps_) |*x| x else return .{ .err = .{ .code = message.ErrorCode.server_not_initialized.int(), .message = "not initialized" } };
        for (params.registrations) |reg| cp.addRegistration(reg) catch |err| {
            log.warn("registerCapability {s}: {t}", .{ reg.method, err });
        };
    }
    const s = &c.services;
    for (params.registrations) |reg| {
        if (eql(reg.method, "workspace/didChangeConfiguration")) {
            s.push_config.store(true, .release);
        } else if (eql(reg.method, "workspace/didChangeWorkspaceFolders")) {
            s.folder_notifications.store(true, .release);
        } else if (eql(reg.method, "workspace/didChangeWatchedFiles")) {
            const w = s.opts.watch orelse continue;
            const o = reg.registerOptions orelse continue;
            const opts = std.json.parseFromValueLeaky(protocol.DidChangeWatchedFilesRegistrationOptions, arena, o, .{ .ignore_unknown_fields = true }) catch {
                log.warn("registerCapability {s}: bad watchers", .{reg.method});
                continue;
            };
            w.set(w.ctx, s.opts.server, reg.id, opts.watchers);
        }
    }
    return nullResult(arena);
}

fn onUnregister(ctx: ?*anyopaque, _: *Endpoint, req: message.Request, arena: Allocator) Endpoint.HandlerResult {
    const c = client(ctx);
    const p = req.params orelse return invalidParams();
    const params = p.parseLeaky(protocol.UnregistrationParams, arena, .{ .ignore_unknown_fields = true }) catch return invalidParams();
    {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        if (c.caps_) |*cp| for (params.unregisterations) |u| cp.removeRegistration(u.id);
    }
    const s = &c.services;
    for (params.unregisterations) |u| {
        if (eql(u.method, "workspace/didChangeConfiguration")) {
            s.push_config.store(false, .release);
        } else if (eql(u.method, "workspace/didChangeWorkspaceFolders")) {
            s.folder_notifications.store(false, .release);
        } else if (eql(u.method, "workspace/didChangeWatchedFiles")) {
            if (s.opts.watch) |w| w.clear(w.ctx, s.opts.server, u.id);
        }
    }
    return nullResult(arena);
}

// ------------------------------------------------------------- workspace

fn onConfiguration(ctx: ?*anyopaque, _: *Endpoint, req: message.Request, arena: Allocator) Endpoint.HandlerResult {
    const c = client(ctx);
    const p = req.params orelse return invalidParams();
    const params = p.parseLeaky(protocol.ConfigurationParams, arena, .{ .ignore_unknown_fields = true }) catch return invalidParams();
    const h = c.services.opts.host;
    const out = arena.alloc(std.json.Value, params.items.len) catch return internal();
    for (params.items, out) |item, *o| o.* = h.getConfiguration(h.ctx, item.section, item.scopeUri, arena);
    return .{ .result = Endpoint.raw(arena, out) catch return internal() };
}

fn onWorkspaceFolders(ctx: ?*anyopaque, _: *Endpoint, _: message.Request, arena: Allocator) Endpoint.HandlerResult {
    const s = &client(ctx).services;
    const io = client(ctx).io;
    s.mutex.lockUncancelable(io);
    defer s.mutex.unlock(io);
    // null: no workspace is open.
    const folders: ?[]const protocol.WorkspaceFolder = if (s.folders.len == 0) null else s.folders;
    return .{ .result = Endpoint.raw(arena, folders) catch return internal() };
}

/// Replaces the workspace folders (E08) and tells the server. Worker only.
pub fn setWorkspaceFolders(c: *Client, folders: []const protocol.WorkspaceFolder) !FolderChange {
    const s = &c.services;
    var scratch: std.heap.ArenaAllocator = .init(c.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var added: std.ArrayList(protocol.WorkspaceFolder) = .empty;
    var removed: std.ArrayList(protocol.WorkspaceFolder) = .empty;
    {
        s.mutex.lockUncancelable(c.io);
        defer s.mutex.unlock(c.io);
        for (folders) |f| if (!hasFolder(s.folders, f.uri)) try added.append(a, f);
        for (s.folders) |f| if (!hasFolder(folders, f.uri)) try removed.append(a, .{ .uri = try a.dupe(u8, f.uri), .name = try a.dupe(u8, f.name) });
        if (added.items.len == 0 and removed.items.len == 0) return .unchanged;
        var next: std.heap.ArenaAllocator = .init(c.gpa);
        errdefer next.deinit();
        const copy = try dupeFolders(next.allocator(), folders);
        s.folder_arena.deinit();
        s.folder_arena = next;
        s.folders = copy;
    }
    if (c.state() != .running or !supportsFolderChanges(c)) return .restart_required;
    try c.notify(.@"workspace/didChangeWorkspaceFolders", .{ .event = .{ .added = added.items, .removed = removed.items } });
    return .notified;
}

fn hasFolder(list: []const protocol.WorkspaceFolder, uri: []const u8) bool {
    for (list) |f| if (eql(f.uri, uri)) return true;
    return false;
}

fn supportsFolderChanges(c: *Client) bool {
    if (c.services.folder_notifications.load(.acquire)) return true;
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);
    const cp = if (c.caps_) |*x| x else return false;
    const ws = cp.raw.workspace orelse return false;
    const wf = ws.workspaceFolders orelse return false;
    const cn = wf.changeNotifications orelse return false;
    return switch (cn) {
        .boolean => |b| b,
        .string => true,
    };
}

/// Tells a server in push mode that settings changed; it then pulls them
/// with `workspace/configuration`. Returns whether it was told.
pub fn settingsChanged(c: *Client) !bool {
    if (!c.services.push_config.load(.acquire) or c.state() != .running) return false;
    try c.notify(.@"workspace/didChangeConfiguration", .{ .settings = .null });
    return true;
}

// ------------------------------------------------------------- window

fn onShowMessage(ctx: ?*anyopaque, _: *Endpoint, n: message.Notification, arena: Allocator) void {
    const c = client(ctx);
    const s = &c.services;
    const p = n.params orelse return;
    const params = p.parseLeaky(protocol.ShowMessageParams, arena, .{ .ignore_unknown_fields = true }) catch return;
    const h = s.opts.host;
    if (params.type == .Error) {
        const now: i64 = std.math.lossyCast(i64, Io.Clock.Timestamp.now(c.io, .awake).raw.nanoseconds);
        const last = s.last_error_toast_ns.load(.acquire);
        const interval: i64 = std.math.lossyCast(i64, s.opts.error_toast_interval.nanoseconds);
        if (now -| last < interval or s.last_error_toast_ns.cmpxchgStrong(last, now, .acq_rel, .acquire) != null) {
            h.logMessage(h.ctx, s.opts.server, params.type, params.message);
            return;
        }
    }
    h.showMessage(h.ctx, s.opts.server, params.type, params.message);
}

fn onLogMessage(ctx: ?*anyopaque, _: *Endpoint, n: message.Notification, arena: Allocator) void {
    const s = &client(ctx).services;
    const p = n.params orelse return;
    const params = p.parseLeaky(protocol.LogMessageParams, arena, .{ .ignore_unknown_fields = true }) catch return;
    s.opts.host.logMessage(s.opts.host.ctx, s.opts.server, params.type, params.message);
}

/// One host answer, shared by the waiting handler and the host callback
/// (the last one to let go frees it).
fn Waiter(comptime T: type) type {
    return struct {
        const W = @This();
        gpa: Allocator,
        io: Io,
        refs: std.atomic.Value(u8) = .init(2),
        answered: std.atomic.Value(bool) = .init(false),
        event: Io.Event = .unset,
        value: ?T = null,

        fn create(gpa: Allocator, io: Io) !*W {
            const w = try gpa.create(W);
            w.* = .{ .gpa = gpa, .io = io };
            return w;
        }

        fn unref(w: *W) void {
            if (w.refs.fetchSub(1, .acq_rel) == 1) w.gpa.destroy(w);
        }

        fn answer(ctx: ?*anyopaque, v: T) void {
            const w: *W = @ptrCast(@alignCast(ctx.?));
            if (!w.answered.swap(true, .acq_rel)) {
                w.value = v;
                w.event.set(w.io);
            }
            w.unref();
        }

        /// The host's answer, or null after `timeout` (or cancelation).
        fn wait(w: *W, timeout: Io.Duration) ?T {
            w.event.waitTimeout(w.io, .{ .duration = .{ .raw = timeout, .clock = .awake } }) catch {
                // The host may be answering right now.
                if (!w.answered.swap(true, .acq_rel)) return null;
                w.event.waitUncancelable(w.io);
            };
            return w.value;
        }
    };
}

fn onShowMessageRequest(ctx: ?*anyopaque, _: *Endpoint, req: message.Request, arena: Allocator) Endpoint.HandlerResult {
    const c = client(ctx);
    const s = &c.services;
    const p = req.params orelse return invalidParams();
    const params = p.parseLeaky(protocol.ShowMessageRequestParams, arena, .{ .ignore_unknown_fields = true }) catch return invalidParams();
    const actions = params.actions orelse &.{};
    const titles = arena.alloc([]const u8, actions.len) catch return internal();
    for (actions, titles) |act, *t| t.* = act.title;

    const W = Waiter(?usize);
    const w = W.create(c.gpa, c.io) catch return internal();
    defer w.unref();
    const h = s.opts.host;
    h.showMessageRequest(h.ctx, s.opts.server, params.type, params.message, titles, .{ .ctx = w, .func = W.answer });
    const choice: ?usize = w.wait(s.opts.reply_timeout) orelse null;
    // Answer with the chosen action item itself (it may carry extra
    // properties), or null.
    if (choice) |i| if (i < actions.len) {
        const raw_actions = actionItems(arena, p.bytes) orelse return nullResult(arena);
        if (i < raw_actions.len) return .{ .result = Endpoint.raw(arena, raw_actions[i]) catch return internal() };
    };
    return nullResult(arena);
}

/// The `actions` of showMessageRequest params as JSON values.
fn actionItems(arena: Allocator, params_json: []const u8) ?[]const std.json.Value {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, params_json, .{}) catch return null;
    if (v != .object) return null;
    const a = v.object.get("actions") orelse return null;
    return if (a == .array) a.array.items else null;
}

fn onShowDocument(ctx: ?*anyopaque, _: *Endpoint, req: message.Request, arena: Allocator) Endpoint.HandlerResult {
    const c = client(ctx);
    const s = &c.services;
    const p = req.params orelse return invalidParams();
    const params = p.parseLeaky(protocol.ShowDocumentParams, arena, .{ .ignore_unknown_fields = true }) catch return invalidParams();
    const W = Waiter(bool);
    const w = W.create(c.gpa, c.io) catch return internal();
    defer w.unref();
    const h = s.opts.host;
    h.showDocument(h.ctx, params.uri, params.external orelse false, params.takeFocus orelse true, params.selection, .{ .ctx = w, .func = W.answer });
    const ok = w.wait(s.opts.reply_timeout) orelse false;
    return .{ .result = Endpoint.raw(arena, protocol.ShowDocumentResult{ .success = ok }) catch return internal() };
}

// ------------------------------------------------------------- progress

fn onProgressCreate(ctx: ?*anyopaque, _: *Endpoint, req: message.Request, arena: Allocator) Endpoint.HandlerResult {
    const s = &client(ctx).services;
    const p = req.params orelse return invalidParams();
    const params = p.parseLeaky(protocol.WorkDoneProgressCreateParams, arena, .{ .ignore_unknown_fields = true }) catch return invalidParams();
    if (s.opts.progress) |t| t.create(s.opts.server, params.token) catch return internal();
    return nullResult(arena);
}

fn onProgress(ctx: ?*anyopaque, _: *Endpoint, n: message.Notification, arena: Allocator) void {
    const s = &client(ctx).services;
    const t = s.opts.progress orelse return;
    const p = n.params orelse return;
    t.onProgress(s.opts.server, p.bytes, arena);
}

// ------------------------------------------------------------- refresh

const refresh_methods = .{
    .{ "workspace/semanticTokens/refresh", host_mod.RefreshFeature.semantic_tokens },
    .{ "workspace/inlayHint/refresh", host_mod.RefreshFeature.inlay_hint },
    .{ "workspace/inlineValue/refresh", host_mod.RefreshFeature.inline_value },
    .{ "workspace/diagnostic/refresh", host_mod.RefreshFeature.diagnostic },
    .{ "workspace/codeLens/refresh", host_mod.RefreshFeature.code_lens },
    .{ "workspace/foldingRange/refresh", host_mod.RefreshFeature.folding_range },
};

fn Refresh(comptime feature: host_mod.RefreshFeature) type {
    return struct {
        fn handle(ctx: ?*anyopaque, _: *Endpoint, _: message.Request, arena: Allocator) Endpoint.HandlerResult {
            const s = &client(ctx).services;
            if (s.opts.refresh) |l| l.func(l.ctx, .{ .server = s.opts.server, .feature = feature });
            return nullResult(arena);
        }
    };
}

// ------------------------------------------------------------- other

fn onLogTrace(ctx: ?*anyopaque, _: *Endpoint, n: message.Notification, _: Allocator) void {
    const c = client(ctx);
    const body = if (n.params) |p| p.bytes else null;
    c.trace.record(.{
        .dir = .recv,
        .kind = .notification,
        .method = "$/logTrace",
        .size = if (body) |b| b.len else 0,
        .at_ns = Io.Clock.Timestamp.now(c.io, .awake).raw.nanoseconds,
        .body = body,
    });
}

/// Telemetry stays in the process (E16): logged, never forwarded.
fn onTelemetry(_: ?*anyopaque, _: *Endpoint, n: message.Notification, _: Allocator) void {
    log.debug("telemetry/event ({d} bytes) dropped", .{if (n.params) |p| p.bytes.len else 0});
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn nullResult(arena: Allocator) Endpoint.HandlerResult {
    const raw = Endpoint.raw(arena, null) catch return internal();
    return .{ .result = raw };
}

fn invalidParams() Endpoint.HandlerResult {
    return .{ .err = .{ .code = message.ErrorCode.invalid_params.int(), .message = "invalid params" } };
}

fn internal() Endpoint.HandlerResult {
    return .{ .err = .{ .code = message.ErrorCode.internal_error.int(), .message = "out of memory" } };
}
