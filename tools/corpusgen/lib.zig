//! zg_corpus (E14.F06.S01.T01): deterministic synthetic corpora for
//! benchmarks, from a profile, a seed and the generator `version`, with
//! std only. Corpora live in a cache folder and are never committed or
//! downloaded. docs/perf/benchmarks.md ("Corpora") describes the shapes.
//!
//! ```zig
//! const path = try zg_corpus.ensure(gpa, io, .{ .profile = .lines_100k }, cache_root);
//! ```

const std = @import("std");
pub const profiles = @import("profiles.zig");
pub const names = @import("names.zig");
pub const content = @import("content.zig");
pub const tree = @import("tree.zig");

/// Bump on ANY output change: baselines record the corpus version.
pub const version: u32 = 1;

pub const Profile = profiles.Profile;

pub const Materialize = enum {
    /// `paths.txt` and `paths.bin` only.
    paths_only,
    /// Real files.
    tree,
    /// Files of the right size with no content, for scans that only stat.
    tree_sparse,
};

pub const Spec = struct {
    profile: Profile,
    seed: u64 = 0x5A16_0001,
    materialize: Materialize = .tree,
    /// Size scale in parts per million (tests use 10 000, 1 %).
    scale_ppm: u32 = 1_000_000,

    /// The profile's default: paths only for chromium and huge.
    pub fn default(p: Profile) Spec {
        return .{ .profile = p, .materialize = if (profiles.defaultsToTree(p)) .tree else .paths_only };
    }
};

pub const Manifest = struct {
    version: u32,
    profile: Profile,
    seed: u64,
    scale_ppm: u32,
    materialize: Materialize,
    files: u64,
    dirs: u64,
    bytes: u64,
    lines: u64,
    /// Blake3 over the paths digest and every file's digest, in path
    /// order (the paths digest alone for `paths_only`).
    digest: [32]u8,
    /// Blake3 of `paths.txt`.
    paths_digest: [32]u8,
};

/// MANIFEST.json's shape.
const ManifestJson = struct {
    version: u32,
    profile: []const u8,
    seed: u64,
    scale_ppm: u32,
    materialize: []const u8,
    files: u64,
    dirs: u64,
    bytes: u64,
    lines: u64,
    digest: []const u8,
    paths_digest: []const u8,
};

const Kind = enum { source_tabs, source_spaces, binary, lines, log, minified, note, unicode };

const PlanFile = struct { path: []const u8, size: u64, kind: Kind, note: u32 = 0 };

const Plan = struct {
    files: []PlanFile,
    dirs: []const []const u8,
    /// Per note: its title and link targets.
    notes: []const NotePlan = &.{},
    max_depth: u8 = 0,
};

const NotePlan = struct { title: []const u8, links: []const []const u8 };

fn profileSeed(spec: Spec) u64 {
    return spec.seed ^ std.hash.Wyhash.hash(0, @tagName(spec.profile));
}

fn kindForPath(path: []const u8) Kind {
    const base = std.fs.path.basenamePosix(path);
    if (std.mem.eql(u8, base, "Makefile") or std.mem.eql(u8, base, "Kconfig")) return .source_tabs;
    const ext = std.fs.path.extension(base);
    for ([_][]const u8{ ".c", ".h", ".S", ".dts" }) |e| if (std.mem.eql(u8, ext, e)) return .source_tabs;
    if (std.mem.eql(u8, ext, ".png")) return .binary;
    return .source_spaces;
}

fn single(arena: std.mem.Allocator, path: []const u8, size: u64, kind: Kind) !Plan {
    const files = try arena.alloc(PlanFile, 1);
    files[0] = .{ .path = path, .size = size, .kind = kind };
    return .{ .files = files, .dirs = &.{} };
}

fn makePlan(arena: std.mem.Allocator, spec: Spec) !Plan {
    var prng: std.Random.DefaultPrng = .init(profileSeed(spec));
    const r = prng.random();
    const s = spec.scale_ppm;
    if (profiles.tree(spec.profile)) |shape| {
        const t = try tree.build(arena, r, shape, s);
        const files = try arena.alloc(PlanFile, t.files.len);
        for (t.files, files) |e, *f| f.* = .{ .path = e.path, .size = e.size, .kind = kindForPath(e.path) };
        return .{ .files = files, .dirs = t.dirs, .max_depth = t.max_depth };
    }
    return switch (spec.profile) {
        .lines_100k => single(arena, "lines_100k.zig", profiles.scaled(profiles.lines_100k_lines, s, 1), .lines),
        .bigfile_1g => single(arena, "big.log", profiles.scaled(profiles.bigfile_bytes, s, 1), .log),
        .minified_50m => single(arena, "min.json", profiles.scaled(profiles.minified_bytes, s, 2), .minified),
        .mixed_unicode_10m => single(arena, "unicode.txt", profiles.scaled(profiles.unicode_bytes, s, 64), .unicode),
        .notes_10k => notesPlan(arena, r, profiles.scaled(profiles.notes_count, s, 2)),
        else => unreachable,
    };
}

const note_folders = [_][]const u8{ "daily", "projects", "people", "ideas", "reference", "meetings", "archive", "inbox" };

/// Notes whose links pick targets by preferential attachment (a
/// power-law in-degree); 2 % of links point at notes that do not exist.
fn notesPlan(arena: std.mem.Allocator, r: std.Random, n: u64) !Plan {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    const titles = try arena.alloc([]const u8, n);
    var name: std.ArrayList(u8) = .empty;
    for (titles) |*t| {
        var k: u32 = 1;
        while (true) : (k += 1) {
            name.clearRetainingCapacity();
            try names.identifier(r, &name, arena, 2, 3, '-');
            if (k > 1) try name.print(arena, "-{d}", .{k});
            const gop = try seen.getOrPut(arena, name.items);
            if (!gop.found_existing) {
                gop.key_ptr.* = try arena.dupe(u8, name.items);
                t.* = gop.key_ptr.*;
                break;
            }
        }
    }
    var pool: std.ArrayList(u32) = .empty;
    for (0..n) |i| try pool.append(arena, @intCast(i));
    const notes = try arena.alloc(NotePlan, n);
    var files = try arena.alloc(PlanFile, n);
    var dirs: std.ArrayList([]const u8) = .empty;
    for (note_folders) |f| try dirs.append(arena, try std.fmt.allocPrint(arena, "notes/{s}", .{f}));
    for (0..n) |i| {
        const nl = 1 + names.pick(r, 8);
        const links = try arena.alloc([]const u8, nl);
        for (links) |*l| {
            if (r.uintLessThan(u8, 50) == 0) {
                l.* = try std.fmt.allocPrint(arena, "missing-{d}", .{r.uintLessThan(u32, 1000)});
                continue;
            }
            const t = pool.items[names.pick(r, pool.items.len)];
            try pool.append(arena, t);
            l.* = titles[t];
        }
        notes[i] = .{ .title = titles[i], .links = links };
        files[i] = .{ .path = try std.fmt.allocPrint(arena, "notes/{s}/{s}.md", .{ note_folders[names.pick(r, note_folders.len)], titles[i] }), .size = 0, .kind = .note, .note = @intCast(i) };
    }
    std.mem.sort(PlanFile, files, {}, struct {
        fn lt(_: void, a: PlanFile, b: PlanFile) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);
    return .{ .files = files, .dirs = dirs.items, .notes = notes, .max_depth = 2 };
}

fn hex(out: *[64]u8, d: [32]u8) []const u8 {
    return std.fmt.bufPrint(out, "{x}", .{&d}) catch unreachable;
}

const WriteCtx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir,
    plan: *const Plan,
    spec: Spec,
    digests: [][32]u8,
    bytes: std.atomic.Value(u64) = .init(0),
    lines: std.atomic.Value(u64) = .init(0),
    err: std.atomic.Value(u16) = .init(0),

    fn fail(c: *WriteCtx, e: anyerror) void {
        _ = c.err.cmpxchgStrong(0, @intFromError(e), .acq_rel, .monotonic);
    }
};

fn fileSeed(spec: Spec, path: []const u8) u64 {
    return std.hash.Wyhash.hash(spec.seed, path);
}

fn writeOne(c: *WriteCtx, i: usize, buf: []u8) !void {
    const f = c.plan.files[i];
    const file = try c.dir.createFile(c.io, f.path, .{});
    defer file.close(c.io);
    if (c.spec.materialize == .tree_sparse) {
        try file.setLength(c.io, f.size);
        var h: std.crypto.hash.Blake3 = .init(.{});
        var sz: [8]u8 = undefined;
        std.mem.writeInt(u64, &sz, f.size, .little);
        h.update(&sz);
        h.final(&c.digests[i]);
        _ = c.bytes.fetchAdd(f.size, .monotonic);
        return;
    }
    var prng: std.Random.DefaultPrng = .init(fileSeed(c.spec, f.path));
    const r = prng.random();
    var s: content.Sink = .{ .buf = buf, .file = file, .io = c.io };
    switch (f.kind) {
        .source_tabs => content.source(&s, r, f.size, true, c.gpa),
        .source_spaces => content.source(&s, r, f.size, false, c.gpa),
        .binary => {
            var left = f.size;
            var chunk: [256]u8 = undefined;
            while (left > 0) {
                const n: usize = @intCast(@min(left, chunk.len));
                r.bytes(chunk[0..n]);
                s.put(chunk[0..n]);
                left -= n;
            }
        },
        .lines => content.zigLines(&s, r, f.size, c.gpa),
        .log => content.log(&s, r, f.size, c.gpa),
        .minified => content.minified(&s, r, f.size, c.gpa),
        .unicode => content.unicode(&s, r, f.size),
        .note => {
            const n = c.plan.notes[f.note];
            content.note(&s, r, n.title, n.links, c.gpa);
        },
    }
    c.digests[i] = s.finish();
    if (s.failed) |e| return e;
    _ = c.bytes.fetchAdd(s.bytes, .monotonic);
    _ = c.lines.fetchAdd(s.lines, .monotonic);
}

fn writeChunk(c: *WriteCtx, from: usize, to: usize) std.Io.Cancelable!void {
    const buf = c.gpa.alloc(u8, 64 * 1024) catch return c.fail(error.OutOfMemory);
    defer c.gpa.free(buf);
    for (from..to) |i| {
        if (c.err.load(.monotonic) != 0) return;
        writeOne(c, i, buf) catch |e| return c.fail(e);
    }
}

/// Generates `spec` into `out_dir` (which should be empty) and writes
/// MANIFEST.json there.
pub fn generate(gpa: std.mem.Allocator, io: std.Io, spec: Spec, out_dir: std.Io.Dir) !Manifest {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const plan = try makePlan(arena, spec);

    // paths.txt (sorted, `\n`-separated) and paths.bin (u32 LE length +
    // bytes).
    var txt: std.ArrayList(u8) = .empty;
    var bin: std.ArrayList(u8) = .empty;
    var planned: u64 = 0;
    for (plan.files) |f| {
        try txt.appendSlice(arena, f.path);
        try txt.append(arena, '\n');
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(f.path.len), .little);
        try bin.appendSlice(arena, &len);
        try bin.appendSlice(arena, f.path);
        planned += f.size;
    }
    try out_dir.writeFile(io, .{ .sub_path = "paths.txt", .data = txt.items });
    try out_dir.writeFile(io, .{ .sub_path = "paths.bin", .data = bin.items });
    var paths_digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(txt.items, &paths_digest, .{});

    var m: Manifest = .{
        .version = version,
        .profile = spec.profile,
        .seed = spec.seed,
        .scale_ppm = spec.scale_ppm,
        .materialize = spec.materialize,
        .files = plan.files.len,
        .dirs = plan.dirs.len,
        .bytes = planned,
        .lines = 0,
        .digest = paths_digest,
        .paths_digest = paths_digest,
    };
    if (spec.materialize != .paths_only) {
        for (plan.dirs) |d| try out_dir.createDirPath(io, d);
        const digests = try arena.alloc([32]u8, plan.files.len);
        var ctx: WriteCtx = .{ .io = io, .gpa = gpa, .dir = out_dir, .plan = &plan, .spec = spec, .digests = digests };
        // Contiguous chunks on workers; contents depend only on each
        // file's path, so the split does not change the output.
        const workers = @min(16, @max(1, std.Thread.getCpuCount() catch 1), plan.files.len);
        var group: std.Io.Group = .init;
        for (0..workers) |w| {
            const from = plan.files.len * w / workers;
            const to = plan.files.len * (w + 1) / workers;
            // No concurrency: write the chunk here.
            group.concurrent(io, writeChunk, .{ &ctx, from, to }) catch try writeChunk(&ctx, from, to);
        }
        try group.await(io);
        if (ctx.err.load(.acquire) != 0) return @errorFromInt(ctx.err.load(.acquire));
        var h: std.crypto.hash.Blake3 = .init(.{});
        h.update(&paths_digest);
        for (digests) |*d| h.update(d);
        h.final(&m.digest);
        m.bytes = ctx.bytes.load(.acquire);
        m.lines = ctx.lines.load(.acquire);
    }
    try writeManifest(arena, io, out_dir, m);
    return m;
}

fn writeManifest(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, m: Manifest) !void {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    const json = try std.json.Stringify.valueAlloc(arena, ManifestJson{
        .version = m.version,
        .profile = @tagName(m.profile),
        .seed = m.seed,
        .scale_ppm = m.scale_ppm,
        .materialize = @tagName(m.materialize),
        .files = m.files,
        .dirs = m.dirs,
        .bytes = m.bytes,
        .lines = m.lines,
        .digest = hex(&a, m.digest),
        .paths_digest = hex(&b, m.paths_digest),
    }, .{ .whitespace = .indent_2 });
    try dir.writeFile(io, .{ .sub_path = "MANIFEST.json", .data = json });
}

/// Reads MANIFEST.json from `dir`.
pub fn readManifest(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Manifest {
    const text = try dir.readFileAlloc(io, "MANIFEST.json", arena, .limited(1 << 16));
    const j = try std.json.parseFromSliceLeaky(ManifestJson, arena, text, .{ .ignore_unknown_fields = true });
    var m: Manifest = .{
        .version = j.version,
        .profile = std.meta.stringToEnum(Profile, j.profile) orelse return error.BadManifest,
        .seed = j.seed,
        .scale_ppm = j.scale_ppm,
        .materialize = std.meta.stringToEnum(Materialize, j.materialize) orelse return error.BadManifest,
        .files = j.files,
        .dirs = j.dirs,
        .bytes = j.bytes,
        .lines = j.lines,
        .digest = undefined,
        .paths_digest = undefined,
    };
    if (j.digest.len != 64 or j.paths_digest.len != 64) return error.BadManifest;
    _ = std.fmt.hexToBytes(&m.digest, j.digest) catch return error.BadManifest;
    _ = std.fmt.hexToBytes(&m.paths_digest, j.paths_digest) catch return error.BadManifest;
    return m;
}

/// The folder name of `spec` in the cache.
pub fn cacheName(buf: []u8, spec: Spec) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.print("{t}-v{d}-{x:0>16}", .{ spec.profile, version, spec.seed });
    if (spec.scale_ppm != 1_000_000) try w.print("-s{d}", .{spec.scale_ppm});
    try w.writeAll(switch (spec.materialize) {
        .tree => "",
        .paths_only => "-paths",
        .tree_sparse => "-sparse",
    });
    return w.buffered();
}

/// The cache root: `ZG_CORPUS_DIR`, else `fallback` (build.zig passes
/// `<global zig cache>/zg-corpus`).
pub fn cacheRoot(env: *const std.process.Environ.Map, fallback: []const u8) []const u8 {
    if (env.get("ZG_CORPUS_DIR")) |d| if (d.len > 0) return d;
    return fallback;
}

/// The corpus folder for `spec` under `cache_root` (allocated with
/// `gpa`), generated when missing or when its manifest does not match
/// (version, profile, seed, scale, digest of paths.txt).
pub fn ensure(gpa: std.mem.Allocator, io: std.Io, spec: Spec, cache_root: []const u8) ![]const u8 {
    var nb: [128]u8 = undefined;
    const name = try cacheName(&nb, spec);
    const path = try std.fs.path.join(gpa, &.{ cache_root, name });
    errdefer gpa.free(path);
    const cwd = std.Io.Dir.cwd();
    if (cwd.openDir(io, path, .{})) |d| {
        var dir = d;
        defer dir.close(io);
        if (matches(gpa, io, dir, spec)) return path;
    } else |_| {}
    cwd.deleteTree(io, path) catch {};
    try cwd.createDirPath(io, path);
    var dir = try cwd.openDir(io, path, .{});
    defer dir.close(io);
    _ = try generate(gpa, io, spec, dir);
    return path;
}

fn matches(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, spec: Spec) bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const m = readManifest(arena.allocator(), io, dir) catch return false;
    if (m.version != version or m.profile != spec.profile or m.seed != spec.seed or m.scale_ppm != spec.scale_ppm or m.materialize != spec.materialize) return false;
    const txt = dir.readFileAlloc(io, "paths.txt", arena.allocator(), .unlimited) catch return false;
    var d: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(txt, &d, .{});
    return std.mem.eql(u8, &d, &m.paths_digest);
}

/// Re-reads every file under `dir` and checks it against MANIFEST.json.
pub fn verify(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !bool {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const m = try readManifest(arena, io, dir);
    const txt = try dir.readFileAlloc(io, "paths.txt", arena, .unlimited);
    var pd: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(txt, &pd, .{});
    if (!std.mem.eql(u8, &pd, &m.paths_digest)) return false;
    if (m.materialize == .paths_only) return std.mem.eql(u8, &pd, &m.digest);
    var h: std.crypto.hash.Blake3 = .init(.{});
    h.update(&pd);
    var it = std.mem.splitScalar(u8, txt, '\n');
    const buf = try arena.alloc(u8, 64 * 1024);
    while (it.next()) |p| {
        if (p.len == 0) continue;
        const file = try dir.openFile(io, p, .{});
        defer file.close(io);
        var fd: [32]u8 = undefined;
        if (m.materialize == .tree_sparse) {
            var fh: std.crypto.hash.Blake3 = .init(.{});
            var sz: [8]u8 = undefined;
            std.mem.writeInt(u64, &sz, (try file.stat(io)).size, .little);
            fh.update(&sz);
            fh.final(&fd);
        } else {
            var fh: std.crypto.hash.Blake3 = .init(.{});
            var r = file.reader(io, buf);
            while (true) {
                const chunk = r.interface.peekGreedy(1) catch |e| switch (e) {
                    error.EndOfStream => break,
                    else => return e,
                };
                fh.update(chunk);
                r.interface.toss(chunk.len);
            }
            fh.final(&fd);
        }
        h.update(&fd);
    }
    var d: [32]u8 = undefined;
    h.final(&d);
    return std.mem.eql(u8, &d, &m.digest);
}

fn tmpPath(buf: []u8, tmp: *const std.testing.TmpDir) []const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path}) catch unreachable;
}

fn genTo(spec: Spec, tmp: *std.testing.TmpDir, sub: []const u8) !Manifest {
    try tmp.dir.createDirPath(std.testing.io, sub);
    var d = try tmp.dir.openDir(std.testing.io, sub, .{});
    defer d.close(std.testing.io);
    return generate(std.testing.allocator, std.testing.io, spec, d);
}

const small_linux: Spec = .{ .profile = .linux, .scale_ppm = 10_000 };

test "corpusgen: deterministic across runs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = try genTo(small_linux, &tmp, "a");
    const b = try genTo(small_linux, &tmp, "b");
    try std.testing.expectEqualSlices(u8, &a.digest, &b.digest);
    try std.testing.expect(a.bytes > 5_000_000 and a.lines > 100_000);
    var d = try tmp.dir.openDir(std.testing.io, "a", .{});
    defer d.close(std.testing.io);
    try std.testing.expect(try verify(std.testing.allocator, std.testing.io, d));
    // Another seed is another corpus.
    var other = small_linux;
    other.seed += 1;
    other.materialize = .paths_only;
    const c = try genTo(other, &tmp, "c");
    try std.testing.expect(!std.mem.eql(u8, &a.paths_digest, &c.paths_digest));
}

test "corpusgen: golden digest for scale 0.01" {
    // Update together with `version` when the output changes on purpose.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const m = try genTo(small_linux, &tmp, "g");
    var h: [64]u8 = undefined;
    try std.testing.expectEqualStrings(golden_linux_1pct, hex(&h, m.digest));
}

const golden_linux_1pct = "cbdd381735535b66bbac5874c70971edf9bd8a83a84da1562c170ff2cc90e525";

test "corpusgen: distribution sanity" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const plan = try makePlan(arena.allocator(), small_linux);
    var c: u64 = 0;
    var h: u64 = 0;
    for (plan.files) |f| {
        if (std.mem.endsWith(u8, f.path, ".c")) c += 1;
        if (std.mem.endsWith(u8, f.path, ".h")) h += 1;
    }
    const n = plan.files.len;
    try std.testing.expect(c * 1000 >= n * 430 and c * 1000 <= n * 470);
    try std.testing.expect(h * 1000 >= n * 200 and h * 1000 <= n * 240);
    try std.testing.expect(plan.max_depth <= 9);
}

test "corpusgen: paths sorted and unique" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const plan = try makePlan(arena.allocator(), .{ .profile = .chromium, .scale_ppm = 5_000, .materialize = .paths_only });
    try std.testing.expectEqual(@as(usize, 5_000), plan.files.len);
    var longest: usize = 0;
    for (plan.files[1..], plan.files[0 .. plan.files.len - 1]) |b, a| try std.testing.expect(std.mem.lessThan(u8, a.path, b.path));
    for (plan.files) |f| longest = @max(longest, f.path.len);
    try std.testing.expect(longest > 60);
}

test "corpusgen: notes link targets exist and in-degree is heavy-tailed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const plan = try makePlan(arena.allocator(), .{ .profile = .notes_10k, .scale_ppm = 100_000 });
    var titles: std.StringHashMapUnmanaged(u32) = .empty;
    for (plan.notes) |n| try titles.put(arena.allocator(), n.title, 0);
    var total: u64 = 0;
    var found: u64 = 0;
    for (plan.notes) |n| for (n.links) |l| {
        total += 1;
        if (titles.getPtr(l)) |c| {
            found += 1;
            c.* += 1;
        }
    };
    try std.testing.expect(found * 100 >= total * 95);
    var max: u32 = 0;
    var it = titles.valueIterator();
    while (it.next()) |v| max = @max(max, v.*);
    // The mean in-degree is about 4; the most-linked note has many more.
    try std.testing.expect(max >= 20);
}

test "corpusgen: unicode corpus is valid UTF-8" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const m = try genTo(.{ .profile = .mixed_unicode_10m, .scale_ppm = 10_000 }, &tmp, "u");
    try std.testing.expectEqual(@as(u64, 100_000), m.bytes);
    const text = try tmp.dir.readFileAlloc(std.testing.io, "u/unicode.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
}

test "corpusgen: ensure cache hit is fast" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    const root = tmpPath(&buf, &tmp);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const spec: Spec = .{ .profile = .lines_100k, .scale_ppm = 10_000 };
    const p1 = try ensure(gpa, io, spec, root);
    defer gpa.free(p1);
    const t0 = std.Io.Clock.awake.now(io).nanoseconds;
    const p2 = try ensure(gpa, io, spec, root);
    defer gpa.free(p2);
    const dt = std.Io.Clock.awake.now(io).nanoseconds - t0;
    try std.testing.expectEqualStrings(p1, p2);
    try std.testing.expect(dt < 200 * std.time.ns_per_ms);
    // A sparse big file has its size and no content.
    const sp = try ensure(gpa, io, .{ .profile = .bigfile_1g, .scale_ppm = 1_000, .materialize = .tree_sparse }, root);
    defer gpa.free(sp);
    var d = try std.Io.Dir.cwd().openDir(io, sp, .{});
    defer d.close(io);
    try std.testing.expectEqual(@as(u64, (1 << 30) / 1000), (try d.statFile(io, "big.log", .{})).size);
    try std.testing.expect(try verify(gpa, io, d));
}

test {
    _ = names;
    _ = profiles;
    _ = content;
    _ = tree;
}
