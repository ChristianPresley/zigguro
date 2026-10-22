//! Per-message era selection and the server method table.
//!
//! Era per message (VERS "dual-era server"):
//! - `initialize` makes the connection legacy and negotiates its revision
//!   (the client's if we support it, else our newest legacy one);
//! - a request whose `_meta` has `io.modelcontextprotocol/protocolVersion`
//!   is modern and stateless; `clientCapabilities` must be there too
//!   (`-32602`), and an unsupported version is `-32022` listing ours;
//! - anything else uses the connection's legacy session, and without one
//!   is `-32602` naming the supported versions (we do not assume
//!   2025-03-26 for a client that skipped `initialize`).
//!
//! Modern results carry `resultType` and `_meta` serverInfo; modern lists
//! and reads also carry `ttlMs` and `cacheScope`. List pages are serialized
//! once per (list, era, offset) and cached on the registry snapshot.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const zg_jsonrpc = @import("zg_jsonrpc");
const protocol = @import("../protocol/root.zig");
const schema = @import("../schema/root.zig");
const Server = @import("Server.zig");
const Registry = @import("registry.zig");
const pagination = @import("pagination.zig");
const mrtr_seal = @import("mrtr_seal.zig");
const legacy_requests = @import("legacy_requests.zig");

const messages = protocol.messages;
const codec = protocol.codec;
const errors = protocol.errors;
const meta_keys = protocol.meta_keys;
const Revision = protocol.Revision;
const Era = protocol.revision.Era;
const RequestId = protocol.RequestId;
const Conn = Server.Conn;
const CallCtx = Server.CallCtx;
const message = zg_jsonrpc.message;

/// A legacy session, established by `initialize`.
pub const Legacy = struct {
    revision: Revision,
    caps: protocol.ClientCapabilities,
    client_info: messages.Implementation,
    initialized: bool = false,
    log_level: ?messages.LoggingLevel = null,
    /// URIs from `resources/subscribe` (keys live in the connection arena).
    subscribed: std.StringArrayHashMapUnmanaged(void) = .empty,
};

/// What a connection remembers between messages.
pub const ConnState = struct {
    /// The era of the last request served.
    era: ?Era = null,
    legacy: ?Legacy = null,
};

/// The era context of one request.
const Ctx = struct {
    era: Era,
    revision: Revision,
    meta: protocol.RequestMeta,
    log_level: ?messages.LoggingLevel,
    client_caps: protocol.ClientCapabilities = .empty,
};

const Failure = struct { code: i32, msg: []const u8, data: ?Value = null };

/// Handles one message from the client.
pub fn receive(conn: *Conn, body: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(conn.server.gpa);
    var handed_off = false;
    defer if (!handed_off) arena.deinit();
    const a = arena.allocator();
    const msg = switch (message.parse(a, body)) {
        .single => |m| m,
        .batch => return conn.sendError(.null, errors.invalid_request, "Batches are not supported", null),
        .invalid => |e| return conn.sendError(.null, e.code, e.message, null),
    };
    switch (msg) {
        .response => |r| legacy_requests.onResponse(conn, r),
        .notification => |n| notification(conn, a, n),
        .request => |r| handed_off = request(conn, &arena, r),
    }
}

fn notification(conn: *Conn, a: Allocator, n: message.Notification) void {
    const s = conn.server;
    if (std.mem.eql(u8, n.method, "notifications/initialized")) {
        conn.mutex.lockUncancelable(s.io);
        defer conn.mutex.unlock(s.io);
        if (conn.state.legacy) |*l| l.initialized = true;
    } else if (std.mem.eql(u8, n.method, "notifications/cancelled")) {
        const p = codec.decodeParams(messages.Cancelled, a, n.params, .{}) catch return;
        const id = p.request_id orelse return;
        if (s.hub.cancel(conn, id)) return;
        conn.mutex.lockUncancelable(s.io);
        defer conn.mutex.unlock(s.io);
        for (conn.inflight.items) |cc| if (cc.id.eql(id)) cc.canceled.store(true, .release);
    }
    // notifications/roots/list_changed and unknown notifications: nothing to do yet.
}

/// Serves request `r`. Returns true when a task took ownership of `arena`.
fn request(conn: *Conn, arena: *std.heap.ArenaAllocator, r: message.Request) bool {
    const a = arena.allocator();
    const params: Value = if (r.params) |p| codec.parseValue(a, p.bytes) catch {
        conn.sendError(r.id, errors.invalid_params, "params are not valid JSON", null);
        return false;
    } else .{ .object = .empty };
    if (params != .object) {
        conn.sendError(r.id, errors.invalid_params, "params must be an object", null);
        return false;
    }
    if (std.mem.eql(u8, r.method, "initialize")) {
        initialize(conn, a, r.id, params);
        return false;
    }
    const ctx = switch (classify(conn, a, params) catch {
        conn.sendError(r.id, errors.internal_error, "out of memory", null);
        return false;
    }) {
        .ok => |c| c,
        .refused => |f| {
            conn.sendError(r.id, f.code, f.msg, f.data);
            return false;
        },
    };
    const m = messages.Method.fromString(r.method) orelse {
        conn.sendError(r.id, errors.method_not_found, "Method not found", null);
        return false;
    };
    if (!allowed(ctx.era, m)) {
        conn.sendError(r.id, errors.method_not_found, "Method not found", null);
        return false;
    }
    serve(conn, arena, r.id, m, params, ctx) catch |err| switch (err) {
        error.OutOfMemory => conn.sendError(r.id, errors.internal_error, "out of memory", null),
        error.HandedOff => return true,
    };
    return false;
}

const Classified = union(enum) { ok: Ctx, refused: Failure };

fn classify(conn: *Conn, a: Allocator, params: Value) error{OutOfMemory}!Classified {
    const s = conn.server;
    const meta_v = params.object.get("_meta");
    const meta: protocol.RequestMeta = if (meta_v) |mv|
        codec.decodeFromValue(protocol.RequestMeta, a, mv, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .refused = .{ .code = errors.invalid_params, .msg = "malformed _meta" } },
        }
    else
        .{};
    if (meta.protocol_version) |pv| {
        const rev = Revision.parse(pv);
        const ok = if (rev) |r| r.era() == .modern and supports(s, r) else false;
        if (!ok) return .{ .refused = .{
            .code = errors.unsupported_protocol_version,
            .msg = "Unsupported protocol version",
            .data = try unsupportedData(s, a, pv),
        } };
        if (meta.client_capabilities == null) return .{ .refused = .{
            .code = errors.invalid_params,
            .msg = "missing _meta \"" ++ meta_keys.client_capabilities ++ "\"",
        } };
        conn.mutex.lockUncancelable(s.io);
        conn.state.era = .modern;
        conn.mutex.unlock(s.io);
        return .{ .ok = .{ .era = .modern, .revision = rev.?, .meta = meta, .log_level = meta.log_level, .client_caps = meta.client_capabilities.? } };
    }
    conn.mutex.lockUncancelable(s.io);
    defer conn.mutex.unlock(s.io);
    if (conn.state.legacy) |l| {
        conn.state.era = .legacy;
        return .{ .ok = .{ .era = .legacy, .revision = l.revision, .meta = meta, .log_level = l.log_level, .client_caps = l.caps } };
    }
    return .{ .refused = .{ .code = errors.invalid_params, .msg = try std.fmt.allocPrint(
        a,
        "missing _meta \"{s}\"; supported versions: {s} (legacy versions need initialize)",
        .{ meta_keys.protocol_version, try versionList(s, a) },
    ) } };
}

fn supports(s: *Server, r: Revision) bool {
    return std.mem.indexOfScalar(Revision, s.opts.revisions, r) != null;
}

/// Our revisions, newest first, as wire strings.
fn supportedStrings(s: *Server, a: Allocator) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (protocol.revision.supported_newest_first) |r| if (supports(s, r)) try out.append(a, r.string());
    return out.items;
}

fn versionList(s: *Server, a: Allocator) error{OutOfMemory}![]const u8 {
    return std.mem.join(a, ", ", try supportedStrings(s, a));
}

fn unsupportedData(s: *Server, a: Allocator, requested: []const u8) error{OutOfMemory}!Value {
    return codec.toValue(a, protocol.errors.UnsupportedProtocolVersionData{
        .supported = try supportedStrings(s, a),
        .requested = requested,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}

/// Whether era `e` has method `m` on the server side.
fn allowed(e: Era, m: messages.Method) bool {
    return switch (m) {
        .server_discover, .subscriptions_listen => e == .modern,
        .ping, .logging_set_level, .resources_subscribe, .resources_unsubscribe => e == .legacy,
        .tools_list, .tools_call, .resources_list, .resources_read, .resources_templates_list, .prompts_list, .prompts_get, .completion_complete => true,
        else => false,
    };
}

fn initialize(conn: *Conn, a: Allocator, id: RequestId, params: Value) void {
    const s = conn.server;
    // Session data outlives the request: decode into the connection arena.
    conn.mutex.lockUncancelable(s.io);
    const p = codec.decodeFromValue(messages.InitializeParams, conn.arena.allocator(), params, .{}) catch {
        conn.mutex.unlock(s.io);
        return conn.sendError(id, errors.invalid_params, "invalid initialize params", null);
    };
    const requested = Revision.parse(p.protocol_version);
    const rev: ?Revision = if (requested) |r| (if (r.era() == .legacy and supports(s, r)) r else null) else null;
    const chosen = rev orelse newestLegacy(s) orelse {
        conn.mutex.unlock(s.io);
        const data = unsupportedData(s, a, p.protocol_version) catch null;
        return conn.sendError(id, errors.unsupported_protocol_version, "No legacy protocol version is supported", data);
    };
    if (conn.state.legacy) |*old| old.subscribed.deinit(s.gpa);
    conn.state.legacy = .{ .revision = chosen, .caps = p.capabilities, .client_info = p.client_info };
    conn.state.era = .legacy;
    conn.mutex.unlock(s.io);
    conn.sendResult(id, codec.json(messages.InitializeResult{
        .protocol_version = chosen.string(),
        .capabilities = s.capabilities,
        .server_info = s.opts.info,
        .instructions = s.opts.instructions,
    }));
}

fn newestLegacy(s: *Server) ?Revision {
    for (protocol.revision.supported_newest_first) |r| if (r.era() == .legacy and supports(s, r)) return r;
    return null;
}

const ServeError = error{ OutOfMemory, HandedOff };

fn serve(conn: *Conn, arena: *std.heap.ArenaAllocator, id: RequestId, m: messages.Method, params: Value, ctx: Ctx) ServeError!void {
    const s = conn.server;
    const a = arena.allocator();
    switch (m) {
        .server_discover => sendOk(conn, id, ctx, messages.DiscoverResult{
            .supported_versions = try supportedStrings(s, a),
            .capabilities = s.capabilities,
            .instructions = s.opts.instructions,
            .ttl_ms = s.opts.list_ttl_ms,
            .cache_scope = cacheScope(s),
        }),
        .ping => sendOk(conn, id, ctx, messages.EmptyResult{}),
        .logging_set_level => {
            const p = decodeOr(messages.SetLevelParams, conn, a, id, params) orelse return;
            conn.mutex.lockUncancelable(s.io);
            if (conn.state.legacy) |*l| l.log_level = p.level;
            conn.mutex.unlock(s.io);
            sendOk(conn, id, ctx, messages.EmptyResult{});
        },
        .resources_subscribe, .resources_unsubscribe => {
            const p = decodeOr(messages.SubscribeParams, conn, a, id, params) orelse return;
            {
                conn.mutex.lockUncancelable(s.io);
                defer conn.mutex.unlock(s.io);
                const l = &conn.state.legacy.?;
                if (m == .resources_subscribe) {
                    if (!l.subscribed.contains(p.uri))
                        try l.subscribed.put(s.gpa, try conn.arena.allocator().dupe(u8, p.uri), {});
                } else _ = l.subscribed.orderedRemove(p.uri);
            }
            sendOk(conn, id, ctx, messages.EmptyResult{});
        },
        .tools_list => try list(conn, id, ctx, .tools, params),
        .resources_list => try list(conn, id, ctx, .resources, params),
        .resources_templates_list => try list(conn, id, ctx, .templates, params),
        .prompts_list => try list(conn, id, ctx, .prompts, params),
        .completion_complete => sendOk(conn, id, ctx, messages.CompleteResult{ .completion = .{ .values = &.{} } }),
        .subscriptions_listen => {
            const p = decodeOr(messages.SubscriptionsListenParams, conn, a, id, params) orelse return;
            try s.hub.listen(conn, id, p.notifications);
        },
        .tools_call, .resources_read, .prompts_get => {
            try spawn(conn, arena, id, m, params, ctx);
            return error.HandedOff;
        },
        else => unreachable,
    }
}

fn decodeOr(comptime T: type, conn: *Conn, a: Allocator, id: RequestId, params: Value) ?T {
    return codec.decodeFromValue(T, a, params, .{}) catch {
        conn.sendError(id, errors.invalid_params, "invalid params for " ++ @typeName(T), null);
        return null;
    };
}

fn cacheScope(s: *Server) messages.CacheScope {
    return if (s.opts.principal_dependent) .private else .public;
}

/// Sends a complete result, adding `resultType` and `_meta` serverInfo for
/// modern requests.
fn sendOk(conn: *Conn, id: RequestId, ctx: Ctx, value: anytype) void {
    var v = value;
    if (ctx.era == .modern) {
        v.meta = .{ .server_info = conn.server.opts.info };
        conn.sendResult(id, codec.withResultType(.complete, v));
    } else conn.sendResult(id, codec.json(v));
}

// ---------------------------------------------------------------- lists

const PageBuild = struct {
    s: *Server,
    snap: *Registry.Snapshot,
    key: Registry.PageKey,
};

fn list(conn: *Conn, id: RequestId, ctx: Ctx, comptime k: Registry.ListKind, params: Value) error{OutOfMemory}!void {
    const s = conn.server;
    const snap = s.registry.snapshot();
    const cursor: ?[]const u8 = if (params.object.get("cursor")) |c| switch (c) {
        .string => |str| str,
        .null => null,
        else => return conn.sendError(id, errors.invalid_params, "cursor must be a string", null),
    } else null;
    const offset = pagination.offsetFor(cursor, snap.version, snap.len(k)) catch
        return conn.sendError(id, errors.invalid_params, "Invalid cursor", null);
    const key: Registry.PageKey = .{ .list = k, .era = ctx.era, .offset = offset };
    const bytes = try snap.page(s.io, s.gpa, key, PageBuild{ .s = s, .snap = snap, .key = key }, buildPage(k));
    conn.sendResult(id, message.RawJson{ .bytes = bytes });
}

fn buildPage(comptime k: Registry.ListKind) fn (PageBuild, Allocator) error{OutOfMemory}![]u8 {
    return struct {
        fn build(b: PageBuild, gpa: Allocator) error{OutOfMemory}![]u8 {
            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();
            const a = scratch.allocator();
            const entries = switch (k) {
                .tools => b.snap.tools,
                .resources => b.snap.resources,
                .templates => b.snap.templates,
                .prompts => b.snap.prompts,
            };
            const items, const more = pagination.page(@TypeOf(entries[0]), entries, b.key.offset, b.s.opts.page_size);
            const Def = @FieldType(@typeInfo(@TypeOf(entries[0])).pointer.child, "def");
            const defs = try a.alloc(Def, items.len);
            for (items, defs) |e, *d| d.* = e.def;
            var cbuf: [pagination.encoded_len]u8 = undefined;
            const next: ?[]const u8 = if (more) pagination.encode(&cbuf, .{
                .offset = b.key.offset + @as(u32, @intCast(items.len)),
                .version = b.snap.version,
            }) else null;
            const modern = b.key.era == .modern;
            const ttl: ?i64 = if (modern) b.s.opts.list_ttl_ms else null;
            const scope: ?messages.CacheScope = if (modern) cacheScope(b.s) else null;
            const meta: ?protocol.meta.ResultMeta = if (modern) .{ .server_info = b.s.opts.info } else null;
            const result = switch (k) {
                .tools => messages.ListToolsResult{ .tools = defs, .next_cursor = next, .ttl_ms = ttl, .cache_scope = scope, .meta = meta },
                .resources => messages.ListResourcesResult{ .resources = defs, .next_cursor = next, .ttl_ms = ttl, .cache_scope = scope, .meta = meta },
                .templates => messages.ListResourceTemplatesResult{ .resource_templates = defs, .next_cursor = next, .ttl_ms = ttl, .cache_scope = scope, .meta = meta },
                .prompts => messages.ListPromptsResult{ .prompts = defs, .next_cursor = next, .ttl_ms = ttl, .cache_scope = scope, .meta = meta },
            };
            var aw: std.Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();
            var st: std.json.Stringify = .{ .writer = &aw.writer };
            (if (modern) st.write(codec.withResultType(.complete, result)) else st.write(codec.json(result))) catch return error.OutOfMemory;
            return aw.toOwnedSlice();
        }
    }.build;
}

// ---------------------------------------------------------------- calls

/// Runs a request that calls user code as a group task owning `arena`.
fn spawn(conn: *Conn, arena: *std.heap.ArenaAllocator, id: RequestId, m: messages.Method, params: Value, ctx: Ctx) error{OutOfMemory}!void {
    const s = conn.server;
    const Job = struct { cc: CallCtx, arena: std.heap.ArenaAllocator, method: messages.Method, params: Value };
    const job = try s.gpa.create(Job);
    job.* = .{
        .cc = .{
            .server = s,
            .conn = conn,
            .arena = undefined,
            .id = id,
            .era = ctx.era,
            .revision = ctx.revision,
            .client_caps = ctx.client_caps,
            .progress_token = ctx.meta.progress_token,
            .log_level = ctx.log_level,
        },
        .arena = arena.*,
        .method = m,
        .params = params,
    };
    job.cc.arena = job.arena.allocator();
    {
        conn.mutex.lockUncancelable(s.io);
        defer conn.mutex.unlock(s.io);
        conn.inflight.append(s.gpa, &job.cc) catch |err| {
            s.gpa.destroy(job);
            return err;
        };
    }
    const Run = struct {
        fn run(j: *Job) Io.Cancelable!void {
            const c = j.cc.conn;
            const sv = j.cc.server;
            defer {
                c.mutex.lockUncancelable(sv.io);
                for (c.inflight.items, 0..) |x, i| if (x == &j.cc) {
                    _ = c.inflight.swapRemove(i);
                    break;
                };
                const free_conn = c.release and c.inflight.items.len == 0;
                c.mutex.unlock(sv.io);
                j.arena.deinit();
                sv.gpa.destroy(j);
                if (free_conn) sv.destroyConn(c);
            }
            const ctx2: Ctx = .{ .era = j.cc.era, .revision = j.cc.revision, .meta = .{}, .log_level = j.cc.log_level };
            switch (j.method) {
                .tools_call => callTool(&j.cc, j.params, ctx2),
                .resources_read => readResource(&j.cc, j.params, ctx2),
                .prompts_get => getPrompt(&j.cc, j.params, ctx2),
                else => unreachable,
            }
        }
    };
    // The arena moved into the job.
    arena.* = .init(s.gpa);
    s.tasks.concurrent(s.io, Run.run, .{job}) catch {
        // No spare thread: run here (the reader blocks for this call).
        Run.run(job) catch {};
    };
}

fn callTool(cc: *CallCtx, params: Value, ctx: Ctx) void {
    const s = cc.server;
    const conn = cc.conn;
    const a = cc.arena;
    const p = codec.decodeFromValue(messages.CallToolParams, a, params, .{}) catch
        return conn.sendError(cc.id, errors.invalid_params, "invalid tools/call params", null);
    const tool = s.registry.snapshot().tool(p.name) orelse
        return conn.sendError(cc.id, errors.invalid_params, std.fmt.allocPrint(a, "Unknown tool: {s}", .{p.name}) catch "Unknown tool", null);
    const args = p.arguments orelse Value{ .object = .empty };
    const result = run: {
        var out: schema.Output = .init(s.gpa);
        defer out.deinit();
        const valid = schema.validate(tool.input, s.gpa, args, &out) catch false;
        if (!valid) {
            const first = if (out.errors.items.len > 0) out.errors.items[0] else null;
            break :run if (first) |e|
                Server.toolError(a, "invalid arguments: {s}: {s}", .{ if (e.instance_location.len == 0) "/" else e.instance_location, e.message })
            else
                Server.toolError(a, "invalid arguments", .{});
        }
        if (s.opts.authorizer) |auth| switch (auth.decide(auth.ctx, conn.principal, "tools/call", p.name)) {
            .allow => {},
            .deny => |rule| break :run Server.toolError(a, "denied by zigguro policy: {s}", .{rule}),
        };
        s.call_slots.wait(s.io) catch return;
        defer s.call_slots.post(s.io);
        if (cc.isCanceled()) return;
        const Inv = struct {
            h: Registry.DynHandler,
            args: Value,
            fn call(i: @This(), c: *CallCtx) anyerror!messages.CallToolResult {
                return i.h.call(i.h.ctx, c, i.args);
            }
        };
        const outcome = withInput(messages.CallToolResult, cc, ctx, .tools_call, params, Inv{ .h = tool.handler, .args = args }, Inv.call) orelse return;
        break :run outcome catch |err| switch (err) {
            error.OutOfMemory => Server.toolError(a, "out of memory", .{}),
            else => Server.toolError(a, "tool failed: {t}", .{err}),
        };
    } catch return conn.sendError(cc.id, errors.internal_error, "out of memory", null);
    if (cc.isCanceled()) return;
    sendOk(conn, cc.id, ctx, result);
}

fn readResource(cc: *CallCtx, params: Value, ctx: Ctx) void {
    const s = cc.server;
    const conn = cc.conn;
    const p = codec.decodeFromValue(messages.ReadResourceParams, cc.arena, params, .{}) catch
        return conn.sendError(cc.id, errors.invalid_params, "invalid resources/read params", null);
    const res = s.registry.snapshot().resource(p.uri) orelse {
        // Legacy revisions use -32002; modern ones -32602 (RESOURCES "Errors").
        const code = if (ctx.era == .modern) errors.invalid_params else errors.legacy_resource_not_found;
        return conn.sendError(cc.id, code, "Resource not found", null);
    };
    const Inv = struct {
        h: Registry.ReadHandler,
        uri: []const u8,
        fn call(i: @This(), c: *CallCtx) anyerror![]const protocol.content.ResourceContents {
            return i.h.read(i.h.ctx, c, i.uri);
        }
    };
    const outcome = withInput([]const protocol.content.ResourceContents, cc, ctx, .resources_read, params, Inv{ .h = res.handler, .uri = p.uri }, Inv.call) orelse return;
    const contents = outcome catch |err|
        return conn.sendError(cc.id, errors.internal_error, @errorName(err), null);
    if (cc.isCanceled()) return;
    const modern = ctx.era == .modern;
    sendOk(conn, cc.id, ctx, messages.ReadResourceResult{
        .contents = contents,
        .ttl_ms = if (modern) s.opts.read_ttl_ms else null,
        .cache_scope = if (modern) cacheScope(s) else null,
    });
}

fn getPrompt(cc: *CallCtx, params: Value, ctx: Ctx) void {
    const s = cc.server;
    const conn = cc.conn;
    const p = codec.decodeFromValue(messages.GetPromptParams, cc.arena, params, .{}) catch
        return conn.sendError(cc.id, errors.invalid_params, "invalid prompts/get params", null);
    const prompt = s.registry.snapshot().prompt(p.name) orelse
        return conn.sendError(cc.id, errors.invalid_params, "Unknown prompt", null);
    const Inv = struct {
        h: Registry.GetHandler,
        args: ?Value,
        fn call(i: @This(), c: *CallCtx) anyerror!messages.GetPromptResult {
            return i.h.get(i.h.ctx, c, i.args);
        }
    };
    const outcome = withInput(messages.GetPromptResult, cc, ctx, .prompts_get, params, Inv{ .h = prompt.handler, .args = p.arguments }, Inv.call) orelse return;
    const result = outcome catch |err|
        return conn.sendError(cc.id, errors.internal_error, @errorName(err), null);
    if (cc.isCanceled()) return;
    sendOk(conn, cc.id, ctx, result);
}

// ---------------------------------------------------------------- input (MRTR)

/// Runs `f` until it stops asking for input (`CallCtx.elicit` and co.).
/// Modern: an input request ends the call with `input_required` and a
/// sealed `requestState`; the retry comes back here with the answers.
/// Legacy: the requests go to the client on the session and `f` runs
/// again. Null means a reply (or, once canceled, nothing) was sent.
fn withInput(comptime R: type, cc: *CallCtx, ctx: Ctx, m: messages.Method, params: Value, inv: anytype, comptime f: fn (@TypeOf(inv), *CallCtx) anyerror!R) ?(anyerror!R) {
    const s = cc.server;
    const conn = cc.conn;
    if (ctx.era == .modern) prepareModern(cc, m, params) catch |err| {
        if (err == error.OutOfMemory) {
            conn.sendError(cc.id, errors.internal_error, "out of memory", null);
        } else conn.sendError(cc.id, errors.invalid_params, "invalid or expired requestState", null);
        return null;
    };
    while (true) {
        cc.input_requests.clearRetainingCapacity();
        cc.missing_capability = null;
        const r = f(inv, cc);
        if (r) |_| return r else |err| switch (err) {
            error.InputRequired => {
                if (cc.isCanceled()) return null;
                if (cc.input_requests.items.len == 0) return r;
                if (cc.round >= s.opts.max_input_rounds) {
                    conn.sendError(cc.id, errors.invalid_params, "too many input rounds", null);
                    return null;
                }
                if (ctx.era == .modern) {
                    sendInputRequired(cc, m, params) catch conn.sendError(cc.id, errors.internal_error, "out of memory", null);
                    return null;
                }
                legacy_requests.roundTrip(cc) catch |e| switch (e) {
                    error.Canceled => return null,
                    else => {
                        conn.sendError(cc.id, errors.internal_error, "out of memory", null);
                        return null;
                    },
                };
                cc.round += 1;
                if (cc.next_state) |st| cc.prev_state = st;
            },
            error.CapabilityMissing => {
                sendMissing(cc);
                return null;
            },
            error.Canceled => if (cc.isCanceled()) return null else return r,
            else => return r,
        }
    }
}

const PrepareError = mrtr_seal.OpenError || error{InvalidResponses};

/// Takes a modern retry's `inputResponses` and opens its `requestState`.
fn prepareModern(cc: *CallCtx, m: messages.Method, params: Value) PrepareError!void {
    const s = cc.server;
    var fresh: messages.InputResponses = .{};
    if (params.object.get("inputResponses")) |ir| {
        if (ir != .null) fresh = codec.decodeFromValue(messages.InputResponses, cc.arena, ir, .{}) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidResponses,
        };
    }
    cc.input_responses = fresh;
    const token_v = params.object.get("requestState") orelse return;
    if (token_v != .string) return error.Invalid;
    const digest = try mrtr_seal.paramsDigest(cc.arena, params);
    var ad: [mrtr_seal.ad_len]u8 = undefined;
    const p = try s.sealer.open(cc.arena, token_v.string, mrtr_seal.associatedData(&ad, m, digest));
    try mrtr_seal.check(p, nowMs(s.io), mrtr_seal.principalHash(cc.conn.principal, ""), m, digest);
    cc.round = p.round;
    // The sealed state: the handler's own and the earlier rounds' answers
    // (a retry carries only the last round's).
    const sealed = codec.decodeBytes(SealedState, cc.arena, p.handler_state, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Invalid,
    };
    cc.prev_state = sealed.state;
    var all: std.ArrayList(messages.InputResponses.Entry) = .empty;
    try all.appendSlice(cc.arena, fresh.entries);
    if (sealed.answers) |old| for (old.entries) |e| if (fresh.get(e.key) == null) try all.append(cc.arena, e);
    cc.input_responses = .{ .entries = all.items };
}

/// What `requestState` carries for the dispatcher.
const SealedState = struct {
    state: ?[]const u8 = null,
    answers: ?messages.InputResponses = null,
};

fn nowMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}

fn sendInputRequired(cc: *CallCtx, m: messages.Method, params: Value) error{OutOfMemory}!void {
    const s = cc.server;
    const digest = try mrtr_seal.paramsDigest(cc.arena, params);
    const state = try codec.encodeAlloc(cc.arena, SealedState{
        .state = cc.next_state orelse cc.prev_state,
        .answers = if (cc.input_responses.entries.len > 0) cc.input_responses else null,
    });
    const token = try s.sealer.seal(s.io, cc.arena, .{
        .principal_hash = mrtr_seal.principalHash(cc.conn.principal, ""),
        .expires_at_ms = nowMs(s.io) + s.opts.request_state_ttl_ms,
        .method = m,
        .params_digest = digest,
        .handler_state = state,
        .round = cc.round + 1,
    });
    if (cc.isCanceled()) return;
    cc.conn.sendResult(cc.id, codec.withResultType(.input_required, messages.InputRequiredResult{
        .input_requests = .{ .entries = cc.input_requests.items },
        .request_state = token,
        .meta = .{ .server_info = s.opts.info },
    }));
}

/// `-32021` naming the capability the handler needed.
fn sendMissing(cc: *CallCtx) void {
    const cap = cc.missing_capability orelse "elicitation";
    var b: protocol.capabilities.Builder = .init(cc.arena);
    b.set(cap, null) catch return cc.conn.sendError(cc.id, errors.internal_error, "out of memory", null);
    const data = codec.toValue(cc.arena, errors.MissingRequiredClientCapabilityData{ .required_capabilities = b.finish() }) catch
        return cc.conn.sendError(cc.id, errors.internal_error, "out of memory", null);
    cc.conn.sendError(cc.id, errors.missing_required_client_capability, "Missing required client capability", data);
}
