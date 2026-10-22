//! The indexer's persistent cache, `<storage>/index/files.bin`: one record
//! per indexed file, keyed by path hash, so a warm start re-reads only
//! files whose size or mtime changed. Plugin payloads live in plugin-owned
//! files; this cache only says what was indexed, and with which plugin
//! versions.
//!
//! Layout (little-endian): magic "ZGIX", version u32, plugin_count u32,
//! record_count u32, then per plugin {name_len u8, name, version u32}, then
//! records of 40 bytes {path_hash u64, size u64, mtime_ns i128, class u8,
//! 7 pad}, then an xxhash3 u64 of everything before it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ContentClass = @import("content_class.zig").ContentClass;
const writeAtomic = @import("../model/storage.zig").writeAtomic;

/// What the cache remembers about one file.
pub const Record = struct {
    size: u64,
    mtime_ns: i128,
    class: ContentClass,
};

/// File name inside the index directory.
pub const file_name = "files.bin";
const magic = "ZGIX";
const version: u32 = 1;
const record_len = 40;

/// The cache table. Thread-safe.
pub const Cache = struct {
    gpa: Allocator,
    io: Io,
    lock: Io.Mutex = .init,
    map: std.AutoHashMapUnmanaged(u64, Record) = .empty,
    /// Plugin versions the records were made with (name -> version).
    versions: std.StringHashMapUnmanaged(u32) = .empty,
    dirty: bool = false,
    /// True when `load` found a damaged file and started empty.
    rebuilt: bool = false,

    /// An empty cache.
    pub fn init(gpa: Allocator, io: Io) Cache {
        return .{ .gpa = gpa, .io = io };
    }

    /// Frees the cache.
    pub fn deinit(c: *Cache) void {
        c.map.deinit(c.gpa);
        var it = c.versions.keyIterator();
        while (it.next()) |k| c.gpa.free(k.*);
        c.versions.deinit(c.gpa);
    }

    /// The record for `path_hash`.
    pub fn get(c: *Cache, path_hash: u64) ?Record {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        return c.map.get(path_hash);
    }

    /// Records a file as indexed.
    pub fn put(c: *Cache, path_hash: u64, rec: Record) !void {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        try c.map.put(c.gpa, path_hash, rec);
        c.dirty = true;
    }

    /// Forgets a file.
    pub fn remove(c: *Cache, path_hash: u64) void {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        if (c.map.remove(path_hash)) c.dirty = true;
    }

    /// Number of records.
    pub fn count(c: *Cache) usize {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        return c.map.count();
    }

    /// The version `plugin` had when the records were written, if known.
    pub fn pluginVersion(c: *Cache, plugin: []const u8) ?u32 {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        return c.versions.get(plugin);
    }

    /// Records the current version of a plugin (written by `save`).
    pub fn setPluginVersion(c: *Cache, plugin: []const u8, v: u32) !void {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        const gop = try c.versions.getOrPut(c.gpa, plugin);
        if (!gop.found_existing) {
            gop.key_ptr.* = c.gpa.dupe(u8, plugin) catch |err| {
                c.versions.removeByPtr(gop.key_ptr);
                return err;
            };
        }
        if (!gop.found_existing or gop.value_ptr.* != v) c.dirty = true;
        gop.value_ptr.* = v;
    }

    /// Loads `dir/files.bin`. A missing file leaves the cache empty; a
    /// damaged one too, with `rebuilt` set.
    pub fn load(c: *Cache, dir: Io.Dir) !void {
        const bytes = dir.readFileAlloc(c.io, file_name, c.gpa, .limited(1 << 30)) catch |err| switch (err) {
            error.FileNotFound => return,
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                c.rebuilt = true;
                return;
            },
        };
        defer c.gpa.free(bytes);
        c.parse(bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                c.map.clearRetainingCapacity();
                var it = c.versions.keyIterator();
                while (it.next()) |k| c.gpa.free(k.*);
                c.versions.clearRetainingCapacity();
                c.rebuilt = true;
            },
        };
    }

    fn parse(c: *Cache, b: []const u8) !void {
        if (b.len < 24 or !std.mem.eql(u8, b[0..4], magic)) return error.BadMagic;
        const body = b[0 .. b.len - 8];
        if (std.hash.XxHash3.hash(0, body) != std.mem.readInt(u64, b[b.len - 8 ..][0..8], .little)) return error.ChecksumMismatch;
        if (std.mem.readInt(u32, b[4..8], .little) != version) return error.UnsupportedVersion;
        const np = std.mem.readInt(u32, b[8..12], .little);
        const nr = std.mem.readInt(u32, b[12..16], .little);
        var p: usize = 16;
        for (0..np) |_| {
            if (p + 1 > body.len) return error.Truncated;
            const len = b[p];
            p += 1;
            if (p + len + 4 > body.len) return error.Truncated;
            try c.setPluginVersion(b[p..][0..len], std.mem.readInt(u32, b[p + len ..][0..4], .little));
            p += len + 4;
        }
        if (p + @as(usize, nr) * record_len != body.len) return error.Truncated;
        try c.map.ensureTotalCapacity(c.gpa, nr);
        for (0..nr) |_| {
            const r = b[p..][0..record_len];
            const class = std.enums.fromInt(ContentClass, r[32]) orelse return error.BadRecord;
            c.map.putAssumeCapacity(std.mem.readInt(u64, r[0..8], .little), .{
                .size = std.mem.readInt(u64, r[8..16], .little),
                .mtime_ns = std.mem.readInt(i128, r[16..32], .little),
                .class = class,
            });
            p += record_len;
        }
        c.dirty = false;
    }

    /// Writes `dir/files.bin` atomically.
    pub fn save(c: *Cache, dir: Io.Dir) !void {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(c.gpa);
        try out.ensureTotalCapacity(c.gpa, 24 + c.map.count() * record_len);
        try out.appendSlice(c.gpa, magic);
        var h: [4]u8 = undefined;
        for ([_]u32{ version, c.versions.count(), c.map.count() }) |v| {
            std.mem.writeInt(u32, &h, v, .little);
            try out.appendSlice(c.gpa, &h);
        }
        var vit = c.versions.iterator();
        while (vit.next()) |e| {
            try out.append(c.gpa, @intCast(e.key_ptr.len));
            try out.appendSlice(c.gpa, e.key_ptr.*);
            std.mem.writeInt(u32, &h, e.value_ptr.*, .little);
            try out.appendSlice(c.gpa, &h);
        }
        var it = c.map.iterator();
        while (it.next()) |e| {
            var r: [record_len]u8 = @splat(0);
            std.mem.writeInt(u64, r[0..8], e.key_ptr.*, .little);
            std.mem.writeInt(u64, r[8..16], e.value_ptr.size, .little);
            std.mem.writeInt(i128, r[16..32], e.value_ptr.mtime_ns, .little);
            r[32] = @intFromEnum(e.value_ptr.class);
            try out.appendSlice(c.gpa, &r);
        }
        var sum: [8]u8 = undefined;
        std.mem.writeInt(u64, &sum, std.hash.XxHash3.hash(0, out.items), .little);
        try out.appendSlice(c.gpa, &sum);
        try writeAtomic(c.io, dir, file_name, out.items);
        c.dirty = false;
    }
};

test "cache: save/load roundtrip; corrupted checksum -> rebuild" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var c: Cache = .init(gpa, io);
    defer c.deinit();
    try c.put(1, .{ .size = 10, .mtime_ns = -5, .class = .text });
    try c.put(2, .{ .size = 20, .mtime_ns = 1 << 70, .class = .binary });
    try c.setPluginVersion("trigram", 3);
    try c.save(tmp.dir);
    var d: Cache = .init(gpa, io);
    defer d.deinit();
    try d.load(tmp.dir);
    try std.testing.expect(!d.rebuilt);
    try std.testing.expectEqual(@as(usize, 2), d.count());
    try std.testing.expectEqual(@as(i128, 1 << 70), d.get(2).?.mtime_ns);
    try std.testing.expectEqual(ContentClass.binary, d.get(2).?.class);
    try std.testing.expectEqual(@as(?u32, 3), d.pluginVersion("trigram"));

    const bytes = try tmp.dir.readFileAlloc(io, file_name, gpa, .unlimited);
    defer gpa.free(bytes);
    bytes[20] ^= 1;
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = bytes });
    var e: Cache = .init(gpa, io);
    defer e.deinit();
    try e.load(tmp.dir);
    try std.testing.expect(e.rebuilt);
    try std.testing.expectEqual(@as(usize, 0), e.count());
}
