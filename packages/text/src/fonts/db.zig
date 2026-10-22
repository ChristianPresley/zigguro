//! `FontDb`: what every installed face is (names, style, axes, color,
//! code point coverage), built by scanning font files on a worker and
//! kept as one immutable buffer in the persistent cache format
//! (db_cache.zig), so loading from the cache is one read and a check.
//!
//! A database is a snapshot: `rescan` builds a new one from a file
//! listing, reusing the records of files whose (path, size, mtime) did
//! not change and parsing only the rest. The owner swaps snapshots at
//! a frame start (the UI thread is the only reader) and frees the old
//! one; `generation` tells caches keyed by faces that the set changed.
//!
//! Scanning reads only the table directory, `name`, `OS/2`, `post`,
//! `head`, `hmtx` (for the monospace check), `fvar` and `cmap`, and
//! unmaps each file before the next.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ot = @import("../ot/root.zig");
const reader = @import("../ot/reader.zig");
const name_mod = @import("../ot/name.zig");
const fvar_mod = @import("../ot/var/fvar.zig");
const cache = @import("db_cache.zig");
const discovery = @import("discovery.zig");
const matcher = @import("matcher.zig");

/// An interned string.
pub const StrId = u32;
/// A face of one database snapshot (its index in `faces`).
pub const FaceRef = u32;

/// 256-code-point blocks of the inverted coverage index.
pub const block_count = 0x1100;

pub const Slant = enum(u8) { normal, italic, oblique };
pub const ColorKind = enum(u8) { none, colr, cbdt, sbix };

/// Variation axes a face has (bits of `FaceInfo.axes`).
pub const Axis = struct {
    pub const wght: u8 = 1 << 0;
    pub const wdth: u8 = 1 << 1;
    pub const ital: u8 = 1 << 2;
    pub const slnt: u8 = 1 << 3;
    pub const opsz: u8 = 1 << 4;
};

/// One face, as stored (fixed size, used in place).
pub const FaceInfo = extern struct {
    file: u32,
    coverage: u32,
    family: StrId,
    typographic_family: StrId,
    style_name: StrId,
    full_name: StrId,
    postscript: StrId,
    /// Face index in a collection.
    index: u16,
    /// OS/2 weight class at the default instance.
    weight: u16,
    /// Weight range (equal to `weight` unless the face has a wght axis).
    weight_min: u16,
    weight_max: u16,
    /// OS/2 width class 1..9 and its range (wdth axis, in classes).
    width: u8,
    width_min: u8,
    width_max: u8,
    /// `Slant` at the default instance.
    slant: u8,
    monospace: bool,
    /// `Axis` bits; non-zero means variable.
    axes: u8,
    /// `ColorKind`.
    color: u8,
    _pad: u8 = 0,

    pub fn slantOf(f: *const FaceInfo) Slant {
        return @enumFromInt(f.slant);
    }

    pub fn colorOf(f: *const FaceInfo) ColorKind {
        return @enumFromInt(f.color);
    }

    pub fn variable(f: *const FaceInfo) bool {
        return f.axes != 0;
    }
};

pub const FileRec = extern struct {
    path: StrId,
    _pad: u32 = 0,
    size: u64,
    /// Modification time, nanoseconds since the epoch.
    mtime: i64,
};

/// A name a face answers to, keyed by its ASCII-lowercased form; the
/// index is sorted by key bytes.
pub const FamilyEntry = extern struct {
    key: StrId,
    name: StrId,
    face: FaceRef,
};

pub const ScanStats = struct {
    added: u32 = 0,
    removed: u32 = 0,
    changed: u32 = 0,
    unchanged: u32 = 0,
    /// Files that could not be parsed (kept out of the database).
    failed: u32 = 0,
    ms: u64 = 0,
};

var next_generation: std.atomic.Value(u64) = .init(1);

/// The cache file name; the version is bumped with the format.
pub const cache_file = "fontdb-v1.bin";

/// Where the database cache lives: `$XDG_CACHE_HOME/zigguro/` (default
/// `~/.cache`) on Linux and other Unixes, `%LOCALAPPDATA%\zigguro\cache\`
/// on Windows. Null when the environment names no such directory.
pub fn defaultCachePath(arena: Allocator, env: *const std.process.Environ.Map, os: std.Target.Os.Tag) Allocator.Error!?[]const u8 {
    if (os == .windows) {
        const base = env.get("LOCALAPPDATA") orelse return null;
        return try std.mem.concat(arena, u8, &.{ std.mem.trimEnd(u8, base, "\\"), "\\zigguro\\cache\\", cache_file });
    }
    if (env.get("XDG_CACHE_HOME")) |x| if (x.len > 0) return try std.mem.concat(arena, u8, &.{ std.mem.trimEnd(u8, x, "/"), "/zigguro/", cache_file });
    const home = env.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return try std.mem.concat(arena, u8, &.{ std.mem.trimEnd(u8, home, "/"), "/.cache/zigguro/", cache_file });
}

pub const FontDb = struct {
    /// The buffer every section points into (empty for an empty db).
    buf: []align(8) const u8 = &.{},
    s: cache.Sections = .{},
    /// Distinct per snapshot.
    generation: u64 = 0,

    /// A database with no faces.
    pub const empty: FontDb = .{};

    /// Frees the buffer.
    pub fn deinit(d: *FontDb, gpa: Allocator) void {
        if (d.buf.len > 0) gpa.free(d.buf);
        d.* = undefined;
    }

    /// Takes ownership of `buf` (freed on error).
    pub fn fromBytes(gpa: Allocator, buf: []align(8) u8) cache.Error!FontDb {
        errdefer gpa.free(buf);
        return .{ .buf = buf, .s = try cache.parse(buf), .generation = next_generation.fetchAdd(1, .monotonic) };
    }

    /// The cached database at `path`, or an empty one when the file is
    /// missing, unreadable, corrupt or of another version.
    pub fn load(gpa: Allocator, io: Io, cache_path: []const u8) Allocator.Error!FontDb {
        const buf = Io.Dir.cwd().readFileAllocOptions(io, cache_path, gpa, .limited(1 << 30), .@"8", null) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .empty,
        };
        return fromBytes(gpa, buf) catch .empty;
    }

    /// Writes the database to `path` atomically (a temporary file, then
    /// a rename), creating the parent directory.
    pub fn save(d: *const FontDb, gpa: Allocator, io: Io, cache_path: []const u8) !void {
        const owned: ?[]align(8) u8 = if (d.buf.len == 0) try cache.serialize(gpa, &d.s) else null;
        defer if (owned) |o| gpa.free(o);
        const bytes = owned orelse d.buf;
        const cwd = Io.Dir.cwd();
        if (std.fs.path.dirname(cache_path)) |dir| try cwd.createDirPath(io, dir);
        const tmp = try std.mem.concat(gpa, u8, &.{ cache_path, ".tmp" });
        defer gpa.free(tmp);
        try cwd.writeFile(io, .{ .sub_path = tmp, .data = bytes });
        errdefer cwd.deleteFile(io, tmp) catch {};
        try Io.Dir.rename(cwd, tmp, cwd, cache_path, io);
    }

    pub fn str(d: *const FontDb, id: StrId) []const u8 {
        const so = d.s.str_offs[id];
        return d.s.strings[so[0]..][0..so[1]];
    }

    pub fn faces(d: *const FontDb) []const FaceInfo {
        return d.s.faces;
    }

    pub fn face(d: *const FontDb, f: FaceRef) *const FaceInfo {
        return &d.s.faces[f];
    }

    pub fn files(d: *const FontDb) []const FileRec {
        return d.s.files;
    }

    /// The file `f` lives in.
    pub fn path(d: *const FontDb, f: FaceRef) []const u8 {
        return d.str(d.s.files[d.s.faces[f].file].path);
    }

    /// The (first, last) code point ranges `f` maps, ascending.
    pub fn coverage(d: *const FontDb, f: FaceRef) []const [2]u32 {
        const c = d.s.coverages[d.s.faces[f].coverage];
        return d.s.ranges[c[0]..][0..c[1]];
    }

    /// True when face `f` maps `cp`.
    pub fn covers(d: *const FontDb, f: FaceRef, cp: u21) bool {
        const rs = d.coverage(f);
        var lo: usize = 0;
        var hi: usize = rs.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (rs[mid][1] < cp) lo = mid + 1 else hi = mid;
        }
        return lo < rs.len and rs[lo][0] <= cp;
    }

    /// The faces mapping `cp`, through the block index.
    pub fn coveringFaces(d: *const FontDb, cp: u21) CoveringIterator {
        if (d.s.block_offs.len == 0) return .{ .db = d, .cp = cp, .list = &.{} };
        const b = @min(cp >> 8, block_count - 1);
        return .{ .db = d, .cp = cp, .list = d.s.block_faces[d.s.block_offs[b]..d.s.block_offs[b + 1]] };
    }

    pub const CoveringIterator = struct {
        db: *const FontDb,
        cp: u21,
        list: []const u32,
        i: usize = 0,

        pub fn next(it: *CoveringIterator) ?FaceRef {
            while (it.i < it.list.len) {
                const f = it.list[it.i];
                it.i += 1;
                if (it.db.covers(f, it.cp)) return f;
            }
            return null;
        }
    };

    /// Index entries whose name equals `name` (ASCII case-insensitive;
    /// typographic, legacy, full and localized names all count).
    pub fn named(d: *const FontDb, name: []const u8) []const FamilyEntry {
        const fam = d.s.families;
        var lo: usize = 0;
        var hi: usize = fam.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (cmpLower(d.str(fam[mid].key), name) == .lt) lo = mid + 1 else hi = mid;
        }
        var end = lo;
        while (end < fam.len and cmpLower(d.str(fam[end].key), name) == .eq) end += 1;
        return fam[lo..end];
    }

    /// Distinct family names (the typographic family of each face),
    /// sorted case-insensitively.
    pub fn families(d: *const FontDb, arena: Allocator) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (d.s.faces) |f| try out.append(arena, d.str(f.typographic_family));
        std.mem.sort([]const u8, out.items, {}, lessLower);
        var n: usize = 0;
        for (out.items) |s| {
            if (n > 0 and std.ascii.eqlIgnoreCase(out.items[n - 1], s)) continue;
            out.items[n] = s;
            n += 1;
        }
        return out.items[0..n];
    }

    /// CSS Fonts 4 §5.2 matching within the named family (see
    /// matcher.zig, which also resolves generic families).
    pub fn match(d: *const FontDb, q: matcher.Query) ?matcher.Match {
        return matcher.matchFamily(d, q);
    }

    /// A new snapshot for `listing`: unchanged files keep their records,
    /// new and changed files are parsed. Runs on a worker.
    pub fn rescan(d: *const FontDb, gpa: Allocator, io: Io, listing: []const discovery.FileEntry, stats: *ScanStats) !FontDb {
        const t0 = Io.Clock.awake.now(io);
        var b: Builder = .init(gpa);
        defer b.deinit();
        var old: std.StringHashMapUnmanaged(u32) = .empty;
        defer old.deinit(gpa);
        for (d.s.files, 0..) |f, i| try old.put(gpa, d.str(f.path), @intCast(i));
        // Faces of each old file, in order.
        var by_file: std.ArrayList(std.ArrayList(FaceRef)) = .empty;
        defer {
            for (by_file.items) |*l| l.deinit(gpa);
            by_file.deinit(gpa);
        }
        try by_file.appendNTimes(gpa, .empty, d.s.files.len);
        for (d.s.faces, 0..) |f, i| try by_file.items[f.file].append(gpa, @intCast(i));
        // Names of each old face.
        var names: std.ArrayList(std.ArrayList([]const u8)) = .empty;
        defer {
            for (names.items) |*l| l.deinit(gpa);
            names.deinit(gpa);
        }
        try names.appendNTimes(gpa, .empty, d.s.faces.len);
        for (d.s.families) |e| try names.items[e.face].append(gpa, d.str(e.name));
        var kept: usize = 0;
        for (listing) |e| {
            const mtime: i64 = @truncate(e.mtime.nanoseconds);
            if (old.get(e.path)) |fi| {
                const rec = d.s.files[fi];
                if (rec.size == e.size and rec.mtime == mtime) {
                    kept += 1;
                    stats.unchanged += 1;
                    const nf = try b.addFile(e.path, e.size, mtime);
                    for (by_file.items[fi].items) |f| try b.copyFace(d, f, nf, names.items[f].items);
                    continue;
                }
                kept += 1;
                stats.changed += 1;
            } else stats.added += 1;
            b.scanFile(io, e.path, e.size, mtime) catch {
                stats.failed += 1;
                continue;
            };
        }
        stats.removed += @intCast(d.s.files.len -| kept);
        const out = try b.finish();
        stats.ms = @intCast(@divTrunc(t0.durationTo(Io.Clock.awake.now(io)).nanoseconds, std.time.ns_per_ms));
        return out;
    }
};

fn lowerByte(c: u8) u8 {
    return std.ascii.toLower(c);
}

fn cmpLower(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        const o = std.math.order(lowerByte(x), lowerByte(y));
        if (o != .eq) return o;
    }
    return std.math.order(a.len, b.len);
}

fn lessLower(_: void, a: []const u8, b: []const u8) bool {
    return cmpLower(a, b) == .lt;
}

/// What `Builder.addFace` needs besides strings.
pub const FaceDesc = struct {
    index: u16 = 0,
    family: []const u8,
    typographic_family: ?[]const u8 = null,
    style_name: []const u8 = "Regular",
    full_name: ?[]const u8 = null,
    postscript: []const u8 = "",
    /// Extra names (localized families) the face answers to.
    aliases: []const []const u8 = &.{},
    weight: u16 = 400,
    weight_range: ?[2]u16 = null,
    width: u8 = 5,
    width_range: ?[2]u8 = null,
    slant: Slant = .normal,
    monospace: bool = false,
    axes: u8 = 0,
    color: ColorKind = .none,
    coverage: []const [2]u32,
};

/// Accumulates files and faces, then produces a `FontDb`.
pub const Builder = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    strings: std.ArrayList(u8) = .empty,
    str_offs: std.ArrayList([2]u32) = .empty,
    str_map: std.StringHashMapUnmanaged(StrId) = .empty,
    files: std.ArrayList(FileRec) = .empty,
    faces: std.ArrayList(FaceInfo) = .empty,
    ranges: std.ArrayList([2]u32) = .empty,
    coverages: std.ArrayList([2]u32) = .empty,
    cov_map: std.AutoHashMapUnmanaged(u64, std.ArrayList(u32)) = .empty,
    families: std.ArrayList(FamilyEntry) = .empty,

    pub fn init(gpa: Allocator) Builder {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(b: *Builder) void {
        const gpa = b.gpa;
        b.strings.deinit(gpa);
        b.str_offs.deinit(gpa);
        b.str_map.deinit(gpa);
        b.files.deinit(gpa);
        b.faces.deinit(gpa);
        b.ranges.deinit(gpa);
        b.coverages.deinit(gpa);
        var it = b.cov_map.valueIterator();
        while (it.next()) |l| l.deinit(gpa);
        b.cov_map.deinit(gpa);
        b.families.deinit(gpa);
        b.arena.deinit();
        b.* = undefined;
    }

    pub fn intern(b: *Builder, s: []const u8) Allocator.Error!StrId {
        if (b.str_map.get(s)) |id| return id;
        const id: StrId = @intCast(b.str_offs.items.len);
        try b.str_offs.append(b.gpa, .{ @intCast(b.strings.items.len), @intCast(s.len) });
        try b.strings.appendSlice(b.gpa, s);
        try b.str_map.put(b.gpa, try b.arena.allocator().dupe(u8, s), id);
        return id;
    }

    /// Lowercase key of `s`, interned.
    fn internKey(b: *Builder, s: []const u8) Allocator.Error!StrId {
        var buf: [256]u8 = undefined;
        const n = @min(s.len, buf.len);
        for (s[0..n], buf[0..n]) |c, *o| o.* = lowerByte(c);
        return b.intern(buf[0..n]);
    }

    pub fn addFile(b: *Builder, p: []const u8, size: u64, mtime: i64) Allocator.Error!u32 {
        try b.files.append(b.gpa, .{ .path = try b.intern(p), .size = size, .mtime = mtime });
        return @intCast(b.files.items.len - 1);
    }

    /// Interns a coverage set (shared by faces with the same ranges).
    fn internCoverage(b: *Builder, rs: []const [2]u32) Allocator.Error!u32 {
        const h = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(rs));
        const gop = try b.cov_map.getOrPut(b.gpa, h);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (gop.value_ptr.items) |id| {
            const c = b.coverages.items[id];
            if (std.mem.eql([2]u32, b.ranges.items[c[0]..][0..c[1]], rs)) return id;
        }
        const id: u32 = @intCast(b.coverages.items.len);
        try b.coverages.append(b.gpa, .{ @intCast(b.ranges.items.len), @intCast(rs.len) });
        try b.ranges.appendSlice(b.gpa, rs);
        try gop.value_ptr.append(b.gpa, id);
        return id;
    }

    pub fn addFace(b: *Builder, file: u32, fd: FaceDesc) Allocator.Error!void {
        const fam = try b.intern(fd.family);
        const typo = if (fd.typographic_family) |t| try b.intern(t) else fam;
        const full = if (fd.full_name) |n| try b.intern(n) else fam;
        const ref: FaceRef = @intCast(b.faces.items.len);
        const wr = fd.weight_range orelse .{ fd.weight, fd.weight };
        const dr = fd.width_range orelse .{ fd.width, fd.width };
        try b.faces.append(b.gpa, .{
            .file = file,
            .coverage = try b.internCoverage(fd.coverage),
            .family = fam,
            .typographic_family = typo,
            .style_name = try b.intern(fd.style_name),
            .full_name = full,
            .postscript = try b.intern(fd.postscript),
            .index = fd.index,
            .weight = fd.weight,
            .weight_min = wr[0],
            .weight_max = wr[1],
            .width = fd.width,
            .width_min = dr[0],
            .width_max = dr[1],
            .slant = @intFromEnum(fd.slant),
            .monospace = fd.monospace,
            .axes = fd.axes,
            .color = @intFromEnum(fd.color),
        });
        // Every distinct name, once per face.
        const start = b.families.items.len;
        const all = [_][]const u8{ b.strAt(typo), b.strAt(fam), b.strAt(full) };
        for (&all) |n| try b.addName(start, n, ref);
        for (fd.aliases) |n| try b.addName(start, n, ref);
    }

    fn addName(b: *Builder, start: usize, n: []const u8, ref: FaceRef) Allocator.Error!void {
        if (n.len == 0) return;
        const key = try b.internKey(n);
        for (b.families.items[start..]) |e| if (e.key == key) return;
        try b.families.append(b.gpa, .{ .key = key, .name = try b.intern(n), .face = ref });
    }

    fn strAt(b: *const Builder, id: StrId) []const u8 {
        const so = b.str_offs.items[id];
        return b.strings.items[so[0]..][0..so[1]];
    }

    /// Copies face `f` of `old` into file `file`; `aliases` are the
    /// names the face answers to in `old`.
    pub fn copyFace(b: *Builder, old: *const FontDb, f: FaceRef, file: u32, aliases: []const []const u8) Allocator.Error!void {
        const o = old.face(f);
        try b.addFace(file, .{
            .index = o.index,
            .family = old.str(o.family),
            .typographic_family = old.str(o.typographic_family),
            .style_name = old.str(o.style_name),
            .full_name = old.str(o.full_name),
            .postscript = old.str(o.postscript),
            .aliases = aliases,
            .weight = o.weight,
            .weight_range = .{ o.weight_min, o.weight_max },
            .width = o.width,
            .width_range = .{ o.width_min, o.width_max },
            .slant = o.slantOf(),
            .monospace = o.monospace,
            .axes = o.axes,
            .color = o.colorOf(),
            .coverage = old.coverage(f),
        });
    }

    /// Parses every face of the font file at `p`.
    pub fn scanFile(b: *Builder, io: Io, p: []const u8, size: u64, mtime: i64) !void {
        var mf = try ot.MappedFont.openAlloc(io, Io.Dir.cwd(), p, b.gpa);
        defer mf.close(io);
        const bytes = mf.bytes();
        const n = try ot.Face.faceCount(bytes);
        // Parse first so a broken file adds nothing.
        var descs: std.ArrayList(FaceDesc) = .empty;
        defer descs.deinit(b.gpa);
        var tmp: std.heap.ArenaAllocator = .init(b.gpa);
        defer tmp.deinit();
        for (0..@min(n, 256)) |i| {
            const fc = ot.Face.init(bytes, @intCast(i)) catch continue;
            try descs.append(b.gpa, try describe(tmp.allocator(), &fc, @intCast(i)));
        }
        if (descs.items.len == 0) return error.Malformed;
        const file = try b.addFile(p, size, mtime);
        for (descs.items) |fd| try b.addFace(file, fd);
    }

    /// The finished snapshot (the builder can be reused or freed).
    pub fn finish(b: *Builder) Allocator.Error!FontDb {
        const gpa = b.gpa;
        // Block index: count, prefix sums, fill.
        const offs = try gpa.alloc(u32, block_count + 1);
        defer gpa.free(offs);
        @memset(offs, 0);
        const last = try gpa.alloc(u32, block_count);
        defer gpa.free(last);
        @memset(last, std.math.maxInt(u32));
        for (b.faces.items, 0..) |f, fi| forBlocks(b, f, @intCast(fi), last, offs, null);
        var total: u32 = 0;
        for (offs[0..block_count]) |*o| {
            const c = o.*;
            o.* = total;
            total += c;
        }
        offs[block_count] = total;
        const list = try gpa.alloc(u32, total);
        defer gpa.free(list);
        const cursor = try gpa.dupe(u32, offs[0..block_count]);
        defer gpa.free(cursor);
        @memset(last, std.math.maxInt(u32));
        for (b.faces.items, 0..) |f, fi| forBlocks(b, f, @intCast(fi), last, cursor, list);

        const Ctx = struct {
            b: *const Builder,
            fn less(c: @This(), x: FamilyEntry, y: FamilyEntry) bool {
                return switch (std.mem.order(u8, c.b.strAt(x.key), c.b.strAt(y.key))) {
                    .lt => true,
                    .gt => false,
                    .eq => x.face < y.face,
                };
            }
        };
        std.mem.sort(FamilyEntry, b.families.items, Ctx{ .b = b }, Ctx.less);
        const s: cache.Sections = .{
            .strings = b.strings.items,
            .str_offs = b.str_offs.items,
            .files = b.files.items,
            .faces = b.faces.items,
            .ranges = b.ranges.items,
            .coverages = b.coverages.items,
            .block_offs = offs,
            .block_faces = list,
            .families = b.families.items,
        };
        const buf = try cache.serialize(gpa, &s);
        return FontDb.fromBytes(gpa, buf) catch unreachable;
    }

    /// Visits each block face `fi` covers once: counts into `counts`
    /// (when `out` is null) or writes `fi` at `counts[block]++`.
    fn forBlocks(b: *const Builder, f: FaceInfo, fi: u32, last: []u32, counts: []u32, out: ?[]u32) void {
        const c = b.coverages.items[f.coverage];
        for (b.ranges.items[c[0]..][0..c[1]]) |r| {
            var blk = r[0] >> 8;
            while (blk <= @min(r[1] >> 8, block_count - 1)) : (blk += 1) {
                if (last[blk] == fi) continue;
                last[blk] = fi;
                if (out) |o| {
                    o[counts[blk]] = fi;
                    counts[blk] += 1;
                } else counts[blk] += 1;
            }
        }
    }
};

/// The database description of one face (strings in `arena`).
pub fn describe(arena: Allocator, f: *const ot.Face, index: u16) Allocator.Error!FaceDesc {
    var buf: [512]u8 = undefined;
    const names = f.names();
    const dupe = struct {
        fn d(a: Allocator, s: ?[]const u8) Allocator.Error!?[]const u8 {
            return if (s) |v| try a.dupe(u8, v) else null;
        }
    }.d;
    const legacy = try dupe(arena, names.get(.family, &buf));
    const typo = try dupe(arena, names.get(.typographic_family, &buf));
    const sub = (try dupe(arena, names.get(.typographic_subfamily, &buf))) orelse (try dupe(arena, names.get(.subfamily, &buf)));
    const full = try dupe(arena, names.get(.full, &buf));
    const ps = try dupe(arena, names.get(.postscript, &buf));
    const family = legacy orelse typo orelse ps orelse "";
    const st = f.style();
    var fd: FaceDesc = .{
        .index = index,
        .family = family,
        .typographic_family = typo orelse family,
        .style_name = sub orelse "Regular",
        .full_name = full,
        .postscript = ps orelse "",
        .aliases = try localizedNames(arena, names),
        .weight = @max(1, @min(st.weight, 1000)),
        .width = @intCast(@max(1, @min(st.width, 9))),
        .slant = if (st.italic) .italic else if (st.oblique) .oblique else .normal,
        .monospace = st.monospace,
        .color = if (f.knownTable(.colr) != null) .colr else if (f.knownTable(.cbdt) != null) .cbdt else if (f.knownTable(.sbix) != null) .sbix else .none,
        .coverage = &.{},
    };
    if (ot.variation.instance.fvarOf(f)) |fv| {
        for (0..fv.axis_count) |i| {
            const a = fv.axis(i);
            if (a.tag == ot.tag("wght")) {
                fd.axes |= Axis.wght;
                fd.weight_range = .{ clampWeight(a.min), clampWeight(a.max) };
            } else if (a.tag == ot.tag("wdth")) {
                fd.axes |= Axis.wdth;
                fd.width_range = .{ widthClass(a.min), widthClass(a.max) };
            } else if (a.tag == ot.tag("ital")) {
                fd.axes |= Axis.ital;
            } else if (a.tag == ot.tag("slnt")) {
                fd.axes |= Axis.slnt;
            } else if (a.tag == ot.tag("opsz")) {
                fd.axes |= Axis.opsz;
            }
        }
    }
    if (f.cmap) |cm| {
        const cov = try cm.coverage(arena);
        const rs = try arena.alloc([2]u32, cov.ranges.len);
        for (cov.ranges, rs) |r, *o| o.* = .{ r[0], r[1] };
        fd.coverage = rs;
    }
    return fd;
}

fn clampWeight(v: f32) u16 {
    return @intFromFloat(@max(1, @min(1000, @round(v))));
}

/// CSS width percentages of the OS/2 width classes 1..9.
pub const width_percent = [9]f32{ 50, 62.5, 75, 87.5, 100, 112.5, 125, 150, 200 };

/// The width class nearest `pct`.
pub fn widthClass(pct: f32) u8 {
    var best: u8 = 1;
    for (width_percent, 1..) |p, c| if (@abs(p - pct) < @abs(width_percent[best - 1] - pct)) {
        best = @intCast(c);
    };
    return best;
}

/// Family and full names in every language (records 1, 4 and 16 of all
/// platforms), decoded.
fn localizedNames(arena: Allocator, names: ot.NameTable) Allocator.Error![]const []const u8 {
    const data = names.data;
    const count = reader.readAt(u16, data, 2) catch return &.{};
    const storage = reader.readAt(u16, data, 4) catch return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var buf: [512]u8 = undefined;
    for (0..count) |i| {
        const off = 6 + i * 12;
        const pid = reader.readAt(u16, data, off) catch break;
        const nid = reader.readAt(u16, data, off + 6) catch break;
        const len = reader.readAt(u16, data, off + 8) catch break;
        const soff = reader.readAt(u16, data, off + 10) catch break;
        if (nid != 1 and nid != 4 and nid != 16) continue;
        if (pid != 0 and pid != 1 and pid != 3) continue;
        const bytes = reader.subLen(data, @as(usize, storage) + soff, len) catch continue;
        const s = name_mod.decode(pid, bytes, &buf);
        if (s.len == 0) continue;
        for (out.items) |o| {
            if (std.mem.eql(u8, o, s)) break;
        } else try out.append(arena, try arena.dupe(u8, s));
    }
    return out.items;
}
