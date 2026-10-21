//! A tiny std-only benchmark harness: adaptive batch sizes, warmup,
//! per-sample percentiles, allocation counting and JSON output (schema in
//! `docs/bench-format.md`, consumed by E14).
//!
//! A package's `bench/main.zig`:
//! ```zig
//! pub fn main(min: std.process.Init.Minimal) !u8 {
//!     return zg_core.bench.mainFromArgs(min, register);
//! }
//! fn register(b: *zg_core.bench.Bench) !void {
//!     try b.run("thing", ctx, struct { fn f(c: Ctx, s: *zg_core.bench.State) void { ... } }.f);
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");
const alloc = @import("alloc.zig");

/// Harness options.
pub const Options = struct {
    /// Minimum measured time per benchmark.
    min_time_ns: u64 = 200 * std.time.ns_per_ms,
    /// Warmup time per benchmark.
    warmup_ns: u64 = 50 * std.time.ns_per_ms,
    /// Upper bound on total iterations.
    max_iters: u64 = 1 << 30,
    /// Only run benchmarks whose name contains this.
    filter: ?[]const u8 = null,
    /// Quick mode (CI smoke): 20 ms measure, 5 ms warmup.
    quick: bool = false,
    /// Package name written to the JSON.
    package: []const u8 = "unknown",
};

/// One benchmark result.
pub const Result = struct {
    name: []const u8,
    iters: u64,
    ns_per_op: f64,
    p50_ns: f64,
    p99_ns: f64,
    bytes_per_op: ?f64 = null,
    allocs_per_op: f64,
    bytes_alloc_per_op: f64,
};

/// Per-call state handed to a benchmark function.
pub const State = struct {
    iters: u64,
    counting: *alloc.CountingAllocator,
    bytes: ?u64 = null,
    io: std.Io,

    /// How many operations this call must perform.
    pub fn iterations(s: *State) u64 {
        return s.iters;
    }

    /// An allocator whose allocations are counted into the result.
    pub fn allocator(s: *State) std.mem.Allocator {
        return s.counting.allocator();
    }

    /// Declares that each operation processes `n` bytes (for throughput).
    pub fn setBytes(s: *State, n: u64) void {
        s.bytes = n;
    }

    /// The harness `Io` (for benchmarks that need threads or clocks).
    pub fn ioHandle(s: *State) std.Io {
        return s.io;
    }
};

/// Prevents the optimizer from deleting work that produces `v`.
pub inline fn doNotOptimizeAway(v: anytype) void {
    std.mem.doNotOptimizeAway(v);
}

/// A benchmark session collecting results.
pub const Bench = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    opts: Options,
    results: std.ArrayList(Result) = .empty,
    counting: alloc.CountingAllocator,

    /// Creates a session; `gpa` backs the counted allocator and the results.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: Options) Bench {
        var o = opts;
        if (o.quick) {
            o.min_time_ns = 20 * std.time.ns_per_ms;
            o.warmup_ns = 5 * std.time.ns_per_ms;
        }
        return .{ .gpa = gpa, .io = io, .opts = o, .counting = .init(gpa) };
    }

    fn now(self: *Bench) u64 {
        return @intCast(@max(0, std.Io.Timestamp.now(self.io, .awake).nanoseconds));
    }

    fn call(self: *Bench, ctx: anytype, comptime func: anytype, iters: u64, bytes: *?u64) u64 {
        var st: State = .{ .iters = iters, .counting = &self.counting, .io = self.io };
        const t0 = self.now();
        func(ctx, &st);
        const t1 = self.now();
        bytes.* = st.bytes;
        return t1 - t0;
    }

    /// Runs `func(ctx, *State)` adaptively and records a result, unless the
    /// filter excludes `name`.
    pub fn run(self: *Bench, name: []const u8, ctx: anytype, comptime func: anytype) !void {
        if (self.opts.filter) |f| if (std.mem.indexOf(u8, name, f) == null) return;
        var bytes: ?u64 = null;
        // 1. Warm up, doubling the batch, and estimate the per-op time.
        var batch: u64 = 1;
        var spent: u64 = 0;
        var per_op: f64 = 0;
        while (true) {
            const t = self.call(ctx, func, batch, &bytes);
            spent += t;
            per_op = @as(f64, @floatFromInt(t)) / @as(f64, @floatFromInt(batch));
            if (spent >= self.opts.warmup_ns or batch >= self.opts.max_iters) break;
            if (t < 1_000_000) batch *= 2;
        }
        // 2. Size samples to >= 1 ms each.
        batch = @intFromFloat(@max(1.0, @ceil(1_000_000.0 / @max(per_op, 0.01))));
        batch = @min(batch, self.opts.max_iters);
        // 3. Collect at least 10 samples for at least min_time.
        var samples: std.ArrayList(f64) = .empty;
        defer samples.deinit(self.gpa);
        self.counting.resetCounters();
        var total_iters: u64 = 0;
        var total_ns: u64 = 0;
        while (samples.items.len < 10 or total_ns < self.opts.min_time_ns) {
            const t = self.call(ctx, func, batch, &bytes);
            total_ns += t;
            total_iters += batch;
            try samples.append(self.gpa, @as(f64, @floatFromInt(t)) / @as(f64, @floatFromInt(batch)));
            if (total_iters >= self.opts.max_iters) break;
        }
        std.mem.sort(f64, samples.items, {}, std.sort.asc(f64));
        const n = samples.items.len;
        const iters_f: f64 = @floatFromInt(total_iters);
        try self.results.append(self.gpa, .{
            .name = try self.gpa.dupe(u8, name),
            .iters = total_iters,
            .ns_per_op = @as(f64, @floatFromInt(total_ns)) / iters_f,
            .p50_ns = samples.items[n / 2],
            .p99_ns = samples.items[@min(n - 1, (n * 99) / 100)],
            .bytes_per_op = if (bytes) |b| @floatFromInt(b) else null,
            .allocs_per_op = @as(f64, @floatFromInt(self.counting.allocs.load(.monotonic))) / iters_f,
            .bytes_alloc_per_op = @as(f64, @floatFromInt(self.counting.bytes_total.load(.monotonic))) / iters_f,
        });
    }

    /// Writes the results as the schema-1 JSON document.
    pub fn writeJson(self: *Bench, w: *std.Io.Writer) !void {
        var arch_os_buf: [64]u8 = undefined;
        const target = try std.fmt.bufPrint(&arch_os_buf, "{t}-{t}", .{ builtin.cpu.arch, builtin.os.tag });
        var s: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
        try s.write(.{
            .schema = @as(u32, 1),
            .package = self.opts.package,
            .zig = builtin.zig_version_string,
            .target = target,
            .optimize = @tagName(builtin.mode),
            .cpu = builtin.cpu.model.name,
            .quick = self.opts.quick,
            .results = self.results.items,
        });
        try w.writeAll("\n");
    }

    /// Frees the results.
    pub fn deinit(self: *Bench) void {
        for (self.results.items) |r| self.gpa.free(r.name);
        self.results.deinit(self.gpa);
        self.* = undefined;
    }
};

/// Entry point for `bench/main.zig`: parses `--out <file>`, `--filter <s>`,
/// `--quick` and `--package <name>`, runs `register`, prints a summary to
/// stderr and writes the JSON (to `--out` or stdout). Returns the exit code.
pub fn mainFromArgs(min: std.process.Init.Minimal, comptime register: fn (*Bench) anyerror!void) !u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = if (builtin.mode == .Debug) gpa_state.allocator() else std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{ .argv0 = .init(min.args), .environ = min.environ });
    defer threaded.deinit();
    const io = threaded.io();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const args = try min.args.toSlice(arena.allocator());
    var opts: Options = .{};
    var out_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--quick")) {
            opts.quick = true;
        } else if (i + 1 < args.len and std.mem.eql(u8, a, "--out")) {
            i += 1;
            out_path = args[i];
        } else if (i + 1 < args.len and std.mem.eql(u8, a, "--filter")) {
            i += 1;
            opts.filter = args[i];
        } else if (i + 1 < args.len and std.mem.eql(u8, a, "--package")) {
            i += 1;
            opts.package = args[i];
        } else {
            std.debug.print("usage: bench [--quick] [--filter <s>] [--package <name>] [--out <file>]\n", .{});
            return 2;
        }
    }

    var b = Bench.init(gpa, io, opts);
    defer b.deinit();
    try register(&b);
    for (b.results.items) |r| std.debug.print("{s:<40} {d:>12.2} ns/op  p50 {d:>10.2}  p99 {d:>10.2}  allocs/op {d:.3}\n", .{ r.name, r.ns_per_op, r.p50_ns, r.p99_ns, r.allocs_per_op });

    var buf: [4096]u8 = undefined;
    if (out_path) |p| {
        var file = try std.Io.Dir.cwd().createFile(io, p, .{});
        defer file.close(io);
        var fw = file.writer(io, &buf);
        try b.writeJson(&fw.interface);
        try fw.interface.flush();
    } else {
        var fw: std.Io.File.Writer = .init(.stdout(), io, &buf);
        try b.writeJson(&fw.interface);
        try fw.interface.flush();
    }
    return 0;
}

fn fakeFast(_: void, s: *State) void {
    var x: u64 = 0;
    for (0..s.iterations()) |i| x +%= i;
    doNotOptimizeAway(x);
}

fn allocating(_: void, s: *State) void {
    for (0..s.iterations()) |_| {
        const p = s.allocator().alloc(u8, 16) catch unreachable;
        s.allocator().free(p);
    }
    s.setBytes(16);
}

test "bench: runs function at least 10 samples" {
    var b = Bench.init(std.testing.allocator, std.testing.io, .{ .quick = true, .min_time_ns = 1_000_000, .warmup_ns = 100_000 });
    b.opts.min_time_ns = 1_000_000;
    b.opts.warmup_ns = 100_000;
    defer b.deinit();
    try b.run("fast", {}, fakeFast);
    try b.run("alloc", {}, allocating);
    try std.testing.expectEqual(@as(usize, 2), b.results.items.len);
    try std.testing.expect(b.results.items[0].iters >= 10);
    try std.testing.expect(b.results.items[0].p50_ns <= b.results.items[0].p99_ns);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), b.results.items[1].allocs_per_op, 0.01);
    try std.testing.expectEqual(@as(?f64, 16), b.results.items[1].bytes_per_op);
}

test "bench: json output parses back" {
    const gpa = std.testing.allocator;
    var b = Bench.init(gpa, std.testing.io, .{ .package = "zg_test" });
    b.opts.min_time_ns = 500_000;
    b.opts.warmup_ns = 100_000;
    defer b.deinit();
    try b.run("fast", {}, fakeFast);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try b.writeJson(&out.writer);
    const Doc = struct { schema: u32, package: []const u8, zig: []const u8, target: []const u8, optimize: []const u8, cpu: []const u8, quick: bool, results: []const Result };
    const parsed = try std.json.parseFromSlice(Doc, gpa, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1), parsed.value.schema);
    try std.testing.expectEqualStrings("zg_test", parsed.value.package);
    try std.testing.expectEqualStrings("fast", parsed.value.results[0].name);
}

test "bench: filter skips non-matching names" {
    var b = Bench.init(std.testing.allocator, std.testing.io, .{ .filter = "keep" });
    defer b.deinit();
    b.opts.min_time_ns = 100_000;
    b.opts.warmup_ns = 10_000;
    try b.run("skip-me", {}, fakeFast);
    try b.run("keep-me", {}, fakeFast);
    try std.testing.expectEqual(@as(usize, 1), b.results.items.len);
}
