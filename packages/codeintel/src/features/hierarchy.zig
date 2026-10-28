//! Call and type hierarchies (E07.F04.S01.T03): `prepare` asks the server
//! for the item at a position (`textDocument/prepareCallHierarchy` or
//! `prepareTypeHierarchy`); the items become the roots of a tree whose
//! nodes load their children when first expanded (`expand`): incoming or
//! outgoing calls, supertypes or subtypes. Several prepared items are
//! several roots.
//!
//! Each item goes back to the server exactly as it came (its raw JSON,
//! `data` included). A node that repeats one of its ancestors (recursion)
//! is marked `recursive` and has no children. An incoming call's
//! `from_ranges` are in the caller's document, an outgoing call's in the
//! document of the node expanded (`ranges_uri` says which).

const HierarchyService = @This();
const std = @import("std");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Manager = @import("../Manager.zig");
const requester = @import("request.zig");
const oneshot = @import("oneshot.zig");
const position = @import("position.zig");
const raw_json = @import("raw_json.zig");

const Allocator = std.mem.Allocator;
const protocol = zg_lsp.protocol;
const Client = zg_lsp.client.Client;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const PrepCalls = requester.Requester(.@"textDocument/prepareCallHierarchy", .call_hierarchy);
const PrepTypes = requester.Requester(.@"textDocument/prepareTypeHierarchy", .type_hierarchy);
const Incoming = oneshot.Oneshot(.@"callHierarchy/incomingCalls", Tag);
const Outgoing = oneshot.Oneshot(.@"callHierarchy/outgoingCalls", Tag);
const Supertypes = oneshot.Oneshot(.@"typeHierarchy/supertypes", Tag);
const Subtypes = oneshot.Oneshot(.@"typeHierarchy/subtypes", Tag);

pub const Kind = enum { calls, types };
pub const Direction = enum { incoming, outgoing, supertypes, subtypes };

/// Identifies a node: its index in `nodes` plus one.
pub const NodeId = u64;

const Tag = struct { node: NodeId, round: u64 };

pub const HierItem = struct {
    /// The item as the server sent it.
    raw: []const u8,
    name: []const u8,
    kind: protocol.SymbolKind,
    detail: ?[]const u8 = null,
    uri: []const u8,
    range: protocol.Range,
    selection: protocol.Range,
    enc: position.Encoding,
    client: *Client,
};

pub const Node = struct {
    item: HierItem,
    parent: ?NodeId,
    /// Null until loaded.
    children: ?[]const NodeId = null,
    loading: bool = false,
    /// It repeats an ancestor.
    recursive: bool = false,
    /// Where the call is (calls only), in `ranges_uri`.
    from_ranges: []const protocol.Range = &.{},
    ranges_uri: ?[]const u8 = null,
    /// The server failed to list the children.
    failed: bool = false,
};

gpa: Allocator,
mgr: *Manager,
arena: std.heap.ArenaAllocator,
nodes: std.ArrayList(Node) = .empty,
roots: std.ArrayList(NodeId) = .empty,
kind: Kind = .calls,
dir: Direction = .incoming,
prep_calls: PrepCalls,
prep_types: PrepTypes,
incoming: Incoming,
outgoing: Outgoing,
supertypes: Supertypes,
subtypes: Subtypes,
/// Bumped by `prepare` and `clear`: answers of older rounds are dropped.
round: u64 = 0,
preparing: bool = false,
/// Nodes whose children arrived since the last `takeLoaded`.
loaded: std.ArrayList(NodeId) = .empty,
/// Bumped whenever the tree changes.
generation: u64 = 0,
elems: std.ArrayList([]const u8) = .empty,

pub fn init(mgr: *Manager, waker: zg_core.runtime.Waker) HierarchyService {
    const gpa = mgr.gpa;
    const io = mgr.rt.io;
    return .{
        .gpa = gpa,
        .mgr = mgr,
        .arena = .init(gpa),
        .prep_calls = .init(mgr, waker),
        .prep_types = .init(mgr, waker),
        .incoming = .init(gpa, io, waker),
        .outgoing = .init(gpa, io, waker),
        .supertypes = .init(gpa, io, waker),
        .subtypes = .init(gpa, io, waker),
    };
}

/// Call after `Manager.deinit`.
pub fn deinit(h: *HierarchyService) void {
    h.prep_calls.deinit();
    h.prep_types.deinit();
    h.incoming.deinit();
    h.outgoing.deinit();
    h.supertypes.deinit();
    h.subtypes.deinit();
    h.nodes.deinit(h.gpa);
    h.roots.deinit(h.gpa);
    h.loaded.deinit(h.gpa);
    h.elems.deinit(h.gpa);
    h.arena.deinit();
}

/// Whether a server can answer `kind` for `d`.
pub fn available(h: *HierarchyService, kind: Kind, d: DocHandle) bool {
    return switch (kind) {
        .calls => h.prep_calls.available(d),
        .types => h.prep_types.available(d),
    };
}

/// Empties the tree.
pub fn clear(h: *HierarchyService) void {
    h.round += 1;
    h.nodes.clearRetainingCapacity();
    h.roots.clearRetainingCapacity();
    h.loaded.clearRetainingCapacity();
    _ = h.arena.reset(.retain_capacity);
    h.preparing = false;
    h.generation += 1;
}

/// Starts a tree for the symbol at byte `pos` of `d`, listing `dir`
/// (incoming or outgoing for calls, supertypes or subtypes for types).
/// Returns the servers asked (0: none can).
pub fn prepare(h: *HierarchyService, d: DocHandle, pos: u64, dir: Direction) !u8 {
    h.clear();
    h.dir = dir;
    h.kind = switch (dir) {
        .incoming, .outgoing => .calls,
        .supertypes, .subtypes => .types,
    };
    const n = switch (h.kind) {
        .calls => try h.prep_calls.ask(d, pos, .{}),
        .types => try h.prep_types.ask(d, pos, .{}),
    };
    h.preparing = n > 0;
    return n;
}

/// The other direction of the same kind, same roots: children load
/// again.
pub fn setDirection(h: *HierarchyService, dir: Direction) void {
    if (dir == h.dir) return;
    h.dir = dir;
    h.round += 1;
    // Keep the roots, forget everything under them.
    var keep: std.ArrayList(Node) = .empty;
    for (h.roots.items) |id| keep.append(h.gpa, h.nodes.items[id - 1]) catch return;
    defer keep.deinit(h.gpa);
    h.nodes.clearRetainingCapacity();
    h.roots.clearRetainingCapacity();
    for (keep.items) |n| {
        var c = n;
        c.children = null;
        c.loading = false;
        c.failed = false;
        h.nodes.append(h.gpa, c) catch return;
        h.roots.append(h.gpa, h.nodes.items.len) catch return;
    }
    h.loaded.clearRetainingCapacity();
    h.generation += 1;
}

pub fn node(h: *const HierarchyService, id: NodeId) ?*const Node {
    if (id == 0 or id > h.nodes.items.len) return null;
    return &h.nodes.items[id - 1];
}

/// Asks for `id`'s children (once).
pub fn expand(h: *HierarchyService, id: NodeId) !void {
    if (id == 0 or id > h.nodes.items.len) return;
    const n = &h.nodes.items[id - 1];
    if (n.children != null or n.loading or n.recursive) return;
    var body: std.Io.Writer.Allocating = .init(h.gpa);
    defer body.deinit();
    try body.writer.print("{{\"item\":{s}}}", .{n.item.raw});
    const tag: Tag = .{ .node = id, .round = h.round };
    const c = n.item.client;
    switch (h.dir) {
        .incoming => try h.incoming.sendRaw(c, body.written(), .{}, tag),
        .outgoing => try h.outgoing.sendRaw(c, body.written(), .{}, tag),
        .supertypes => try h.supertypes.sendRaw(c, body.written(), .{}, tag),
        .subtypes => try h.subtypes.sendRaw(c, body.written(), .{}, tag),
    }
    n.loading = true;
}

/// The nodes whose children arrived since the last call.
pub fn takeLoaded(h: *HierarchyService, out: *std.ArrayList(NodeId)) Allocator.Error!void {
    out.clearRetainingCapacity();
    try out.appendSlice(h.gpa, h.loaded.items);
    h.loaded.clearRetainingCapacity();
}

/// Takes answers; true when the tree changed.
pub fn tick(h: *HierarchyService) bool {
    const g = h.generation;
    if (h.preparing) {
        switch (h.kind) {
            .calls => for (h.prep_calls.take()) |a| h.onPrepared(a.client, a.result),
            .types => for (h.prep_types.take()) |a| h.onPrepared(a.client, a.result),
        }
        const done = switch (h.kind) {
            .calls => h.prep_calls.done(),
            .types => h.prep_types.done(),
        };
        if (done) {
            h.preparing = false;
            h.generation += 1;
        }
    }
    for (h.incoming.take()) |a| h.onCalls(a.tag, a.client, a.result, "from");
    for (h.outgoing.take()) |a| h.onCalls(a.tag, a.client, a.result, "to");
    for (h.supertypes.take()) |a| h.onTypes(a.tag, a.client, a.result);
    for (h.subtypes.take()) |a| h.onTypes(a.tag, a.client, a.result);
    return h.generation != g;
}

/// Whether the prepare round is still waiting.
pub fn busy(h: *const HierarchyService) bool {
    return h.preparing;
}

fn rawOf(result: anytype) []const u8 {
    return switch (result) {
        .ok => |o| if (o.resp.response.result) |r| r.bytes else "null",
        else => "null",
    };
}

fn itemFrom(h: *HierarchyService, c: *Client, raw: []const u8, x: anytype) !HierItem {
    const a = h.arena.allocator();
    return .{
        .raw = try a.dupe(u8, raw),
        .name = try a.dupe(u8, x.name),
        .kind = x.kind,
        .detail = if (x.detail) |d| try a.dupe(u8, d) else null,
        .uri = try a.dupe(u8, x.uri),
        .range = x.range,
        .selection = x.selectionRange,
        .enc = position.encodingOf(c.encoding()),
        .client = c,
    };
}

fn onPrepared(h: *HierarchyService, c: *Client, result: anytype) void {
    const items = switch (result) {
        .ok => |o| o.value orelse return,
        else => return,
    };
    raw_json.elements(h.gpa, rawOf(result), &h.elems) catch return;
    if (h.elems.items.len != items.len) return;
    for (items, h.elems.items) |x, raw| {
        const it = h.itemFrom(c, raw, x) catch return;
        h.nodes.append(h.gpa, .{ .item = it, .parent = null }) catch return;
        h.roots.append(h.gpa, h.nodes.items.len) catch return;
    }
}

/// Whether `it` repeats `parent` or one of its ancestors.
fn repeats(h: *const HierarchyService, parent: NodeId, it: HierItem) bool {
    var at: ?NodeId = parent;
    while (at) |id| {
        const n = &h.nodes.items[id - 1];
        if (std.mem.eql(u8, n.item.uri, it.uri) and std.meta.eql(n.item.selection.start, it.selection.start) and std.mem.eql(u8, n.item.name, it.name)) return true;
        at = n.parent;
    }
    return false;
}

fn finish(h: *HierarchyService, id: NodeId, kids: []const NodeId, failed: bool) void {
    const n = &h.nodes.items[id - 1];
    n.loading = false;
    n.failed = failed;
    n.children = h.arena.allocator().dupe(NodeId, kids) catch &.{};
    h.loaded.append(h.gpa, id) catch {};
    h.generation += 1;
}

fn onCalls(h: *HierarchyService, tag: Tag, c: *Client, result: anytype, comptime key: []const u8) void {
    if (tag.round != h.round or tag.node == 0 or tag.node > h.nodes.items.len) return;
    var kids: std.ArrayList(NodeId) = .empty;
    defer kids.deinit(h.gpa);
    const calls = switch (result) {
        .ok => |o| o.value orelse &.{},
        else => return h.finish(tag.node, &.{}, true),
    };
    raw_json.elements(h.gpa, rawOf(result), &h.elems) catch return h.finish(tag.node, &.{}, true);
    if (h.elems.items.len != calls.len) return h.finish(tag.node, &.{}, true);
    const a = h.arena.allocator();
    // Incoming: ranges in the caller; outgoing: in the expanded item.
    const outgoing = comptime std.mem.eql(u8, key, "to");
    const here = h.nodes.items[tag.node - 1].item.uri;
    for (calls, h.elems.items) |call, elem| {
        const target = @field(call, key);
        const raw = raw_json.field(elem, key) orelse continue;
        const it = h.itemFrom(c, raw, target) catch continue;
        const rec = h.repeats(tag.node, it);
        h.nodes.append(h.gpa, .{
            .item = it,
            .parent = tag.node,
            .recursive = rec,
            .children = if (rec) &.{} else null,
            .from_ranges = a.dupe(protocol.Range, call.fromRanges) catch &.{},
            .ranges_uri = if (outgoing) here else it.uri,
        }) catch continue;
        kids.append(h.gpa, h.nodes.items.len) catch {};
    }
    h.finish(tag.node, kids.items, false);
}

fn onTypes(h: *HierarchyService, tag: Tag, c: *Client, result: anytype) void {
    if (tag.round != h.round or tag.node == 0 or tag.node > h.nodes.items.len) return;
    var kids: std.ArrayList(NodeId) = .empty;
    defer kids.deinit(h.gpa);
    const items = switch (result) {
        .ok => |o| o.value orelse &.{},
        else => return h.finish(tag.node, &.{}, true),
    };
    raw_json.elements(h.gpa, rawOf(result), &h.elems) catch return h.finish(tag.node, &.{}, true);
    if (h.elems.items.len != items.len) return h.finish(tag.node, &.{}, true);
    for (items, h.elems.items) |x, raw| {
        const it = h.itemFrom(c, raw, x) catch continue;
        const rec = h.repeats(tag.node, it);
        h.nodes.append(h.gpa, .{ .item = it, .parent = tag.node, .recursive = rec, .children = if (rec) &.{} else null }) catch continue;
        kids.append(h.gpa, h.nodes.items.len) catch {};
    }
    h.finish(tag.node, kids.items, false);
}
