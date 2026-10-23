//! A change's provenance manifest (E09.F05): for each file the change
//! touches, the blob it attributes and its attribution map, stored
//! compactly (records once, then varint runs). `Change.provenance` points
//! at it; it is a `Kind.attribution` object. Lines a change did not write
//! are inherited (record index 0).

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const enc = @import("../store/encode.zig");
const store_mod = @import("../store/store.zig");
const attribution = @import("attribution.zig");
const ObjectId = id_mod.ObjectId;
const Kind = id_mod.Kind;
const AttributionMap = attribution.AttributionMap;
const Allocator = std.mem.Allocator;

/// A run of one file: `rec` 0 is inherited, otherwise `records[rec - 1]`.
pub const EncRun = struct {
    len: u32,
    rec: u32,
    mixed: bool = false,
};

pub const FileAttribution = struct {
    /// Repository-relative, '/'-separated.
    path: []const u8,
    /// The blob the map describes.
    blob: ObjectId,
    records: []const ObjectId,
    runs: []const EncRun,

    pub fn validate(f: FileAttribution) object.ValidateError!void {
        for (f.runs, 0..) |r, i| {
            if (r.len == 0 or r.rec > f.records.len) return error.InvalidAttribution;
            if (i > 0 and f.runs[i - 1].rec == r.rec and f.runs[i - 1].mixed == r.mixed) return error.InvalidAttribution;
        }
        for (f.records) |r| if (r.eql(attribution.inherited)) return error.InvalidAttribution;
    }

    /// The map, allocated in `arena`.
    pub fn map(f: FileAttribution, arena: Allocator) !AttributionMap {
        const runs = try arena.alloc(attribution.Run, f.runs.len);
        var pos: u32 = 0;
        for (runs, f.runs) |*r, e| {
            r.* = .{ .start_line = pos, .len = e.len, .prov = if (e.rec == 0) attribution.inherited else f.records[e.rec - 1], .mixed = e.mixed };
            pos += e.len;
        }
        return .{ .runs = runs };
    }
};

/// `m` for `path` at `blob`, encoded into `arena`.
pub fn encodeFile(arena: Allocator, path: []const u8, blob: ObjectId, m: AttributionMap) !FileAttribution {
    var records: std.ArrayList(ObjectId) = .empty;
    const runs = try arena.alloc(EncRun, m.runs.len);
    for (runs, m.runs) |*e, r| {
        var rec: u32 = 0;
        if (!r.prov.eql(attribution.inherited)) {
            rec = for (records.items, 0..) |x, i| {
                if (x.eql(r.prov)) break @intCast(i + 1);
            } else blk: {
                try records.append(arena, r.prov);
                break :blk @intCast(records.items.len);
            };
        }
        e.* = .{ .len = r.len, .rec = rec, .mixed = r.mixed };
    }
    return .{ .path = path, .blob = blob, .records = records.items, .runs = runs };
}

pub const ProvenanceManifest = struct {
    pub const kind: Kind = .attribution;

    /// Sorted by path, unique.
    files: []const FileAttribution,
    extra: []const object.Extra = &.{},

    pub fn validate(m: ProvenanceManifest) object.ValidateError!void {
        try object.validateExtra(m.extra);
        for (m.files, 0..) |f, i| {
            if (i > 0 and std.mem.order(u8, m.files[i - 1].path, f.path) != .lt) return error.InvalidAttribution;
        }
    }

    pub fn find(m: ProvenanceManifest, path: []const u8) ?FileAttribution {
        var lo: usize = 0;
        var hi: usize = m.files.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            switch (std.mem.order(u8, m.files[mid].path, path)) {
                .eq => return m.files[mid],
                .lt => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return null;
    }

    /// Every record the manifest names, once each.
    pub fn records(m: ProvenanceManifest, arena: Allocator) ![]const ObjectId {
        var seen: std.AutoArrayHashMapUnmanaged([32]u8, void) = .empty;
        for (m.files) |f| for (f.records) |r| try seen.put(arena, r.bytes, {});
        const out = try arena.alloc(ObjectId, seen.count());
        for (out, seen.keys()) |*o, k| o.* = .{ .bytes = k };
        return out;
    }
};

/// Sorts `files` by path in place (before building a manifest).
pub fn sortFiles(files: []FileAttribution) void {
    std.mem.sort(FileAttribution, files, {}, struct {
        fn lt(_: void, a: FileAttribution, b: FileAttribution) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lt);
}

/// Writes `m` in `batch`; returns its ID.
pub fn write(batch: *store_mod.WriteBatch, gpa: Allocator, m: ProvenanceManifest) !ObjectId {
    const bytes = try enc.encodeAlloc(gpa, ProvenanceManifest, m);
    defer gpa.free(bytes);
    return batch.put(.attribution, bytes);
}

/// Reads the manifest `id` into `arena`.
pub fn read(s: *store_mod.Store, arena: Allocator, id: ObjectId) !ProvenanceManifest {
    const r = try s.read(id);
    defer r.release();
    if (r.kind != .attribution) return error.WrongKind;
    const bytes = try arena.dupe(u8, r.bytes);
    return enc.decode(ProvenanceManifest, arena, bytes) catch error.CorruptObject;
}

const testing = std.testing;

fn idN(n: u8) ObjectId {
    var o: ObjectId = .zero;
    o.bytes[0] = n;
    return o;
}

test "manifest: compact encoding of a 10k-line file with 3 actors" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var b = try attribution.Builder.initInherited(gpa, 10_000);
    defer b.deinit();
    // 30 edits spread over the file by three actors.
    for (0..30) |i| try b.splice(@intCast(i * 300 + 5), 20, 20, idN(@intCast(1 + i % 3)), i % 7 == 0);
    const m = try b.toMap(a);
    const fa = try encodeFile(a, "src/big.zig", idN(9), m);
    try testing.expectEqual(@as(usize, 3), fa.records.len);
    const man: ProvenanceManifest = .{ .files = &.{fa} };
    const bytes = try enc.encodeAlloc(a, ProvenanceManifest, man);
    try testing.expect(bytes.len < 1024);
    const back = try enc.decode(ProvenanceManifest, a, bytes);
    try testing.expect((try back.find("src/big.zig").?.map(a)).eql(m));
    try testing.expect(back.find("src/other.zig") == null);
    try testing.expectEqual(@as(usize, 3), (try back.records(a)).len);
}
