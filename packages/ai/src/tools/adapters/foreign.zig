//! Tools exported by other packages (E10.F06.S03.T01).
//!
//! zg_lsp, zg_dap, the task runner, zg_workspace, zg_notes, zg_scm and
//! zg_mcp sit on zg_ai's layer, so they cannot build `proto.ToolSpec`s.
//! They export tools through `Exporter` instead, which uses only std
//! types, and answer calls with an MCP `CallToolResult` as JSON text. The
//! app wires each package's exporter in; `Adapter` turns it into a
//! registry source:
//!
//! - names stay as exported (MCP tools are namespaced by the registry);
//! - effects come from the exporter, and for MCP from the tool
//!   annotations, which count only for servers the user trusts;
//! - each call has a deadline (30 s LSP and debug, 10 s search and notes,
//!   60 s SCM, 120 s tasks and MCP);
//! - a mutating tool must answer with an E12 changeset. One that does not
//!   fails closed: the model gets an error and the result is dropped.

const std = @import("std");
const proto = @import("zg_ai_proto");
const registry = @import("../registry.zig");
const ratelimit = @import("../../provider/ratelimit.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.ai_tools);

/// What `Exporter.subscribe_changed` registers.
pub const ChangedCb = registry.ChangedCb;

pub const Kind = enum {
    lsp,
    debug,
    tasks,
    workspace,
    notes,
    scm,
    mcp,

    /// The default deadline of a call, in ms.
    pub fn deadlineMs(k: Kind) u64 {
        return switch (k) {
            .lsp, .debug => 30_000,
            .workspace, .notes => 10_000,
            .scm => 60_000,
            .tasks, .mcp => 120_000,
        };
    }
};

/// MCP tool annotations (hints, not guarantees).
pub const Annotations = struct {
    title: ?[]const u8 = null,
    read_only_hint: ?bool = null,
    destructive_hint: ?bool = null,
    idempotent_hint: ?bool = null,
    open_world_hint: ?bool = null,
};

pub const ForeignTool = struct {
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8,
    /// Package exporters: whether the tool only reads.
    read_only: bool = false,
    /// Changes workspace content; must answer with a changeset (E12).
    mutates: bool = false,
    /// MCP annotations.
    annotations: Annotations = .{},
};

/// What a call returns: an MCP `CallToolResult` as JSON text, and the E12
/// changeset holding any change it proposed.
pub const Result = struct {
    json: []const u8,
    changeset: ?u64 = null,
};

pub const Exporter = struct {
    /// The subsystem, or the configured MCP server name.
    name: []const u8,
    kind: Kind,
    /// MCP: whether the server's annotations are believed (E11 config).
    trusted: bool = false,
    ctx: *anyopaque,
    /// The tools, allocated in `arena`.
    list: *const fn (ctx: *anyopaque, arena: Allocator) anyerror![]const ForeignTool,
    /// Calls `tool` (its exported name); allocates in `arena`.
    call: *const fn (ctx: *anyopaque, io: Io, arena: Allocator, tool: []const u8, input_json: []const u8) anyerror!Result,
    subscribe_changed: ?*const fn (ctx: *anyopaque, cb: registry.ChangedCb) void = null,
};

pub const Config = struct {
    /// Overrides `Kind.deadlineMs`.
    deadline_ms: ?u64 = null,
    clock: ratelimit.Clock = .real,
};

const Entry = struct {
    adapter: *Adapter,
    name: []const u8,
    mutates: bool,
};

/// One exporter as a registry source. Lives as long as the registry.
pub const Adapter = struct {
    gpa: Allocator,
    io: Io,
    exporter: Exporter,
    cfg: Config,
    mutex: Io.Mutex = .init,
    /// Entries of every listing (handlers of older generations stay valid).
    arena: std.heap.ArenaAllocator,
    /// Mutating calls that came back without a changeset.
    fail_closed: std.atomic.Value(u32) = .init(0),

    pub fn init(gpa: Allocator, io: Io, e: Exporter, cfg: Config) Adapter {
        return .{ .gpa = gpa, .io = io, .exporter = e, .cfg = cfg, .arena = .init(gpa) };
    }

    pub fn deinit(a: *Adapter) void {
        a.arena.deinit();
    }

    pub fn source(a: *Adapter) registry.ToolSource {
        return .{
            .name = a.exporter.name,
            .ctx = a,
            .list = list,
            .subscribe_changed = if (a.exporter.subscribe_changed != null) subscribe else null,
            .kind = if (a.exporter.kind == .mcp) .mcp else .package,
        };
    }

    fn subscribe(ctx: *anyopaque, cb: registry.ChangedCb) void {
        const a: *Adapter = @ptrCast(@alignCast(ctx));
        a.exporter.subscribe_changed.?(a.exporter.ctx, cb);
    }

    fn list(ctx: *anyopaque, gpa: Allocator, out: *std.ArrayList(proto.ToolSpec)) anyerror!void {
        const a: *Adapter = @ptrCast(@alignCast(ctx));
        a.mutex.lockUncancelable(a.io);
        defer a.mutex.unlock(a.io);
        const ar = a.arena.allocator();
        var tmp: std.heap.ArenaAllocator = .init(a.gpa);
        defer tmp.deinit();
        const tools = try a.exporter.list(a.exporter.ctx, tmp.allocator());
        for (tools) |t| {
            const entry = try ar.create(Entry);
            const effects = a.effectsOf(t);
            entry.* = .{ .adapter = a, .name = try ar.dupe(u8, t.name), .mutates = t.mutates };
            try out.append(gpa, .{
                .name = t.name,
                .description = t.description,
                .input_schema_json = t.input_schema_json,
                .read_only = effects.read_only,
                .effects = effects,
                .permission = if (effects.read_only) .read else if (a.exporter.kind == .mcp or a.exporter.kind == .tasks) .execute else .control,
                .handler = .{ .ctx = entry, .call = callTool },
                .origin = if (a.exporter.kind == .mcp) .{ .mcp = a.exporter.name } else .{ .extension = @tagName(a.exporter.kind) },
            });
        }
    }

    /// Package tools declare their effects. MCP annotations count only for
    /// trusted servers; an untrusted server's tools are treated as
    /// mutating, whatever they claim.
    pub fn effectsOf(a: *const Adapter, t: ForeignTool) proto.tool.Effects {
        if (a.exporter.kind != .mcp) return .{
            .read_only = t.read_only and !t.mutates,
            .writes_workspace = t.mutates,
            .idempotent = t.annotations.idempotent_hint orelse t.read_only,
            .open_world = false,
        };
        const n = t.annotations;
        if (!a.exporter.trusted) return .{ .writes_workspace = true, .open_world = true };
        const ro = (n.read_only_hint orelse false) and !(n.destructive_hint orelse false) and !t.mutates;
        return .{
            .read_only = ro,
            .writes_workspace = !ro,
            .idempotent = n.idempotent_hint orelse false,
            .open_world = n.open_world_hint orelse true,
        };
    }

    fn callTool(ctx: *anyopaque, c: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
        const e: *const Entry = @ptrCast(@alignCast(ctx));
        const a = e.adapter;
        const deadline = a.cfg.deadline_ms orelse a.exporter.kind.deadlineMs();
        const r = withDeadline(a, c, e.name, deadline) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Timeout => return text(c.arena, try std.fmt.allocPrint(c.arena, "{s} did not answer within {d}s.", .{ c.name, deadline / 1000 }), true),
            error.OutOfMemory => return error.OutOfMemory,
            else => return text(c.arena, try std.fmt.allocPrint(c.arena, "{s} failed: {s}", .{ c.name, @errorName(err) }), true),
        };
        var out = mapResult(c.arena, r.json) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return text(c.arena, try std.fmt.allocPrint(c.arena, "{s} returned a result that is not an MCP CallToolResult.", .{c.name}), true),
        };
        if (e.mutates and !out.is_error) {
            const id = r.changeset orelse {
                _ = a.fail_closed.fetchAdd(1, .monotonic);
                log.info("{s} exporter: mutating tool {s} answered without a changeset; result dropped", .{ a.exporter.name, e.name });
                return text(c.arena, try std.fmt.allocPrint(c.arena, "{s} changed files without a reviewable changeset, so its result was dropped. Tell the user; do not retry.", .{c.name}), true);
            };
            out.changeset = .{ .id = id };
        }
        return out;
    }
};

const Raced = union(enum) {
    done: anyerror!Result,
    timeout: Io.Cancelable!void,
};

/// Runs the foreign call, giving up after `ms`.
fn withDeadline(a: *Adapter, c: *proto.ToolCall, name: []const u8, ms: u64) anyerror!Result {
    const x = a.exporter;
    var buf: [2]Raced = undefined;
    var sel: Io.Select(Raced) = .init(c.io, &buf);
    defer sel.cancelDiscard();
    sel.concurrent(.done, callExporter, .{ x, c.io, c.arena, name, c.input_json }) catch
        return x.call(x.ctx, c.io, c.arena, name, c.input_json);
    sel.concurrent(.timeout, ratelimit.Clock.sleep, .{ a.cfg.clock, c.io, ms }) catch {};
    return switch (try sel.await()) {
        .done => |r| r,
        .timeout => |t| {
            try t;
            return error.Timeout;
        },
    };
}

fn callExporter(x: Exporter, io: Io, arena: Allocator, name: []const u8, input_json: []const u8) anyerror!Result {
    return x.call(x.ctx, io, arena, name, input_json);
}

fn text(arena: Allocator, s: []const u8, is_error: bool) Allocator.Error!proto.ToolOutput {
    return proto.ToolOutput.text(arena, s, is_error);
}

/// Maps an MCP `CallToolResult`: `content` to parts, `structuredContent`
/// to `structured_json`, `isError` to `is_error`.
pub fn mapResult(arena: Allocator, json: []const u8) !proto.ToolOutput {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    if (v != .object) return error.NotAResult;
    var parts: std.ArrayList(proto.ResultPart) = .empty;
    if (v.object.get("content")) |content| {
        if (content != .array) return error.NotAResult;
        for (content.array.items) |item| {
            if (item != .object) continue;
            const ty = str(item, "type") orelse continue;
            if (std.mem.eql(u8, ty, "text")) {
                try parts.append(arena, .{ .text = str(item, "text") orelse "" });
            } else if (std.mem.eql(u8, ty, "image")) {
                try parts.append(arena, .{ .image = .{ .media_type = str(item, "mimeType") orelse "image/png", .data = .{ .base64 = str(item, "data") orelse "" } } });
            } else if (std.mem.eql(u8, ty, "resource_link")) {
                const uri = str(item, "uri") orelse continue;
                try parts.append(arena, .{ .resource_link = .{ .uri = uri, .name = str(item, "name") orelse uri, .mime = str(item, "mimeType") } });
            } else if (std.mem.eql(u8, ty, "resource")) {
                const res = item.object.get("resource") orelse continue;
                if (res != .object) continue;
                if (str(res, "text")) |t| {
                    try parts.append(arena, .{ .text = t });
                } else if (str(res, "uri")) |uri| {
                    try parts.append(arena, .{ .resource_link = .{ .uri = uri, .name = uri, .mime = str(res, "mimeType") } });
                }
            } else {
                try parts.append(arena, .{ .text = try std.fmt.allocPrint(arena, "[{s} content not shown]", .{ty}) });
            }
        }
    }
    const structured: ?[]const u8 = if (v.object.get("structuredContent")) |s|
        try std.json.Stringify.valueAlloc(arena, s, .{})
    else
        null;
    // Structured-only results still give the model text.
    if (parts.items.len == 0) try parts.append(arena, .{ .text = structured orelse "" });
    const is_error = if (v.object.get("isError")) |e| e == .bool and e.bool else false;
    return .{ .parts = parts.items, .is_error = is_error, .structured_json = structured };
}

fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}
