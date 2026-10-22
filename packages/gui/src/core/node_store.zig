//! `NodeStore`: the retained node tree in struct-of-arrays form. Hot fields
//! (links, flags, rects) live in a `MultiArrayList`; the style, retained
//! props and layout cache live in a parallel cold array.

const std = @import("std");
const geom = @import("geom.zig");
const ids = @import("ids.zig");
const widget = @import("widget.zig");
const style_mod = @import("../layout/style.zig");
const canvas = @import("../paint/canvas.zig");

const NodeId = ids.NodeId;
const Key = ids.Key;
const KindId = ids.KindId;
const Allocator = std.mem.Allocator;

/// Per-node flags.
pub const NodeFlags = packed struct(u32) {
    layout_dirty: bool = true,
    paint_dirty: bool = true,
    seen: bool = false,
    focusable: bool = false,
    hit_testable: bool = false,
    clips: bool = false,
    layer: bool = false,
    relayout_boundary: bool = false,
    has_a11y: bool = false,
    hidden: bool = false,
    /// A descendant needs layout.
    subtree_dirty: bool = true,
    /// The node is a view boundary (`Ui.mount`).
    view_root: bool = false,
    disabled: bool = false,
    /// The node was painted at least once (`abs` is meaningful).
    painted: bool = false,
    _pad: u18 = 0,
};

/// The hot, per-frame fields of a node.
pub const NodeHot = struct {
    key: Key,
    parent: NodeId,
    first_child: NodeId,
    next_sibling: NodeId,
    kind: KindId,
    view: u16,
    flags: NodeFlags,
    props_hash: u64,
    paint_hash: u64,
    /// x, y, w, h relative to the parent's border box.
    rect: [4]f32,
    /// Absolute rectangle from the last paint.
    abs: [4]f32,
    paint_range: canvas.Range,
    state: ?*anyopaque,
};

/// Inputs and output of a node's last layout, for cache hits.
pub const LayoutCache = struct {
    valid: bool = false,
    known_w: f32 = 0,
    known_h: f32 = 0,
    avail_w: f32 = 0,
    avail_h: f32 = 0,
    size: geom.Size = .{},
    /// Distance from the top of the node to its first baseline.
    baseline: f32 = 0,
};

/// The cold fields of a node.
pub const NodeCold = struct {
    gen: u8 = 0,
    depth: u16 = 0,
    style: style_mod.Style = .{},
    style_hash: u64 = 0,
    blob: widget.Blob = .{},
    cache: LayoutCache = .{},
    test_id: u64 = 0,
};

/// Iterates a node's children in order.
pub const ChildIter = struct {
    store: *const NodeStore,
    cur: NodeId,

    /// The next child, or null.
    pub fn next(it: *ChildIter) ?NodeId {
        if (it.cur.isNone()) return null;
        const id = it.cur;
        it.cur = it.store.hot.items(.next_sibling)[id.index];
        return id;
    }
};

/// The node tree storage of one window.
pub const NodeStore = struct {
    gpa: Allocator,
    hot: std.MultiArrayList(NodeHot) = .empty,
    cold: std.ArrayList(NodeCold) = .empty,
    free_list: std.ArrayList(u24) = .empty,
    live: u32 = 0,
    /// Called for every freed node (damage, focus fix-ups).
    on_free: ?struct { ctx: *anyopaque, f: *const fn (*anyopaque, NodeId) void } = null,

    /// An empty store with room for `capacity` nodes. Index 0 is reserved.
    pub fn init(gpa: Allocator, capacity: u32) !NodeStore {
        var s: NodeStore = .{ .gpa = gpa };
        try s.hot.ensureTotalCapacity(gpa, capacity + 1);
        try s.cold.ensureTotalCapacity(gpa, capacity + 1);
        // Slot 0 backs `NodeId.none` and is never handed out.
        s.hot.appendAssumeCapacity(blank(0, .root));
        s.cold.appendAssumeCapacity(.{});
        return s;
    }

    /// Frees every node and the store.
    pub fn deinit(s: *NodeStore) void {
        const states = s.hot.items(.state);
        const kinds = s.hot.items(.kind);
        for (s.cold.items, 0..) |*c, i| {
            if (i == 0) continue;
            if (states[i]) |st| freeState(s.gpa, kinds[i], st);
            c.blob.deinit(s.gpa);
        }
        s.hot.deinit(s.gpa);
        s.cold.deinit(s.gpa);
        s.free_list.deinit(s.gpa);
    }

    fn blank(key: Key, kind: KindId) NodeHot {
        return .{
            .key = key,
            .parent = .none,
            .first_child = .none,
            .next_sibling = .none,
            .kind = kind,
            .view = 0,
            .flags = .{},
            .props_hash = 0,
            .paint_hash = 0,
            .rect = .{ 0, 0, 0, 0 },
            .abs = .{ 0, 0, 0, 0 },
            .paint_range = .{},
            .state = null,
        };
    }

    /// Allocates a node, reusing a freed slot (with a new generation).
    pub fn alloc(s: *NodeStore, key: Key, kind: KindId) !NodeId {
        const vt = widget.vtable(kind);
        var state: ?*anyopaque = null;
        if (vt.state_size > 0) {
            const mem = s.gpa.rawAlloc(vt.state_size, .fromByteUnits(vt.state_align), @returnAddress()) orelse return error.OutOfMemory;
            vt.initState(mem);
            state = mem;
        }
        errdefer if (state) |st| freeState(s.gpa, kind, st);
        var index: u24 = undefined;
        if (s.free_list.pop()) |i| {
            index = i;
        } else {
            if (s.hot.len >= std.math.maxInt(u24)) return error.OutOfMemory;
            try s.hot.append(s.gpa, blank(0, kind));
            errdefer _ = s.hot.pop();
            try s.cold.append(s.gpa, .{});
            index = @intCast(s.hot.len - 1);
        }
        var h = blank(key, kind);
        h.state = state;
        h.flags.focusable = vt.focusable;
        h.flags.hit_testable = vt.hit_testable;
        s.hot.set(index, h);
        const c = &s.cold.items[index];
        c.gen +%= 1;
        if (c.gen == 0) c.gen = 1;
        c.cache = .{};
        c.style = .{};
        c.style_hash = 0;
        c.test_id = 0;
        s.live += 1;
        return .{ .index = index, .gen = c.gen };
    }

    /// Frees one node (not its children): runs the state's deinit, keeps
    /// the props blob for reuse, bumps the generation on next alloc.
    pub fn free(s: *NodeStore, id: NodeId) void {
        std.debug.assert(s.valid(id));
        if (s.on_free) |cb| cb.f(cb.ctx, id);
        const i = id.index;
        if (s.hot.items(.state)[i]) |st| freeState(s.gpa, s.hot.items(.kind)[i], st);
        s.hot.items(.state)[i] = null;
        s.hot.items(.key)[i] = 0;
        s.cold.items[i].gen +%= 1; // stale ids stop validating immediately
        s.cold.items[i].cache.valid = false;
        s.free_list.append(s.gpa, i) catch {
            // The slot leaks until the store is freed; ids stay safe.
        };
        s.live -= 1;
    }

    /// Frees `id` and its whole subtree, children first.
    pub fn freeSubtree(s: *NodeStore, id: NodeId) void {
        var c = s.hot.items(.first_child)[id.index];
        while (!c.isNone()) {
            const next = s.hot.items(.next_sibling)[c.index];
            s.freeSubtree(c);
            c = next;
        }
        s.free(id);
    }

    fn freeState(gpa: Allocator, kind: KindId, st: *anyopaque) void {
        const vt = widget.vtable(kind);
        vt.deinitState(st);
        const bytes: [*]u8 = @ptrCast(st);
        gpa.rawFree(bytes[0..vt.state_size], .fromByteUnits(vt.state_align), @returnAddress());
    }

    /// True when `id` refers to a live node.
    pub fn valid(s: *const NodeStore, id: NodeId) bool {
        if (id.isNone() or id.index >= s.hot.len) return false;
        return s.cold.items[id.index].gen == id.gen;
    }

    /// The index of `id`, or null when stale.
    pub fn get(s: *const NodeStore, id: NodeId) ?usize {
        return if (s.valid(id)) id.index else null;
    }

    /// The children of `id`.
    pub fn children(s: *const NodeStore, id: NodeId) ChildIter {
        return .{ .store = s, .cur = s.hot.items(.first_child)[id.index] };
    }

    /// The flags of `id`.
    pub fn flags(s: *NodeStore, id: NodeId) *NodeFlags {
        return &s.hot.items(.flags)[id.index];
    }

    /// The cold record of `id`.
    pub fn coldOf(s: *NodeStore, id: NodeId) *NodeCold {
        return &s.cold.items[id.index];
    }

    /// The retained props of `id` (null before the first build).
    pub fn props(s: *const NodeStore, id: NodeId) ?*const anyopaque {
        const b = s.cold.items[id.index].blob.bytes;
        return if (b.len == 0) null else @ptrCast(b.ptr);
    }

    /// The parent of `id`.
    pub fn parent(s: *const NodeStore, id: NodeId) NodeId {
        return s.hot.items(.parent)[id.index];
    }

    /// The absolute rectangle from the last paint.
    pub fn absRect(s: *const NodeStore, id: NodeId) geom.Rect {
        return geom.Rect.fromArray(s.hot.items(.abs)[id.index]);
    }

    /// The rectangle relative to the parent from the last layout.
    pub fn relRect(s: *const NodeStore, id: NodeId) geom.Rect {
        return geom.Rect.fromArray(s.hot.items(.rect)[id.index]);
    }

    /// Marks `id` for layout and flags its ancestors.
    pub fn markLayout(s: *NodeStore, id: NodeId) void {
        const fl = s.hot.items(.flags);
        const par = s.hot.items(.parent);
        fl[id.index].layout_dirty = true;
        fl[id.index].paint_dirty = true;
        var p = id;
        while (!p.isNone()) : (p = par[p.index]) {
            if (fl[p.index].subtree_dirty and !p.eql(id)) break;
            fl[p.index].subtree_dirty = true;
        }
    }

    /// Flags `id` and its ancestors as having a descendant that needs
    /// layout (child list changed), without repainting `id`.
    pub fn markChildren(s: *NodeStore, id: NodeId) void {
        const fl = s.hot.items(.flags);
        const par = s.hot.items(.parent);
        var p = id;
        var first = true;
        while (!p.isNone()) : (p = par[p.index]) {
            if (fl[p.index].subtree_dirty and !first) break;
            fl[p.index].subtree_dirty = true;
            first = false;
        }
    }

    /// Marks `id` for repaint.
    pub fn markPaint(s: *NodeStore, id: NodeId) void {
        s.hot.items(.flags)[id.index].paint_dirty = true;
    }

    /// True when `anc` is `id` or one of its ancestors.
    pub fn isAncestor(s: *const NodeStore, anc: NodeId, id: NodeId) bool {
        var p = id;
        while (!p.isNone()) : (p = s.hot.items(.parent)[p.index]) {
            if (p.eql(anc)) return true;
        }
        return false;
    }
};

comptime {
    // E04 budget: hot SoA at most 160 bytes per node.
    var total: usize = 0;
    for (@typeInfo(NodeHot).@"struct".fields) |f| total += @sizeOf(f.type);
    std.debug.assert(total <= 160);
}

test "alloc, free and generations" {
    const box = @import("../widgets/box.zig");
    box.registerBuiltins();
    var s = try NodeStore.init(std.testing.allocator, 4);
    defer s.deinit();
    const a = try s.alloc(11, .box);
    try std.testing.expect(s.valid(a));
    s.free(a);
    try std.testing.expect(!s.valid(a));
    const b = try s.alloc(12, .box);
    try std.testing.expectEqual(a.index, b.index);
    try std.testing.expect(a.gen != b.gen);
    try std.testing.expect(s.valid(b));
    try std.testing.expectEqual(@as(u32, 1), s.live);
}
