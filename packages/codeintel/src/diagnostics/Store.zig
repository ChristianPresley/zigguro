//! DiagnosticStore (E07.F02.S02.T01): every diagnostic the language
//! servers (and later tasks and agent checks) report, per document and
//! per owner, published as immutable snapshots.
//!
//! The UI thread writes: `replace` swaps one owner's set for one document
//! and `commit` publishes everything replaced since as a new snapshot
//! (copy-on-write: the new snapshot shares every untouched document's
//! bucket and every untouched set). Any thread reads: `acquire` returns
//! the current snapshot with a reference, which stays valid (and
//! unchanged) until `release`, however many commits follow.
//!
//! Documents are keyed by `keyOf`: the case-folded normalized path for
//! `file:` URIs (so a server's spelling of a path matches the editor's),
//! the URI itself otherwise.

const DiagnosticStore = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");

const registry = zg_editor.model.api.registry;
pub const PathStyle = registry.PathStyle;

/// Who reported a set.
pub const Owner = union(enum) {
    /// A language server (`Manager.Server.id`).
    server: u32,
    task: u32,
    agent_check: u32,

    pub fn eql(a: Owner, b: Owner) bool {
        return std.meta.eql(a, b);
    }
};

pub const Severity = enum(u8) {
    err = 1,
    warning = 2,
    information = 3,
    hint = 4,

    pub fn label(s: Severity) []const u8 {
        return switch (s) {
            .err => "error",
            .warning => "warning",
            .information => "info",
            .hint => "hint",
        };
    }
};

pub const Flags = packed struct(u8) {
    /// Fade (`DiagnosticTag.Unnecessary`).
    unnecessary: bool = false,
    /// Strike through (`DiagnosticTag.Deprecated`).
    deprecated: bool = false,
    /// `message` is Markdown (3.18 `MarkupContent`).
    markdown: bool = false,
    _: u5 = 0,
};

/// An LSP position, in the reporting server's column units.
pub const Pos = struct { line: u32, character: u32 };

/// Bytes `[start, end)`.
pub const ByteRange = struct { start: u64, end: u64 };

pub const Diagnostic = struct {
    start: Pos,
    end: Pos,
    /// The range in bytes at its set's `version`; null when the document
    /// was not open in the editor.
    bytes: ?ByteRange = null,
    severity: Severity = .err,
    flags: Flags = .{},
    message: []const u8,
    /// Interned within the set.
    source: []const u8 = "",
    code: []const u8 = "",
    /// The server's `data`, as JSON, for code action requests.
    data: ?[]const u8 = null,
};

/// One owner's diagnostics for one document; immutable once published.
pub const Set = struct {
    refs: std.atomic.Value(u32) = .init(1),
    arena: std.heap.ArenaAllocator,
    owner: Owner,
    /// The document version `bytes` are at (null: no byte ranges).
    version: ?u64 = null,
    /// Sorted by start, then severity.
    diags: []Diagnostic = &.{},
    /// Per severity (index `severity - 1`).
    counts: [4]u32 = @splat(0),

    pub fn create(gpa: Allocator, owner: Owner) Allocator.Error!*Set {
        const s = try gpa.create(Set);
        s.* = .{ .arena = .init(gpa), .owner = owner };
        return s;
    }

    /// Frees a set that was never handed to the store.
    pub fn destroy(s: *Set) void {
        const gpa = s.arena.child_allocator;
        s.arena.deinit();
        gpa.destroy(s);
    }

    pub fn allocator(s: *Set) Allocator {
        return s.arena.allocator();
    }

    /// Sorts the diagnostics and counts them; call once filled.
    pub fn finish(s: *Set) void {
        std.mem.sort(Diagnostic, s.diags, {}, lessThan);
        s.counts = @splat(0);
        for (s.diags) |d| s.counts[@intFromEnum(d.severity) - 1] += 1;
    }

    fn retain(s: *Set) void {
        _ = s.refs.fetchAdd(1, .monotonic);
    }

    fn release(s: *Set) void {
        if (s.refs.fetchSub(1, .acq_rel) == 1) s.destroy();
    }
};

pub fn lessThan(_: void, a: Diagnostic, b: Diagnostic) bool {
    if (a.start.line != b.start.line) return a.start.line < b.start.line;
    if (a.start.character != b.start.character) return a.start.character < b.start.character;
    return @intFromEnum(a.severity) < @intFromEnum(b.severity);
}

/// One document's sets.
pub const Bucket = struct {
    refs: std.atomic.Value(u32) = .init(1),
    key: []u8,
    sets: []*Set,
    counts: [4]u32 = @splat(0),

    fn retain(b: *Bucket) void {
        _ = b.refs.fetchAdd(1, .monotonic);
    }

    fn release(b: *Bucket, gpa: Allocator) void {
        if (b.refs.fetchSub(1, .acq_rel) != 1) return;
        for (b.sets) |s| s.release();
        gpa.free(b.sets);
        gpa.free(b.key);
        gpa.destroy(b);
    }

    /// `owner`'s set, if any.
    pub fn setOf(b: *const Bucket, owner: Owner) ?*const Set {
        for (b.sets) |s| if (s.owner.eql(owner)) return s;
        return null;
    }
};

/// An immutable view of every diagnostic.
pub const Snapshot = struct {
    refs: std.atomic.Value(u32) = .init(1),
    gpa: Allocator,
    /// Bumped by every commit that changed something.
    generation: u64,
    /// Sorted by key.
    buckets: std.StringArrayHashMapUnmanaged(*Bucket) = .empty,
    /// Per severity, over every document.
    counts: [4]u32 = @splat(0),

    pub fn release(s: *Snapshot) void {
        if (s.refs.fetchSub(1, .acq_rel) != 1) return;
        for (s.buckets.values()) |b| b.release(s.gpa);
        s.buckets.deinit(s.gpa);
        s.gpa.destroy(s);
    }

    fn retain(s: *Snapshot) void {
        _ = s.refs.fetchAdd(1, .monotonic);
    }

    pub fn bucket(s: *const Snapshot, key: []const u8) ?*const Bucket {
        return s.buckets.get(key);
    }

    /// Appends `key`'s diagnostics, every owner's, sorted by start then
    /// severity.
    pub fn forKey(s: *const Snapshot, key: []const u8, gpa: Allocator, out: *std.ArrayList(*const Diagnostic)) Allocator.Error!void {
        const b = s.bucket(key) orelse return;
        const first = out.items.len;
        for (b.sets) |set| for (set.diags) |*d| try out.append(gpa, d);
        std.mem.sort(*const Diagnostic, out.items[first..], {}, struct {
            fn lt(_: void, x: *const Diagnostic, y: *const Diagnostic) bool {
                return lessThan({}, x.*, y.*);
            }
        }.lt);
    }

    /// The keys with diagnostics, sorted.
    pub fn keys(s: *const Snapshot) []const []const u8 {
        return s.buckets.keys();
    }

    pub fn errors(s: *const Snapshot) u32 {
        return s.counts[0];
    }

    pub fn warnings(s: *const Snapshot) u32 {
        return s.counts[1];
    }
};

/// Hears commits, on the UI thread: `changed` holds the keys whose
/// diagnostics changed (valid during the call).
pub const Listener = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, snap: *const Snapshot, changed: []const []const u8) void,
};

gpa: Allocator,
io: Io,
style: PathStyle,
mutex: Io.Mutex = .init,
/// Guarded by `mutex` (readers retain it under the lock).
current: *Snapshot,
/// The next snapshot, while `replace`s are pending (UI thread).
next: ?*Snapshot = null,
changed: std.StringArrayHashMapUnmanaged(void) = .empty,
listeners: std.ArrayList(Listener) = .empty,

pub fn init(gpa: Allocator, io: Io, style: PathStyle) Allocator.Error!DiagnosticStore {
    const s = try gpa.create(Snapshot);
    s.* = .{ .gpa = gpa, .generation = 0 };
    return .{ .gpa = gpa, .io = io, .style = style, .current = s };
}

/// Every reader must have released its snapshots.
pub fn deinit(st: *DiagnosticStore) void {
    if (st.next) |n| n.release();
    st.current.release();
    st.clearChanged();
    st.changed.deinit(st.gpa);
    st.listeners.deinit(st.gpa);
}

pub fn addListener(st: *DiagnosticStore, l: Listener) Allocator.Error!void {
    try st.listeners.append(st.gpa, l);
}

/// The current snapshot, retained; any thread. `release` it.
pub fn acquire(st: *DiagnosticStore) *Snapshot {
    st.mutex.lockUncancelable(st.io);
    defer st.mutex.unlock(st.io);
    st.current.retain();
    return st.current;
}

/// The key of `uri` (see the module doc); caller frees.
pub fn keyOf(st: *const DiagnosticStore, gpa: Allocator, uri: []const u8) Allocator.Error![]u8 {
    const path = zg_lsp.uri.pathFromUriStyle(gpa, uri, switch (st.style) {
        .posix => .posix,
        .windows => .windows,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    } orelse return gpa.dupe(u8, uri);
    defer gpa.free(path);
    return st.keyOfPath(gpa, path);
}

/// The key of the absolute path `path`; caller frees.
pub fn keyOfPath(st: *const DiagnosticStore, gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    const norm = try registry.normalizePath(gpa, path, st.style);
    defer gpa.free(norm);
    return registry.pathKey(gpa, norm, st.style);
}

/// Replaces `owner`'s set for `key` with `set` (taking it; null or an
/// empty set removes it). Published by the next `commit`. UI thread.
pub fn replace(st: *DiagnosticStore, key: []const u8, owner: Owner, set: ?*Set) Allocator.Error!void {
    var new = set;
    errdefer if (new) |s| s.destroy();
    if (new) |s| if (s.diags.len == 0) {
        s.destroy();
        new = null;
    };
    const next = try st.ensureNext();
    const old = next.buckets.get(key);
    if (old == null and new == null) return;
    if (old) |b| if (new == null and b.setOf(owner) == null) return;

    // The new bucket: the old one's other sets, plus `new`.
    var sets: std.ArrayList(*Set) = .empty;
    defer sets.deinit(st.gpa);
    if (old) |b| for (b.sets) |s| if (!s.owner.eql(owner)) try sets.append(st.gpa, s);
    if (new) |s| try sets.append(st.gpa, s);
    try st.markChanged(key);
    try next.buckets.ensureUnusedCapacity(st.gpa, 1);

    if (sets.items.len == 0) {
        const kv = next.buckets.fetchOrderedRemove(key).?;
        sub(&next.counts, kv.value.counts);
        kv.value.release(st.gpa);
        return;
    }
    const b = try st.gpa.create(Bucket);
    errdefer st.gpa.destroy(b);
    const owned_key = try st.gpa.dupe(u8, key);
    errdefer st.gpa.free(owned_key);
    const owned_sets = try sets.toOwnedSlice(st.gpa);
    // Nothing below fails.
    b.* = .{ .key = owned_key, .sets = owned_sets };
    for (owned_sets) |s| {
        add(&b.counts, s.counts);
        if (s != new) s.retain();
    }
    if (old) |ob| {
        // Same key: swap in place (the map key now points at `b.key`).
        sub(&next.counts, ob.counts);
        const i = next.buckets.getIndex(key).?;
        next.buckets.keys()[i] = b.key;
        next.buckets.values()[i] = b;
        ob.release(st.gpa);
    } else {
        next.buckets.putAssumeCapacity(b.key, b);
    }
    new = null;
    add(&next.counts, b.counts);
}

/// Removes every set of `owner` (a server stopped or crashed). UI thread.
pub fn clearOwner(st: *DiagnosticStore, owner: Owner) Allocator.Error!void {
    const next = try st.ensureNext();
    var doomed: std.ArrayList([]const u8) = .empty;
    defer doomed.deinit(st.gpa);
    for (next.buckets.values()) |b| if (b.setOf(owner) != null) try doomed.append(st.gpa, b.key);
    // Keys are freed as their buckets go: copy each first.
    for (doomed.items) |k| {
        const key = try st.gpa.dupe(u8, k);
        defer st.gpa.free(key);
        try st.replace(key, owner, null);
    }
}

/// Publishes the pending replacements and tells the listeners. UI thread.
pub fn commit(st: *DiagnosticStore) void {
    const next = st.next orelse return;
    st.next = null;
    if (st.changed.count() == 0) {
        next.release();
        return;
    }
    next.buckets.sort(struct {
        ks: []const []const u8,
        pub fn lessThan(c: @This(), a: usize, b: usize) bool {
            return std.mem.order(u8, c.ks[a], c.ks[b]) == .lt;
        }
    }{ .ks = next.buckets.keys() });
    const old = blk: {
        st.mutex.lockUncancelable(st.io);
        defer st.mutex.unlock(st.io);
        next.generation = st.current.generation + 1;
        const o = st.current;
        st.current = next;
        break :blk o;
    };
    old.release();
    for (st.listeners.items) |l| l.func(l.ctx, next, st.changed.keys());
    st.clearChanged();
}

/// The snapshot `replace` writes into: a shallow copy of the current one.
fn ensureNext(st: *DiagnosticStore) Allocator.Error!*Snapshot {
    if (st.next) |n| return n;
    const cur = st.current;
    const n = try st.gpa.create(Snapshot);
    errdefer st.gpa.destroy(n);
    n.* = .{ .gpa = st.gpa, .generation = cur.generation, .counts = cur.counts };
    n.buckets = try cur.buckets.clone(st.gpa);
    for (n.buckets.values()) |b| b.retain();
    st.next = n;
    return n;
}

fn markChanged(st: *DiagnosticStore, key: []const u8) Allocator.Error!void {
    if (st.changed.contains(key)) return;
    const k = try st.gpa.dupe(u8, key);
    errdefer st.gpa.free(k);
    try st.changed.put(st.gpa, k, {});
}

fn clearChanged(st: *DiagnosticStore) void {
    for (st.changed.keys()) |k| st.gpa.free(k);
    st.changed.clearRetainingCapacity();
}

fn add(a: *[4]u32, b: [4]u32) void {
    for (a, b) |*x, y| x.* += y;
}

fn sub(a: *[4]u32, b: [4]u32) void {
    for (a, b) |*x, y| x.* -= y;
}
