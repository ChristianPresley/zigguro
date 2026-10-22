//! Mark-and-sweep garbage collection.
//!
//! Mark: walk everything reachable from the roots (supplied by providers:
//! the op log, the git bridge map) plus the store's pins, following the
//! references inside trees, changes and chunked blobs. Live objects are
//! recorded by their first 8 bytes; two IDs sharing a prefix only keep an
//! extra object alive, never lose one.
//!
//! Sweep: segments older than the grace period whose live share is low are
//! rewritten with just their live records, then retired. Segments younger
//! than the grace period are never touched, which protects writers that
//! have stored objects but not yet published the operation naming them.

const std = @import("std");
const id_mod = @import("id.zig");
const object = @import("object.zig");
const enc = @import("encode.zig");
const seg = @import("segment.zig");
const store_mod = @import("store.zig");
const ObjectId = id_mod.ObjectId;
const Kind = id_mod.Kind;
const Store = store_mod.Store;
const Segment = store_mod.Segment;
const Allocator = std.mem.Allocator;

/// Receives root IDs from a provider.
pub const RootSink = struct {
    gpa: Allocator,
    ids: *std.ArrayList(ObjectId),

    pub fn add(sink: *RootSink, id: ObjectId) Allocator.Error!void {
        try sink.ids.append(sink.gpa, id);
    }
};

/// A source of GC roots (F03 op log, F09 git map, ...).
pub const RootProvider = struct {
    ctx: *anyopaque,
    forEachRoot: *const fn (ctx: *anyopaque, sink: *RootSink) anyerror!void,
};

/// Reports the references of object kinds this module does not know
/// (operations, views, provenance records: defined by later epics).
pub const EdgeFn = *const fn (ctx: ?*anyopaque, kind: Kind, bytes: []const u8, sink: *RootSink) anyerror!void;

/// How objects reference each other.
pub const EdgeOptions = struct {
    /// Keep the commits a change rewrote (its evolution history).
    follow_predecessors: bool = true,
    extra_edges: ?EdgeFn = null,
    extra_ctx: ?*anyopaque = null,
};

/// Appends to `sink` every object `bytes` (an object of `kind`) refers to.
/// Gitlinks are skipped: they name commits in other repositories.
pub fn references(arena: Allocator, kind: Kind, bytes: []const u8, opts: EdgeOptions, sink: *RootSink) !void {
    switch (kind) {
        .tree => {
            const t = try enc.decode(object.Tree, arena, bytes);
            for (t.entries) |e| if (e.kind != .gitlink) try sink.add(e.id);
        },
        .change => {
            const c = try enc.decode(object.Change, arena, bytes);
            for (c.parents) |p| try sink.add(p);
            for (c.tree_terms) |t| try sink.add(t);
            if (opts.follow_predecessors) for (c.predecessors) |p| try sink.add(p);
            if (c.provenance) |p| try sink.add(p);
        },
        .chunked_blob => {
            const cb = try enc.decode(object.ChunkedBlob, arena, bytes);
            for (cb.chunks) |ch| try sink.add(ch.id);
        },
        .blob, .text => {},
        .operation, .view, .attribution, .prov_record => if (opts.extra_edges) |f| try f(opts.extra_ctx, kind, bytes, sink),
    }
}

/// The first 8 bytes of an ID: the mark set's key.
pub fn prefix(id: ObjectId) u64 {
    return std.mem.readInt(u64, id.bytes[0..8], .little);
}

/// Where an object lives in a snapshot.
pub const Found = struct { segment: *Segment, index: u32 };

/// Finds `id` in `segs` (newest first).
pub fn locate(segs: []const *Segment, id: ObjectId) ?Found {
    for (segs) |sg| if (sg.index.find(id)) |i| return .{ .segment = sg, .index = i };
    return null;
}

/// The decoded bytes of a record: the payload itself, or an inflated copy
/// in `arena`.
pub fn recordBytes(arena: Allocator, rec: seg.Record) ![]const u8 {
    if (!rec.deflated()) return rec.payload;
    const out = try arena.alloc(u8, rec.raw_len);
    try store_mod.inflateRaw(rec.payload, out);
    return out;
}

/// Result of `mark`.
pub const Marked = struct {
    live: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Referenced but not in the store.
    missing: std.ArrayList(ObjectId) = .empty,

    pub fn deinit(m: *Marked, gpa: Allocator) void {
        m.live.deinit(gpa);
        m.missing.deinit(gpa);
    }

    pub fn isLive(m: *const Marked, id: ObjectId) bool {
        return m.live.contains(prefix(id));
    }
};

/// Marks everything reachable from `roots` and the store's pins in `segs`.
pub fn mark(gpa: Allocator, s: *Store, segs: []const *Segment, roots: []const RootProvider, opts: EdgeOptions) !Marked {
    var m: Marked = .{};
    errdefer m.deinit(gpa);
    var queue: std.ArrayList(ObjectId) = .empty;
    defer queue.deinit(gpa);
    var sink: RootSink = .{ .gpa = gpa, .ids = &queue };
    for (roots) |r| try r.forEachRoot(r.ctx, &sink);
    const pins = try s.pinned(gpa);
    defer gpa.free(pins);
    try queue.appendSlice(gpa, pins);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    while (queue.pop()) |id| {
        const gop = try m.live.getOrPut(gpa, prefix(id));
        if (gop.found_existing) continue;
        const loc = locate(segs, id) orelse {
            try m.missing.append(gpa, id);
            continue;
        };
        const kind = try loc.segment.kindAt(loc.index);
        switch (kind) {
            .blob, .text => continue,
            else => {},
        }
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        const rec = try loc.segment.record(loc.index);
        try references(arena, kind, try recordBytes(arena, rec), opts, &sink);
    }
    return m;
}

pub const GcOptions = struct {
    /// Segments whose data file is younger than this are left alone.
    grace_ns: u64 = std.time.ns_per_hour,
    /// Rewrite a segment when less than this share of its records is live.
    rewrite_below: f32 = 0.5,
    edges: EdgeOptions = .{},
    /// Deflate records while rewriting.
    deflate: bool = true,
    /// Override "now" (nanoseconds since the epoch) for tests.
    now_ns: ?i96 = null,
};

pub const GcReport = struct {
    /// Distinct live prefixes found by the mark phase.
    marked: usize = 0,
    /// Referenced objects absent from the store.
    missing: usize = 0,
    segments_rewritten: usize = 0,
    segments_deleted: usize = 0,
    objects_removed: usize = 0,
    bytes_freed: u64 = 0,
    /// Unpublished segment data files and stale temporaries removed.
    unpublished_removed: usize = 0,
};

fn olderThanGrace(sg: *const Segment, now: i96, grace_ns: u64) bool {
    return now - sg.data.mtime.nanoseconds >= grace_ns;
}

/// Collects garbage: see the file comment.
pub fn gc(s: *Store, roots: []const RootProvider, opts: GcOptions) !GcReport {
    const gpa = s.gpa;
    try s.rescan();
    const segs = try s.snapshot(gpa);
    defer Store.releaseSnapshot(gpa, segs);
    var m = try mark(gpa, s, segs, roots, opts.edges);
    defer m.deinit(gpa);
    var report: GcReport = .{ .marked = m.live.count(), .missing = m.missing.items.len };
    const now = opts.now_ns orelse std.Io.Timestamp.now(s.io, .real).nanoseconds;

    var retired: std.ArrayList(*Segment) = .empty;
    defer retired.deinit(gpa);
    var b = s.batch();
    defer b.abort();
    for (segs) |sg| {
        if (!olderThanGrace(sg, now, opts.grace_ns)) continue;
        var live: usize = 0;
        for (0..sg.index.count) |k| {
            if (m.isLive(sg.index.id(@intCast(k)))) live += 1;
        }
        if (live == sg.index.count) continue;
        const share = @as(f32, @floatFromInt(live)) / @as(f32, @floatFromInt(@max(1, sg.index.count)));
        if (live > 0 and share >= opts.rewrite_below) continue;
        for (0..sg.index.count) |k| {
            const i: u32 = @intCast(k);
            const id = sg.index.id(i);
            if (m.isLive(id)) {
                try b.copyRecord(id, try sg.record(i), opts.deflate);
            } else report.objects_removed += 1;
        }
        report.bytes_freed += sg.data.bytes.len + sg.index_file.bytes.len;
        if (live > 0) report.segments_rewritten += 1 else report.segments_deleted += 1;
        try retired.append(gpa, sg);
    }
    if (retired.items.len > 0) {
        try b.commit();
        s.retire(retired.items);
    }
    report.unpublished_removed = try removeUnpublished(s, now, opts.grace_ns);
    return report;
}

/// Deletes `.zgs` files without an index, and leftover temporary files
/// (16 hex digits, no extension), once older than the grace period.
fn removeUnpublished(s: *Store, now: i96, grace_ns: u64) !usize {
    const gpa = s.gpa;
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var published: std.StringHashMapUnmanaged(void) = .empty;
    defer published.deinit(gpa);
    var it = s.seg_dir.iterate();
    while (try it.next(s.io)) |e| {
        if (e.kind != .file) continue;
        const name = try gpa.dupe(u8, e.name);
        try names.append(gpa, name);
        if (std.mem.endsWith(u8, name, ".zgi")) try published.put(gpa, name[0 .. name.len - 4], {});
    }
    var removed: usize = 0;
    for (names.items) |name| {
        const unpublished_data = std.mem.endsWith(u8, name, ".zgs") and !published.contains(name[0 .. name.len - 4]);
        const temp = name.len == 16 and for (name) |c| {
            if (!std.ascii.isHex(c)) break false;
        } else true;
        if (!unpublished_data and !temp) continue;
        const st = s.seg_dir.statFile(s.io, name, .{}) catch continue;
        if (now - st.mtime.nanoseconds < grace_ns) continue;
        s.seg_dir.deleteFile(s.io, name) catch continue;
        removed += 1;
    }
    return removed;
}
