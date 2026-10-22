//! Benchmarks for zg_workspace; run with `zig build bench` at the repo root.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_workspace = @import("zg_workspace");
const bench = zg_core.bench;
const wm = zg_workspace.ignore.wildmatch;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

/// A seeded synthetic monorepo, about ten files per directory:
/// packages/p<0..199>/<dir>/<dir><0..4>/f<i>_<file>.
fn monorepo(a: std.mem.Allocator, n: usize) ![]const []const u8 {
    var prng: std.Random.DefaultPrng = .init(1_000_000);
    const r = prng.random();
    const dirs = [_][]const u8{ "src", "lib", "test", "components", "utils", "internal", "api", "core", "views", "models" };
    const files = [_][]const u8{ "index.ts", "mod.rs", "__init__.py", "main.zig", "util.go", "README.md", "types.d.ts", "handler.ts" };
    const out = try a.alloc([]const u8, n);
    for (out, 0..) |*p, i| {
        p.* = try std.fmt.allocPrint(a, "packages/p{d}/{s}/{s}{d}/f{d}_{s}", .{
            r.uintLessThan(u32, 200), dirs[r.uintLessThan(usize, dirs.len)], dirs[r.uintLessThan(usize, dirs.len)],
            r.uintLessThan(u32, 5),   i,                                     files[r.uintLessThan(usize, files.len)],
        });
    }
    return out;
}

const StoreCtx = struct { paths: []const []const u8, ops: []zg_workspace.paths.Delta.Op };

const FastCtx = struct { pats: []const wm.Pattern, names: []const []const u8 };

fn register(b: *bench.Bench) !void {
    const a = arena_state.allocator();

    // Budget: <= 15 ns p50 per fast-path match (E08.F01.S02.T01).
    const srcs = [_][]const u8{ "*.o", "node_modules", "build*", "*_test.zig" };
    var pats: [srcs.len]wm.Pattern = undefined;
    for (srcs, 0..) |s, i| pats[i] = try wm.compile(a, s, .{});
    const names = [_][]const u8{ "main.o", "node_modules", "build.zig", "parser_test.zig", "README.md", "x.c" };
    try b.run("workspace/wildmatch_fast", FastCtx{ .pats = &pats, .names = &names }, struct {
        fn f(c: FastCtx, s: *bench.State) void {
            var hits: u64 = 0;
            for (0..s.iterations()) |i| {
                const p = &c.pats[i % c.pats.len];
                if (wm.match(p, c.names[i % c.names.len], .{})) hits += 1;
            }
            bench.doNotOptimizeAway(hits);
        }
    }.f);

    // Budget: 1 M paths < 110 MB and < 400 ms single-threaded
    // (E08.F01.S01.T02). One op = building the whole store; bytes_alloc_per_op
    // is the total footprint, and lookups are timed separately below.
    const mono = try monorepo(a, 1_000_000);
    // A directory listing groups paths by directory, as a scan delivers them.
    std.mem.sort([]const u8, @constCast(mono), {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    const ops = try a.alloc(zg_workspace.paths.Delta.Op, mono.len);
    for (ops, mono) |*o, p| o.* = .{ .upsert = .{ .root = .of(0), .rel = p, .info = .{ .kind = .file, .size = 10 } } };
    try b.run("workspace/path_store_1m", StoreCtx{ .paths = mono, .ops = ops }, struct {
        fn f(c: StoreCtx, s: *bench.State) void {
            for (0..s.iterations()) |_| {
                const ps = zg_workspace.PathStore.init(s.allocator(), s.ioHandle()) catch @panic("oom");
                defer ps.deinit();
                ps.addRoot(.of(0), false) catch @panic("oom");
                var ch: std.ArrayList(zg_workspace.paths.Change) = .empty;
                defer ch.deinit(std.heap.page_allocator);
                ch.ensureTotalCapacity(std.heap.page_allocator, c.ops.len * 5 / 4) catch @panic("oom");
                ps.applyWith(&.{ .ops = c.ops }, &ch, std.heap.page_allocator) catch @panic("oom");
                bench.doNotOptimizeAway(ps.nodeCount());
            }
        }
    }.f);
    {
        const ps = try zg_workspace.PathStore.init(std.heap.page_allocator, b.io);
        try ps.addRoot(.of(0), false);
        var ch: std.ArrayList(zg_workspace.paths.Change) = .empty;
        try ps.apply(&.{ .ops = ops }, &ch);
        const snap = ps.snapshot();
        for (mono[0..1000]) |p| _ = snap.lookup(.of(0), p); // warm the children caches
        const LookupCtx = struct { snap: *const zg_workspace.Snapshot, paths: []const []const u8 };
        try b.run("workspace/path_store_lookup", LookupCtx{ .snap = snap, .paths = mono[0..1000] }, struct {
            fn f(c: LookupCtx, s: *bench.State) void {
                for (0..s.iterations()) |i| bench.doNotOptimizeAway(c.snap.lookup(.of(0), c.paths[i % c.paths.len]));
            }
        }.f);
    }

    // Budget: isIgnored p50 <= 300 ns at depth 8 with 200 rules over 4 levels
    // (E08.F01.S02.T02).
    const st = try zg_workspace.IgnoreStack.init(std.heap.page_allocator, b.io, 1);
    const dirs = [_][]const u8{ "", "a/b", "a/b/c/d", "a/b/c/d/e/f" };
    for (dirs, 0..) |d, li| {
        var text: std.ArrayList(u8) = .empty;
        for (0..50) |k| {
            switch (k % 5) {
                0 => try text.print(a, "*.ext{d}{d}\n", .{ li, k }),
                1 => try text.print(a, "name{d}{d}\n", .{ li, k }),
                2 => try text.print(a, "dir{d}{d}/\n", .{ li, k }),
                3 => try text.print(a, "/anch{d}{d}/x\n", .{ li, k }),
                else => try text.print(a, "pre{d}{d}*\n", .{ li, k }),
            }
        }
        try st.loadDir(.of(0), d, text.items, null);
    }
    const paths = [_][]const u8{ "a/b/c/d/e/f/g/file.zig", "a/b/c/d/e/f/g/name011", "a/b/c/d/e/f/g/x.ext30" };
    try b.run("workspace/ignore_query", st, struct {
        fn f(s0: *zg_workspace.IgnoreStack, s: *bench.State) void {
            var n: u64 = 0;
            for (0..s.iterations()) |i| {
                if (s0.isIgnored(.of(0), paths[i % paths.len], false).isIgnored()) n += 1;
            }
            bench.doNotOptimizeAway(n);
        }
    }.f);

    // Budget: 100 k files < 350 ms warm (E08.F02.S01.T01). The tree is
    // generated once under .zig-cache and reused; the first run warms the
    // page cache.
    const scan_dir = try scanTree(b.io, a);
    // The 1-worker run is the baseline for the scaling criterion (1 -> 8
    // workers >= 4x).
    try b.run("workspace/scan_100k", ScanCtx{ .abs = scan_dir, .workers = 0 }, scanOnce);
    try b.run("workspace/scan_100k_1worker", ScanCtx{ .abs = scan_dir, .workers = 1 }, scanOnce);

    // Budgets (E08.F02.S02): classification >= 300 MB/s aggregate with 7
    // workers (here one worker, per byte); trigram build >= 150 MB/s per
    // worker; a selective literal over 70 k files < 20 ms.
    const corpus = try codeCorpus(a, 70_000);
    var corpus_bytes: usize = 0;
    for (corpus) |d| corpus_bytes += d.len;
    try b.run("workspace/index_classify", corpus, struct {
        fn f(docs: []const []const u8, s: *bench.State) void {
            const cfg: zg_workspace.content_class.IndexConfig = .{};
            var n: u64 = 0;
            for (0..s.iterations()) |i| {
                const d = docs[i % docs.len];
                n += @intFromEnum(zg_workspace.content_class.classify(d, d.len, "x.ts", &cfg));
            }
            bench.doNotOptimizeAway(n);
        }
    }.f);
    try b.run("workspace/trigram_build", corpus[0..5000], struct {
        fn f(docs: []const []const u8, s: *bench.State) void {
            const gpa = std.heap.smp_allocator;
            for (0..s.iterations()) |_| {
                const ix = zg_workspace.trigram.TrigramIndex.open(gpa, s.ioHandle(), null, .{}) catch @panic("oom");
                defer ix.deinit();
                for (docs, 0..) |d, k| ix.add(k, .{ .index = @intCast(k), .gen = 1 }, d) catch @panic("oom");
                ix.flush() catch @panic("oom");
            }
        }
    }.f);
    {
        const gpa = std.heap.smp_allocator;
        const ix = try zg_workspace.trigram.TrigramIndex.open(gpa, b.io, null, .{});
        for (corpus, 0..) |d, k| {
            try ix.add(k, .{ .index = @intCast(k), .gen = 1 }, d);
            if (k % 10_000 == 9_999) try ix.flush();
        }
        try ix.flush();
        const r = try ix.reader();
        var seg_bytes: usize = 0;
        for (r.segs) |sg| seg_bytes += sg.seg.bytes.len;
        std.debug.print("trigram corpus: {d} docs, {d} MB text, {d} MB segments ({d}%)\n", .{ corpus.len, corpus_bytes >> 20, seg_bytes >> 20, seg_bytes * 100 / corpus_bytes });
        try b.run("workspace/trigram_query", r, struct {
            fn f(rd: *const zg_workspace.trigram.index.Reader, s: *bench.State) void {
                var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
                defer arena.deinit();
                const q = zg_workspace.trigram.planLiteral(arena.allocator(), "handleRequest4711", false) catch @panic("oom");
                for (0..s.iterations()) |_| {
                    const c = rd.execute(q, std.heap.smp_allocator) catch @panic("oom");
                    bench.doNotOptimizeAway(c);
                    c.deinit(std.heap.smp_allocator);
                }
            }
        }.f);
    }
}

/// Seeded pseudo-source files, about 2 KB each, with identifiers like
/// `handleRequest<n>` so a literal can be made selective.
fn codeCorpus(a: std.mem.Allocator, n: usize) ![]const []const u8 {
    var prng: std.Random.DefaultPrng = .init(42);
    const r = prng.random();
    const words = [_][]const u8{ "const", "return", "if", "else", "function", "value", "result", "error", "self", "buffer", "index", "count", "for", "while", "import", "export", "class", "public", "private", "string", "number", "await", "async", "null", "true", "false", "=", "{", "}", "(", ")", ";", "." };
    const out = try a.alloc([]const u8, n);
    for (out) |*d| {
        var w: std.ArrayList(u8) = .empty;
        while (w.items.len < 2048) {
            if (r.uintLessThan(u8, 12) == 0) {
                try w.print(a, "handleRequest{d}(", .{r.uintLessThan(u32, 1_000_000)});
            } else {
                try w.appendSlice(a, words[r.uintLessThan(usize, words.len)]);
            }
            try w.append(a, if (r.uintLessThan(u8, 10) == 0) '\n' else ' ');
        }
        d.* = w.items;
    }
    return out;
}

const ScanCtx = struct { abs: []const u8, workers: u8 };

fn scanOnce(c: ScanCtx, s: *bench.State) void {
    for (0..s.iterations()) |_| {
        // A real multi-threaded allocator: page_allocator would serialize
        // the workers on mmap.
        const gpa = std.heap.smp_allocator;
        const ps = zg_workspace.PathStore.init(gpa, s.ioHandle()) catch @panic("oom");
        defer ps.deinit();
        const ign = zg_workspace.IgnoreStack.init(gpa, s.ioHandle(), 0) catch @panic("oom");
        defer ign.deinit();
        const root = ign.addRoot() catch @panic("oom");
        ps.addRoot(root, false) catch @panic("oom");
        const job = zg_workspace.Scanner.start(gpa, s.ioHandle(), .{ .paths = ps, .ignore = ign, .root = root, .abs_path = c.abs }, "", .{ .max_workers = c.workers }) catch @panic("scan");
        job.wait();
        const snap = ps.snapshot();
        defer snap.release();
        if (snap.fileCount() != scan_files + 1) @panic("scan incomplete"); // + the marker
        job.deinit();
    }
}

const scan_files = 100 * 10 * 10 * 10;

/// packages/p<0..99>/<dir>/d<0..9>/f<0..9>.zig: 100 k files in 11 k
/// directories, created once.
fn scanTree(io: std.Io, a: std.mem.Allocator) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const rel = ".zig-cache/bench/scan_100k";
    var root = try cwd.createDirPathOpen(io, rel, .{});
    defer root.close(io);
    if (root.statFile(io, "complete", .{})) |_| {} else |_| {
        const dirs = [_][]const u8{ "src", "lib", "test", "components", "utils", "internal", "api", "core", "views", "models" };
        var buf: [256]u8 = undefined;
        for (0..100) |p| for (dirs) |d| for (0..10) |k| {
            const dir_rel = try std.fmt.bufPrint(&buf, "packages/p{d}/{s}/d{d}", .{ p, d, k });
            var dir = try root.createDirPathOpen(io, dir_rel, .{});
            defer dir.close(io);
            for (0..10) |i| {
                var nb: [32]u8 = undefined;
                try dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&nb, "f{d}.zig", .{i}), .data = "" });
            }
        };
        try root.writeFile(io, .{ .sub_path = "complete", .data = "" });
    }
    const z = try cwd.realPathFileAlloc(io, rel, a);
    return z;
}
