//! Directory tree generation (E14.F06.S01.T01). Directories attach to a
//! parent chosen with probability proportional to its child count plus
//! one (preferential attachment), and files to a directory proportional
//! to its file count plus one, which gives the Zipf-like fan-out of real
//! trees: a few directories with over 1 000 entries, many with a handful.
//! Extensions are dealt from exact quotas, then shuffled.

const std = @import("std");
const profiles = @import("profiles.zig");
const names = @import("names.zig");

pub const Entry = struct {
    path: []const u8,
    /// Planned size (0 when the shape has no size table).
    size: u64,
};

pub const Tree = struct {
    /// Sorted by path, `/`-separated.
    files: []Entry,
    /// Every directory, sorted.
    dirs: [][]const u8,
    max_depth: u8,
};

const Dir = struct { path: []const u8, depth: u8, test_data: bool };

/// Generates `shape` scaled by `scale_ppm` into `arena`.
pub fn build(arena: std.mem.Allocator, r: std.Random, shape: profiles.TreeShape, scale_ppm: u32) !Tree {
    const n_files = profiles.scaled(shape.files, scale_ppm, 1);
    const n_dirs = profiles.scaled(shape.dirs, scale_ppm, shape.top.len);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var dirs: std.ArrayList(Dir) = .empty;
    var pool: std.ArrayList(u32) = .empty;
    try dirs.ensureTotalCapacity(arena, n_dirs);
    for (shape.top) |t| {
        try seen.put(arena, t, {});
        const idx: u32 = @intCast(dirs.items.len);
        try dirs.append(arena, .{ .path = t, .depth = 1, .test_data = false });
        try pool.append(arena, idx);
        for (shape.heavy_top) |h| if (std.mem.eql(u8, h, t)) for (0..8) |_| try pool.append(arena, idx);
    }
    var name: std.ArrayList(u8) = .empty;
    while (dirs.items.len < n_dirs) {
        var parent = pool.items[names.pick(r, pool.items.len)];
        var tries: u32 = 0;
        while (dirs.items[parent].depth >= shape.max_depth and tries < 16) : (tries += 1)
            parent = pool.items[names.pick(r, pool.items.len)];
        if (dirs.items[parent].depth >= shape.max_depth) parent = r.uintLessThan(u32, @intCast(shape.top.len));
        const p = dirs.items[parent];
        name.clearRetainingCapacity();
        const td = shape.test_data_permille > 0 and r.uintLessThan(u16, 1000) < shape.test_data_permille;
        if (td) {
            try name.appendSlice(arena, if (r.boolean()) "test_data" else "testdata");
        } else if (shape.long_name_permille > 0 and r.uintLessThan(u16, 1000) < shape.long_name_permille) {
            try names.longName(r, &name, arena, 40, 120);
        } else try names.identifier(r, &name, arena, shape.name_parts[0], shape.name_parts[1], '_');
        const path = try unique(arena, &seen, p.path, name.items, "");
        const idx: u32 = @intCast(dirs.items.len);
        try dirs.append(arena, .{ .path = path, .depth = p.depth + 1, .test_data = td or p.test_data });
        try pool.append(arena, parent);
        try pool.append(arena, idx);
    }

    // Files: dirs attract files in proportion to the files they have.
    var fpool: std.ArrayList(u32) = .empty;
    try fpool.ensureTotalCapacity(arena, dirs.items.len + n_files);
    for (dirs.items, 0..) |d, i| {
        fpool.appendAssumeCapacity(@intCast(i));
        if (d.test_data) for (0..4) |_| try fpool.append(arena, @intCast(i));
    }
    // Exact extension quotas, shuffled.
    const exts = try arena.alloc(u8, n_files);
    var at: usize = 0;
    for (shape.exts, 0..) |e, i| {
        const n = if (i + 1 == shape.exts.len) n_files - at else @min(n_files - at, (n_files * e.permille + 500) / 1000);
        @memset(exts[at..][0..n], @intCast(i));
        at += n;
    }
    // Fisher-Yates with u64 draws (std's shuffle draws usize).
    var k: usize = exts.len;
    while (k > 1) : (k -= 1) std.mem.swap(u8, &exts[k - 1], &exts[names.pick(r, k)]);

    var files = try arena.alloc(Entry, n_files);
    var max_depth: u8 = 0;
    for (0..n_files) |i| {
        const di = fpool.items[names.pick(r, fpool.items.len)];
        try fpool.append(arena, di);
        const d = dirs.items[di];
        max_depth = @max(max_depth, d.depth);
        const e = shape.exts[exts[i]];
        name.clearRetainingCapacity();
        if (e.whole) {
            try name.appendSlice(arena, e.name);
        } else if (shape.long_name_permille > 0 and r.uintLessThan(u16, 1000) < shape.long_name_permille) {
            try names.longName(r, &name, arena, 40, 110);
        } else try names.identifier(r, &name, arena, shape.name_parts[0], shape.name_parts[1], '_');
        const path = try unique(arena, &seen, d.path, name.items, if (e.whole) "" else e.name);
        const size: u64 = if (shape.sizes) |s| profiles.pickBucket(u32, r, s) else 0;
        files[i] = .{ .path = path, .size = size };
    }
    std.mem.sort(Entry, files, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);
    const dir_paths = try arena.alloc([]const u8, dirs.items.len);
    for (dirs.items, dir_paths) |d, *o| o.* = d.path;
    std.mem.sort([]const u8, dir_paths, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return .{ .files = files, .dirs = dir_paths, .max_depth = max_depth };
}

/// `parent/name ext`, made unique with `_2`, `_3`... before the extension.
fn unique(arena: std.mem.Allocator, seen: *std.StringHashMapUnmanaged(void), parent: []const u8, name: []const u8, ext: []const u8) ![]const u8 {
    var n: u32 = 1;
    while (true) : (n += 1) {
        const path = if (n == 1)
            try std.fmt.allocPrint(arena, "{s}/{s}{s}", .{ parent, name, ext })
        else
            try std.fmt.allocPrint(arena, "{s}/{s}_{d}{s}", .{ parent, name, n, ext });
        const gop = try seen.getOrPut(arena, path);
        if (!gop.found_existing) return path;
    }
}

test "corpusgen tree: sorted, unique, shaped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(1);
    const t = try build(arena.allocator(), prng.random(), profiles.linux, 10_000);
    try std.testing.expectEqual(@as(usize, 1081), t.files.len);
    for (t.files[1..], t.files[0 .. t.files.len - 1]) |b, a| try std.testing.expect(std.mem.lessThan(u8, a.path, b.path));
    try std.testing.expect(t.max_depth <= 9);
}
