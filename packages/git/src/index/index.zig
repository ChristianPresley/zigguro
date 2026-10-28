//! git's index (`$GIT_DIR/index`, E09.F07.S03.T01): versions 2, 3 and 4,
//! SHA-1 and SHA-256, extensions, and the trailing checksum.
//!
//! Entries stay sorted by (path, stage). Optional extensions git may add
//! are kept as raw bytes and written back unchanged while no entry
//! changes; once entries change, the ones that describe entries (TREE,
//! UNTR, FSMN, EOIE, IEOT) are dropped so git rebuilds them. Required
//! extensions this reader cannot honour (`link` split index, `sdir`
//! sparse directories) fail with `error.UnsupportedIndexExtension`.
//! `write` holds `index.lock` and renames it into place.

const std = @import("std");
const oid_mod = @import("../oid.zig");
const Oid = oid_mod.Oid;
const ObjectFormat = oid_mod.ObjectFormat;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Time = struct {
    sec: u32 = 0,
    nsec: u32 = 0,

    /// From nanoseconds since the epoch (truncated to git's 32 bits).
    pub fn fromNanos(ns: i96) Time {
        const n: i128 = @max(ns, 0);
        return .{ .sec = @truncate(@as(u128, @intCast(@divTrunc(n, std.time.ns_per_s)))), .nsec = @intCast(@mod(n, std.time.ns_per_s)) };
    }

    pub fn eql(a: Time, b: Time) bool {
        return a.sec == b.sec and a.nsec == b.nsec;
    }
};

pub const Flags = struct {
    assume_valid: bool = false,
    /// 0 for a merged entry; 1 (base), 2 (ours), 3 (theirs) in a conflict.
    stage: u2 = 0,
    skip_worktree: bool = false,
    intent_to_add: bool = false,

    fn extended(f: Flags) bool {
        return f.skip_worktree or f.intent_to_add;
    }
};

pub const Entry = struct {
    ctime: Time = .{},
    mtime: Time = .{},
    dev: u32 = 0,
    ino: u32 = 0,
    mode: u32,
    uid: u32 = 0,
    gid: u32 = 0,
    size: u32 = 0,
    oid: Oid,
    flags: Flags = .{},
    /// '/'-separated, relative to the top of the working tree.
    path: []const u8,
};

pub const Extension = struct {
    sig: [4]u8,
    data: []const u8,

    /// Whether the extension describes entries (stale once they change).
    fn dependsOnEntries(x: Extension) bool {
        const deps = [_]*const [4]u8{ "TREE", "UNTR", "FSMN", "EOIE", "IEOT" };
        for (deps) |d| if (std.mem.eql(u8, &x.sig, d)) return true;
        return false;
    }
};

pub const Error = error{ CorruptIndex, UnsupportedIndexVersion, UnsupportedIndexExtension } || Allocator.Error;

/// Path then stage, the order of the entries.
pub fn order(a_path: []const u8, a_stage: u2, b_path: []const u8, b_stage: u2) std.math.Order {
    const o = std.mem.order(u8, a_path, b_path);
    if (o != .eq) return o;
    return std.math.order(a_stage, b_stage);
}

pub const Index = struct {
    arena: std.heap.ArenaAllocator,
    format: ObjectFormat,
    version: u32 = 2,
    entries: std.ArrayList(Entry) = .empty,
    extensions: std.ArrayList(Extension) = .empty,
    /// Set by edits; `serialize` then drops entry-derived extensions.
    changed: bool = false,
    /// The index file's modification time when read (racy-git checks:
    /// an entry whose mtime is not older than this must be re-hashed).
    file_mtime: ?Time = null,

    /// An empty version-2 index.
    pub fn init(gpa: Allocator, format: ObjectFormat) Index {
        return .{ .arena = .init(gpa), .format = format };
    }

    pub fn deinit(ix: *Index) void {
        ix.arena.deinit();
    }

    /// Reads `index` in `git_dir`; an empty index when there is none.
    pub fn read(gpa: Allocator, io: Io, git_dir: Io.Dir, format: ObjectFormat) !Index {
        var f = git_dir.openFile(io, "index", .{}) catch |e| switch (e) {
            error.FileNotFound => return init(gpa, format),
            else => return e,
        };
        defer f.close(io);
        const st = try f.stat(io);
        const bytes = try gpa.alloc(u8, std.math.cast(usize, st.size) orelse return error.CorruptIndex);
        defer gpa.free(bytes);
        const n = try f.readPositionalAll(io, bytes, 0);
        if (n != bytes.len) return error.CorruptIndex;
        var ix = try parse(gpa, format, bytes);
        ix.file_mtime = .fromNanos(st.mtime.nanoseconds);
        return ix;
    }

    /// Parses index bytes (verifying the checksum).
    pub fn parse(gpa: Allocator, format: ObjectFormat, bytes: []const u8) Error!Index {
        var ix = init(gpa, format);
        errdefer ix.deinit();
        const a = ix.arena.allocator();
        const hl = format.len();
        if (bytes.len < 12 + hl) return error.CorruptIndex;
        const body = bytes[0 .. bytes.len - hl];
        if (!std.mem.eql(u8, oid_mod.hashBytes(format, body).slice(), bytes[body.len..])) return error.CorruptIndex;
        if (!std.mem.eql(u8, body[0..4], "DIRC")) return error.CorruptIndex;
        ix.version = be32(body[4..8]);
        if (ix.version < 2 or ix.version > 4) return error.UnsupportedIndexVersion;
        const count = be32(body[8..12]);
        try ix.entries.ensureTotalCapacityPrecise(a, count);
        var pos: usize = 12;
        var prev: []const u8 = "";
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const start = pos;
            if (pos + 40 + hl + 2 > body.len) return error.CorruptIndex;
            var e: Entry = .{
                .ctime = .{ .sec = be32(body[pos..][0..4]), .nsec = be32(body[pos + 4 ..][0..4]) },
                .mtime = .{ .sec = be32(body[pos + 8 ..][0..4]), .nsec = be32(body[pos + 12 ..][0..4]) },
                .dev = be32(body[pos + 16 ..][0..4]),
                .ino = be32(body[pos + 20 ..][0..4]),
                .mode = be32(body[pos + 24 ..][0..4]),
                .uid = be32(body[pos + 28 ..][0..4]),
                .gid = be32(body[pos + 32 ..][0..4]),
                .size = be32(body[pos + 36 ..][0..4]),
                .oid = Oid.fromBytes(format, body[pos + 40 ..][0..hl]),
                .path = "",
            };
            pos += 40 + hl;
            const flags = be16(body[pos..][0..2]);
            pos += 2;
            e.flags.assume_valid = flags & 0x8000 != 0;
            e.flags.stage = @intCast((flags >> 12) & 3);
            if (flags & 0x4000 != 0) {
                if (ix.version < 3 or pos + 2 > body.len) return error.CorruptIndex;
                const x = be16(body[pos..][0..2]);
                pos += 2;
                e.flags.skip_worktree = x & 0x4000 != 0;
                e.flags.intent_to_add = x & 0x2000 != 0;
            }
            if (ix.version == 4) {
                const strip = try varint(body, &pos);
                if (strip > prev.len) return error.CorruptIndex;
                const nul = std.mem.indexOfScalarPos(u8, body, pos, 0) orelse return error.CorruptIndex;
                const keep = prev[0 .. prev.len - strip];
                const path = try a.alloc(u8, keep.len + nul - pos);
                @memcpy(path[0..keep.len], keep);
                @memcpy(path[keep.len..], body[pos..nul]);
                e.path = path;
                pos = nul + 1;
            } else {
                const nul = std.mem.indexOfScalarPos(u8, body, pos, 0) orelse return error.CorruptIndex;
                e.path = try a.dupe(u8, body[pos..nul]);
                // 1 to 8 NULs pad the entry to a multiple of 8.
                pos = start + ((nul - start + 8) & ~@as(usize, 7));
                if (pos > body.len) return error.CorruptIndex;
            }
            if (e.path.len == 0) return error.CorruptIndex;
            if (ix.entries.items.len > 0) {
                const last = ix.entries.items[ix.entries.items.len - 1];
                if (order(last.path, last.flags.stage, e.path, e.flags.stage) != .lt) return error.CorruptIndex;
            }
            prev = e.path;
            ix.entries.appendAssumeCapacity(e);
        }
        while (pos < body.len) {
            if (pos + 8 > body.len) return error.CorruptIndex;
            const sig = body[pos..][0..4].*;
            const size = be32(body[pos + 4 ..][0..4]);
            pos += 8;
            if (pos + size > body.len) return error.CorruptIndex;
            const data = body[pos .. pos + size];
            pos += size;
            if (sig[0] < 'A' or sig[0] > 'Z') return error.UnsupportedIndexExtension;
            // The offset tables only speed up reading.
            if (std.mem.eql(u8, &sig, "EOIE") or std.mem.eql(u8, &sig, "IEOT")) continue;
            try ix.extensions.append(a, .{ .sig = sig, .data = try a.dupe(u8, data) });
        }
        return ix;
    }

    /// The index file's bytes.
    pub fn serialize(ix: *const Index, gpa: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        const hl = ix.format.len();
        // v2 cannot hold extended flags.
        var version = ix.version;
        if (version == 2) for (ix.entries.items) |e| if (e.flags.extended()) {
            version = 3;
            break;
        };
        try out.appendSlice(gpa, "DIRC");
        try put32(&out, gpa, version);
        try put32(&out, gpa, @intCast(ix.entries.items.len));
        var prev: []const u8 = "";
        for (ix.entries.items) |e| {
            const start = out.items.len;
            for ([_]u32{ e.ctime.sec, e.ctime.nsec, e.mtime.sec, e.mtime.nsec, e.dev, e.ino, e.mode, e.uid, e.gid, e.size }) |v| try put32(&out, gpa, v);
            try out.appendSlice(gpa, e.oid.slice()[0..hl]);
            var flags: u16 = @intCast(@min(e.path.len, 0xFFF));
            flags |= @as(u16, e.flags.stage) << 12;
            if (e.flags.assume_valid) flags |= 0x8000;
            const ext = version >= 3 and e.flags.extended();
            if (ext) flags |= 0x4000;
            try put16(&out, gpa, flags);
            if (ext) {
                var x: u16 = 0;
                if (e.flags.skip_worktree) x |= 0x4000;
                if (e.flags.intent_to_add) x |= 0x2000;
                try put16(&out, gpa, x);
            }
            if (version == 4) {
                var common: usize = 0;
                while (common < prev.len and common < e.path.len and prev[common] == e.path[common]) common += 1;
                try putVarint(&out, gpa, prev.len - common);
                try out.appendSlice(gpa, e.path[common..]);
                try out.append(gpa, 0);
            } else {
                try out.appendSlice(gpa, e.path);
                const len = out.items.len - start;
                const padded = (len + 8) & ~@as(usize, 7);
                try out.appendNTimes(gpa, 0, padded - len);
            }
            prev = e.path;
        }
        for (ix.extensions.items) |x| {
            if (ix.changed and x.dependsOnEntries()) continue;
            try out.appendSlice(gpa, &x.sig);
            try put32(&out, gpa, @intCast(x.data.len));
            try out.appendSlice(gpa, x.data);
        }
        const sum = oid_mod.hashBytes(ix.format, out.items);
        try out.appendSlice(gpa, sum.slice()[0..hl]);
        return out.toOwnedSlice(gpa);
    }

    /// Writes the index under `index.lock` (fails with `error.IndexLocked`
    /// when another process holds it).
    pub fn write(ix: *const Index, gpa: Allocator, io: Io, git_dir: Io.Dir) !void {
        const bytes = try ix.serialize(gpa);
        defer gpa.free(bytes);
        var f = git_dir.createFile(io, "index.lock", .{ .exclusive = true }) catch |e| switch (e) {
            error.PathAlreadyExists => return error.IndexLocked,
            else => return e,
        };
        var ok = false;
        defer if (!ok) git_dir.deleteFile(io, "index.lock") catch {};
        {
            defer f.close(io);
            try f.writeStreamingAll(io, bytes);
        }
        try git_dir.rename("index.lock", git_dir, "index", io);
        ok = true;
    }

    /// The first position not ordered before (path, stage).
    fn lowerBound(ix: *const Index, path: []const u8, stage: u2) usize {
        var lo: usize = 0;
        var hi: usize = ix.entries.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const e = ix.entries.items[mid];
            if (order(e.path, e.flags.stage, path, stage) == .lt) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// The entry for `path` at `stage`.
    pub fn find(ix: *const Index, path: []const u8, stage: u2) ?usize {
        const i = ix.lowerBound(path, stage);
        if (i < ix.entries.items.len) {
            const e = ix.entries.items[i];
            if (e.flags.stage == stage and std.mem.eql(u8, e.path, path)) return i;
        }
        return null;
    }

    /// The entries of `path` (every stage), as a range.
    pub fn range(ix: *const Index, path: []const u8) [2]usize {
        const lo = ix.lowerBound(path, 0);
        var hi = lo;
        while (hi < ix.entries.items.len and std.mem.eql(u8, ix.entries.items[hi].path, path)) hi += 1;
        return .{ lo, hi };
    }

    /// Whether any entry lies under directory `dir` ('/'-separated, no
    /// trailing slash; "" is the top).
    pub fn hasUnder(ix: *const Index, dir: []const u8) bool {
        if (dir.len == 0) return ix.entries.items.len > 0;
        var buf: [4096]u8 = undefined;
        if (dir.len + 1 > buf.len) return false;
        @memcpy(buf[0..dir.len], dir);
        buf[dir.len] = '/';
        const prefix = buf[0 .. dir.len + 1];
        const i = ix.lowerBound(prefix, 0);
        return i < ix.entries.items.len and std.mem.startsWith(u8, ix.entries.items[i].path, prefix);
    }

    /// Sets the merged (stage 0) entry of `e.path`, replacing any
    /// conflict stages and removing entries it would collide with (a file
    /// where a directory was, or the reverse).
    pub fn add(ix: *Index, e: Entry) !void {
        const a = ix.arena.allocator();
        ix.changed = true;
        ix.removeDirectoryConflicts(e.path);
        var copy = e;
        copy.flags.stage = 0;
        copy.path = try a.dupe(u8, e.path);
        const r = ix.range(e.path);
        if (r[1] > r[0]) {
            ix.entries.items[r[0]] = copy;
            if (r[1] - r[0] > 1) ix.entries.replaceRangeAssumeCapacity(r[0] + 1, r[1] - r[0] - 1, &.{});
            return;
        }
        try ix.entries.insert(a, r[0], copy);
    }

    /// Adds one conflict stage (1, 2 or 3) of `e.path`.
    pub fn addStage(ix: *Index, e: Entry, stage: u2) !void {
        const a = ix.arena.allocator();
        ix.changed = true;
        var copy = e;
        copy.flags.stage = stage;
        copy.path = try a.dupe(u8, e.path);
        if (ix.find(e.path, 0)) |i| _ = ix.entries.orderedRemove(i);
        if (ix.find(e.path, stage)) |i| {
            ix.entries.items[i] = copy;
            return;
        }
        try ix.entries.insert(a, ix.lowerBound(e.path, stage), copy);
    }

    /// Removes every stage of `path`; false when there was none.
    pub fn remove(ix: *Index, path: []const u8) bool {
        const r = ix.range(path);
        if (r[1] == r[0]) return false;
        ix.entries.replaceRangeAssumeCapacity(r[0], r[1] - r[0], &.{});
        ix.changed = true;
        return true;
    }

    /// Removes every entry under directory `dir`; how many went.
    pub fn removeDir(ix: *Index, dir: []const u8) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < ix.entries.items.len) {
            const p = ix.entries.items[i].path;
            if (p.len > dir.len and p[dir.len] == '/' and std.mem.startsWith(u8, p, dir)) {
                _ = ix.entries.orderedRemove(i);
                n += 1;
            } else i += 1;
        }
        if (n > 0) ix.changed = true;
        return n;
    }

    fn removeDirectoryConflicts(ix: *Index, path: []const u8) void {
        // Files named like a parent directory of `path`.
        var it = std.mem.splitScalar(u8, path, '/');
        var len: usize = 0;
        while (it.next()) |part| {
            if (len + part.len >= path.len) break;
            len += part.len;
            _ = ix.remove(path[0..len]);
            len += 1;
        }
        // Entries below `path` (it was a directory).
        _ = ix.removeDir(path);
    }

    /// Whether `path` has conflict stages.
    pub fn conflicted(ix: *const Index, path: []const u8) bool {
        const r = ix.range(path);
        return r[1] > r[0] and ix.entries.items[r[0]].flags.stage != 0;
    }

    pub fn extension(ix: *const Index, sig: *const [4]u8) ?[]const u8 {
        for (ix.extensions.items) |x| if (std.mem.eql(u8, &x.sig, sig)) return x.data;
        return null;
    }
};

fn be32(b: *const [4]u8) u32 {
    return std.mem.readInt(u32, b, .big);
}

fn be16(b: *const [2]u8) u16 {
    return std.mem.readInt(u16, b, .big);
}

fn put32(out: *std.ArrayList(u8), gpa: Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    try out.appendSlice(gpa, &b);
}

fn put16(out: *std.ArrayList(u8), gpa: Allocator, v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .big);
    try out.appendSlice(gpa, &b);
}

/// git's offset varint (`decode_varint`): big-endian 7-bit groups, each
/// continuation adding one.
fn varint(b: []const u8, pos: *usize) error{CorruptIndex}!usize {
    if (pos.* >= b.len) return error.CorruptIndex;
    var c = b[pos.*];
    pos.* += 1;
    var v: usize = c & 0x7f;
    while (c & 0x80 != 0) {
        if (pos.* >= b.len or v > (std.math.maxInt(usize) >> 8)) return error.CorruptIndex;
        v += 1;
        c = b[pos.*];
        pos.* += 1;
        v = (v << 7) + (c & 0x7f);
    }
    return v;
}

fn putVarint(out: *std.ArrayList(u8), gpa: Allocator, value: usize) !void {
    var buf: [16]u8 = undefined;
    var i: usize = buf.len - 1;
    var v = value;
    buf[i] = @intCast(v & 0x7f);
    while (true) {
        v >>= 7;
        if (v == 0) break;
        v -= 1;
        i -= 1;
        buf[i] = @intCast(0x80 | (v & 0x7f));
    }
    try out.appendSlice(gpa, buf[i..]);
}

const testing = std.testing;

fn testEntry(path: []const u8, n: u8) Entry {
    var raw: [20]u8 = @splat(n);
    raw[0] = 0xab;
    return .{ .mode = 0o100644, .size = n, .mtime = .{ .sec = n, .nsec = 7 }, .oid = Oid.fromBytes(.sha1, &raw), .path = path };
}

test "index: roundtrip byte-identical for v2, v3 and v4" {
    const gpa = testing.allocator;
    for ([_]u32{ 2, 3, 4 }) |v| {
        var ix = Index.init(gpa, .sha1);
        defer ix.deinit();
        ix.version = v;
        try ix.add(testEntry("b.txt", 2));
        try ix.add(testEntry("a/deep/x.zig", 1));
        try ix.add(testEntry("a/deep/y.zig", 3));
        var e = testEntry("c", 4);
        if (v >= 3) e.flags.intent_to_add = true;
        try ix.add(e);
        ix.changed = false;
        try ix.extensions.append(ix.arena.allocator(), .{ .sig = "TREE".*, .data = "tree-bytes" });
        const bytes = try ix.serialize(gpa);
        defer gpa.free(bytes);
        var back = try Index.parse(gpa, .sha1, bytes);
        defer back.deinit();
        try testing.expectEqual(v, back.version);
        try testing.expectEqual(@as(usize, 4), back.entries.items.len);
        try testing.expectEqualStrings("a/deep/x.zig", back.entries.items[0].path);
        try testing.expectEqualStrings("c", back.entries.items[3].path);
        try testing.expectEqual(v >= 3, back.entries.items[3].flags.intent_to_add);
        try testing.expectEqualStrings("tree-bytes", back.extension("TREE").?);
        const again = try back.serialize(gpa);
        defer gpa.free(again);
        try testing.expectEqualSlices(u8, bytes, again);
    }
}

test "index: v4 prefix compression" {
    const gpa = testing.allocator;
    var ix = Index.init(gpa, .sha1);
    defer ix.deinit();
    ix.version = 4;
    try ix.add(testEntry("src/aaaaaaaaaaaaaaaa/one.zig", 1));
    try ix.add(testEntry("src/aaaaaaaaaaaaaaaa/two.zig", 2));
    const v4 = try ix.serialize(gpa);
    defer gpa.free(v4);
    ix.version = 2;
    const v2 = try ix.serialize(gpa);
    defer gpa.free(v2);
    try testing.expect(v4.len < v2.len);
    // The second path stores only "two.zig" after a strip count of 7.
    try testing.expect(std.mem.indexOf(u8, v4, "\x07two.zig\x00") != null);
    var n: usize = 0;
    for ([_]usize{ 0, 127, 128, 16511, 16512, 1 << 30 }) |val| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try putVarint(&out, gpa, val);
        n = 0;
        try testing.expectEqual(val, try varint(out.items, &n));
        try testing.expectEqual(out.items.len, n);
    }
}

test "index: corrupt, unknown optional ext kept, required ext error" {
    const gpa = testing.allocator;
    var ix = Index.init(gpa, .sha1);
    defer ix.deinit();
    try ix.add(testEntry("f", 1));
    ix.changed = false;
    try ix.extensions.append(ix.arena.allocator(), .{ .sig = "ZZZZ".*, .data = "opt" });
    try ix.extensions.append(ix.arena.allocator(), .{ .sig = "UNTR".*, .data = "cache" });
    const bytes = try ix.serialize(gpa);
    defer gpa.free(bytes);
    var back = try Index.parse(gpa, .sha1, bytes);
    defer back.deinit();
    try testing.expectEqualStrings("opt", back.extension("ZZZZ").?);
    // An edit drops the entry-derived UNTR, keeps the rest.
    try back.add(testEntry("g", 2));
    const edited = try back.serialize(gpa);
    defer gpa.free(edited);
    var e2 = try Index.parse(gpa, .sha1, edited);
    defer e2.deinit();
    try testing.expect(e2.extension("UNTR") == null);
    try testing.expect(e2.extension("ZZZZ") != null);

    const bad = try gpa.dupe(u8, bytes);
    defer gpa.free(bad);
    bad[14] ^= 1;
    try testing.expectError(error.CorruptIndex, Index.parse(gpa, .sha1, bad));

    var req = Index.init(gpa, .sha1);
    defer req.deinit();
    try req.extensions.append(req.arena.allocator(), .{ .sig = "link".*, .data = "x" });
    const rb = try req.serialize(gpa);
    defer gpa.free(rb);
    try testing.expectError(error.UnsupportedIndexExtension, Index.parse(gpa, .sha1, rb));
}

test "index: add replaces conflicts and file/directory collisions" {
    const gpa = testing.allocator;
    var ix = Index.init(gpa, .sha1);
    defer ix.deinit();
    try ix.addStage(testEntry("m", 1), 1);
    try ix.addStage(testEntry("m", 2), 2);
    try ix.addStage(testEntry("m", 3), 3);
    try testing.expect(ix.conflicted("m"));
    try ix.add(testEntry("m", 9));
    try testing.expect(!ix.conflicted("m"));
    try testing.expectEqual(@as(usize, 1), ix.entries.items.len);
    try ix.add(testEntry("d/x", 1));
    try ix.add(testEntry("d/y", 1));
    try testing.expect(ix.hasUnder("d"));
    try ix.add(testEntry("d", 1));
    try testing.expect(!ix.hasUnder("d"));
    try ix.add(testEntry("m/inner", 1));
    try testing.expect(ix.find("m", 0) == null);
    try testing.expectEqual(@as(usize, 2), ix.entries.items.len);
}

test "index: write and read back under the lock" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ix = Index.init(gpa, .sha256);
    defer ix.deinit();
    var raw: [32]u8 = @splat(5);
    try ix.add(.{ .mode = 0o100755, .oid = Oid.fromBytes(.sha256, &raw), .path = "run.sh" });
    try ix.write(gpa, io, tmp.dir);
    var back = try Index.read(gpa, io, tmp.dir, .sha256);
    defer back.deinit();
    try testing.expectEqual(@as(u32, 0o100755), back.entries.items[0].mode);
    try testing.expect(back.file_mtime != null);
    // A held lock refuses the write.
    var lock = try tmp.dir.createFile(io, "index.lock", .{});
    lock.close(io);
    try testing.expectError(error.IndexLocked, ix.write(gpa, io, tmp.dir));
    // No index file: an empty index.
    try tmp.dir.deleteFile(io, "index");
    var none = try Index.read(gpa, io, tmp.dir, .sha1);
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.entries.items.len);
}

test "index: read git's fixtures v2/v3/v4 (sha1 + sha256) and a conflict" {
    const gpa = testing.allocator;
    const io = testing.io;
    const testdata = @import("../testdata.zig");
    const cases = [_]struct { []const u8, ObjectFormat, u32 }{
        .{ "index/v2", .sha1, 2 },
        .{ "index/v3", .sha1, 3 },
        .{ "index/v4", .sha1, 4 },
        .{ "index/sha256", .sha256, 2 },
        .{ "index/conflict", .sha1, 2 },
    };
    for (cases) |c| {
        var dir = try testdata.openDir(io, c[0]);
        defer dir.close(io);
        var ix = try Index.read(gpa, io, dir, c[1]);
        defer ix.deinit();
        try testing.expectEqual(c[2], ix.version);
        const ls = try dir.readFileAlloc(io, "ls.txt", gpa, .limited(1 << 20));
        defer gpa.free(ls);
        var lines = std.mem.tokenizeScalar(u8, ls, '\n');
        var i: usize = 0;
        while (lines.next()) |line| : (i += 1) {
            const e = ix.entries.items[i];
            var buf: [256]u8 = undefined;
            var hb: [64]u8 = undefined;
            const want = try std.fmt.bufPrint(&buf, "{o} {s} {d}\t{s}", .{ e.mode, e.oid.hex(&hb), e.flags.stage, e.path });
            try testing.expectEqualStrings(line, want);
        }
        try testing.expectEqual(ix.entries.items.len, i);
        if (std.mem.eql(u8, c[0], "index/v3")) {
            const later = ix.entries.items[ix.find("later.txt", 0).?];
            try testing.expect(later.flags.intent_to_add);
        }
        if (std.mem.eql(u8, c[0], "index/conflict")) try testing.expect(ix.conflicted("f.txt"));
        // Unchanged, the writer gives back git's bytes.
        const raw = try dir.readFileAlloc(io, "index", gpa, .limited(1 << 20));
        defer gpa.free(raw);
        const again = try ix.serialize(gpa);
        defer gpa.free(again);
        try testing.expectEqualSlices(u8, raw, again);
    }
}
