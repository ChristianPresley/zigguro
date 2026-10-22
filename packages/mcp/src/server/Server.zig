//! `zg_mcp.Server`: an MCP server that answers modern (2026-07-28) and
//! legacy (2024-11-05 to 2025-11-25) clients at the same time.
//!
//! Register tools (typed via `addTool`, or `addDynamicTool`), resources and
//! prompts, then attach connections: `connect` takes any byte sink, and
//! `serveInProcess` wires an `InProcPair`. Each connection keeps its own era
//! state (`dispatch.ConnState`); requests that run user code (`tools/call`,
//! `resources/read`, `prompts/get`) run as group tasks, so `Conn.receive`
//! never blocks the reader.

const Server = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const zg_jsonrpc = @import("zg_jsonrpc");
const protocol = @import("../protocol/root.zig");
const InProcPair = @import("../transport/in_process.zig");
const typed = @import("typed.zig");
const Registry = @import("registry.zig");
const Hub = @import("subscriptions.zig");
const dispatch = @import("dispatch.zig");

const messages = protocol.messages;
const codec = protocol.codec;
const Revision = protocol.Revision;
const RequestId = protocol.RequestId;
const message = zg_jsonrpc.message;

pub const DynamicTool = Registry.DynamicTool;
pub const DynHandler = Registry.DynHandler;
pub const ReadHandler = Registry.ReadHandler;
pub const GetHandler = Registry.GetHandler;

/// An authorization decision for one operation.
pub const Decision = union(enum) {
    allow,
    /// Denied by the named policy rule.
    deny: []const u8,
};

/// Decides whether `principal` may perform `operation` on `target`
/// (`"tools/call"`, tool name). Production servers adapt E16's policy
/// engine; tests use allow-all or deny-all fakes.
pub const Authorizer = struct {
    ctx: ?*anyopaque,
    decide: *const fn (ctx: ?*anyopaque, principal: ?[]const u8, operation: []const u8, target: []const u8) Decision,
};

/// Server configuration.
pub const Options = struct {
    info: messages.Implementation,
    instructions: ?[]const u8 = null,
    /// Revisions we answer, any order.
    revisions: []const Revision = &protocol.revision.supported_newest_first,
    /// Items per list page.
    page_size: u32 = 100,
    /// `ttlMs` on modern lists and `server/discover`.
    list_ttl_ms: i64 = 60_000,
    /// `ttlMs` on `resources/read` (resources are volatile by default).
    read_ttl_ms: i64 = 0,
    /// Lists depend on the principal (`cacheScope: private`).
    principal_dependent: bool = false,
    /// Tool calls running at once; the rest wait.
    max_concurrent_calls: usize = 16,
    authorizer: ?Authorizer = null,
};

/// One request being served by user code.
pub const CallCtx = struct {
    server: *Server,
    conn: *Conn,
    /// Request-lifetime memory; results may borrow from it.
    arena: Allocator,
    id: RequestId,
    era: protocol.revision.Era,
    revision: Revision,
    progress_token: ?protocol.ProgressToken = null,
    /// Minimum level of `log` notifications; null sends none.
    log_level: ?messages.LoggingLevel = null,
    canceled: std.atomic.Value(bool) = .init(false),

    /// Whether the client cancelled the request.
    pub fn isCanceled(cc: *const CallCtx) bool {
        return cc.canceled.load(.acquire);
    }

    /// The connection's principal.
    pub fn principal(cc: *const CallCtx) ?[]const u8 {
        return cc.conn.principal;
    }

    /// Reports progress when the client asked for it.
    pub fn progress(cc: *CallCtx, value: f64, total: ?f64, msg: ?[]const u8) void {
        const token = cc.progress_token orelse return;
        if (cc.isCanceled()) return;
        Hub.sendNotification(cc.conn, .{ .progress = .{ .progress_token = token, .progress = value, .total = total, .message = msg } });
    }

    /// Sends a log notification about this request if `level` is at or
    /// above the requested minimum.
    pub fn log(cc: *CallCtx, level: messages.LoggingLevel, data: Value) void {
        const min = cc.log_level orelse return;
        if (@intFromEnum(level) < @intFromEnum(min)) return;
        Hub.sendNotification(cc.conn, .{ .message = .{ .level = level, .logger = cc.server.opts.info.name, .data = data } });
    }
};

/// Where a connection's outgoing messages go. `send` must be thread-safe
/// and must not call back into the connection.
pub const Sink = struct {
    ctx: ?*anyopaque,
    send: *const fn (ctx: ?*anyopaque, body: []const u8) void,
};

/// One client connection.
pub const Conn = struct {
    server: *Server,
    sink: Sink,
    principal: ?[]const u8,
    /// Guards `state`, `arena`, `inflight` and `closed`, and serializes sends.
    mutex: Io.Mutex = .init,
    state: dispatch.ConnState = .{},
    /// Session memory (legacy client info and capabilities, subscriptions).
    arena: std.heap.ArenaAllocator,
    inflight: std.ArrayList(*CallCtx) = .empty,
    closed: bool = false,

    /// Handles one complete JSON-RPC message from the client.
    pub fn receive(c: *Conn, body: []const u8) void {
        dispatch.receive(c, body);
    }

    /// Sends raw bytes to the client (dropped once closed).
    pub fn send(c: *Conn, body: []const u8) void {
        c.mutex.lockUncancelable(c.server.io);
        defer c.mutex.unlock(c.server.io);
        if (!c.closed) c.sink.send(c.sink.ctx, body);
    }

    /// Sends a success response; `result` is written with `std.json.Stringify`.
    pub fn sendResult(c: *Conn, id: RequestId, result: anytype) void {
        var aw: std.Io.Writer.Allocating = .init(c.server.gpa);
        defer aw.deinit();
        message.writeResult(&aw.writer, id, result) catch return;
        c.send(aw.written());
    }

    /// Sends an error response.
    pub fn sendError(c: *Conn, id: RequestId, code: i32, msg: []const u8, data: ?Value) void {
        var aw: std.Io.Writer.Allocating = .init(c.server.gpa);
        defer aw.deinit();
        (if (data) |d| message.writeError(&aw.writer, id, code, msg, d) else message.writeError(&aw.writer, id, code, msg, null)) catch return;
        c.send(aw.written());
    }

    /// Detaches the connection: later sends are dropped and its listen
    /// streams end. Memory is reclaimed by `Server.deinit`.
    pub fn close(c: *Conn) void {
        c.server.hub.dropConn(c);
        c.mutex.lockUncancelable(c.server.io);
        defer c.mutex.unlock(c.server.io);
        c.closed = true;
        for (c.inflight.items) |cc| cc.canceled.store(true, .release);
    }

    fn deinit(c: *Conn) void {
        if (c.state.legacy) |*l| l.subscribed.deinit(c.server.gpa);
        c.inflight.deinit(c.server.gpa);
        c.arena.deinit();
    }

    fn sendToPair(ctx: ?*anyopaque, body: []const u8) void {
        const pair: *InProcPair = @ptrCast(@alignCast(ctx.?));
        pair.serverSend(body);
    }

    fn onPairMessage(ctx: ?*anyopaque, _: *InProcPair, body: []const u8) void {
        const c: *Conn = @ptrCast(@alignCast(ctx.?));
        c.receive(body);
    }
};

gpa: Allocator,
io: Io,
opts: Options,
registry: Registry,
hub: Hub,
/// Server-lifetime memory: capabilities and the copied options.
arena: std.heap.ArenaAllocator,
capabilities: protocol.Capabilities,
conns_mutex: Io.Mutex = .init,
conns: std.ArrayList(*Conn) = .empty,
tasks: Io.Group = .init,
call_slots: Io.Semaphore,

/// Creates a server.
pub fn init(gpa: Allocator, io: Io, opts: Options) error{OutOfMemory}!*Server {
    const s = try gpa.create(Server);
    errdefer gpa.destroy(s);
    s.* = .{
        .gpa = gpa,
        .io = io,
        .opts = opts,
        .registry = try .init(gpa, io),
        .hub = .init(gpa, io),
        .arena = .init(gpa),
        .capabilities = undefined,
        .call_slots = .{ .permits = @max(1, opts.max_concurrent_calls) },
    };
    errdefer s.registry.deinit();
    errdefer s.arena.deinit();
    const a = s.arena.allocator();
    var b: protocol.capabilities.Builder = .init(a);
    try b.set("tools.listChanged", .{ .bool = true });
    try b.set("resources.listChanged", .{ .bool = true });
    try b.set("resources.subscribe", .{ .bool = true });
    try b.set("prompts.listChanged", .{ .bool = true });
    try b.set("completions", null);
    try b.set("logging", null);
    s.capabilities = b.finish();
    s.registry.on_change = .{ .ctx = s, .func = onRegistryChange };
    return s;
}

/// Stops running calls and frees everything, connections included.
pub fn deinit(s: *Server) void {
    s.tasks.cancel(s.io);
    for (s.conns.items) |c| {
        c.deinit();
        s.gpa.destroy(c);
    }
    s.conns.deinit(s.gpa);
    s.hub.deinit();
    s.registry.deinit();
    s.arena.deinit();
    s.gpa.destroy(s);
}

/// Attaches a connection whose messages go to `sink`. `principal`
/// (borrowed for the server's lifetime) identifies the authenticated peer.
pub fn connect(s: *Server, sink: Sink, principal: ?[]const u8) error{OutOfMemory}!*Conn {
    const c = try s.gpa.create(Conn);
    c.* = .{ .server = s, .sink = sink, .principal = principal, .arena = .init(s.gpa) };
    s.conns_mutex.lockUncancelable(s.io);
    defer s.conns_mutex.unlock(s.io);
    s.conns.append(s.gpa, c) catch |err| {
        s.gpa.destroy(c);
        return err;
    };
    return c;
}

/// Serves the server side of `pair`. Close the connection before
/// deinitializing the pair.
pub fn serveInProcess(s: *Server, pair: *InProcPair) error{OutOfMemory}!*Conn {
    const c = try s.connect(.{ .ctx = pair, .send = Conn.sendToPair }, null);
    pair.setServer(.{ .ctx = c, .onMessage = Conn.onPairMessage });
    return c;
}

/// Registers typed tool `T` (see `typed`).
pub fn addTool(s: *Server, comptime T: type) Registry.AddError!void {
    const Spec = typed.ToolSpecOf(T);
    const Adapter = struct {
        fn call(_: ?*anyopaque, cc: *CallCtx, args: Value) anyerror!messages.CallToolResult {
            const a = typed.decode(Spec.Args, cc.arena, args) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return toolError(cc.arena, "invalid arguments: {t}", .{err}),
            };
            const r: typed.ToolReturn(Spec.Output) = try T.call(cc, a);
            switch (r) {
                .tool_error => |m| return toolError(cc.arena, "{s}", .{m}),
                .content => |blocks| return .{ .content = blocks },
                .ok => |ok| {
                    const extra = ok.content orelse &.{};
                    if (Spec.Output == void) return .{ .content = extra };
                    const json = try typed.encodeAlloc(cc.arena, ok.value);
                    const blocks = try cc.arena.alloc(protocol.ContentBlock, 1 + extra.len);
                    blocks[0] = .textBlock(json);
                    @memcpy(blocks[1..], extra);
                    return .{ .content = blocks, .structured_content = try codec.parseValue(cc.arena, json) };
                },
            }
        }
    };
    var scratch: std.heap.ArenaAllocator = .init(s.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const ann = Spec.annotations;
    const def: messages.Tool = .{
        .name = Spec.name,
        .title = ann.title,
        .description = Spec.description,
        .input_schema = codec.parseValue(a, Spec.input_schema) catch return error.OutOfMemory,
        .output_schema = if (Spec.output_schema) |o| codec.parseValue(a, o) catch return error.OutOfMemory else null,
        .annotations = .{
            .title = ann.title,
            .read_only_hint = ann.read_only_hint,
            .destructive_hint = ann.destructive_hint,
            .idempotent_hint = ann.idempotent_hint,
            .open_world_hint = ann.open_world_hint,
        },
    };
    return s.registry.addTool(def, .{ .ctx = null, .call = Adapter.call });
}

/// Registers a tool described at runtime; its schema is compiled here.
pub fn addDynamicTool(s: *Server, t: DynamicTool) Registry.AddError!void {
    return s.registry.addTool(t.def, t.handler);
}

/// Removes a tool; false when there is none.
pub fn removeTool(s: *Server, name: []const u8) error{OutOfMemory}!bool {
    return s.registry.removeTool(name);
}

/// Registers a resource.
pub fn addResource(s: *Server, def: messages.Resource, handler: ReadHandler) Registry.AddError!void {
    return s.registry.addResource(def, handler);
}

/// Removes a resource; false when there is none.
pub fn removeResource(s: *Server, uri: []const u8) error{OutOfMemory}!bool {
    return s.registry.removeResource(uri);
}

/// Registers a resource template.
pub fn addResourceTemplate(s: *Server, def: messages.ResourceTemplate) Registry.AddError!void {
    return s.registry.addTemplate(def);
}

/// Registers a prompt.
pub fn addPrompt(s: *Server, def: messages.Prompt, handler: GetHandler) Registry.AddError!void {
    return s.registry.addPrompt(def, handler);
}

/// Removes a prompt; false when there is none.
pub fn removePrompt(s: *Server, name: []const u8) error{OutOfMemory}!bool {
    return s.registry.removePrompt(name);
}

/// Tells subscribers that the resource at `uri` changed.
pub fn resourceUpdated(s: *Server, uri: []const u8) void {
    s.hub.resourceUpdated(uri);
    s.conns_mutex.lockUncancelable(s.io);
    defer s.conns_mutex.unlock(s.io);
    for (s.conns.items) |c| {
        const subscribed = blk: {
            c.mutex.lockUncancelable(s.io);
            defer c.mutex.unlock(s.io);
            const l = c.state.legacy orelse break :blk false;
            break :blk l.initialized and l.subscribed.contains(uri);
        };
        if (subscribed) Hub.sendNotification(c, .{ .resources_updated = .{ .uri = uri } });
    }
}

/// Ends every `subscriptions/listen` stream gracefully (shutdown).
pub fn endSubscriptions(s: *Server) void {
    s.hub.endAll(s.opts.info);
}

fn onRegistryChange(ctx: ?*anyopaque, k: Registry.ListKind) void {
    const s: *Server = @ptrCast(@alignCast(ctx.?));
    s.hub.listChanged(k);
    s.conns_mutex.lockUncancelable(s.io);
    defer s.conns_mutex.unlock(s.io);
    for (s.conns.items) |c| {
        const initialized = blk: {
            c.mutex.lockUncancelable(s.io);
            defer c.mutex.unlock(s.io);
            const l = c.state.legacy orelse break :blk false;
            break :blk l.initialized;
        };
        if (initialized) Hub.sendNotification(c, Hub.listChangedNote(k, null));
    }
}

/// A `CallToolResult` with `isError` and one text block.
pub fn toolError(arena: Allocator, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!messages.CallToolResult {
    const text = try std.fmt.allocPrint(arena, fmt, args);
    const blocks = try arena.alloc(protocol.ContentBlock, 1);
    blocks[0] = .textBlock(text);
    return .{ .content = blocks, .is_error = true };
}

test {
    _ = @import("server_test.zig");
}
