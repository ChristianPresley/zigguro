//! Go to Symbol in Workspace (E07.F04.S01.T02): `query` asks every
//! running server with `workspaceSymbolProvider` for `workspace/symbol`
//! `debounce_ms` after the last keystroke. Answers merge as they arrive,
//! deduplicated by name, kind and location; the picker ranks them by its
//! own fuzzy score on the name (servers rank differently). A symbol the
//! server sent without a range (`WorkspaceSymbol` with a bare URI) is
//! resolved (`workspaceSymbol/resolve`) when picked.

const WorkspaceSymbols = @This();
const std = @import("std");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const Manager = @import("../Manager.zig");
const oneshot = @import("oneshot.zig");

const Allocator = std.mem.Allocator;
const protocol = zg_lsp.protocol;
const Client = zg_lsp.client.Client;
const Query = oneshot.Oneshot(.@"workspace/symbol", u64);
const Resolve = oneshot.Oneshot(.@"workspaceSymbol/resolve", u64);

pub const Hit = struct {
    name: []const u8,
    kind: protocol.SymbolKind,
    container: ?[]const u8 = null,
    deprecated: bool = false,
    uri: []const u8,
    /// Null until resolved.
    range: ?protocol.Range,
    /// The server's position encoding.
    enc: zg_lsp.position.PositionEncoding,
    client: *Client,
    /// The symbol's `data`, as JSON, for the resolve.
    data: ?[]const u8 = null,
};

pub const Options = struct { debounce_ms: u64 = 100 };

gpa: Allocator,
mgr: *Manager,
opts: Options,
query_req: Query,
resolve_req: Resolve,
/// The hits of the current query (owned by `arena`).
list: std.ArrayList(Hit) = .empty,
arena: std.heap.ArenaAllocator,
text: std.ArrayList(u8) = .empty,
round: u64 = 0,
due_ms: ?u64 = null,
/// Servers asked in this round, and those that answered.
asked: u32 = 0,
answered: u32 = 0,
/// The picked hit waiting for its resolve, then the result.
resolving: ?u64 = null,
resolved: ?Hit = null,
resolved_arena: std.heap.ArenaAllocator,
/// Bumped when `hits` changes.
generation: u64 = 0,

pub fn init(mgr: *Manager, waker: zg_core.runtime.Waker, opts: Options) WorkspaceSymbols {
    return .{
        .gpa = mgr.gpa,
        .mgr = mgr,
        .opts = opts,
        .query_req = .init(mgr.gpa, mgr.rt.io, waker),
        .resolve_req = .init(mgr.gpa, mgr.rt.io, waker),
        .arena = .init(mgr.gpa),
        .resolved_arena = .init(mgr.gpa),
    };
}

/// Call after `Manager.deinit`.
pub fn deinit(w: *WorkspaceSymbols) void {
    w.query_req.deinit();
    w.resolve_req.deinit();
    w.list.deinit(w.gpa);
    w.arena.deinit();
    w.resolved_arena.deinit();
    w.text.deinit(w.gpa);
}

fn servers(w: *WorkspaceSymbols, out: []*Manager.Server) usize {
    var n: usize = 0;
    for (w.mgr.serverList()) |s| {
        if (n == out.len) break;
        if (s.status != .running) continue;
        const caps = (s.client orelse continue).caps() orelse continue;
        if (!caps.supports(.workspace_symbol, null)) continue;
        out[n] = s;
        n += 1;
    }
    return n;
}

/// Whether any server can search the workspace.
pub fn available(w: *WorkspaceSymbols) bool {
    var buf: [1]*Manager.Server = undefined;
    return w.servers(&buf) > 0;
}

/// The search text changed.
pub fn query(w: *WorkspaceSymbols, text: []const u8, now_ms: u64) !void {
    if (std.mem.eql(u8, text, w.text.items) and (w.due_ms != null or w.asked > 0)) return;
    w.text.clearRetainingCapacity();
    try w.text.appendSlice(w.gpa, text);
    w.round += 1;
    w.asked = 0;
    w.answered = 0;
    w.list.clearRetainingCapacity();
    _ = w.arena.reset(.retain_capacity);
    w.generation += 1;
    // An empty query lists nothing (most servers answer nothing anyway).
    w.due_ms = if (text.len == 0) null else now_ms + w.opts.debounce_ms;
}

/// Whether every server asked has answered.
pub fn complete(w: *const WorkspaceSymbols) bool {
    return w.due_ms == null and w.answered >= w.asked;
}

pub fn hits(w: *const WorkspaceSymbols) []const Hit {
    return w.list.items;
}

pub fn nextDue(w: *const WorkspaceSymbols) ?u64 {
    return w.due_ms;
}

/// Sends a due query, merges answers; true when `hits` or `resolved`
/// changed.
pub fn tick(w: *WorkspaceSymbols, now_ms: u64) bool {
    const g = w.generation;
    if (w.due_ms) |d| if (now_ms >= d) {
        w.due_ms = null;
        var buf: [8]*Manager.Server = undefined;
        const n = w.servers(&buf);
        for (buf[0..n]) |s| {
            w.query_req.send(s.client.?, .{ .query = w.text.items }, .{}, w.round) catch continue;
            w.asked += 1;
        }
    };
    for (w.query_req.take()) |a| {
        if (a.tag != w.round) continue;
        w.answered += 1;
        const v = switch (a.result) {
            .ok => |o| o.value orelse continue,
            else => continue,
        };
        w.merge(a.client, v) catch {};
        w.generation += 1;
    }
    for (w.resolve_req.take()) |a| {
        if (w.resolving == null or a.tag != w.resolving.?) continue;
        const i: usize = @intCast(a.tag & 0xffff_ffff);
        w.resolving = null;
        if (i >= w.list.items.len) continue;
        const hit = w.list.items[i];
        switch (a.result) {
            .ok => |o| w.setResolved(hit, o.value) catch {},
            else => w.setResolvedAs(hit),
        }
        w.generation += 1;
    }
    return w.generation != g;
}

fn same(a: Hit, b: Hit) bool {
    if (a.kind != b.kind or !std.mem.eql(u8, a.name, b.name) or !std.mem.eql(u8, a.uri, b.uri)) return false;
    const ar = a.range orelse return b.range == null;
    const br = b.range orelse return false;
    return ar.start.line == br.start.line and ar.start.character == br.start.character;
}

fn deprecated(tags: ?[]const protocol.SymbolTag, flag: ?bool) bool {
    if (flag orelse false) return true;
    for (tags orelse &.{}) |t| if (t == .Deprecated) return true;
    return false;
}

fn add(w: *WorkspaceSymbols, h: Hit) !void {
    for (w.list.items) |x| if (same(x, h)) return;
    try w.list.append(w.gpa, h);
}

fn merge(w: *WorkspaceSymbols, c: *Client, v: protocol.WorkspaceSymbolResult) !void {
    const a = w.arena.allocator();
    const enc = c.encoding();
    switch (v) {
        .symbol_information_array => |si| for (si) |s| try w.add(.{
            .name = try a.dupe(u8, s.name),
            .kind = s.kind,
            .container = if (s.containerName) |x| try a.dupe(u8, x) else null,
            .deprecated = deprecated(s.tags, s.deprecated),
            .uri = try a.dupe(u8, s.location.uri),
            .range = s.location.range,
            .enc = enc,
            .client = c,
        }),
        .workspace_symbol_array => |ws| for (ws) |s| {
            const uri, const range: ?protocol.Range = switch (s.location) {
                .location => |l| .{ l.uri, l.range },
                .location_uri_only => |l| .{ l.uri, null },
            };
            try w.add(.{
                .name = try a.dupe(u8, s.name),
                .kind = s.kind,
                .container = if (s.containerName) |x| try a.dupe(u8, x) else null,
                .deprecated = deprecated(s.tags, null),
                .uri = try a.dupe(u8, uri),
                .range = range,
                .enc = enc,
                .client = c,
                .data = if (s.data) |d| try std.json.Stringify.valueAlloc(a, d, .{}) else null,
            });
        },
    }
}

fn canResolve(c: *Client) bool {
    const caps = c.caps() orelse return false;
    const p = caps.raw.workspaceSymbolProvider orelse return false;
    return switch (p) {
        .boolean => false,
        .workspace_symbol_options => |o| o.resolveProvider orelse false,
    };
}

/// Picks hit `i`: ready at once when it has a range (`resolved`), else
/// after the server resolves it (then `resolved` is set in `tick`; a
/// failed resolve leaves the file without a position).
pub fn pick(w: *WorkspaceSymbols, i: usize) !void {
    const hit = w.list.items[i];
    w.resolving = null;
    if (hit.range != null or !canResolve(hit.client)) return w.setResolvedAs(hit);
    const a = w.resolved_arena.allocator();
    const data: ?std.json.Value = if (hit.data) |d| try std.json.parseFromSliceLeaky(std.json.Value, a, d, .{}) else null;
    const tag = (w.round << 32) | @as(u64, @intCast(i));
    try w.resolve_req.send(hit.client, .{ .name = hit.name, .kind = hit.kind, .containerName = hit.container, .location = .{ .location_uri_only = .{ .uri = hit.uri } }, .data = data }, .{}, tag);
    w.resolving = tag;
}

fn setResolvedAs(w: *WorkspaceSymbols, hit: Hit) void {
    w.setResolved(hit, null) catch {};
}

fn setResolved(w: *WorkspaceSymbols, hit: Hit, got: ?protocol.WorkspaceSymbol) !void {
    _ = w.resolved_arena.reset(.retain_capacity);
    const a = w.resolved_arena.allocator();
    var h = hit;
    h.name = try a.dupe(u8, hit.name);
    h.uri = try a.dupe(u8, hit.uri);
    h.container = null;
    h.data = null;
    if (got) |g| switch (g.location) {
        .location => |l| {
            h.uri = try a.dupe(u8, l.uri);
            h.range = l.range;
        },
        .location_uri_only => {},
    };
    w.resolved = h;
}

/// Takes the picked hit once it is ready.
pub fn takeResolved(w: *WorkspaceSymbols) ?Hit {
    const h = w.resolved orelse return null;
    w.resolved = null;
    return h;
}
