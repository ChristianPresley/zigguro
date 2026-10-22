//! The accessibility snapshot (E04.F09.S01.T01): an immutable copy of a
//! window's semantic tree that platform bridges read from their own
//! threads, and the lock-free protocol that publishes it.
//!
//! The UI thread builds each snapshot into a pooled buffer and publishes
//! it with one atomic store. A reader on another thread `acquire`s the
//! current one (an acquire load, a reference count increment, and a
//! re-check that it is still current, else it backs off and retries) and
//! `release`s it when done. The UI thread writes only into a buffer that
//! is not current and has no references; when every spare buffer is held
//! it allocates another. Nothing on the UI thread takes a lock.

const std = @import("std");
const widget = @import("../core/widget.zig");
const ids = @import("../core/ids.zig");

const Allocator = std.mem.Allocator;
const NodeId = ids.NodeId;

/// States of a node, as bits (bridges map them to UIA properties or
/// AT-SPI state words).
pub const State = packed struct(u16) {
    focusable: bool = false,
    focused: bool = false,
    checkable: bool = false,
    checked: bool = false,
    expandable: bool = false,
    expanded: bool = false,
    selectable: bool = false,
    selected: bool = false,
    disabled: bool = false,
    /// Not painted, outside the window, or behind a modal overlay.
    offscreen: bool = false,
    /// A modal dialog.
    modal: bool = false,
    /// Takes text (text boxes).
    editable: bool = false,
    _pad: u4 = 0,

    /// The bits as an integer.
    pub fn bits(s: State) u16 {
        return @bitCast(s);
    }
};

/// One node of the semantic tree.
pub const Node = struct {
    /// Stable id: `(window << 32) | (gen << 24 | index)`; a reused node
    /// index has another generation, so ids never repeat while a node
    /// lives.
    id: u64,
    /// The parent's index in `Snapshot.nodes` (`no_parent` for the root).
    parent: u32,
    /// The children: `Snapshot.kids[kids_start..][0..kids_len]`.
    kids_start: u32 = 0,
    kids_len: u32 = 0,
    role: widget.Role,
    name: []const u8 = "",
    /// An editable node's text.
    text: []const u8 = "",
    state: State = .{},
    value: ?f32 = null,
    level: u16 = 0,
    row_count: u64 = 0,
    col_count: u32 = 0,
    row_index: u64 = 0,
    col_index: u32 = 0,
    sort: widget.SortState = .none,
    /// Window logical pixels from the last paint: x, y, w, h.
    bounds: [4]f32 = .{ 0, 0, 0, 0 },
    /// The hash of the node's `test_id` (0: none); bridges expose it as
    /// the automation id.
    test_id: u64 = 0,
    /// The node in the window's store (UI thread only).
    node: NodeId,
    /// Hash of every field above except the links, for diffs.
    hash: u64 = 0,

    pub const no_parent = std.math.maxInt(u32);
};

/// The id of node `n` in window `window`.
pub fn idOf(window: u32, n: NodeId) u64 {
    return (@as(u64, window) << 32) | n.raw();
}

/// Node ids to positions. Ids are unique, so a multiplicative hash
/// spreads them well enough.
pub const Index = std.HashMapUnmanaged(u64, u32, struct {
    pub fn hash(_: @This(), k: u64) u64 {
        return (k ^ (k >> 29)) *% 0x9e3779b97f4a7c15;
    }
    pub fn eql(_: @This(), a: u64, b: u64) bool {
        return a == b;
    }
}, std.hash_map.default_max_load_percentage);

/// An immutable semantic tree. `nodes[0]` is the window.
pub const Snapshot = struct {
    nodes: []const Node = &.{},
    kids: []const u32 = &.{},
    /// The focused node's id (0: none).
    focus: u64 = 0,
    window: u32 = 0,
    /// Logical to physical pixels.
    scale: f32 = 1,
    /// The window's top-left on screen, physical pixels (null where the
    /// platform doesn't say, as on Wayland).
    screen_origin: ?[2]i32 = null,
    /// The window is the active (focused) one.
    active: bool = false,
    /// Bumped by each publish.
    version: u64 = 0,
    index: Index = .empty,

    arena: std.heap.ArenaAllocator,
    refs: std.atomic.Value(u32) = .init(0),

    /// The node with `id`.
    pub fn find(s: *const Snapshot, id: u64) ?*const Node {
        const i = s.index.get(id) orelse return null;
        return &s.nodes[i];
    }

    /// The children of `n`.
    pub fn children(s: *const Snapshot, n: *const Node) []const u32 {
        return s.kids[n.kids_start..][0..n.kids_len];
    }

    /// The window node.
    pub fn root(s: *const Snapshot) ?*const Node {
        return if (s.nodes.len > 0) &s.nodes[0] else null;
    }

    /// The deepest visible node whose bounds contain `p` (logical
    /// pixels), for hit tests from bridges.
    pub fn nodeAt(s: *const Snapshot, x: f32, y: f32) ?*const Node {
        var cur = s.root() orelse return null;
        outer: while (true) {
            const ks = s.children(cur);
            var i = ks.len;
            // Later children paint above earlier ones.
            while (i > 0) {
                i -= 1;
                const k = &s.nodes[ks[i]];
                if (k.state.offscreen) continue;
                const b = k.bounds;
                if (x >= b[0] and y >= b[1] and x < b[0] + b[2] and y < b[1] + b[3]) {
                    cur = k;
                    continue :outer;
                }
            }
            return cur;
        }
    }

    /// Drops a reference taken by `Publisher.acquire` (any thread).
    pub fn release(s: *Snapshot) void {
        _ = s.refs.fetchSub(1, .release);
    }
};

/// Publishes snapshots to other threads; see the module doc.
pub const Publisher = struct {
    gpa: Allocator,
    current: std.atomic.Value(?*Snapshot) = .init(null),
    /// Every buffer (UI thread).
    pool: std.ArrayList(*Snapshot) = .empty,
    version: u64 = 0,

    pub fn init(gpa: Allocator) Publisher {
        return .{ .gpa = gpa };
    }

    /// Frees every buffer. No reader may hold one.
    pub fn deinit(p: *Publisher) void {
        for (p.pool.items) |s| {
            s.arena.deinit();
            p.gpa.destroy(s);
        }
        p.pool.deinit(p.gpa);
        p.current.store(null, .release);
    }

    /// The current snapshot with a reference held, or null before the
    /// first publish (any thread). Pair with `Snapshot.release`.
    pub fn acquire(p: *Publisher) ?*Snapshot {
        while (true) {
            const s = p.current.load(.acquire) orelse return null;
            _ = s.refs.fetchAdd(1, .seq_cst);
            // Still current: the UI thread won't write it until released.
            if (p.current.load(.seq_cst) == s) return s;
            _ = s.refs.fetchSub(1, .release);
            std.atomic.spinLoopHint();
        }
    }

    /// The current snapshot without a reference (UI thread only: only it
    /// replaces snapshots).
    pub fn peek(p: *const Publisher) ?*Snapshot {
        return p.current.load(.acquire);
    }

    /// A cleared buffer to build the next snapshot in (UI thread).
    pub fn fresh(p: *Publisher) Allocator.Error!*Snapshot {
        const cur = p.current.load(.acquire);
        for (p.pool.items) |s| {
            if (s == cur or s.refs.load(.seq_cst) != 0) continue;
            _ = s.arena.reset(.retain_capacity);
            // Field by field: a late reader may be bumping `refs` (it
            // backs off once it sees this buffer isn't current).
            s.nodes = &.{};
            s.kids = &.{};
            s.focus = 0;
            s.window = 0;
            s.scale = 1;
            s.screen_origin = null;
            s.active = false;
            s.index = .empty;
            return s;
        }
        const s = try p.gpa.create(Snapshot);
        errdefer p.gpa.destroy(s);
        try p.pool.append(p.gpa, s);
        s.* = .{ .arena = .init(p.gpa) };
        return s;
    }

    /// Makes `s` (from `fresh`) the current snapshot (UI thread).
    pub fn publish(p: *Publisher, s: *Snapshot) void {
        p.version += 1;
        s.version = p.version;
        p.current.store(s, .seq_cst);
    }
};
