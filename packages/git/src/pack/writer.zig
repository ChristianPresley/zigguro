//! Pack writing for push and bulk export: objects are grouped like git does
//! (type, path-name hash, size descending), delta-compressed against a
//! sliding window of earlier objects, and emitted with OFS_DELTA (or
//! REF_DELTA against `thin_bases` the receiver already has).

const std = @import("std");
const oid_mod = @import("../oid.zig");
const object = @import("../object.zig");
const loose = @import("../loose.zig");
const deltify = @import("deltify.zig");
const idx_mod = @import("idx.zig");
const rev_mod = @import("rev.zig");
const Odb = @import("../odb.zig").Odb;
const Oid = oid_mod.Oid;
const ObjectFormat = oid_mod.ObjectFormat;
const ObjectType = object.ObjectType;
const Allocator = std.mem.Allocator;

/// What the writer knows about an object before reading it.
pub const ObjectHint = struct {
    /// Path the object was reached by (groups versions of one file).
    path: []const u8 = "",
};

/// Pack writing options.
pub const WriteOptions = struct {
    /// Delta search window.
    window: u16 = 10,
    /// Maximum delta chain depth.
    depth: u16 = 50,
    /// Objects the receiver has: usable as REF_DELTA bases, not written.
    thin_bases: []const Oid = &.{},
    /// Use OFS_DELTA (else REF_DELTA) for in-pack bases.
    ofs_delta: bool = true,
    /// zlib level.
    level: std.compress.flate.Compress.Options = .default,
};

/// Result of writing a pack.
pub const Written = struct {
    /// Pack trailer checksum (also the pack's name).
    checksum: Oid,
    /// Objects written.
    count: u32,
    /// Objects stored as deltas.
    deltas: u32,
};

const Item = struct {
    id: Oid,
    type: ObjectType,
    data: []u8,
    name_hash: u32,
    external: bool,
    // Filled by the delta search.
    base: ?u32 = null,
    delta: ?[]u8 = null,
    depth: u16 = 0,
    // Filled while writing.
    offset: u64 = 0,
    crc: u32 = 0,
};

/// git's `pack_name_hash`: favours the last characters of the path so that
/// files with the same name group together.
pub fn nameHash(path: []const u8) u32 {
    var h: u32 = 0;
    for (path) |c| {
        if (std.ascii.isWhitespace(c)) continue;
        h = (h >> 2) +% (@as(u32, c) << 24);
    }
    return h;
}

/// Collects objects and writes them as one pack. Not thread-safe.
pub const PackWriter = struct {
    gpa: Allocator,
    odb: ?*Odb,
    format: ObjectFormat,
    items: std.ArrayList(Item) = .empty,
    seen: std.AutoHashMapUnmanaged(Oid, void) = .empty,

    /// A writer reading `add`ed objects from `odb`.
    pub fn init(gpa: Allocator, odb: ?*Odb, fmt: ObjectFormat) PackWriter {
        return .{ .gpa = gpa, .odb = odb, .format = fmt };
    }

    /// Frees all collected objects.
    pub fn deinit(w: *PackWriter) void {
        for (w.items.items) |*it| {
            w.gpa.free(it.data);
            if (it.delta) |d| w.gpa.free(d);
        }
        w.items.deinit(w.gpa);
        w.seen.deinit(w.gpa);
        w.* = undefined;
    }

    /// Adds an object from the odb (duplicates are ignored).
    pub fn add(w: *PackWriter, id: Oid, hint: ObjectHint) !void {
        if (w.seen.contains(id)) return;
        const odb = w.odb orelse return error.ObjectNotFound;
        const obj = try odb.read(w.gpa, id);
        errdefer w.gpa.free(obj.data);
        try w.push(id, obj.type, obj.data, hint, false);
    }

    /// Adds an object from memory (copied; duplicates ignored).
    pub fn addData(w: *PackWriter, t: ObjectType, data: []const u8, hint: ObjectHint) !Oid {
        const id = object.hashObject(w.format, t, data);
        if (w.seen.contains(id)) return id;
        const copy = try w.gpa.dupe(u8, data);
        errdefer w.gpa.free(copy);
        try w.push(id, t, copy, hint, false);
        return id;
    }

    fn push(w: *PackWriter, id: Oid, t: ObjectType, data: []u8, hint: ObjectHint, external: bool) !void {
        try w.seen.put(w.gpa, id, {});
        errdefer _ = w.seen.remove(id);
        try w.items.append(w.gpa, .{ .id = id, .type = t, .data = data, .name_hash = nameHash(hint.path), .external = external });
    }

    /// Number of objects that will be written.
    pub fn count(w: *const PackWriter) u32 {
        var n: u32 = 0;
        for (w.items.items) |it| n += @intFromBool(!it.external);
        return n;
    }

    fn order(_: void, a: Item, b: Item) bool {
        if (a.type != b.type) return @intFromEnum(a.type) < @intFromEnum(b.type);
        if (a.name_hash != b.name_hash) return a.name_hash < b.name_hash;
        if (a.data.len != b.data.len) return a.data.len > b.data.len;
        return a.id.order(b.id) == .lt;
    }

    fn searchDeltas(w: *PackWriter, opts: WriteOptions) !void {
        const items = w.items.items;
        std.mem.sort(Item, items, {}, order);
        var aw: std.Io.Writer.Allocating = .init(w.gpa);
        defer aw.deinit();
        // Index of each window member, built lazily and reused.
        var indexes: std.AutoHashMapUnmanaged(u32, deltify.Index) = .empty;
        defer {
            var it = indexes.valueIterator();
            while (it.next()) |ix| ix.deinit(w.gpa);
            indexes.deinit(w.gpa);
        }
        for (items, 0..) |*target, ti| {
            if (target.external or target.data.len < 32) continue;
            var best: ?u32 = null;
            var best_len: usize = target.data.len / 2;
            const lo = ti -| opts.window;
            var j = ti;
            while (j > lo) {
                j -= 1;
                const base = &items[j];
                if (base.type != target.type or base.data.len < 16) continue;
                if (base.depth >= opts.depth) continue;
                if (base.data.len > deltify.max_base) continue;
                // Size heuristic: a much smaller base rarely pays off.
                if (base.data.len * 32 < target.data.len) continue;
                const gop = try indexes.getOrPut(w.gpa, @intCast(j));
                if (!gop.found_existing) gop.value_ptr.* = try deltify.Index.init(w.gpa, base.data);
                aw.clearRetainingCapacity();
                if (try deltify.encode(gop.value_ptr, target.data, &aw.writer, best_len) and aw.written().len < best_len) {
                    best_len = aw.written().len;
                    best = @intCast(j);
                    if (target.delta) |d| w.gpa.free(d);
                    target.delta = try w.gpa.dupe(u8, aw.written());
                }
            }
            if (best) |b| {
                target.base = b;
                target.depth = items[b].depth + 1;
            }
            // Drop indexes that left the window.
            if (ti >= opts.window) {
                if (indexes.fetchRemove(@intCast(ti - opts.window))) |kv| {
                    var ix = kv.value;
                    ix.deinit(w.gpa);
                }
            }
        }
    }

    /// Writes the pack to `out` and fills each object's offset and CRC.
    pub fn finish(w: *PackWriter, out: *std.Io.Writer, opts: WriteOptions) !Written {
        if (w.odb) |odb| for (opts.thin_bases) |id| {
            if (w.seen.contains(id)) continue;
            const obj = odb.read(w.gpa, id) catch continue;
            errdefer w.gpa.free(obj.data);
            try w.push(id, obj.type, obj.data, .{}, true);
        };
        try w.searchDeltas(opts);
        const items = w.items.items;

        // Bases must precede their deltas: emit in sorted order, which puts
        // every in-window base before its targets.
        var hasher = oid_mod.Hasher.init(w.format);
        var hbuf: [64 * 1024]u8 = undefined;
        var hw = out.hashed(&hasher, &hbuf);
        const o = &hw.writer;
        var pos: u64 = 0;
        try o.writeAll("PACK");
        try o.writeInt(u32, 2, .big);
        try o.writeInt(u32, w.count(), .big);
        pos += 12;
        var aw: std.Io.Writer.Allocating = .init(w.gpa);
        defer aw.deinit();
        var deltas: u32 = 0;
        for (items) |*it| {
            if (it.external) continue;
            aw.clearRetainingCapacity();
            const ew = &aw.writer;
            var payload: []const u8 = it.data;
            if (it.base) |b| {
                const base = &items[b];
                payload = it.delta.?;
                const ofs = opts.ofs_delta and !base.external;
                try writeEntryHeader(ew, if (ofs) 6 else 7, payload.len);
                if (ofs) try writeOfs(ew, pos - base.offset) else try ew.writeAll(base.id.slice());
                deltas += 1;
            } else {
                try writeEntryHeader(ew, @intFromEnum(it.type), payload.len);
            }
            try zlibInto(w.gpa, ew, payload, opts.level);
            it.offset = pos;
            it.crc = std.hash.Crc32.hash(aw.written());
            try o.writeAll(aw.written());
            pos += aw.written().len;
        }
        try o.flush();
        const sum = hasher.final();
        try out.writeAll(sum.slice());
        return .{ .checksum = sum, .count = w.count(), .deltas = deltas };
    }

    /// Writes `.idx` v2 for the last `finish`.
    pub fn writeIndex(w: *PackWriter, out: *std.Io.Writer, checksum: Oid) !void {
        const entries = try w.gpa.alloc(idx_mod.Entry, w.count());
        defer w.gpa.free(entries);
        var n: usize = 0;
        for (w.items.items) |it| {
            if (it.external) continue;
            entries[n] = .{ .oid = it.id, .crc32 = it.crc, .offset = it.offset };
            n += 1;
        }
        std.mem.sort(idx_mod.Entry, entries, {}, idx_mod.Entry.lessThan);
        _ = try idx_mod.writeIndex(out, w.format, entries, checksum.slice());
    }

    /// Writes `.rev` for the last `finish`.
    pub fn writeRev(w: *PackWriter, out: *std.Io.Writer, checksum: Oid) !void {
        const entries = try w.gpa.alloc(idx_mod.Entry, w.count());
        defer w.gpa.free(entries);
        var n: usize = 0;
        for (w.items.items) |it| {
            if (it.external) continue;
            entries[n] = .{ .oid = it.id, .crc32 = it.crc, .offset = it.offset };
            n += 1;
        }
        std.mem.sort(idx_mod.Entry, entries, {}, idx_mod.Entry.lessThan);
        const positions = try w.gpa.alloc(u32, n);
        defer w.gpa.free(positions);
        for (positions, 0..) |*p, i| p.* = @intCast(i);
        std.mem.sort(u32, positions, entries, struct {
            fn lt(es: []idx_mod.Entry, a: u32, b: u32) bool {
                return es[a].offset < es[b].offset;
            }
        }.lt);
        try rev_mod.writeRev(out, w.format, positions, checksum.slice());
    }
};

/// Writes a pack entry header: type and size varint.
pub fn writeEntryHeader(w: *std.Io.Writer, kind: u3, size: u64) std.Io.Writer.Error!void {
    var s = size;
    var b: u8 = (@as(u8, kind) << 4) | @as(u8, @truncate(s & 15));
    s >>= 4;
    while (s != 0) {
        try w.writeByte(b | 0x80);
        b = @truncate(s & 0x7f);
        s >>= 7;
    }
    try w.writeByte(b);
}

/// Writes an OFS_DELTA negative offset (git's offset encoding).
pub fn writeOfs(w: *std.Io.Writer, distance: u64) std.Io.Writer.Error!void {
    var buf: [10]u8 = undefined;
    var i: usize = buf.len - 1;
    var v = distance;
    buf[i] = @truncate(v & 0x7f);
    v >>= 7;
    while (v != 0) {
        v -= 1;
        i -= 1;
        buf[i] = 0x80 | @as(u8, @truncate(v & 0x7f));
        v >>= 7;
    }
    try w.writeAll(buf[i..]);
}

fn zlibInto(gpa: Allocator, w: *std.Io.Writer, data: []const u8, level: std.compress.flate.Compress.Options) !void {
    const flate = std.compress.flate;
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    const comp = try gpa.create(flate.Compress);
    defer gpa.destroy(comp);
    _ = try w.writableSliceGreedy(16);
    comp.* = try .init(w, window, .zlib, level);
    try comp.writer.writeAll(data);
    try comp.finish();
}

test "writer: roundtrip all objects with valid deltas and bounded depth" {
    const t = std.testing;
    const gpa = t.allocator;
    const Pack = @import("pack.zig").Pack;
    const DeltaBaseCache = @import("cache.zig").DeltaBaseCache;
    var pw = PackWriter.init(gpa, null, .sha1);
    defer pw.deinit();
    // 60 versions of a growing file, so deltas chain.
    var ids: std.ArrayList(Oid) = .empty;
    defer ids.deinit(gpa);
    var content: std.Io.Writer.Allocating = .init(gpa);
    defer content.deinit();
    for (0..60) |i| {
        try content.writer.print("line {d} of a file that keeps growing\n", .{i});
        try ids.append(gpa, try pw.addData(.blob, content.written(), .{ .path = "src/file.txt" }));
    }
    _ = try pw.addData(.commit, "tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\nauthor a <b> 1 +0000\ncommitter a <b> 1 +0000\n\nm\n", .{});
    var pack_out: std.Io.Writer.Allocating = .init(gpa);
    defer pack_out.deinit();
    const res = try pw.finish(&pack_out.writer, .{ .depth = 5, .window = 4 });
    try t.expectEqual(@as(u32, 61), res.count);
    try t.expect(res.deltas > 40);
    var idx_out: std.Io.Writer.Allocating = .init(gpa);
    defer idx_out.deinit();
    try pw.writeIndex(&idx_out.writer, res.checksum);
    for (pw.items.items) |it| try t.expect(it.depth <= 5);

    var p = try Pack.init(.borrowed(pack_out.written()), .borrowed(idx_out.written()), .sha1, 0);
    var cache: DeltaBaseCache = .init(gpa, t.io, 1 << 20);
    defer cache.deinit();
    for (ids.items) |id| {
        var o = try p.readAt(gpa, &cache, p.find(id).?);
        defer o.deinit(gpa);
        try t.expect(object.hashObject(.sha1, o.type, o.data).eql(id));
    }
    // The trailer hash covers the whole pack.
    const body = pack_out.written();
    try t.expect(oid_mod.hashBytes(.sha1, body[0 .. body.len - 20]).eql(res.checksum));
}

test "writer: offset encoding matches the reader" {
    const t = std.testing;
    const parseEntryHeader = @import("pack.zig").parseEntryHeader;
    const gpa = t.allocator;
    for ([_]u64{ 1, 127, 128, 129, 16511, 16512, 1 << 20, (1 << 21) + 5 }) |dist| {
        // An OFS_DELTA entry at offset 12 + dist pointing back to offset 12.
        const off: usize = @intCast(12 + dist);
        const data = try gpa.alloc(u8, off + 32);
        defer gpa.free(data);
        @memset(data, 0);
        var w: std.Io.Writer = .fixed(data[off..]);
        try writeEntryHeader(&w, 6, 1000);
        try writeOfs(&w, dist);
        const h = try parseEntryHeader(data, off, .sha1);
        try t.expectEqual(@as(u64, 1000), h.size);
        try t.expectEqual(@as(u64, 12), h.base.offset);
    }
}

test "writer: thin pack uses REF_DELTA to thin_bases" {
    const t = std.testing;
    const gpa = t.allocator;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const odb = try Odb.open(gpa, t.io, tmp.dir, .sha1, .{});
    defer odb.close();
    var big: std.Io.Writer.Allocating = .init(gpa);
    defer big.deinit();
    for (0..400) |i| try big.writer.print("shared line {d}\n", .{i});
    const base_id = try odb.writeLoose(.blob, big.written());
    try big.writer.writeAll("one more line\n");
    var pw = PackWriter.init(gpa, odb, .sha1);
    defer pw.deinit();
    const new_id = try pw.addData(.blob, big.written(), .{ .path = "f" });
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const res = try pw.finish(&out.writer, .{ .thin_bases = &.{base_id} });
    try t.expectEqual(@as(u32, 1), res.count);
    try t.expectEqual(@as(u32, 1), res.deltas);
    const h = try @import("pack.zig").parseEntryHeader(out.written()[0 .. out.written().len - 20], 12, .sha1);
    try t.expectEqual(@import("pack.zig").EntryKind.ref_delta, h.kind);
    try t.expect(h.base.oid.eql(base_id));
    _ = new_id;
}
