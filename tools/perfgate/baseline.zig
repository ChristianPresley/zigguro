//! Bench sets and baselines (E14.F06.S02.T01).
//!
//! A bench set is one or more E00 bench files; `perfgate merge` writes
//! them as `{"schema": 1, "files": [...]}` and folds repeated runs of a
//! suite into one file: each result's `samples_ns` gathers every run's
//! samples (or its `ns_per_op`), and its other numbers are the medians
//! over the runs.
//!
//! A baseline is one JSON per suite in `perf/baselines/<machine>/`: the
//! machine-independent fields (allocations) that perfgate checks
//! deterministically, plus informational medians. Results are sorted by
//! name so diffs stay reviewable.

const std = @import("std");
const zg_perf = @import("zg_perf");
const stats = @import("stats.zig");

pub const BenchFile = zg_perf.budget.bench_bind.BenchFile;
pub const BenchResult = zg_perf.budget.bench_bind.BenchResult;

/// A merged bench set.
pub const Set = struct {
    schema: u32 = 1,
    files: []const BenchFile,

    pub fn find(s: Set, suite: []const u8, name: []const u8) ?*const BenchResult {
        for (s.files) |*f| if (std.mem.eql(u8, f.package, suite)) {
            for (f.results) |*r| if (std.mem.eql(u8, r.name, name)) return r;
        };
        return null;
    }
};

/// Parses a bench file or a merged set.
pub fn parseAny(arena: std.mem.Allocator, bytes: []const u8) ![]const BenchFile {
    const probe = try std.json.parseFromSliceLeaky(struct { files: ?[]const BenchFile = null }, arena, bytes, .{ .ignore_unknown_fields = true });
    if (probe.files) |f| return f;
    const one = try arena.alloc(BenchFile, 1);
    one[0] = try zg_perf.budget.bench_bind.parseBenchFile(arena, bytes);
    return one;
}

fn medianOf(arena: std.mem.Allocator, v: []const f64) !f64 {
    return stats.median(arena, v);
}

/// Folds `files` into one file per suite (in first-seen order).
pub fn merge(arena: std.mem.Allocator, files: []const BenchFile) !Set {
    var suites: std.ArrayList([]const u8) = .empty;
    for (files) |f| {
        for (suites.items) |s| {
            if (std.mem.eql(u8, s, f.package)) break;
        } else try suites.append(arena, f.package);
    }
    const out = try arena.alloc(BenchFile, suites.items.len);
    for (suites.items, out) |suite, *o| {
        var first: ?BenchFile = null;
        var names: std.ArrayList([]const u8) = .empty;
        var runs: u32 = 0;
        for (files) |f| if (std.mem.eql(u8, f.package, suite)) {
            if (first == null) first = f;
            runs += 1;
            for (f.results) |r| {
                for (names.items) |n| {
                    if (std.mem.eql(u8, n, r.name)) break;
                } else try names.append(arena, r.name);
            }
        };
        const results = try arena.alloc(BenchResult, names.items.len);
        for (names.items, results) |name, *res| {
            var samples: std.ArrayList(f64) = .empty;
            var fields: [7]std.ArrayList(f64) = @splat(.empty);
            var iters: u64 = 0;
            var have_p95 = false;
            var have_bytes = false;
            for (files) |f| if (std.mem.eql(u8, f.package, suite)) for (f.results) |r| if (std.mem.eql(u8, r.name, name)) {
                if (r.samples_ns) |s| try samples.appendSlice(arena, s) else try samples.append(arena, r.ns_per_op);
                iters += r.iters;
                try fields[0].append(arena, r.ns_per_op);
                try fields[1].append(arena, r.p50_ns);
                try fields[2].append(arena, r.p99_ns);
                try fields[3].append(arena, r.allocs_per_op);
                try fields[4].append(arena, r.bytes_alloc_per_op);
                if (r.p95_ns) |v| {
                    have_p95 = true;
                    try fields[5].append(arena, v);
                }
                if (r.bytes_per_op) |v| {
                    have_bytes = true;
                    try fields[6].append(arena, v);
                }
            };
            res.* = .{
                .name = name,
                .iters = iters,
                .ns_per_op = try medianOf(arena, fields[0].items),
                .p50_ns = try medianOf(arena, fields[1].items),
                .p99_ns = try medianOf(arena, fields[2].items),
                .allocs_per_op = try medianOf(arena, fields[3].items),
                .bytes_alloc_per_op = try medianOf(arena, fields[4].items),
                .p95_ns = if (have_p95) try medianOf(arena, fields[5].items) else null,
                .bytes_per_op = if (have_bytes) try medianOf(arena, fields[6].items) else null,
                .samples_ns = samples.items,
            };
        }
        const f = first.?;
        o.* = .{ .schema = 1, .package = suite, .zig = f.zig, .target = f.target, .optimize = f.optimize, .cpu = f.cpu, .quick = f.quick, .results = results };
    }
    return .{ .files = out };
}

/// One baseline row.
pub const Entry = struct {
    name: []const u8,
    allocs_per_op: f64,
    bytes_alloc_per_op: f64,
    /// Informational.
    median_ns: f64,
};

/// One suite's baseline file.
pub const File = struct {
    schema: u32 = 1,
    machine: []const u8,
    suite: []const u8,
    zig: []const u8,
    target: []const u8,
    cpu: ?[]const u8 = null,
    results: []const Entry,

    pub fn find(f: File, name: []const u8) ?*const Entry {
        for (f.results) |*e| if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }
};

/// Baselines by suite.
pub const Baselines = struct {
    files: []const File = &.{},

    pub fn find(b: Baselines, suite: []const u8, name: []const u8) ?*const Entry {
        for (b.files) |f| if (std.mem.eql(u8, f.suite, suite)) return f.find(name);
        return null;
    }
};

/// Baseline files for every suite in `set`, results sorted by name.
pub fn fromSet(arena: std.mem.Allocator, set: Set, machine: []const u8) ![]File {
    const out = try arena.alloc(File, set.files.len);
    for (set.files, out) |f, *o| {
        const entries = try arena.alloc(Entry, f.results.len);
        for (f.results, entries) |r, *e| e.* = .{
            .name = r.name,
            .allocs_per_op = r.allocs_per_op,
            .bytes_alloc_per_op = r.bytes_alloc_per_op,
            .median_ns = if (r.samples_ns) |s| (if (s.len > 0) try stats.median(arena, s) else r.p50_ns) else r.p50_ns,
        };
        std.mem.sort(Entry, entries, {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lt);
        o.* = .{ .machine = machine, .suite = f.package, .zig = f.zig, .target = f.target, .cpu = f.cpu, .results = entries };
    }
    return out;
}

pub fn writeFile(w: *std.Io.Writer, f: File) !void {
    try std.json.Stringify.value(f, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, w);
    try w.writeAll("\n");
}

/// Writes `<dir>/<suite>.json` for each file.
pub fn writeAll(io: std.Io, dir: std.Io.Dir, files: []const File, arena: std.mem.Allocator) !void {
    for (files) |f| {
        var aw: std.Io.Writer.Allocating = .init(arena);
        try writeFile(&aw.writer, f);
        const name = try std.fmt.allocPrint(arena, "{s}.json", .{f.suite});
        try dir.writeFile(io, .{ .sub_path = name, .data = aw.written() });
    }
}

/// Reads every `*.json` in `dir` (a missing folder is no baselines).
pub fn readDir(arena: std.mem.Allocator, io: std.Io, path: []const u8) !Baselines {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return .{},
        else => return e,
    };
    defer dir.close(io);
    var files: std.ArrayList(File) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".json")) continue;
        const text = try dir.readFileAlloc(io, e.name, arena, .limited(16 << 20));
        try files.append(arena, try std.json.parseFromSliceLeaky(File, arena, text, .{ .ignore_unknown_fields = true }));
    }
    return .{ .files = files.items };
}

fn result(name: []const u8, ns: f64, allocs: f64) BenchResult {
    return .{ .name = name, .iters = 10, .ns_per_op = ns, .p50_ns = ns, .p99_ns = ns * 1.2, .allocs_per_op = allocs, .bytes_alloc_per_op = allocs * 64 };
}

test "baseline: deterministic output" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const run1 = [_]BenchResult{ result("zeta", 10, 1), result("alpha", 20, 0) };
    const run2 = [_]BenchResult{ result("alpha", 22, 0), result("zeta", 12, 1) };
    const files = [_]BenchFile{
        .{ .schema = 1, .package = "zg_core", .zig = "0.16.0", .target = "x86_64-linux", .optimize = "ReleaseFast", .results = &run1 },
        .{ .schema = 1, .package = "zg_core", .zig = "0.16.0", .target = "x86_64-linux", .optimize = "ReleaseFast", .results = &run2 },
    };
    const set = try merge(a, &files);
    try std.testing.expectEqual(@as(usize, 1), set.files.len);
    const zeta = set.find("zg_core", "zeta").?;
    try std.testing.expectEqual(@as(usize, 2), zeta.samples_ns.?.len);
    try std.testing.expectEqual(@as(f64, 11), zeta.ns_per_op);
    // Same input in another order gives the same bytes.
    const b1 = try fromSet(a, set, "ci_linux_x64");
    const swapped = [_]BenchFile{ files[1], files[0] };
    const b2 = try fromSet(a, try merge(a, &swapped), "ci_linux_x64");
    var w1: std.Io.Writer.Allocating = .init(a);
    var w2: std.Io.Writer.Allocating = .init(a);
    try writeFile(&w1.writer, b1[0]);
    try writeFile(&w2.writer, b2[0]);
    try std.testing.expectEqualStrings(w1.written(), w2.written());
    try std.testing.expect(std.mem.indexOf(u8, w1.written(), "\"alpha\"").? < std.mem.indexOf(u8, w1.written(), "\"zeta\"").?);
}
