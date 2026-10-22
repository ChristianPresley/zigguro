//! Store integrity check.
//!
//! For every published segment: the index parses, its BLAKE3 trailer
//! matches, IDs are sorted and agree with the fanout, and the UIDs of index
//! and data match. For every record: it parses, its bytes hash to its ID,
//! and trees, changes and chunked blobs decode and refer only to objects
//! the store has. Segments are checked in parallel on an `Io.Group`.
//! Unpublished data files are listed, and with roots, unreachable objects
//! too.

const std = @import("std");
const id_mod = @import("id.zig");
const seg = @import("segment.zig");
const store_mod = @import("store.zig");
const gc_mod = @import("gc.zig");
const ObjectId = id_mod.ObjectId;
const Store = store_mod.Store;
const Segment = store_mod.Segment;
const Allocator = std.mem.Allocator;

pub const FsckOptions = struct {
    /// When non-empty, objects unreachable from these (and the pins) are
    /// reported as dangling.
    roots: []const gc_mod.RootProvider = &.{},
    edges: gc_mod.EdgeOptions = .{},
};

/// One integrity problem.
pub const Issue = struct {
    /// Segment stem.
    segment: []const u8,
    /// The object, when the problem is about one.
    id: ?ObjectId,
    reason: []const u8,
};

pub const FsckReport = struct {
    arena: std.heap.ArenaAllocator,
    /// Bad segments, indexes or records.
    corrupt: std.ArrayList(Issue) = .empty,
    /// Referenced by a stored object but absent.
    missing: std.ArrayList(ObjectId) = .empty,
    /// Unreachable from the roots (only with roots).
    dangling: std.ArrayList(ObjectId) = .empty,
    /// Data files without an index (garbage until GC removes them).
    unpublished: std.ArrayList([]const u8) = .empty,
    segments: usize = 0,
    objects: usize = 0,

    pub fn deinit(r: *FsckReport) void {
        r.arena.deinit();
        r.* = undefined;
    }

    /// No corruption and nothing missing (dangling and unpublished
    /// objects are garbage, not damage).
    pub fn clean(r: *const FsckReport) bool {
        return r.corrupt.items.len == 0 and r.missing.items.len == 0;
    }

    /// A human-readable summary, one problem per line.
    pub fn format(r: *const FsckReport, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d} segments, {d} objects: {d} corrupt, {d} missing, {d} dangling, {d} unpublished\n", .{
            r.segments, r.objects, r.corrupt.items.len, r.missing.items.len, r.dangling.items.len, r.unpublished.items.len,
        });
        for (r.corrupt.items) |c| {
            if (c.id) |id| try w.print("corrupt {s} {f}: {s}\n", .{ c.segment, id, c.reason }) else try w.print("corrupt {s}: {s}\n", .{ c.segment, c.reason });
        }
        for (r.missing.items) |id| try w.print("missing {f}\n", .{id});
        for (r.dangling.items) |id| try w.print("dangling {f}\n", .{id});
        for (r.unpublished.items) |n| try w.print("unpublished {s}\n", .{n});
    }
};

/// Per-segment results, merged after the parallel phase.
const SegCheck = struct {
    gpa: Allocator,
    sg: *Segment,
    edges: gc_mod.EdgeOptions,
    issues: std.ArrayList(Issue) = .empty,
    refs: std.ArrayList(ObjectId) = .empty,
    err: ?anyerror = null,

    fn run(c: *SegCheck) void {
        c.check() catch |e| {
            c.err = e;
        };
    }

    fn issue(c: *SegCheck, id: ?ObjectId, reason: []const u8) !void {
        try c.issues.append(c.gpa, .{ .segment = c.sg.stem, .id = id, .reason = reason });
    }

    fn check(c: *SegCheck) !void {
        const ix = c.sg.index;
        if (!ix.verifyChecksum()) try c.issue(null, "index checksum mismatch");
        if (!ix.verifyOrder()) try c.issue(null, "index not sorted or fanout wrong");
        var arena_state: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena_state.deinit();
        var sink: gc_mod.RootSink = .{ .gpa = c.gpa, .ids = &c.refs };
        for (0..ix.count) |k| {
            const i: u32 = @intCast(k);
            const id = ix.id(i);
            _ = arena_state.reset(.retain_capacity);
            const arena = arena_state.allocator();
            const rec = c.sg.record(i) catch {
                try c.issue(id, "record does not parse");
                continue;
            };
            const bytes = gc_mod.recordBytes(arena, rec) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => {
                    try c.issue(id, "record does not inflate");
                    continue;
                },
            };
            if (!id_mod.hashObject(rec.kind, bytes).eql(id)) {
                try c.issue(id, "content does not hash to its id");
                continue;
            }
            gc_mod.references(arena, rec.kind, bytes, c.edges, &sink) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => try c.issue(id, "object does not decode"),
            };
        }
    }
};

/// Checks the whole store. Free the report with `deinit`.
pub fn fsck(s: *Store, opts: FsckOptions) !FsckReport {
    const gpa = s.gpa;
    var report: FsckReport = .{ .arena = .init(gpa) };
    errdefer report.deinit();
    const ra = report.arena.allocator();

    // Every index on disk, including ones the store skipped as corrupt.
    var zgi: std.StringHashMapUnmanaged(void) = .empty;
    var zgs: std.ArrayList([]const u8) = .empty;
    var it = s.seg_dir.iterate();
    while (try it.next(s.io)) |e| {
        if (e.kind != .file) continue;
        if (std.mem.endsWith(u8, e.name, ".zgi")) try zgi.put(ra, try ra.dupe(u8, e.name[0 .. e.name.len - 4]), {});
        if (std.mem.endsWith(u8, e.name, ".zgs")) try zgs.append(ra, try ra.dupe(u8, e.name[0 .. e.name.len - 4]));
    }
    for (zgs.items) |stem| if (!zgi.contains(stem)) try report.unpublished.append(ra, stem);

    var segs: std.ArrayList(*Segment) = .empty;
    defer {
        for (segs.items) |sg| sg.release();
        segs.deinit(gpa);
    }
    var kit = zgi.keyIterator();
    while (kit.next()) |stem| {
        const sg = Segment.open(gpa, s.io, s.seg_dir, stem.*) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => {
                try report.corrupt.append(ra, .{ .segment = stem.*, .id = null, .reason = @errorName(e) });
                continue;
            },
        };
        try segs.append(gpa, sg);
    }
    report.segments = segs.items.len;

    const checks = try gpa.alloc(SegCheck, segs.items.len);
    defer {
        for (checks) |*c| {
            c.issues.deinit(gpa);
            c.refs.deinit(gpa);
        }
        gpa.free(checks);
    }
    var g: std.Io.Group = .init;
    for (checks, segs.items) |*c, sg| {
        c.* = .{ .gpa = gpa, .sg = sg, .edges = opts.edges };
        g.async(s.io, SegCheck.run, .{c});
    }
    try g.await(s.io);

    var missing_seen: std.AutoHashMapUnmanaged(ObjectId, void) = .empty;
    defer missing_seen.deinit(gpa);
    for (checks) |*c| {
        if (c.err) |e| return e;
        report.objects += c.sg.index.count;
        for (c.issues.items) |iss| try report.corrupt.append(ra, .{ .segment = try ra.dupe(u8, iss.segment), .id = iss.id, .reason = iss.reason });
        for (c.refs.items) |id| {
            if (gc_mod.locate(segs.items, id) != null) continue;
            if ((try missing_seen.getOrPut(gpa, id)).found_existing) continue;
            try report.missing.append(ra, id);
        }
    }

    if (opts.roots.len > 0) {
        var m = try gc_mod.mark(gpa, s, segs.items, opts.roots, opts.edges);
        defer m.deinit(gpa);
        for (segs.items) |sg| {
            for (0..sg.index.count) |k| {
                const id = sg.index.id(@intCast(k));
                if (!m.isLive(id)) try report.dangling.append(ra, id);
            }
        }
    }
    return report;
}
