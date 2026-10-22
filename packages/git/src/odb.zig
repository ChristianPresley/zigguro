//! The object database: one lookup over the multi-pack-index, per-pack
//! indexes (newest first), loose objects and alternates.
//!
//! Reads are safe from several threads at once (packs are immutable maps;
//! the delta-base cache is sharded and locked). `rescan` and `close` need
//! exclusive access.

const std = @import("std");
const oid_mod = @import("oid.zig");
const object = @import("object.zig");
const loose = @import("loose.zig");
const pack_mod = @import("pack/pack.zig");
const midx_mod = @import("pack/midx.zig");
const MappedFile = @import("mapped.zig").MappedFile;
const DeltaBaseCache = @import("pack/cache.zig").DeltaBaseCache;
const Oid = oid_mod.Oid;
const ObjectFormat = oid_mod.ObjectFormat;
const ObjectType = object.ObjectType;
const Object = object.Object;
const Pack = pack_mod.Pack;
const Allocator = std.mem.Allocator;

/// Errors from object reads.
pub const ReadError = error{ ObjectNotFound, CorruptObject, CorruptPack, MissingBase } || loose.ReadError;

/// Errors from opening an object database.
pub const OpenError = pack_mod.OpenError || std.Io.Dir.OpenError || std.Io.Dir.Iterator.Error ||
    std.Io.Dir.ReadFileAllocError;

/// Options for `Odb.open`.
pub const Options = struct {
    /// Delta-base cache size.
    cache_bytes: usize = DeltaBaseCache.default_max_bytes,
    /// How many levels of `objects/info/alternates` to follow.
    max_alternate_depth: u8 = 5,
};

/// Object type and size.
pub const ObjectHeader = struct {
    /// Object type.
    type: ObjectType,
    /// Object size in bytes.
    size: u64,
};

/// See the file comment.
pub const Odb = struct {
    gpa: Allocator,
    io: std.Io,
    /// Hash function of the repository.
    format: ObjectFormat,
    /// The `objects` directory.
    dir: std.Io.Dir,
    owns_dir: bool = false,
    packs: std.ArrayList(*Pack) = .empty,
    midx_file: ?MappedFile = null,
    midx: ?midx_mod.Midx = null,
    midx_packs: []?*Pack = &.{},
    cache: DeltaBaseCache,
    alternates: std.ArrayList(*Odb) = .empty,
    next_pack_id: u32 = 0,

    /// Opens the object database in `objects_dir` (borrowed; the caller
    /// keeps it open until `close`).
    pub fn open(gpa: Allocator, io: std.Io, objects_dir: std.Io.Dir, fmt: ObjectFormat, opts: Options) OpenError!*Odb {
        const o = try gpa.create(Odb);
        errdefer gpa.destroy(o);
        o.* = .{ .gpa = gpa, .io = io, .format = fmt, .dir = objects_dir, .cache = .init(gpa, io, opts.cache_bytes) };
        errdefer o.closeContents();
        try o.scanPacks();
        if (opts.max_alternate_depth > 0) try o.loadAlternates(opts);
        return o;
    }

    fn closeContents(o: *Odb) void {
        o.dropPacks();
        for (o.alternates.items) |a| a.close();
        o.alternates.deinit(o.gpa);
        o.cache.deinit();
        if (o.owns_dir) o.dir.close(o.io);
    }

    /// Closes packs, alternates and the cache, and frees `o`.
    pub fn close(o: *Odb) void {
        const gpa = o.gpa;
        o.closeContents();
        gpa.destroy(o);
    }

    fn dropPacks(o: *Odb) void {
        for (o.packs.items) |p| p.close(o.gpa, o.io);
        o.packs.clearAndFree(o.gpa);
        if (o.midx_file) |*f| f.close(o.gpa, o.io);
        o.midx_file = null;
        o.midx = null;
        o.gpa.free(o.midx_packs);
        o.midx_packs = &.{};
    }

    /// Re-reads `objects/pack` (after a fetch or repack).
    pub fn rescan(o: *Odb) OpenError!void {
        o.dropPacks();
        try o.scanPacks();
    }

    fn scanPacks(o: *Odb) OpenError!void {
        var pd = o.dir.openDir(o.io, "pack", .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound => return,
            else => |x| return x,
        };
        defer pd.close(o.io);
        var it = pd.iterate();
        while (try it.next(o.io)) |e| {
            if (!std.mem.startsWith(u8, e.name, "pack-") or !std.mem.endsWith(u8, e.name, ".idx")) continue;
            const stem = e.name[0 .. e.name.len - 4];
            const p = Pack.open(o.gpa, o.io, pd, stem, o.format, o.next_pack_id) catch |err| switch (err) {
                // A pack being written or removed concurrently: skip it.
                error.FileNotFound, error.CorruptPack, error.CorruptIndex => continue,
                else => |x| return x,
            };
            o.next_pack_id += 1;
            o.packs.append(o.gpa, p) catch |err| {
                p.close(o.gpa, o.io);
                return err;
            };
        }
        std.mem.sort(*Pack, o.packs.items, {}, struct {
            fn newer(_: void, a: *Pack, b: *Pack) bool {
                return a.pack_file.mtime.nanoseconds > b.pack_file.mtime.nanoseconds;
            }
        }.newer);
        o.loadMidx(pd) catch {}; // a broken midx falls back to the per-pack indexes
    }

    fn loadMidx(o: *Odb, pd: std.Io.Dir) !void {
        var f = try MappedFile.open(o.gpa, o.io, pd, "multi-pack-index");
        errdefer f.close(o.gpa, o.io);
        const m = try midx_mod.Midx.parse(f.bytes, o.format);
        const map = try o.gpa.alloc(?*Pack, m.pack_count);
        errdefer o.gpa.free(map);
        var names = m.packNames();
        var i: usize = 0;
        while (names.next()) |nm| : (i += 1) {
            const stem = if (std.mem.endsWith(u8, nm, ".idx")) nm[0 .. nm.len - 4] else nm;
            map[i] = for (o.packs.items) |p| {
                if (std.mem.eql(u8, p.name, stem)) break p;
            } else null;
        }
        o.midx_file = f;
        o.midx = m;
        o.midx_packs = map;
    }

    fn loadAlternates(o: *Odb, opts: Options) OpenError!void {
        const text = o.dir.readFileAlloc(o.io, "info/alternates", o.gpa, .limited(64 * 1024)) catch |e| switch (e) {
            error.FileNotFound => return,
            else => |x| return x,
        };
        defer o.gpa.free(text);
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            const d = (if (std.fs.path.isAbsolute(line))
                std.Io.Dir.openDirAbsolute(o.io, line, .{})
            else
                o.dir.openDir(o.io, line, .{})) catch continue;
            const alt = open(o.gpa, o.io, d, o.format, .{
                .cache_bytes = opts.cache_bytes / 4,
                .max_alternate_depth = opts.max_alternate_depth - 1,
            }) catch {
                d.close(o.io);
                continue;
            };
            alt.owns_dir = true;
            o.alternates.append(o.gpa, alt) catch |e| {
                alt.close();
                return e;
            };
        }
    }

    const Found = struct { pack: *Pack, offset: u64 };

    fn findPacked(o: *Odb, id: Oid) ?Found {
        if (o.midx) |*m| if (m.find(id)) |loc| {
            if (o.midx_packs[loc.pack]) |p| return .{ .pack = p, .offset = loc.offset };
        };
        for (o.packs.items) |p| if (p.find(id)) |off| return .{ .pack = p, .offset = off };
        return null;
    }

    /// Reads an object; the data is owned by `gpa`.
    pub fn read(o: *Odb, gpa: Allocator, id: Oid) ReadError!Object {
        if (o.findPacked(id)) |f| return f.pack.readAt(gpa, &o.cache, f.offset);
        if (try loose.readLoose(gpa, o.io, o.dir, id)) |obj| return obj;
        for (o.alternates.items) |a| {
            return a.read(gpa, id) catch |e| switch (e) {
                error.ObjectNotFound => continue,
                else => |x| return x,
            };
        }
        return error.ObjectNotFound;
    }

    /// Reads an object and checks that its contents hash to `id`.
    pub fn readVerified(o: *Odb, gpa: Allocator, id: Oid) ReadError!Object {
        var obj = try o.read(gpa, id);
        if (!object.hashObject(o.format, obj.type, obj.data).eql(id)) {
            obj.deinit(gpa);
            return error.CorruptObject;
        }
        return obj;
    }

    /// Type and size of an object. Does not allocate for non-delta packed
    /// objects.
    pub fn readHeader(o: *Odb, id: Oid) ReadError!ObjectHeader {
        if (o.findPacked(id)) |f| {
            const h = try f.pack.readHeaderAt(f.offset);
            return .{ .type = h.type, .size = h.size };
        }
        if (try loose.readLoose(o.gpa, o.io, o.dir, id)) |obj| {
            var x = obj;
            defer x.deinit(o.gpa);
            return .{ .type = x.type, .size = x.data.len };
        }
        for (o.alternates.items) |a| {
            return a.readHeader(id) catch |e| switch (e) {
                error.ObjectNotFound => continue,
                else => |x| return x,
            };
        }
        return error.ObjectNotFound;
    }

    /// Whether the object exists anywhere.
    pub fn exists(o: *Odb, id: Oid) bool {
        if (o.findPacked(id) != null) return true;
        if (loose.exists(o.io, o.dir, id)) return true;
        for (o.alternates.items) |a| if (a.exists(id)) return true;
        return false;
    }

    /// Writes a loose object (no-op when it already exists anywhere).
    pub fn writeLoose(o: *Odb, t: ObjectType, data: []const u8) loose.WriteError!Oid {
        const id = object.hashObject(o.format, t, data);
        if (o.exists(id)) return id;
        return loose.writeLoose(o.gpa, o.io, o.dir, o.format, t, data);
    }
};

test "odb: every fixture object reads, verifies and matches its header" {
    const t = std.testing;
    const gpa = t.allocator;
    const testdata = @import("testdata.zig");
    for ([_]ObjectFormat{ .sha1, .sha256 }) |fmt| {
        var fx = try testdata.Fixture.open(gpa, t.io, fmt);
        defer fx.close();
        const o = try Odb.open(gpa, t.io, fx.objects, fmt, .{});
        defer o.close();
        try t.expect(o.midx != null);
        var it = fx.expected.iterator();
        var n: usize = 0;
        while (it.next()) |e| : (n += 1) {
            var obj = try o.readVerified(gpa, e.key_ptr.*);
            defer obj.deinit(gpa);
            try t.expectEqual(e.value_ptr.type, obj.type);
            const h = try o.readHeader(e.key_ptr.*);
            try t.expectEqual(e.value_ptr.size, h.size);
            try t.expect(o.exists(e.key_ptr.*));
        }
        try t.expectEqual(fx.expected.count(), n);
        try t.expectError(error.ObjectNotFound, o.read(gpa, oid_mod.hashBytes(fmt, "nope")));
        try t.expect(!o.exists(oid_mod.hashBytes(fmt, "nope")));
    }
}

test "odb: alternates and loose writes" {
    const t = std.testing;
    const gpa = t.allocator;
    const testdata = @import("testdata.zig");
    var fx = try testdata.Fixture.open(gpa, t.io, .sha1);
    defer fx.close();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try fx.objects.realPath(t.io, &abs_buf);
    try tmp.dir.createDirPath(t.io, "info");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "info/alternates", .data = abs_buf[0..n] });
    const o = try Odb.open(gpa, t.io, tmp.dir, .sha1, .{});
    defer o.close();
    try t.expectEqual(@as(usize, 1), o.alternates.items.len);
    var it = fx.expected.keyIterator();
    const some = it.next().?.*;
    var obj = try o.readVerified(gpa, some);
    obj.deinit(gpa);
    const id = try o.writeLoose(.blob, "fresh\n");
    var back = try o.readVerified(gpa, id);
    defer back.deinit(gpa);
    try t.expectEqualStrings("fresh\n", back.data);
}
