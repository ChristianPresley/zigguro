//! corpusgen (E14.F06.S01.T01): generates a benchmark corpus.
//!
//!   corpusgen <profile> [--seed N] [--scale-ppm N] [--out DIR]
//!             [--paths-only | --tree | --sparse] [--verify] [--cache-root DIR]
//!
//! Without `--out` the corpus goes to the cache (`ZG_CORPUS_DIR`, else
//! `--cache-root`, which `zig build corpus` sets) and is reused while its
//! manifest matches. `--verify` re-reads the files and checks the digest.
//! Profiles: linux, chromium, huge, lines_100k, bigfile_1g, minified_50m,
//! notes_10k, mixed_unicode_10m (docs/perf/benchmarks.md).

const std = @import("std");
const corpus = @import("lib.zig");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buf);
    const w = &out.interface;
    defer w.flush() catch {};
    var profile: ?corpus.Profile = null;
    for (args[1..], 1..) |a, k| {
        const prev = args[k - 1];
        const takes_value = for ([_][]const u8{ "--seed", "--scale-ppm", "--out", "--cache-root" }) |o| {
            if (std.mem.eql(u8, prev, o)) break true;
        } else false;
        if (!takes_value and !std.mem.startsWith(u8, a, "--")) profile = std.meta.stringToEnum(corpus.Profile, a) orelse return usage();
    }
    var spec = corpus.Spec.default(profile orelse return usage());
    var out_dir: ?[]const u8 = null;
    var cache_root: []const u8 = ".zig-cache/zg-corpus";
    var do_verify = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--paths-only")) {
            spec.materialize = .paths_only;
        } else if (std.mem.eql(u8, a, "--tree")) {
            spec.materialize = .tree;
        } else if (std.mem.eql(u8, a, "--sparse")) {
            spec.materialize = .tree_sparse;
        } else if (std.mem.eql(u8, a, "--verify")) {
            do_verify = true;
        } else if (i + 1 < args.len and std.mem.eql(u8, a, "--seed")) {
            i += 1;
            spec.seed = try std.fmt.parseInt(u64, args[i], 0);
        } else if (i + 1 < args.len and std.mem.eql(u8, a, "--scale-ppm")) {
            i += 1;
            spec.scale_ppm = try std.fmt.parseInt(u32, args[i], 10);
        } else if (i + 1 < args.len and std.mem.eql(u8, a, "--out")) {
            i += 1;
            out_dir = args[i];
        } else if (i + 1 < args.len and std.mem.eql(u8, a, "--cache-root")) {
            i += 1;
            cache_root = args[i];
        } else if (std.mem.startsWith(u8, a, "--")) return usage();
    }
    const cwd = std.Io.Dir.cwd();
    const t0 = std.Io.Clock.awake.now(io).nanoseconds;
    const path = if (out_dir) |o| blk: {
        try cwd.createDirPath(io, o);
        var d = try cwd.openDir(io, o, .{});
        defer d.close(io);
        _ = try corpus.generate(gpa, io, spec, d);
        break :blk try gpa.dupe(u8, o);
    } else try corpus.ensure(gpa, io, spec, corpus.cacheRoot(init.environ_map, cache_root));
    defer gpa.free(path);
    const ms = @divTrunc(std.Io.Clock.awake.now(io).nanoseconds - t0, std.time.ns_per_ms);
    var dir = try cwd.openDir(io, path, .{});
    defer dir.close(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const m = try corpus.readManifest(arena.allocator(), io, dir);
    try w.print("{s}\n{t} v{d} seed 0x{x}: {d} files, {d} dirs, {d} bytes, {d} lines, digest {x} ({d} ms)\n", .{ path, m.profile, m.version, m.seed, m.files, m.dirs, m.bytes, m.lines, &m.digest, ms });
    if (do_verify) {
        const ok = try corpus.verify(gpa, io, dir);
        try w.print("verify: {s}\n", .{if (ok) "ok" else "MISMATCH"});
        if (!ok) return 1;
    }
    return 0;
}

fn usage() u8 {
    std.debug.print("usage: corpusgen <linux|chromium|huge|lines_100k|bigfile_1g|minified_50m|notes_10k|mixed_unicode_10m> [--seed N] [--scale-ppm N] [--out DIR] [--paths-only|--tree|--sparse] [--verify] [--cache-root DIR]\n", .{});
    return 2;
}

test {
    _ = corpus;
}
