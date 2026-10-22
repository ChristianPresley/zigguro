//! `PathStore`: every workspace path as a node in one compact tree.
//!
//! - **Nodes** live in a persistent chunked array (chunks of 4096 nodes).
//!   Each node holds its parent, its siblings (doubly linked), its first
//!   child, an interned basename, `NodeInfo` and a generation. Freed slots go
//!   on a free list with a bumped generation, so a stale `FileId` resolves to
//!   null instead of aliasing a new node.
//! - **Names** are stored in append-only blocks whose bytes never move, so
//!   every snapshot can point at them without copying; common basenames are
//!   shared through a bounded cache.
//! - **Snapshots** are immutable views that share chunks with the writer. The
//!   writer copies a chunk the first time it changes it after a publish
//!   (copy-on-write per chunk), then publishes a new snapshot with one atomic
//!   store. Readers acquire wait-free (three atomic operations) and release
//!   by decrementing a refcount; the writer reclaims retired snapshots once no
//!   reader holds or is acquiring them.
//! - **Writes** come from a single writer (the scanner/watch pipeline task)
//!   through `apply(Delta)`, which reports `Change`s. A rename relinks the
//!   node, so the subtree keeps its `FileId`s.
//!
//! Paths are root-relative, `/`-separated, without leading or trailing `/`.
//! Children are unordered while writing; a snapshot sorts a directory's
//! children (byte order of the names) the first time someone asks and caches
//! the result. Sizes are clamped to 48 bits (256 TiB); mtimes keep seconds
//! and nanoseconds to 64 ns precision.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ids = @import("../ids.zig");
const RootId = ids.RootId;
const FileId = ids.FileId;

/// What a node is.
pub const NodeKind = enum(u3) { file, dir, symlink_file, symlink_dir, other };

/// Per-node flags.
pub const Flags = packed struct(u13) {
    /// Hidden by the ignore stack (kept only when "show ignored" is on).
    ignored: bool = false,
    /// A dotfile or OS-hidden entry.
    hidden: bool = false,
    /// Classified as binary by the indexer.
    binary: bool = false,
    /// Larger than the indexer's size cap.
    too_large: bool = false,
    /// Inside a notes vault.
    vault: bool = false,
    /// A directory whose children are not fully listed yet.
    loading: bool = false,
    /// Hidden by a `files.exclude` setting.
    excluded_by_setting: bool = false,
    _: u6 = 0,
};

/// Kind, flags, size and modification time of a node, in 16 bytes.
pub const NodeInfo = packed struct(u128) {
    kind: NodeKind = .file,
    flags: Flags = .{},
    /// Size in bytes, clamped to 2^48 - 1.
    size: u48 = 0,
    /// Modification time, whole seconds since the Unix epoch (clamped at 0).
    mtime_s: u40 = 0,
    /// Nanoseconds within the second, shifted right by 6 (64 ns units).
    mtime_ns_hi: u24 = 0,

    /// Builds an info from a size and an mtime in nanoseconds.
    pub fn init(kind: NodeKind, size: u64, mtime_ns: i128) NodeInfo {
        const ns: i128 = @max(mtime_ns, 0);
        return .{
            .kind = kind,
            .size = @intCast(@min(size, std.math.maxInt(u48))),
            .mtime_s = @intCast(@min(@divTrunc(ns, std.time.ns_per_s), std.math.maxInt(u40))),
            .mtime_ns_hi = @intCast(@divTrunc(@rem(ns, std.time.ns_per_s), 64)),
        };
    }

    /// The mtime in nanoseconds (64 ns precision).
    pub fn mtimeNs(i: NodeInfo) i128 {
        return @as(i128, i.mtime_s) * std.time.ns_per_s + @as(i128, i.mtime_ns_hi) * 64;
    }

    /// Whether the node is a directory (or a symlink to one).
    pub fn isDir(i: NodeInfo) bool {
        return i.kind == .dir or i.kind == .symlink_dir;
    }

    /// Whether two infos describe the same content state (kind, size, mtime).
    pub fn sameContent(a: NodeInfo, b: NodeInfo) bool {
        return a.kind == b.kind and a.size == b.size and a.mtime_s == b.mtime_s and a.mtime_ns_hi == b.mtime_ns_hi;
    }
};

const nil: u32 = std.math.maxInt(u32);
const chunk_shift = 12;
const chunk_len = 1 << chunk_shift;

const Node = struct {
    name_ptr: [*]const u8,
    name_len: u32,
    parent: u32,
    first_child: u32,
    next_sibling: u32,
    prev_sibling: u32,
    gen: u32,
    /// Hash of the (case-folded on case-insensitive roots) name.
    name_hash: u32,
    root: u16,
    live: bool,
    info: NodeInfo align(8),

    fn name(n: *const Node) []const u8 {
        return n.name_ptr[0..n.name_len];
    }
};

comptime {
    // Node layout is part of the memory budget (1 M paths < 110 MB).
    std.debug.assert(@sizeOf(Node) <= 56);
}

const Chunk = struct {
    refs: std.atomic.Value(u32),
    nodes: [chunk_len]Node,
};

/// A batch of path operations, applied atomically by `PathStore.apply`.
pub const Delta = struct {
    /// The operations, applied in order.
    ops: []const Op,

    /// One operation.
    pub const Op = union(enum) {
        /// Creates or updates a node; creates missing parents as `loading` dirs.
        upsert: struct { root: RootId, rel: []const u8, info: NodeInfo },
        /// Removes a node and its subtree.
        remove: struct { root: RootId, rel: []const u8 },
        /// Moves a node (and its subtree, keeping their ids); replaces any
        /// node already at `to`.
        rename: struct { root: RootId, from: []const u8, to: []const u8 },
        /// Clears a directory's `loading` flag: its listing is complete.
        set_children_complete: struct { root: RootId, rel_dir: []const u8 },
        /// Drops every node of a root except the root itself (rescan).
        reset_root: RootId,
    };
};

/// One effect of `apply`.
pub const Change = struct {
    /// The node concerned (for `removed`, the id it had).
    id: FileId,
    /// What happened.
    what: enum { added, removed, renamed, modified },
    /// For `renamed`: the previous parent directory.
    old_parent: ?FileId = null,
};

/// Errors of `apply`.
pub const ApplyError = Allocator.Error || error{ UnknownRoot, NotADirectory, InvalidPath, RenameIntoSelf };

/// The writer side of the path tree.
pub const PathStore = struct {
    gpa: Allocator,
    io: std.Io,
    names: NameArena,
    chunks: std.ArrayList(*Chunk) = .empty,
    /// Whether the writer may modify chunk i in place (not yet published).
    owned: std.ArrayList(bool) = .empty,
    slots: u32 = 0,
    free: std.ArrayList(u32) = .empty,
    index: std.HashMapUnmanaged(u32, void, IndexCtx, 80) = .empty,
    roots: std.ArrayList(RootSlot) = .empty,
    file_count: u32 = 0,
    generation: u64 = 0,
    current: std.atomic.Value(*Snapshot),
    /// The last parent directory an upsert resolved (scans insert directory
    /// by directory, so consecutive upserts usually share it).
    walk: WalkCache = .{},
    acquiring: std.atomic.Value(u32) = .init(0),
    retired: std.ArrayList(*Snapshot) = .empty,

    /// Creates an empty store and publishes generation 0.
    pub fn init(gpa: Allocator, io: std.Io) !*PathStore {
        const ps = try gpa.create(PathStore);
        errdefer gpa.destroy(ps);
        ps.* = .{ .gpa = gpa, .io = io, .names = .{}, .current = .init(undefined) };
        const s = try ps.buildSnapshot();
        ps.current = .init(s);
        return ps;
    }

    /// Frees everything. No snapshot may still be held.
    pub fn deinit(ps: *PathStore) void {
        const cur = ps.current.load(.acquire);
        _ = cur.refs.fetchSub(1, .acq_rel);
        ps.retired.append(ps.gpa, cur) catch freeSnapshot(ps.gpa, cur);
        for (ps.retired.items) |s| {
            std.debug.assert(s.refs.load(.acquire) == 0);
            freeSnapshot(ps.gpa, s);
        }
        ps.retired.deinit(ps.gpa);
        for (ps.chunks.items) |c| releaseChunk(ps.gpa, c);
        ps.chunks.deinit(ps.gpa);
        ps.owned.deinit(ps.gpa);
        ps.free.deinit(ps.gpa);
        ps.index.deinit(ps.gpa);
        ps.roots.deinit(ps.gpa);
        ps.names.deinit(ps.gpa);
        ps.gpa.destroy(ps);
    }

    /// Registers root `root` (ids must be added in order) with its root
    /// directory node, and publishes.
    pub fn addRoot(ps: *PathStore, root: RootId, case_insensitive: bool) !void {
        std.debug.assert(root.index() == ps.roots.items.len);
        const i = try ps.allocNode();
        const n = try ps.nodeMut(i);
        n.* = .{
            .name_ptr = "".ptr,
            .name_len = 0,
            .parent = nil,
            .first_child = nil,
            .next_sibling = nil,
            .prev_sibling = nil,
            .gen = n.gen,
            .name_hash = 0,
            .root = root.index(),
            .live = true,
            .info = .{ .kind = .dir, .flags = .{ .loading = true } },
        };
        try ps.roots.append(ps.gpa, .{ .node = i, .case_insensitive = case_insensitive, .live = true });
        try ps.publish();
    }

    /// Drops root `root` and all its nodes (its slot stays reserved).
    pub fn removeRoot(ps: *PathStore, root: RootId, changes: *std.ArrayList(Change)) !void {
        const slot = &ps.roots.items[root.index()];
        if (!slot.live) return;
        var out: ChangeList = .{ .list = changes, .gpa = ps.gpa };
        try ps.removeSubtree(slot.node, &out, true);
        slot.live = false;
        try ps.publish();
    }

    /// Applies `delta` (single writer) and publishes a new snapshot.
    /// `changes` grows with the store's allocator.
    pub fn apply(ps: *PathStore, delta: *const Delta, changes: *std.ArrayList(Change)) ApplyError!void {
        return ps.applyWith(delta, changes, ps.gpa);
    }

    /// Like `apply`, with `changes` growing in `changes_gpa`.
    pub fn applyWith(ps: *PathStore, delta: *const Delta, changes: *std.ArrayList(Change), changes_gpa: Allocator) ApplyError!void {
        try ps.index.ensureUnusedCapacityContext(ps.gpa, @intCast(delta.ops.len), .{ .ps = ps });
        var out: ChangeList = .{ .list = changes, .gpa = changes_gpa };
        for (delta.ops) |op| try ps.applyOne(op, &out);
        try ps.publish();
        ps.collect();
    }

    /// Acquires the current snapshot (any thread, wait-free). Release it
    /// with `Snapshot.release`.
    pub fn snapshot(ps: *PathStore) *const Snapshot {
        _ = ps.acquiring.fetchAdd(1, .seq_cst);
        const s = ps.current.load(.seq_cst);
        _ = s.refs.fetchAdd(1, .seq_cst);
        _ = ps.acquiring.fetchSub(1, .seq_cst);
        return s;
    }

    /// Frees retired snapshots nobody holds (writer only; `apply` calls it).
    pub fn collect(ps: *PathStore) void {
        if (ps.acquiring.load(.seq_cst) != 0) return;
        var i: usize = 0;
        while (i < ps.retired.items.len) {
            const s = ps.retired.items[i];
            if (s.refs.load(.seq_cst) == 0) {
                freeSnapshot(ps.gpa, s);
                _ = ps.retired.swapRemove(i);
            } else i += 1;
        }
    }

    /// The live node count (files and directories, excluding root nodes).
    pub fn nodeCount(ps: *const PathStore) u32 {
        return ps.slots - @as(u32, @intCast(ps.free.items.len)) - @as(u32, @intCast(ps.roots.items.len));
    }

    // ---- writer internals ----

    fn node(ps: *const PathStore, i: u32) *const Node {
        return &ps.chunks.items[i >> chunk_shift].nodes[i & (chunk_len - 1)];
    }

    fn nodeMut(ps: *PathStore, i: u32) !*Node {
        const c = i >> chunk_shift;
        if (!ps.owned.items[c]) {
            const old = ps.chunks.items[c];
            const fresh = try ps.gpa.create(Chunk);
            fresh.refs = .init(1);
            fresh.nodes = old.nodes;
            ps.chunks.items[c] = fresh;
            ps.owned.items[c] = true;
            releaseChunk(ps.gpa, old);
        }
        return &ps.chunks.items[c].nodes[i & (chunk_len - 1)];
    }

    fn allocNode(ps: *PathStore) !u32 {
        if (ps.free.pop()) |i| return i;
        const i = ps.slots;
        if (i == nil) return error.OutOfMemory;
        if (i >> chunk_shift == ps.chunks.items.len) {
            const c = try ps.gpa.create(Chunk);
            c.refs = .init(1);
            for (&c.nodes) |*n| n.* = .{ .name_ptr = "".ptr, .name_len = 0, .parent = nil, .first_child = nil, .next_sibling = nil, .prev_sibling = nil, .gen = 0, .name_hash = 0, .root = 0, .live = false, .info = .{} };
            try ps.chunks.append(ps.gpa, c);
            try ps.owned.append(ps.gpa, true);
        }
        ps.slots += 1;
        return i;
    }

    fn idOf(ps: *const PathStore, i: u32) FileId {
        return .{ .index = i, .gen = ps.node(i).gen };
    }

    fn rootSlot(ps: *const PathStore, root: RootId) ApplyError!RootSlot {
        if (root.index() >= ps.roots.items.len) return error.UnknownRoot;
        const s = ps.roots.items[root.index()];
        if (!s.live) return error.UnknownRoot;
        return s;
    }

    fn findChild(ps: *const PathStore, parent: u32, name: []const u8, ci: bool) ?u32 {
        return ps.findChildHashed(parent, name, ci, nameHash(name, ci));
    }

    fn findChildHashed(ps: *const PathStore, parent: u32, name: []const u8, ci: bool, nh: u32) ?u32 {
        const key: IndexKey = .{ .parent = parent, .name = name, .ci = ci, .hash = nh };
        return ps.index.getKeyAdapted(key, IndexAdapter{ .ps = ps });
    }

    /// Walks `rel` from the root; null when a segment is missing.
    fn resolve(ps: *const PathStore, slot: RootSlot, rel: []const u8) ApplyError!?u32 {
        var cur = slot.node;
        if (rel.len == 0) return cur;
        var it = std.mem.splitScalar(u8, rel, '/');
        while (it.next()) |seg| {
            if (seg.len == 0) return error.InvalidPath;
            cur = ps.findChild(cur, seg, slot.case_insensitive) orelse return null;
        }
        return cur;
    }

    fn link(ps: *PathStore, parent: u32, child: u32) !void {
        const p = try ps.nodeMut(parent);
        const old_first = p.first_child;
        p.first_child = child;
        const c = try ps.nodeMut(child);
        c.parent = parent;
        c.prev_sibling = nil;
        c.next_sibling = old_first;
        if (old_first != nil) (try ps.nodeMut(old_first)).prev_sibling = child;
    }

    fn unlink(ps: *PathStore, child: u32) !void {
        const c = ps.node(child).*;
        if (c.prev_sibling != nil) {
            (try ps.nodeMut(c.prev_sibling)).next_sibling = c.next_sibling;
        } else if (c.parent != nil) {
            (try ps.nodeMut(c.parent)).first_child = c.next_sibling;
        }
        if (c.next_sibling != nil) (try ps.nodeMut(c.next_sibling)).prev_sibling = c.prev_sibling;
    }

    fn createChild(ps: *PathStore, parent: u32, name: []const u8, info: NodeInfo, root: u16) !u32 {
        return ps.createChildHashed(parent, name, info, root, nameHash(name, ps.roots.items[root].case_insensitive));
    }

    fn createChildHashed(ps: *PathStore, parent: u32, name: []const u8, info: NodeInfo, root: u16, nh: u32) !u32 {
        const i = try ps.createNode(parent, name, info, root, nh);
        try ps.index.putContext(ps.gpa, i, {}, .{ .ps = ps });
        return i;
    }

    /// Creates and links a node without indexing it.
    fn createNode(ps: *PathStore, parent: u32, name: []const u8, info: NodeInfo, root: u16, nh: u32) !u32 {
        const interned = try ps.names.intern(ps.gpa, name, nh);
        const i = try ps.allocNode();
        const n = try ps.nodeMut(i);
        n.* = .{
            .name_ptr = interned.ptr,
            .name_len = @intCast(interned.len),
            .parent = parent,
            .first_child = nil,
            .next_sibling = nil,
            .prev_sibling = nil,
            .gen = n.gen,
            .name_hash = nh,
            .root = root,
            .live = true,
            .info = info,
        };
        try ps.link(parent, i);
        if (!info.isDir()) ps.file_count += 1;
        return i;
    }

    fn applyOne(ps: *PathStore, op: Delta.Op, changes: *ChangeList) ApplyError!void {
        if (op != .upsert) ps.walk.len = 0;
        switch (op) {
            .upsert => |u| {
                const slot = try ps.rootSlot(u.root);
                if (u.rel.len == 0) {
                    const n = try ps.nodeMut(slot.node);
                    n.info = u.info;
                    n.info.kind = .dir;
                    return;
                }
                var cur = slot.node;
                var rest = u.rel;
                if (std.mem.lastIndexOfScalar(u8, u.rel, '/')) |slash| {
                    if (ps.walk.hit(u.root, u.rel[0..slash], ps)) |parent| {
                        cur = parent;
                        rest = u.rel[slash + 1 ..];
                    }
                }
                var it = std.mem.splitScalar(u8, rest, '/');
                while (it.next()) |seg| {
                    if (seg.len == 0) return error.InvalidPath;
                    const last = it.peek() == null;
                    const nh = nameHash(seg, slot.case_insensitive);
                    // One probe both finds an existing child and reserves the
                    // slot for a new one.
                    const key: IndexKey = .{ .parent = cur, .name = seg, .ci = slot.case_insensitive, .hash = nh };
                    const gop = try ps.index.getOrPutContextAdapted(ps.gpa, key, IndexAdapter{ .ps = ps }, IndexCtx{ .ps = ps });
                    if (gop.found_existing) {
                        const child = gop.key_ptr.*;
                        if (last) {
                            const before = ps.node(child).info;
                            const was_dir = before.isDir();
                            if (was_dir and !u.info.isDir()) {
                                // A directory became a file: drop its subtree.
                                try ps.removeChildren(child, changes);
                            }
                            const n2 = try ps.nodeMut(child);
                            n2.info = u.info;
                            if (was_dir != u.info.isDir()) {
                                if (u.info.isDir()) ps.file_count -= 1 else ps.file_count += 1;
                            }
                            if (!before.sameContent(u.info) or @as(u13, @bitCast(before.flags)) != @as(u13, @bitCast(u.info.flags)))
                                try changes.add(.{ .id = ps.idOf(child), .what = .modified });
                        } else if (!ps.node(child).info.isDir()) {
                            return error.NotADirectory;
                        }
                        cur = child;
                    } else {
                        const info: NodeInfo = if (last) u.info else .{ .kind = .dir, .flags = .{ .loading = true } };
                        const created = ps.createNode(cur, seg, info, u.root.index(), nh) catch |err| {
                            ps.index.removeByPtr(gop.key_ptr);
                            return err;
                        };
                        gop.key_ptr.* = created;
                        cur = created;
                        try changes.add(.{ .id = ps.idOf(cur), .what = .added });
                    }
                }
                if (std.mem.lastIndexOfScalar(u8, u.rel, '/')) |slash| ps.walk.remember(u.root, u.rel[0..slash], ps.node(cur).parent, ps);
            },
            .remove => |r| {
                const slot = try ps.rootSlot(r.root);
                if (r.rel.len == 0) return error.InvalidPath;
                const i = (try ps.resolve(slot, r.rel)) orelse return;
                try ps.removeSubtree(i, changes, false);
            },
            .rename => |r| {
                const slot = try ps.rootSlot(r.root);
                if (r.from.len == 0 or r.to.len == 0) return error.InvalidPath;
                const src = (try ps.resolve(slot, r.from)) orelse return;
                if (std.mem.startsWith(u8, r.to, r.from) and r.to.len > r.from.len and r.to[r.from.len] == '/') return error.RenameIntoSelf;
                const slash = std.mem.lastIndexOfScalar(u8, r.to, '/');
                const parent_rel = if (slash) |s| r.to[0..s] else "";
                const new_name = if (slash) |s| r.to[s + 1 ..] else r.to;
                // Make sure the destination directory exists.
                var parent = slot.node;
                if (parent_rel.len > 0) {
                    var it = std.mem.splitScalar(u8, parent_rel, '/');
                    while (it.next()) |seg| {
                        if (seg.len == 0) return error.InvalidPath;
                        if (ps.findChild(parent, seg, slot.case_insensitive)) |c| {
                            if (!ps.node(c).info.isDir()) return error.NotADirectory;
                            parent = c;
                        } else {
                            parent = try ps.createChild(parent, seg, .{ .kind = .dir, .flags = .{ .loading = true } }, r.root.index());
                            try changes.add(.{ .id = ps.idOf(parent), .what = .added });
                        }
                    }
                }
                if (ps.findChild(parent, new_name, slot.case_insensitive)) |existing| {
                    if (existing == src) {
                        // Case-only rename on a case-insensitive root: just rename.
                    } else try ps.removeSubtree(existing, changes, false);
                }
                const old_parent = ps.node(src).parent;
                const old_parent_id = ps.idOf(old_parent);
                _ = ps.index.removeContext(src, .{ .ps = ps });
                try ps.unlink(src);
                const interned = try ps.names.intern(ps.gpa, new_name, nameHash(new_name, false));
                const n = try ps.nodeMut(src);
                n.name_ptr = interned.ptr;
                n.name_len = @intCast(interned.len);
                n.name_hash = nameHash(new_name, slot.case_insensitive);
                try ps.link(parent, src);
                try ps.index.putContext(ps.gpa, src, {}, .{ .ps = ps });
                try changes.add(.{ .id = ps.idOf(src), .what = .renamed, .old_parent = old_parent_id });
            },
            .set_children_complete => |s| {
                const slot = try ps.rootSlot(s.root);
                const i = (try ps.resolve(slot, s.rel_dir)) orelse return;
                (try ps.nodeMut(i)).info.flags.loading = false;
            },
            .reset_root => |root| {
                const slot = try ps.rootSlot(root);
                try ps.removeChildren(slot.node, changes);
                (try ps.nodeMut(slot.node)).info.flags.loading = true;
            },
        }
    }

    fn removeChildren(ps: *PathStore, dir: u32, changes: *ChangeList) Allocator.Error!void {
        while (ps.node(dir).first_child != nil) try ps.removeSubtree(ps.node(dir).first_child, changes, false);
    }

    fn removeSubtree(ps: *PathStore, top: u32, changes: *ChangeList, is_root: bool) Allocator.Error!void {
        try ps.removeChildren(top, changes);
        const id = ps.idOf(top);
        if (!is_root) {
            _ = ps.index.removeContext(top, .{ .ps = ps });
            try ps.unlink(top);
        }
        const n = try ps.nodeMut(top);
        if (!n.info.isDir()) ps.file_count -= 1;
        n.live = false;
        n.gen +%= 1;
        n.first_child = nil;
        try ps.free.append(ps.gpa, top);
        try changes.add(.{ .id = id, .what = .removed });
    }

    fn buildSnapshot(ps: *PathStore) !*Snapshot {
        const s = try ps.gpa.create(Snapshot);
        errdefer ps.gpa.destroy(s);
        const chunks = try ps.gpa.dupe(*Chunk, ps.chunks.items);
        errdefer ps.gpa.free(chunks);
        const roots = try ps.gpa.dupe(RootSlot, ps.roots.items);
        for (chunks) |c| _ = c.refs.fetchAdd(1, .monotonic);
        @memset(ps.owned.items, false);
        s.* = .{
            .store = ps,
            .gpa = ps.gpa,
            .generation = ps.generation,
            .chunks = chunks,
            .slots = ps.slots,
            .roots = roots,
            .file_count = ps.file_count,
            .refs = .init(1),
        };
        return s;
    }

    fn publish(ps: *PathStore) !void {
        ps.generation += 1;
        const s = try ps.buildSnapshot();
        try ps.retired.ensureUnusedCapacity(ps.gpa, 1);
        const old = ps.current.swap(s, .seq_cst);
        _ = old.refs.fetchSub(1, .seq_cst);
        ps.retired.appendAssumeCapacity(old);
    }
};

const ChangeList = struct {
    list: *std.ArrayList(Change),
    gpa: Allocator,

    fn add(c: *ChangeList, ch: Change) !void {
        try c.list.append(c.gpa, ch);
    }
};

const WalkCache = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,
    root: RootId = .of(0),
    node: u32 = nil,
    gen: u32 = 0,

    fn hit(w: *const WalkCache, root: RootId, dir: []const u8, ps: *const PathStore) ?u32 {
        if (w.len == 0 or w.root != root or dir.len != w.len or !std.mem.eql(u8, dir, w.buf[0..w.len])) return null;
        const n = ps.node(w.node);
        if (!n.live or n.gen != w.gen) return null;
        return w.node;
    }

    fn remember(w: *WalkCache, root: RootId, dir: []const u8, node: u32, ps: *const PathStore) void {
        if (dir.len > w.buf.len or node == nil) {
            w.len = 0;
            return;
        }
        @memcpy(w.buf[0..dir.len], dir);
        w.len = dir.len;
        w.root = root;
        w.node = node;
        w.gen = ps.node(node).gen;
    }
};

const RootSlot = struct { node: u32, case_insensitive: bool, live: bool };

fn releaseChunk(gpa: Allocator, c: *Chunk) void {
    if (c.refs.fetchSub(1, .acq_rel) == 1) gpa.destroy(c);
}

fn freeSnapshot(gpa: Allocator, s: *Snapshot) void {
    for (s.chunks) |c| releaseChunk(gpa, c);
    gpa.free(s.chunks);
    gpa.free(s.roots);
    var it = s.children_cache.valueIterator();
    while (it.next()) |v| gpa.free(v.*);
    s.children_cache.deinit(gpa);
    if (s.flat) |f| f.deinit(gpa);
    gpa.destroy(s);
}

const IndexKey = struct { parent: u32, name: []const u8, ci: bool, hash: u32 };

fn nameHash(name: []const u8, ci: bool) u32 {
    // FNV-1a: names are short, and this beats Wyhash's setup cost.
    var h: u32 = 0x811c9dc5;
    if (ci) {
        for (name) |c| h = (h ^ std.ascii.toLower(c)) *% 0x01000193;
    } else {
        for (name) |c| h = (h ^ c) *% 0x01000193;
    }
    return h;
}

fn mix(parent: u32, name_hash: u32) u64 {
    var x = (@as(u64, parent) << 32) | name_hash;
    x ^= x >> 33;
    x *%= 0xff51afd7ed558ccd;
    x ^= x >> 33;
    return x;
}

const IndexCtx = struct {
    ps: *const PathStore,
    pub fn hash(c: IndexCtx, i: u32) u64 {
        const n = c.ps.node(i);
        return mix(n.parent, n.name_hash);
    }
    pub fn eql(_: IndexCtx, a: u32, b: u32) bool {
        return a == b;
    }
};

const IndexAdapter = struct {
    ps: *const PathStore,
    pub fn hash(_: IndexAdapter, k: IndexKey) u64 {
        return mix(k.parent, k.hash);
    }
    pub fn eql(a: IndexAdapter, k: IndexKey, i: u32) bool {
        const n = a.ps.node(i);
        if (n.parent != k.parent) return false;
        return if (k.ci) std.ascii.eqlIgnoreCase(n.name(), k.name) else std.mem.eql(u8, n.name(), k.name);
    }
};

/// Append-only name storage in blocks that never move. Repeated names
/// (`index.ts`, `mod.rs`) are shared through a bounded direct-mapped cache
/// keyed by hash, so common basenames are stored once without a full
/// dedup table.
const NameArena = struct {
    blocks: std.ArrayList([]u8) = .empty,
    used: usize = 0,
    recent: ?*[cache_len][]const u8 = null,

    const block_size = 256 * 1024;
    const cache_len = 1 << 16;

    /// `h` is any hash of `s` (only used to pick a cache slot).
    fn intern(na: *NameArena, gpa: Allocator, s: []const u8, h: u32) ![]const u8 {
        if (na.recent == null) {
            const r = try gpa.create([cache_len][]const u8);
            @memset(r, "");
            na.recent = r;
        }
        const slot = &na.recent.?[h % cache_len];
        if (slot.len == s.len and std.mem.eql(u8, slot.*, s)) return slot.*;
        const block = blk: {
            if (na.blocks.items.len > 0) {
                const last = na.blocks.items[na.blocks.items.len - 1];
                if (last.len - na.used >= s.len) break :blk last;
            }
            const b = try gpa.alloc(u8, @max(block_size, s.len));
            try na.blocks.append(gpa, b);
            na.used = 0;
            break :blk b;
        };
        const dst = block[na.used..][0..s.len];
        @memcpy(dst, s);
        na.used += s.len;
        slot.* = dst;
        return dst;
    }

    fn deinit(na: *NameArena, gpa: Allocator) void {
        for (na.blocks.items) |b| gpa.free(b);
        na.blocks.deinit(gpa);
        if (na.recent) |r| gpa.destroy(r);
    }
};

/// An immutable view of the tree at one generation. Readers on any thread.
pub const Snapshot = struct {
    store: *PathStore,
    gpa: Allocator,
    /// Publish counter; increases by one per `apply`.
    generation: u64,
    chunks: []const *Chunk,
    slots: u32,
    roots: []const RootSlot,
    file_count: u32,
    refs: std.atomic.Value(u32),
    cache_lock: std.Io.Mutex = .init,
    children_cache: std.AutoHashMapUnmanaged(u32, []const FileId) = .empty,
    flat: ?*FlatNames = null,

    fn node(s: *const Snapshot, i: u32) *const Node {
        return &s.chunks[i >> chunk_shift].nodes[i & (chunk_len - 1)];
    }

    fn get(s: *const Snapshot, id: FileId) ?*const Node {
        if (id.index >= s.slots) return null;
        const n = s.node(id.index);
        if (!n.live or n.gen != id.gen) return null;
        return n;
    }

    /// Drops this reference.
    pub fn release(s: *const Snapshot) void {
        _ = @constCast(s).refs.fetchSub(1, .seq_cst);
    }

    /// Whether `id` names a live node in this snapshot.
    pub fn contains(s: *const Snapshot, id: FileId) bool {
        return s.get(id) != null;
    }

    /// The root directory node of `root`, or null when the root is unknown.
    pub fn rootDir(s: *const Snapshot, root: RootId) ?FileId {
        if (root.index() >= s.roots.len or !s.roots[root.index()].live) return null;
        const i = s.roots[root.index()].node;
        return .{ .index = i, .gen = s.node(i).gen };
    }

    /// The root a node belongs to.
    pub fn rootOf(s: *const Snapshot, id: FileId) ?RootId {
        const n = s.get(id) orelse return null;
        return .of(n.root);
    }

    /// The node at root-relative `rel` (`""` is the root directory).
    pub fn lookup(s: *const Snapshot, root: RootId, rel: []const u8) ?FileId {
        var cur = s.rootDir(root) orelse return null;
        if (rel.len == 0) return cur;
        const ci = s.roots[root.index()].case_insensitive;
        var it = std.mem.splitScalar(u8, rel, '/');
        while (it.next()) |seg| {
            const kids = s.children(cur);
            cur = if (ci) findFolded(s, kids, seg) orelse return null else findSorted(s, kids, seg) orelse return null;
        }
        return cur;
    }

    fn findSorted(s: *const Snapshot, kids: []const FileId, name: []const u8) ?FileId {
        var lo: usize = 0;
        var hi: usize = kids.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            switch (std.mem.order(u8, s.node(kids[mid].index).name(), name)) {
                .eq => return kids[mid],
                .lt => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return null;
    }

    fn findFolded(s: *const Snapshot, kids: []const FileId, name: []const u8) ?FileId {
        if (findSorted(s, kids, name)) |exact| return exact;
        for (kids) |k| if (std.ascii.eqlIgnoreCase(s.node(k.index).name(), name)) return k;
        return null;
    }

    /// Writes the root-relative path of `id` into `buf` and returns it
    /// (`""` for a root, or for a stale id). Truncates to `buf.len`.
    pub fn pathOf(s: *const Snapshot, id: FileId, buf: []u8) []const u8 {
        var n = s.get(id) orelse return buf[0..0];
        var end = buf.len;
        var first = true;
        while (n.parent != nil) {
            const name = n.name();
            const need = name.len + @intFromBool(!first);
            if (need > end) break;
            if (!first) {
                end -= 1;
                buf[end] = '/';
            }
            end -= name.len;
            @memcpy(buf[end..][0..name.len], name);
            first = false;
            n = s.node(n.parent);
        }
        // Move to the front of the buffer.
        const len = buf.len - end;
        std.mem.copyForwards(u8, buf[0..len], buf[end..]);
        return buf[0..len];
    }

    /// The basename of `id` (`""` for a root or a stale id).
    pub fn basename(s: *const Snapshot, id: FileId) []const u8 {
        const n = s.get(id) orelse return "";
        return n.name();
    }

    /// Kind, flags, size and mtime of `id` (a default info for a stale id).
    pub fn info(s: *const Snapshot, id: FileId) NodeInfo {
        const n = s.get(id) orelse return .{ .kind = .other };
        return n.info;
    }

    /// The parent directory of `id`, or null for a root.
    pub fn parentOf(s: *const Snapshot, id: FileId) ?FileId {
        const n = s.get(id) orelse return null;
        if (n.parent == nil) return null;
        return .{ .index = n.parent, .gen = s.node(n.parent).gen };
    }

    /// Number of live non-directory nodes.
    pub fn fileCount(s: *const Snapshot) u32 {
        return s.file_count;
    }

    /// The children of directory `dir`, sorted by name (byte order). Built
    /// on first use and cached for the snapshot's lifetime.
    pub fn children(s: *const Snapshot, dir: FileId) []const FileId {
        const n = s.get(dir) orelse return &.{};
        if (n.first_child == nil) return &.{};
        const self = @constCast(s);
        const io = s.store.io;
        self.cache_lock.lockUncancelable(io);
        defer self.cache_lock.unlock(io);
        if (s.children_cache.get(dir.index)) |c| return c;
        var count: usize = 0;
        var c = n.first_child;
        while (c != nil) : (c = s.node(c).next_sibling) count += 1;
        const out = s.gpa.alloc(FileId, count) catch return &.{};
        c = n.first_child;
        var i: usize = 0;
        while (c != nil) : (c = s.node(c).next_sibling) {
            out[i] = .{ .index = c, .gen = s.node(c).gen };
            i += 1;
        }
        std.mem.sort(FileId, out, s, struct {
            fn lt(snap: *const Snapshot, a: FileId, b: FileId) bool {
                return std.mem.lessThan(u8, snap.node(a.index).name(), snap.node(b.index).name());
            }
        }.lt);
        self.children_cache.put(s.gpa, dir.index, out) catch {
            s.gpa.free(out);
            return &.{};
        };
        return out;
    }

    /// Depth-first iteration over files (not directories) in name order,
    /// over one root or all roots.
    pub fn iterFiles(s: *const Snapshot, root: ?RootId) FileIter {
        var it: FileIter = .{ .snap = s };
        if (root) |r| {
            if (s.rootDir(r)) |d| it.push(d);
        } else {
            var i = s.roots.len;
            while (i > 0) {
                i -= 1;
                if (s.rootDir(.of(@intCast(i)))) |d| it.push(d);
            }
        }
        return it;
    }

    /// Contiguous arrays over all files, for the fuzzy finder's scans.
    /// Built on first use and cached.
    pub fn flatNames(s: *const Snapshot) *const FlatNames {
        const self = @constCast(s);
        const io = s.store.io;
        self.cache_lock.lockUncancelable(io);
        if (s.flat) |f| {
            self.cache_lock.unlock(io);
            return f;
        }
        self.cache_lock.unlock(io);
        const built = FlatNames.build(s) catch return &FlatNames.empty;
        self.cache_lock.lockUncancelable(io);
        defer self.cache_lock.unlock(io);
        if (s.flat) |f| {
            built.deinit(s.gpa);
            return f;
        }
        self.flat = built;
        return built;
    }
};

/// Iterator returned by `Snapshot.iterFiles`.
pub const FileIter = struct {
    snap: *const Snapshot,
    stack: [max_depth]Frame = undefined,
    depth: usize = 0,

    const max_depth = 256;
    const Frame = struct { kids: []const FileId, i: usize };

    fn push(it: *FileIter, dir: FileId) void {
        if (it.depth == max_depth) return;
        it.stack[it.depth] = .{ .kids = it.snap.children(dir), .i = 0 };
        it.depth += 1;
    }

    /// The next file, or null at the end.
    pub fn next(it: *FileIter) ?FileId {
        while (it.depth > 0) {
            const top = &it.stack[it.depth - 1];
            if (top.i >= top.kids.len) {
                it.depth -= 1;
                continue;
            }
            const id = top.kids[top.i];
            top.i += 1;
            const inf = it.snap.info(id);
            if (inf.isDir()) {
                it.push(id);
            } else return id;
        }
        return null;
    }
};

/// Parallel arrays over every file of a snapshot (in `iterFiles` order), for
/// SIMD-friendly fuzzy scanning (E08.F04).
pub const FlatNames = struct {
    /// The file ids.
    ids: []const FileId,
    /// `path_bytes[path_offsets[i]..path_offsets[i+1]]` is file i's
    /// root-relative path (use `ids[i]` and `Snapshot.rootOf` for its root).
    path_offsets: []const u32,
    /// All paths, concatenated.
    path_bytes: []const u8,
    /// Offset of the basename within each path.
    basename_start: []const u16,
    /// Bitmask of the lowercase ASCII letters (bits 0-25), digits (26-35) and
    /// `/`, `.`, `_`, `-` (36-39) present in each path, for prefiltering.
    char_mask: []const u64,

    /// An empty set (used when building fails for lack of memory).
    pub const empty: FlatNames = .{ .ids = &.{}, .path_offsets = &.{0}, .path_bytes = &.{}, .basename_start = &.{}, .char_mask = &.{} };

    /// The path of entry `i`.
    pub fn path(f: *const FlatNames, i: usize) []const u8 {
        return f.path_bytes[f.path_offsets[i]..f.path_offsets[i + 1]];
    }

    /// The mask bit set for byte `c` (0 when `c` is not tracked).
    pub fn maskOf(c: u8) u64 {
        const l = std.ascii.toLower(c);
        return switch (l) {
            'a'...'z' => @as(u64, 1) << @intCast(l - 'a'),
            '0'...'9' => @as(u64, 1) << @intCast(26 + l - '0'),
            '/' => 1 << 36,
            '.' => 1 << 37,
            '_' => 1 << 38,
            '-' => 1 << 39,
            else => 0,
        };
    }

    fn build(s: *const Snapshot) !*FlatNames {
        const gpa = s.gpa;
        var id_list: std.ArrayList(FileId) = .empty;
        defer id_list.deinit(gpa);
        var offs: std.ArrayList(u32) = .empty;
        defer offs.deinit(gpa);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        var bases: std.ArrayList(u16) = .empty;
        defer bases.deinit(gpa);
        var masks: std.ArrayList(u64) = .empty;
        defer masks.deinit(gpa);
        var it = s.iterFiles(null);
        var buf: [4096]u8 = undefined;
        while (it.next()) |id| {
            const p = s.pathOf(id, &buf);
            try id_list.append(gpa, id);
            try offs.append(gpa, @intCast(bytes.items.len));
            try bytes.appendSlice(gpa, p);
            const b = if (std.mem.lastIndexOfScalar(u8, p, '/')) |sl| sl + 1 else 0;
            try bases.append(gpa, @intCast(@min(b, std.math.maxInt(u16))));
            var m: u64 = 0;
            for (p) |c| m |= maskOf(c);
            try masks.append(gpa, m);
        }
        try offs.append(gpa, @intCast(bytes.items.len));
        const f = try gpa.create(FlatNames);
        f.* = .{
            .ids = try id_list.toOwnedSlice(gpa),
            .path_offsets = try offs.toOwnedSlice(gpa),
            .path_bytes = try bytes.toOwnedSlice(gpa),
            .basename_start = try bases.toOwnedSlice(gpa),
            .char_mask = try masks.toOwnedSlice(gpa),
        };
        return f;
    }

    fn deinit(f: *const FlatNames, gpa: Allocator) void {
        gpa.free(f.ids);
        gpa.free(f.path_offsets);
        gpa.free(f.path_bytes);
        gpa.free(f.basename_start);
        gpa.free(f.char_mask);
        gpa.destroy(f);
    }
};
