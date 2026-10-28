//! The variables tree (E07.F06.S04.T01): the selected frame's scopes as
//! roots, children fetched lazily with `variables`, large arrays split
//! into index buckets, values set with `setExpression`/`setVariable`.
//!
//! - **Identity.** A `NodeId` hashes the key path: the frame's function
//!   name and scope name for a scope, the parent's id and the name for a
//!   variable, the range for a bucket. Expansion state is kept by id, so
//!   it survives stops; after a stop previously expanded nodes are fetched
//!   again (at most `reexpand_nodes`, `reexpand_depth` levels below the
//!   scopes, concurrently).
//! - **Generations.** Every node remembers the stop its
//!   `variablesReference` came from. A node of an earlier stop, or any
//!   node while the program runs, is never used for a request: `children`
//!   answers `.stale` with the old children (the UI greys them) until the
//!   next stop's data replaces them, so fast steps do not flicker.
//! - **Buckets.** With paging (the client advertises
//!   `supportsVariablePaging`; `Options.paging`), a variable with more than
//!   100 indexed children shows buckets: 100 elements per leaf bucket and
//!   ×100 per level (`[0..99]`, `[0..9999]`, …). A bucket fetches nothing
//!   until a leaf is expanded (`filter: indexed, start, count`); named
//!   children are fetched with `filter: named`. Without paging everything
//!   is fetched and at most `max_children` are kept, with a "N more not
//!   shown" row.
//! - **Changes.** `changed` is set when a value differs from the one the
//!   same node had at the previous stop.
//! - **Expensive scopes** stay unfetched until expanded; the first other
//!   scope is expanded by default.
//! - **Lazy values** (`presentationHint.lazy`) show "(click to evaluate)";
//!   expanding one fetches its value.
//!
//! Part of an `Inspector`; UI thread only.

const VariablesModel = @This();
const std = @import("std");
const Inspector = @import("Inspector.zig");
const Channel = @import("Channel.zig");

const Allocator = std.mem.Allocator;

pub const NodeId = enum(u64) { _ };

pub const Kind = enum { scope, variable, bucket, more };

pub const ChildCount = struct { named: u32 = 0, indexed: u32 = 0 };

/// `presentationHint`, its open strings as text.
pub const Hint = struct {
    kind: ?[]const u8 = null,
    visibility: ?[]const u8 = null,
    read_only: bool = false,
    raw_string: bool = false,
    has_side_effects: bool = false,
    constant: bool = false,
    static: bool = false,
    has_data_breakpoint: bool = false,
};

pub const VarNode = struct {
    id: NodeId,
    name: []const u8,
    value: []const u8 = "",
    type: ?[]const u8 = null,
    kind: Kind,
    /// Set when the node has children.
    child_count: ?ChildCount = null,
    evaluate_name: ?[]const u8 = null,
    memory_ref: ?[]const u8 = null,
    hint: ?Hint = null,
    /// The value differs from the previous stop's.
    changed: bool = false,
    /// The row is an error (its value is the message).
    err: bool = false,
    /// The value is fetched when the node is expanded.
    lazy: bool = false,
    /// A scope that is fetched only when expanded.
    expensive: bool = false,
};

pub const ChildrenResult = union(enum) {
    ready: []const NodeId,
    /// Nothing to show yet; a fetch is out.
    loading,
    /// The program runs or the node is from an earlier stop: the old
    /// children, for greying.
    stale: []const NodeId,
};

pub const SetCb = struct {
    ctx: ?*anyopaque,
    /// Passed back to `func`.
    user: u64 = 0,
    /// `message` (on failure) is valid during the call.
    func: *const fn (ctx: ?*anyopaque, user: u64, ok: bool, message: ?[]const u8) void,

    fn call(cb: SetCb, ok: bool, message: ?[]const u8) void {
        cb.func(cb.ctx, cb.user, ok, message);
    }
};

pub const lazy_label = "(click to evaluate)";
const leaf_bucket = 100;
/// Generations a node survives without being seen (each stop and resume
/// bumps the generation).
const keep_gens = 16;

const Node = struct {
    v: VarNode,
    /// The strings of `v`, one allocation.
    strings: []u8 = &.{},
    var_ref: i64 = 0,
    /// The stop `var_ref` belongs to.
    gen: u64 = 0,
    parent: ?NodeId = null,
    /// The scope above it.
    root: NodeId,
    /// 0 for scopes; buckets share their owner's.
    depth: u8 = 0,
    /// A bucket's range of its owner's indexed children.
    start: u32 = 0,
    count: u32 = 0,
    children: std.ArrayList(NodeId) = .empty,
    /// The stop `children` was fetched in; 0 when it must be fetched.
    children_gen: u64 = 0,
    loading: bool = false,
    /// For `changed`: this stop's value hash and the previous stop's.
    cur_hash: u64 = 0,
    cur_gen: u64 = 0,
    base_hash: u64 = 0,
    base_valid: bool = false,
};

const PendingSet = struct { cb: SetCb, node: NodeId };

gpa: Allocator,
nodes: std.AutoHashMapUnmanaged(NodeId, *Node) = .empty,
roots_: std.ArrayList(NodeId) = .empty,
/// The selected frame.
frame_id: ?i64 = null,
frame_key: u64 = 0,
expanded: std.AutoHashMapUnmanaged(NodeId, void) = .empty,
/// Scopes the user collapsed (the first scope is expanded otherwise).
collapsed: std.AutoHashMapUnmanaged(NodeId, void) = .empty,
hex: bool = false,
pending_sets: std.AutoHashMapUnmanaged(u64, PendingSet) = .empty,
next_token: u64 = 1,
/// Re-expansion fetches left for this stop or refresh.
budget: u32 = 0,

pub fn init(gpa: Allocator) VariablesModel {
    return .{ .gpa = gpa };
}

pub fn deinit(m: *VariablesModel) void {
    var it = m.nodes.valueIterator();
    while (it.next()) |n| m.destroyNode(n.*);
    m.nodes.deinit(m.gpa);
    m.roots_.deinit(m.gpa);
    m.expanded.deinit(m.gpa);
    m.collapsed.deinit(m.gpa);
    m.pending_sets.deinit(m.gpa);
    m.* = undefined;
}

fn inspector(m: *VariablesModel) *Inspector {
    return @alignCast(@fieldParentPtr("vars", m));
}

fn destroyNode(m: *VariablesModel, n: *Node) void {
    n.children.deinit(m.gpa);
    m.gpa.free(n.strings);
    m.gpa.destroy(n);
}

// ---------------------------------------------------------------------
// Reading.

/// The scopes of the selected frame.
pub fn roots(m: *const VariablesModel) []const NodeId {
    return m.roots_.items;
}

pub fn node(m: *const VariablesModel, n: NodeId) ?*const VarNode {
    const nd = m.nodes.get(n) orelse return null;
    return &nd.v;
}

/// The children of `n` (`range` clamps the slice); fetches them when
/// they are not from this stop.
pub fn children(m: *VariablesModel, n: NodeId, range: ?[2]u32) ChildrenResult {
    const nd = m.nodes.get(n) orelse return .{ .stale = &.{} };
    const old = clamp(nd.children.items, range);
    const gen = m.inspector().liveGen() orelse return .{ .stale = old };
    if (nd.gen != gen) return .{ .stale = old };
    if (nd.children_gen == gen) return .{ .ready = old };
    if (!nd.loading) m.fetchChildren(nd, gen);
    if (nd.children_gen == gen) return .{ .ready = clamp(nd.children.items, range) };
    return if (old.len > 0) .{ .ready = old } else .loading;
}

/// What a view shows under `n` without fetching: the children of this
/// stop (`current`), an earlier stop's for greying, or null while none
/// were fetched.
pub const Peek = struct { ids: []const NodeId, current: bool };

pub fn peekChildren(m: *VariablesModel, n: NodeId) ?Peek {
    const nd = m.nodes.get(n) orelse return null;
    const gen = m.inspector().liveGen();
    const current = gen != null and nd.gen == gen.? and nd.children_gen == gen.?;
    if (!current and nd.children.items.len == 0) return null;
    return .{ .ids = nd.children.items, .current = current };
}

/// Whether `n` is of this stop (requests may use it).
pub fn isLive(m: *VariablesModel, n: NodeId) bool {
    const nd = m.nodes.get(n) orelse return false;
    const gen = m.inspector().liveGen() orelse return false;
    return nd.gen == gen;
}

fn clamp(items: []const NodeId, range: ?[2]u32) []const NodeId {
    const r = range orelse return items;
    const a = @min(r[0], items.len);
    const b = @min(@max(r[1], r[0]), items.len);
    return items[a..b];
}

/// Shown expanded (the first non-expensive scope is, unless collapsed).
pub fn isExpanded(m: *const VariablesModel, n: NodeId) bool {
    if (m.expanded.contains(n)) return true;
    if (m.collapsed.contains(n)) return false;
    const nd = m.nodes.get(n) orelse return false;
    if (nd.v.kind != .scope or nd.v.expensive) return false;
    return m.roots_.items.len > 0 and m.roots_.items[0] == n;
}

pub fn expand(m: *VariablesModel, n: NodeId, on: bool) void {
    if (on) {
        _ = m.collapsed.remove(n);
        m.expanded.put(m.gpa, n, {}) catch {};
        const nd = m.nodes.get(n) orelse return;
        const gen = m.inspector().liveGen() orelse return;
        if (nd.gen != gen) return;
        if (nd.v.lazy) return m.resolveLazy(nd);
        _ = m.children(n, null);
    } else {
        _ = m.expanded.remove(n);
        m.collapsed.put(m.gpa, n, {}) catch {};
    }
}

/// Values in hexadecimal (when the adapter supports
/// `supportsValueFormattingOptions`): fetches the expanded nodes again.
pub fn setHex(m: *VariablesModel, on: bool) void {
    if (m.hex == on) return;
    const insp = m.inspector();
    if (on and !(insp.ch.caps().supportsValueFormattingOptions orelse false)) return;
    m.hex = on;
    m.markDirty(null);
    const gen = insp.liveGen() orelse return;
    m.budget = insp.opts.reexpand_nodes;
    for (m.roots_.items) |r| if (m.isExpanded(r)) if (m.nodes.get(r)) |nd| if (nd.gen == gen) m.fetchChildren(nd, gen);
}

// ---------------------------------------------------------------------
// Frames and scopes.

/// A new stop: re-expansion starts over, old nodes go.
pub fn newStop(m: *VariablesModel, gen: u64) void {
    m.budget = m.inspector().opts.reexpand_nodes;
    m.prune(gen);
}

/// The selected frame changed (or its scopes must be fetched again).
/// `scopes` is a `scopes` body already in hand.
pub fn setFrame(m: *VariablesModel, frame_id: i64, name: []const u8, scopes: ?[]const u8) void {
    const insp = m.inspector();
    m.frame_id = frame_id;
    m.frame_key = std.hash.Wyhash.hash(0x5c09e5, name);
    m.budget = insp.opts.reexpand_nodes;
    const gen = insp.liveGen() orelse return;
    if (scopes) |body| return m.applyScopes(frame_id, gen, true, body) catch {};
    m.requestScopes();
}

/// Fetches the selected frame's scopes again (`invalidated` with
/// `variables`), keeping the expansion.
pub fn refresh(m: *VariablesModel) void {
    m.budget = m.inspector().opts.reexpand_nodes;
    m.markDirty(null);
    m.requestScopes();
}

fn requestScopes(m: *VariablesModel) void {
    const f = m.frame_id orelse return;
    var buf: [48]u8 = undefined;
    const args = std.fmt.bufPrint(&buf, "{{\"frameId\":{d}}}", .{f}) catch unreachable;
    _ = m.inspector().send("scopes", args, .{ .kind = .scopes, .a = @bitCast(f) });
}

pub fn applyScopes(m: *VariablesModel, frame_id: i64, gen: u64, ok: bool, body: []const u8) Allocator.Error!void {
    if (m.frame_id != frame_id) return;
    if (!ok) return;
    const B = struct {
        scopes: []const struct {
            name: []const u8 = "",
            variablesReference: i64 = 0,
            expensive: bool = false,
            namedVariables: ?i64 = null,
            indexedVariables: ?i64 = null,
            presentationHint: ?[]const u8 = null,
        } = &.{},
    };
    var arena: std.heap.ArenaAllocator = .init(m.gpa);
    defer arena.deinit();
    const b = std.json.parseFromSliceLeaky(B, arena.allocator(), body, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    m.roots_.clearRetainingCapacity();
    for (b.scopes) |sc| {
        const id = key(m.frame_key, 's', sc.name);
        const n = try m.upsert(id, .scope, null, id, 0);
        try setStrings(m.gpa, n, .{ .name = sc.name, .hint_kind = sc.presentationHint });
        n.v.expensive = sc.expensive;
        n.var_ref = sc.variablesReference;
        n.v.child_count = counts(sc.variablesReference, sc.namedVariables, sc.indexedVariables);
        n.gen = gen;
        // Scope references are new with every `scopes` answer.
        n.children_gen = 0;
        n.loading = false;
        try m.roots_.append(m.gpa, id);
    }
    for (m.roots_.items) |r| if (m.isExpanded(r)) m.fetchChildren(m.nodes.get(r).?, gen);
}

fn counts(ref: i64, named: ?i64, indexed: ?i64) ?ChildCount {
    if (ref <= 0) return null;
    return .{
        .named = std.math.cast(u32, named orelse 0) orelse 0,
        .indexed = std.math.cast(u32, indexed orelse 0) orelse 0,
    };
}

// ---------------------------------------------------------------------
// Fetching children.

fn fetchChildren(m: *VariablesModel, n: *Node, gen: u64) void {
    if (n.loading) return;
    const insp = m.inspector();
    if (n.v.kind == .bucket) {
        if (n.count > leaf_bucket) {
            m.buildBuckets(n, n.start, n.count, 0, gen) catch return;
            n.children_gen = gen;
            m.reexpand(n, gen);
            return;
        }
        return m.requestVariables(n, .indexed, n.start, n.count);
    }
    if (n.var_ref <= 0 or n.v.kind == .more) {
        n.children.clearRetainingCapacity();
        n.children_gen = gen;
        return;
    }
    const cc = n.v.child_count orelse ChildCount{};
    const paging = insp.opts.paging;
    if (paging and cc.indexed > leaf_bucket) {
        if (cc.named > 0) return m.requestVariables(n, .named, 0, 0);
        n.children.clearRetainingCapacity();
        m.buildBuckets(n, 0, cc.indexed, 0, gen) catch return;
        n.children_gen = gen;
        m.reexpand(n, gen);
        return;
    }
    m.requestVariables(n, .all, 0, 0);
}

const Filter = enum(u2) { all, named, indexed };

fn requestVariables(m: *VariablesModel, n: *Node, filter: Filter, start: u32, count: u32) void {
    var buf: [192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("{{\"variablesReference\":{d}", .{n.var_ref}) catch unreachable;
    switch (filter) {
        .all => {},
        .named => w.writeAll(",\"filter\":\"named\"") catch unreachable,
        .indexed => w.print(",\"filter\":\"indexed\",\"start\":{d},\"count\":{d}", .{ start, count }) catch unreachable,
    }
    if (m.hex) w.writeAll(",\"format\":{\"hex\":true}") catch unreachable;
    w.writeByte('}') catch unreachable;
    if (m.inspector().send("variables", w.buffered(), .{ .kind = .variables, .a = @intFromEnum(n.v.id), .b = @intFromEnum(filter) })) n.loading = true;
}

/// Appends bucket nodes over `[start, start + count)` of `n`'s owner to
/// `n.children` (after the first `keep` children).
fn buildBuckets(m: *VariablesModel, n: *Node, start: u32, count: u32, keep: usize, gen: u64) Allocator.Error!void {
    n.children.shrinkRetainingCapacity(keep);
    var size: u64 = leaf_bucket;
    while ((count + size - 1) / size > leaf_bucket) size *= leaf_bucket;
    var at: u64 = start;
    const end: u64 = @as(u64, start) + count;
    var name_buf: [48]u8 = undefined;
    while (at < end) : (at += size) {
        const len: u64 = @min(size, end - at);
        const name = std.fmt.bufPrint(&name_buf, "[{d}..{d}]", .{ at, at + len - 1 }) catch unreachable;
        const id = key(@intFromEnum(n.v.id), 'b', name);
        const b = try m.upsert(id, .bucket, n.v.id, n.root, n.depth);
        try setStrings(m.gpa, b, .{ .name = name });
        b.var_ref = n.var_ref;
        b.gen = gen;
        b.start = @intCast(at);
        b.count = @intCast(len);
        b.v.child_count = .{ .indexed = b.count };
        if (b.children_gen != 0 and b.children_gen != gen) b.children_gen = 0;
        try n.children.append(m.gpa, id);
    }
}

/// Fetches the expanded children of `n` again, within the budget.
fn reexpand(m: *VariablesModel, n: *Node, gen: u64) void {
    const depth_max = m.inspector().opts.reexpand_depth;
    for (n.children.items) |c| {
        if (m.budget == 0) return;
        if (!m.expanded.contains(c)) continue;
        const cn = m.nodes.get(c) orelse continue;
        if (cn.gen != gen or cn.children_gen == gen or cn.loading) continue;
        if (cn.v.lazy or cn.depth > depth_max) continue;
        if (cn.v.kind != .bucket and cn.var_ref <= 0) continue;
        m.budget -= 1;
        m.fetchChildren(cn, gen);
    }
}

const VarJson = struct {
    name: []const u8 = "",
    value: []const u8 = "",
    type: ?[]const u8 = null,
    presentationHint: ?struct {
        kind: ?[]const u8 = null,
        attributes: ?[]const []const u8 = null,
        visibility: ?[]const u8 = null,
        lazy: ?bool = null,
    } = null,
    evaluateName: ?[]const u8 = null,
    variablesReference: i64 = 0,
    namedVariables: ?i64 = null,
    indexedVariables: ?i64 = null,
    memoryReference: ?[]const u8 = null,
};

/// A `variables` answer for node `id` (`filter` as sent).
pub fn applyVariables(m: *VariablesModel, id: NodeId, filter_raw: u64, gen: u64, ok: bool, body: []const u8) Allocator.Error!void {
    const n = m.nodes.get(id) orelse return;
    n.loading = false;
    if (n.gen != gen) return;
    const filter: Filter = @enumFromInt(@as(u2, @intCast(filter_raw & 3)));
    n.children.clearRetainingCapacity();
    n.children_gen = gen;
    if (!ok) {
        const e = try m.upsert(key(@intFromEnum(id), 'e', ""), .more, id, n.root, n.depth + 1);
        try setStrings(m.gpa, e, .{ .name = "", .value = body });
        e.v.err = true;
        e.gen = gen;
        try n.children.append(m.gpa, e.v.id);
        return;
    }
    var arena: std.heap.ArenaAllocator = .init(m.gpa);
    defer arena.deinit();
    const B = struct { variables: []const VarJson = &.{} };
    const b = std.json.parseFromSliceLeaky(B, arena.allocator(), body, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => B{},
    };
    const max = m.inspector().opts.max_children;
    const shown = if (filter == .all) @min(b.variables.len, max) else b.variables.len;
    try n.children.ensureTotalCapacity(m.gpa, shown + 1);
    // Variables of an owner with buckets hang under the owner's id.
    const parent_key: u64 = @intFromEnum(id);
    for (b.variables[0..shown]) |v| {
        var cid = key(parent_key, 'v', v.name);
        // Shadowed names: number the repeats.
        var dup: u64 = 1;
        while (std.mem.indexOfScalar(NodeId, n.children.items, cid) != null) : (dup += 1) cid = key(parent_key +% dup, 'v', v.name);
        const c = try m.upsert(cid, .variable, id, n.root, n.depth + 1);
        try m.setVar(c, v, gen);
        n.children.appendAssumeCapacity(cid);
    }
    if (shown < b.variables.len) {
        var buf: [48]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d} more not shown", .{b.variables.len - shown}) catch unreachable;
        const more = try m.upsert(key(parent_key, 'm', ""), .more, id, n.root, n.depth + 1);
        try setStrings(m.gpa, more, .{ .name = text });
        more.gen = gen;
        n.children.appendAssumeCapacity(more.v.id);
    }
    if (filter == .named) {
        const cc = n.v.child_count orelse ChildCount{};
        try m.buildBuckets(n, 0, cc.indexed, n.children.items.len, gen);
    }
    m.reexpand(n, gen);
}

fn setVar(m: *VariablesModel, c: *Node, v: VarJson, gen: u64) Allocator.Error!void {
    const lazy = if (v.presentationHint) |h| h.lazy orelse false else false;
    var hint: ?Hint = null;
    if (v.presentationHint) |h| {
        var x: Hint = .{};
        if (h.attributes) |attrs| for (attrs) |a| {
            if (std.mem.eql(u8, a, "readOnly")) x.read_only = true;
            if (std.mem.eql(u8, a, "rawString")) x.raw_string = true;
            if (std.mem.eql(u8, a, "hasSideEffects")) x.has_side_effects = true;
            if (std.mem.eql(u8, a, "constant")) x.constant = true;
            if (std.mem.eql(u8, a, "static")) x.static = true;
            if (std.mem.eql(u8, a, "hasDataBreakpoint")) x.has_data_breakpoint = true;
        };
        hint = x;
    }
    const old_ref = c.var_ref;
    c.v.hint = hint;
    try setStrings(m.gpa, c, .{
        .name = v.name,
        .value = if (lazy) lazy_label else v.value,
        .type = v.type,
        .evaluate_name = v.evaluateName,
        .memory_ref = v.memoryReference,
        .hint_kind = if (v.presentationHint) |h| h.kind else null,
        .hint_visibility = if (v.presentationHint) |h| h.visibility else null,
    });
    c.v.lazy = lazy;
    c.var_ref = v.variablesReference;
    c.v.child_count = counts(v.variablesReference, v.namedVariables, v.indexedVariables);
    if (c.gen == gen and old_ref != c.var_ref) c.children_gen = 0;
    c.gen = gen;
    c.loading = false;
    if (!lazy) noteValue(c, gen);
}

/// Updates `changed` from the value now in `c`.
fn noteValue(c: *Node, gen: u64) void {
    const h = std.hash.Wyhash.hash(0, c.v.value);
    if (c.cur_gen != gen) {
        c.base_valid = c.cur_gen != 0;
        c.base_hash = c.cur_hash;
        c.cur_gen = gen;
    }
    c.cur_hash = h;
    c.v.changed = c.base_valid and c.base_hash != h;
}

fn resolveLazy(m: *VariablesModel, n: *Node) void {
    if (n.loading or n.var_ref <= 0) return;
    var buf: [64]u8 = undefined;
    const args = std.fmt.bufPrint(&buf, "{{\"variablesReference\":{d}}}", .{n.var_ref}) catch unreachable;
    if (m.inspector().send("variables", args, .{ .kind = .lazy, .a = @intFromEnum(n.v.id) })) n.loading = true;
}

/// The value of a lazy node arrived.
pub fn applyLazy(m: *VariablesModel, id: NodeId, gen: u64, ok: bool, body: []const u8) Allocator.Error!void {
    const n = m.nodes.get(id) orelse return;
    n.loading = false;
    if (n.gen != gen) return;
    if (!ok) {
        try setStrings(m.gpa, n, .{ .name = n.v.name, .value = body, .type = n.v.type, .evaluate_name = n.v.evaluate_name });
        n.v.err = true;
        n.v.lazy = false;
        return;
    }
    var arena: std.heap.ArenaAllocator = .init(m.gpa);
    defer arena.deinit();
    const B = struct { variables: []const VarJson = &.{} };
    const b = std.json.parseFromSliceLeaky(B, arena.allocator(), body, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    if (b.variables.len == 0) return;
    var v = b.variables[0];
    v.name = try arena.allocator().dupe(u8, n.v.name);
    if (v.evaluateName == null) v.evaluateName = if (n.v.evaluate_name) |e| try arena.allocator().dupe(u8, e) else null;
    if (v.presentationHint) |*h| h.lazy = false;
    try m.setVar(n, v, gen);
    n.children_gen = 0;
}

/// An `evaluate` result with children (a watch, a REPL or hover result):
/// an expandable root for `expr`, outside the scopes. Like every node it
/// holds for the stop it came from; the same expression keeps its id, so
/// its expansion carries over.
pub fn addEvalRoot(m: *VariablesModel, gen: u64, r: EvalRoot) Allocator.Error!NodeId {
    const id = key(0xe7a1, 'r', r.expr);
    const n = try m.upsert(id, .variable, null, id, 0);
    try setStrings(m.gpa, n, .{ .name = r.expr, .value = r.value, .type = r.type, .evaluate_name = r.expr, .memory_ref = r.memory_ref });
    if (n.gen == gen and n.var_ref != r.ref) n.children_gen = 0;
    n.var_ref = r.ref;
    n.v.child_count = counts(r.ref, r.named, r.indexed);
    n.gen = gen;
    n.loading = false;
    noteValue(n, gen);
    return id;
}

pub const EvalRoot = struct {
    expr: []const u8,
    value: []const u8,
    type: ?[]const u8 = null,
    ref: i64,
    named: ?i64 = null,
    indexed: ?i64 = null,
    memory_ref: ?[]const u8 = null,
};

// ---------------------------------------------------------------------
// Setting values.

/// Sets `n`'s value: `setExpression` with its `evaluateName` when the
/// adapter supports it, else `setVariable` on its parent's reference.
/// The scope is fetched again afterwards (other variables may alias).
pub fn setValue(m: *VariablesModel, n: NodeId, text: []const u8, cb: SetCb) void {
    const insp = m.inspector();
    const nd = m.nodes.get(n) orelse return cb.call(false, "no such variable");
    const gen = insp.liveGen() orelse return cb.call(false, "the program is running");
    if (nd.gen != gen or nd.v.kind != .variable) return cb.call(false, "the program is running");
    const caps = insp.ch.caps();
    var aw: std.Io.Writer.Allocating = .init(m.gpa);
    defer aw.deinit();
    var js: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .emit_null_optional_fields = false } };
    const Format = struct { hex: bool };
    const format: ?Format = if (m.hex) .{ .hex = true } else null;
    const command = blk: {
        if ((caps.supportsSetExpression orelse false) and nd.v.evaluate_name != null) {
            js.write(.{ .expression = nd.v.evaluate_name.?, .value = text, .frameId = m.frame_id, .format = format }) catch return cb.call(false, "out of memory");
            break :blk "setExpression";
        }
        if (caps.supportsSetVariable orelse false) {
            const parent = m.nodes.get(nd.parent orelse return cb.call(false, "no parent")) orelse return cb.call(false, "no parent");
            js.write(.{ .variablesReference = parent.var_ref, .name = nd.v.name, .value = text, .format = format }) catch return cb.call(false, "out of memory");
            break :blk "setVariable";
        }
        return cb.call(false, "the debug adapter cannot set values");
    };
    const args = aw.written();
    const token = m.next_token;
    m.next_token += 1;
    m.pending_sets.put(m.gpa, token, .{ .cb = cb, .node = n }) catch return cb.call(false, "out of memory");
    if (!insp.send(command, args, .{ .kind = .set_value, .a = @intFromEnum(n), .b = token })) {
        _ = m.pending_sets.remove(token);
        cb.call(false, "the debug session ended");
    }
}

/// A set answer that can no longer be applied.
pub fn failSet(m: *VariablesModel, token: u64, message: []const u8) void {
    const p = m.pending_sets.fetchRemove(token) orelse return;
    p.value.cb.call(false, message);
}

pub fn applySet(m: *VariablesModel, token: u64, gen: u64, ok: bool, body: []const u8) Allocator.Error!void {
    const p = (m.pending_sets.fetchRemove(token) orelse return).value;
    if (!ok) return p.cb.call(false, body);
    const n = m.nodes.get(p.node) orelse return p.cb.call(true, null);
    var arena: std.heap.ArenaAllocator = .init(m.gpa);
    defer arena.deinit();
    const B = struct {
        value: []const u8 = "",
        type: ?[]const u8 = null,
        variablesReference: ?i64 = null,
        namedVariables: ?i64 = null,
        indexedVariables: ?i64 = null,
        memoryReference: ?[]const u8 = null,
    };
    const b = std.json.parseFromSliceLeaky(B, arena.allocator(), body, .{ .ignore_unknown_fields = true }) catch B{};
    if (n.gen == gen) {
        try setStrings(m.gpa, n, .{
            .name = n.v.name,
            .value = b.value,
            .type = b.type orelse n.v.type,
            .evaluate_name = n.v.evaluate_name,
            .memory_ref = b.memoryReference orelse n.v.memory_ref,
            .hint_kind = if (n.v.hint) |h| h.kind else null,
            .hint_visibility = if (n.v.hint) |h| h.visibility else null,
        });
        if (b.variablesReference) |r| {
            n.var_ref = r;
            n.v.child_count = counts(r, b.namedVariables, b.indexedVariables);
        }
        noteValue(n, gen);
        // Everything under the scope again.
        m.markDirty(n.root);
        m.budget = m.inspector().opts.reexpand_nodes;
        if (m.nodes.get(n.root)) |root| m.fetchChildren(root, gen);
    }
    p.cb.call(true, null);
}

// ---------------------------------------------------------------------
// Bookkeeping.

/// Marks children for fetching again: under scope `root`, or all.
fn markDirty(m: *VariablesModel, root: ?NodeId) void {
    var it = m.nodes.valueIterator();
    while (it.next()) |np| {
        const n = np.*;
        if (root) |r| if (n.root != r) continue;
        n.children_gen = 0;
    }
}

/// Drops nodes not seen for `keep_gens` generations.
fn prune(m: *VariablesModel, gen: u64) void {
    if (gen <= keep_gens) return;
    const limit = gen - keep_gens;
    var dead: std.ArrayList(NodeId) = .empty;
    defer dead.deinit(m.gpa);
    var it = m.nodes.iterator();
    while (it.next()) |e| {
        const n = e.value_ptr.*;
        if (n.gen < limit) {
            dead.append(m.gpa, e.key_ptr.*) catch return;
        } else if (n.children_gen != 0 and n.children_gen < limit) {
            n.children.clearRetainingCapacity();
            n.children_gen = 0;
        }
    }
    for (dead.items) |id| if (m.nodes.fetchRemove(id)) |kv| m.destroyNode(kv.value);
}

/// Forgets the tree (the session ended); expansion is kept.
pub fn clear(m: *VariablesModel) void {
    var it = m.nodes.valueIterator();
    while (it.next()) |n| m.destroyNode(n.*);
    m.nodes.clearRetainingCapacity();
    m.roots_.clearRetainingCapacity();
    m.frame_id = null;
    var ps = m.pending_sets.valueIterator();
    while (ps.next()) |p| p.cb.call(false, "the debug session ended");
    m.pending_sets.clearRetainingCapacity();
}

/// Nodes in the tree (tests).
pub fn nodeCount(m: *const VariablesModel) usize {
    return m.nodes.count();
}

fn key(parent: u64, comptime role: u8, name: []const u8) NodeId {
    var h: std.hash.Wyhash = .init(parent);
    h.update(&.{role});
    h.update(name);
    const v = h.final();
    return @enumFromInt(if (v == 0) 1 else v);
}

fn upsert(m: *VariablesModel, id: NodeId, kind: Kind, parent: ?NodeId, root: NodeId, depth: u8) Allocator.Error!*Node {
    const gop = try m.nodes.getOrPut(m.gpa, id);
    if (gop.found_existing) {
        const n = gop.value_ptr.*;
        n.v.kind = kind;
        n.v.err = false;
        n.parent = parent;
        n.root = root;
        n.depth = depth;
        return n;
    }
    const n = m.gpa.create(Node) catch |e| {
        m.nodes.removeByPtr(gop.key_ptr);
        return e;
    };
    n.* = .{ .v = .{ .id = id, .name = "", .kind = kind }, .parent = parent, .root = root, .depth = depth };
    gop.value_ptr.* = n;
    return n;
}

const Strings = struct {
    name: []const u8,
    value: []const u8 = "",
    type: ?[]const u8 = null,
    evaluate_name: ?[]const u8 = null,
    memory_ref: ?[]const u8 = null,
    hint_kind: ?[]const u8 = null,
    hint_visibility: ?[]const u8 = null,
};

/// Replaces `n`'s strings with copies in one allocation (the inputs may
/// point into the old one).
fn setStrings(gpa: Allocator, n: *Node, s: Strings) Allocator.Error!void {
    const flags = n.v.hint;
    var total: usize = 0;
    inline for (@typeInfo(Strings).@"struct".fields) |f| {
        const v = @field(s, f.name);
        total += if (@TypeOf(v) == []const u8) v.len else if (v) |x| x.len else 0;
    }
    const buf = try gpa.alloc(u8, total);
    var at: usize = 0;
    var out: Strings = undefined;
    inline for (@typeInfo(Strings).@"struct".fields) |f| {
        const v = @field(s, f.name);
        if (@TypeOf(v) == []const u8) {
            @memcpy(buf[at..][0..v.len], v);
            @field(out, f.name) = buf[at..][0..v.len];
            at += v.len;
        } else if (v) |x| {
            @memcpy(buf[at..][0..x.len], x);
            @field(out, f.name) = buf[at..][0..x.len];
            at += x.len;
        } else @field(out, f.name) = null;
    }
    gpa.free(n.strings);
    n.strings = buf;
    n.v.name = out.name;
    n.v.value = out.value;
    n.v.type = out.type;
    n.v.evaluate_name = out.evaluate_name;
    n.v.memory_ref = out.memory_ref;
    // The flags stay; the strings are the new copies.
    n.v.hint = if (out.hint_kind != null or out.hint_visibility != null or flags != null) blk: {
        var h = flags orelse Hint{};
        h.kind = out.hint_kind;
        h.visibility = out.hint_visibility;
        break :blk h;
    } else null;
}
