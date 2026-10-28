//! The Problems model (E07.F02.S02.T02): the diagnostic store's current
//! snapshot as a filtered list of files, each with its diagnostics in
//! order, for the Problems panel, the "next/previous problem" commands
//! and the status bar's counts.
//!
//! Files come in key order (the store's: the normalized path of `file:`
//! documents) and, inside a file, every owner's diagnostics are merged by
//! line, column and severity. The filter keeps diagnostics at or above a
//! severity whose message, source or code contains a text (ASCII case
//! folded), optionally of one file only, and not from a hidden source.
//! `update` rebuilds only when the snapshot's generation or the filter
//! changed.
//!
//! Every file and diagnostic has a node id that stays the same across
//! updates while it is still there (a hash of the key, owner, position
//! and message), so a tree over the model keeps its selection and open
//! files. UI thread only (the snapshot stays referenced until the next
//! update or `deinit`).

const Problems = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const Store = @import("Store.zig");

const Snapshot = Store.Snapshot;
const Diagnostic = Store.Diagnostic;
pub const Severity = Store.Severity;
pub const Owner = Store.Owner;
pub const Pos = Store.Pos;

/// Which diagnostics show.
pub const Filter = struct {
    /// The least severe shown (`.hint` shows everything).
    min_severity: Severity = .hint,
    /// Shown when the message, source or code contains it (ASCII case
    /// folded); empty matches everything.
    text: []const u8 = "",
    /// Only this key's diagnostics (the current file).
    key: ?[]const u8 = null,
    /// Diagnostics from these sources (exact) are hidden.
    hidden_sources: []const []const u8 = &.{},

    fn eql(a: Filter, b: Filter) bool {
        if (a.min_severity != b.min_severity) return false;
        if (!std.mem.eql(u8, a.text, b.text)) return false;
        if (a.hidden_sources.len != b.hidden_sources.len) return false;
        for (a.hidden_sources, b.hidden_sources) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        if ((a.key == null) != (b.key == null)) return false;
        return a.key == null or std.mem.eql(u8, a.key.?, b.key.?);
    }
};

/// One diagnostic, as shown.
pub const Item = struct {
    diag: *const Diagnostic,
    owner: Owner,
    /// The document version `diag.bytes` is at (null: no byte range).
    version: ?u64,
    /// The tree node id (top bit clear).
    id: u64,
};

/// One file with shown diagnostics.
pub const File = struct {
    /// The store key (valid while the model holds its snapshot).
    key: []const u8,
    /// Its range in `items`.
    first: u32,
    len: u32,
    /// Shown diagnostics per severity (index `severity - 1`).
    counts: [4]u32,
    /// The tree node id (top bit set).
    id: u64,
};

/// A diagnostic's place: file index, item index within the file.
pub const Loc = struct { file: u32, item: u32 };

/// What a node id names.
pub const Node = union(enum) { file: u32, item: Loc };

gpa: Allocator,
snap: ?*Snapshot = null,
generation: u64 = std.math.maxInt(u64),
filter: Filter = .{},
/// Owned copies of the filter's strings.
filter_text: std.ArrayList(u8) = .empty,
filter_key: std.ArrayList(u8) = .empty,
filter_hidden: std.ArrayList([]u8) = .empty,
files: std.ArrayList(File) = .empty,
items: std.ArrayList(Item) = .empty,
nodes: std.AutoHashMapUnmanaged(u64, Node) = .empty,
/// Bumped by every rebuild (the panel reloads its tree).
revision: u64 = 0,

pub fn init(gpa: Allocator) Problems {
    return .{ .gpa = gpa };
}

pub fn deinit(p: *Problems) void {
    if (p.snap) |s| s.release();
    p.filter_text.deinit(p.gpa);
    p.filter_key.deinit(p.gpa);
    for (p.filter_hidden.items) |h| p.gpa.free(h);
    p.filter_hidden.deinit(p.gpa);
    p.files.deinit(p.gpa);
    p.items.deinit(p.gpa);
    p.nodes.deinit(p.gpa);
}

/// Every diagnostic in the store's current snapshot, per severity
/// (unfiltered), for the status bar.
pub fn totals(store: *Store) [4]u32 {
    const s = store.acquire();
    defer s.release();
    return s.counts;
}

/// Brings the model to `store`'s current snapshot under `filter` (its
/// strings are copied); true when it was rebuilt.
pub fn update(p: *Problems, store: *Store, filter: Filter) Allocator.Error!bool {
    const snap = store.acquire();
    if (p.snap != null and snap.generation == p.generation and filter.eql(p.filter)) {
        snap.release();
        return false;
    }
    errdefer snap.release();
    try p.setFilter(filter);
    try p.rebuild(snap);
    if (p.snap) |old| old.release();
    p.snap = snap;
    p.generation = snap.generation;
    p.revision += 1;
    return true;
}

fn setFilter(p: *Problems, f: Filter) Allocator.Error!void {
    p.filter_text.clearRetainingCapacity();
    try p.filter_text.appendSlice(p.gpa, f.text);
    p.filter = .{ .min_severity = f.min_severity, .text = p.filter_text.items };
    if (f.key) |k| {
        p.filter_key.clearRetainingCapacity();
        try p.filter_key.appendSlice(p.gpa, k);
        p.filter.key = p.filter_key.items;
    }
    for (p.filter_hidden.items) |h| p.gpa.free(h);
    p.filter_hidden.clearRetainingCapacity();
    try p.filter_hidden.ensureTotalCapacity(p.gpa, f.hidden_sources.len);
    for (f.hidden_sources) |h| p.filter_hidden.appendAssumeCapacity(try p.gpa.dupe(u8, h));
    p.filter.hidden_sources = p.filter_hidden.items;
}

fn shown(f: Filter, d: *const Diagnostic) bool {
    if (@intFromEnum(d.severity) > @intFromEnum(f.min_severity)) return false;
    for (f.hidden_sources) |h| if (std.mem.eql(u8, d.source, h)) return false;
    if (f.text.len == 0) return true;
    return std.ascii.indexOfIgnoreCase(d.message, f.text) != null or
        std.ascii.indexOfIgnoreCase(d.source, f.text) != null or
        std.ascii.indexOfIgnoreCase(d.code, f.text) != null;
}

fn itemLess(_: void, a: Item, b: Item) bool {
    return Store.lessThan({}, a.diag.*, b.diag.*);
}

fn rebuild(p: *Problems, snap: *const Snapshot) Allocator.Error!void {
    p.files.clearRetainingCapacity();
    p.items.clearRetainingCapacity();
    p.nodes.clearRetainingCapacity();
    try p.items.ensureTotalCapacity(p.gpa, snap.counts[0] + snap.counts[1] + snap.counts[2] + snap.counts[3]);
    const keys = snap.keys();
    for (keys, snap.buckets.values()) |key, b| {
        if (p.filter.key) |only| if (!std.mem.eql(u8, key, only)) continue;
        const first: u32 = @intCast(p.items.items.len);
        var counts: [4]u32 = @splat(0);
        for (b.sets) |set| for (set.diags) |*d| {
            if (!shown(p.filter, d)) continue;
            counts[@intFromEnum(d.severity) - 1] += 1;
            p.items.appendAssumeCapacity(.{ .diag = d, .owner = set.owner, .version = set.version, .id = 0 });
        };
        const len: u32 = @intCast(p.items.items.len - first);
        if (len == 0) continue;
        const mine = p.items.items[first..];
        // One owner's set is sorted already; merge several.
        if (b.sets.len > 1) std.mem.sort(Item, mine, {}, itemLess);
        const fi: u32 = @intCast(p.files.items.len);
        const fid = try p.uniqueId(std.hash.Wyhash.hash(0x0f11e, key) | (1 << 63), .{ .file = fi });
        try p.files.append(p.gpa, .{ .key = key, .first = first, .len = len, .counts = counts, .id = fid });
        try p.nodes.ensureUnusedCapacity(p.gpa, len);
        for (mine, 0..) |*it, i| {
            var h = std.hash.Wyhash.init(fid);
            const ow: [2]u32 = switch (it.owner) {
                .server => |x| .{ 0, x },
                .task => |x| .{ 1, x },
                .agent_check => |x| .{ 2, x },
            };
            h.update(std.mem.asBytes(&ow));
            h.update(std.mem.asBytes(&it.diag.start));
            h.update(&.{@intFromEnum(it.diag.severity)});
            h.update(it.diag.message);
            it.id = try p.uniqueId(h.final() & ~@as(u64, 1 << 63), .{ .item = .{ .file = fi, .item = @intCast(i) } });
        }
    }
}

/// `want`, or the next free id after it (duplicate diagnostics), mapped
/// to `n`.
fn uniqueId(p: *Problems, want: u64, n: Node) Allocator.Error!u64 {
    const top = want & (1 << 63);
    var id = want;
    while (true) {
        const gop = try p.nodes.getOrPut(p.gpa, id);
        if (!gop.found_existing) {
            gop.value_ptr.* = n;
            return id;
        }
        id = ((id +% 1) & ~@as(u64, 1 << 63)) | top;
    }
}

/// What node `id` names, if it is still shown.
pub fn node(p: *const Problems, id: u64) ?Node {
    return p.nodes.get(id);
}

/// File `i`'s shown diagnostics.
pub fn fileItems(p: *const Problems, i: u32) []const Item {
    const f = p.files.items[i];
    return p.items.items[f.first..][0..f.len];
}

/// The diagnostic at `l`.
pub fn item(p: *const Problems, l: Loc) Item {
    return p.fileItems(l.file)[l.item];
}

/// Number of diagnostics shown.
pub fn count(p: *const Problems) usize {
    return p.items.items.len;
}

/// The index of the file with `key`, or where it would go.
fn fileSlot(p: *const Problems, key: []const u8) struct { i: u32, found: bool } {
    var lo: usize = 0;
    var hi: usize = p.files.items.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        switch (std.mem.order(u8, p.files.items[mid].key, key)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return .{ .i = @intCast(mid), .found = true },
        }
    }
    return .{ .i = @intCast(lo), .found = false };
}

fn posLess(a: Pos, b: Pos) bool {
    return a.line < b.line or (a.line == b.line and a.character < b.character);
}

pub const Direction = enum { next, prev };

/// The diagnostic after (or before) position `at` in the file `key`, in
/// the panel's order, wrapping to the next (previous) file and around;
/// `in_file` stays in `key`'s file. `at` is compared with the
/// diagnostics' start positions (LSP lines and columns).
pub fn step(p: *const Problems, key: []const u8, at: Pos, dir: Direction, in_file: bool) ?Loc {
    const n_files: u32 = @intCast(p.files.items.len);
    if (n_files == 0) return null;
    const slot = p.fileSlot(key);
    if (slot.found) {
        const its = p.fileItems(slot.i);
        switch (dir) {
            .next => for (its, 0..) |it, i| {
                if (posLess(at, it.diag.start)) return .{ .file = slot.i, .item = @intCast(i) };
            },
            .prev => {
                var i = its.len;
                while (i > 0) {
                    i -= 1;
                    if (posLess(its[i].diag.start, at)) return .{ .file = slot.i, .item = @intCast(i) };
                }
            },
        }
        if (in_file) return switch (dir) {
            .next => .{ .file = slot.i, .item = 0 },
            .prev => .{ .file = slot.i, .item = @intCast(its.len - 1) },
        };
        const f = switch (dir) {
            .next => (slot.i + 1) % n_files,
            .prev => (slot.i + n_files - 1) % n_files,
        };
        return p.edge(f, dir);
    }
    if (in_file) return null;
    // Not a file with problems: the first one after it in key order.
    return switch (dir) {
        .next => p.edge(slot.i % n_files, .next),
        .prev => p.edge((slot.i + n_files - 1) % n_files, .prev),
    };
}

fn edge(p: *const Problems, f: u32, dir: Direction) Loc {
    return .{ .file = f, .item = switch (dir) {
        .next => 0,
        .prev => p.files.items[f].len - 1,
    } };
}
