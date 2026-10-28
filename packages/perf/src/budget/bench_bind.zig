//! Reads E00 bench JSON files (`docs/bench-format.md`, schema 1) and binds
//! their results to the budgets whose source names them.

const std = @import("std");
const schema = @import("schema.zig");
const registry = @import("registry.zig");
const check = @import("check.zig");

/// One bench JSON document.
pub const BenchFile = struct {
    schema: u32,
    package: []const u8,
    zig: []const u8,
    target: []const u8,
    optimize: []const u8,
    cpu: ?[]const u8 = null,
    quick: bool = false,
    results: []const BenchResult,
};

/// One bench result. `samples_ns` (per-sample ns/op, up to 64) is an
/// optional addition to schema 1 that perfgate uses when present.
pub const BenchResult = struct {
    name: []const u8,
    iters: u64,
    ns_per_op: f64,
    p50_ns: f64,
    p99_ns: f64,
    bytes_per_op: ?f64 = null,
    allocs_per_op: f64,
    bytes_alloc_per_op: f64,
    samples_ns: ?[]const f64 = null,
};

/// Parses a bench file into `arena`; unknown fields are ignored so later
/// schema additions keep parsing.
pub fn parseBenchFile(arena: std.mem.Allocator, bytes: []const u8) !BenchFile {
    return std.json.parseFromSliceLeaky(BenchFile, arena, bytes, .{ .ignore_unknown_fields = true });
}

/// The value of `field` in `r`, or null when it cannot be derived.
pub fn extract(r: *const BenchResult, field: schema.BenchField) ?f64 {
    return switch (field) {
        .ns_per_op => r.ns_per_op,
        .p50_ns => r.p50_ns,
        .p99_ns => r.p99_ns,
        .bytes_per_op => r.bytes_per_op,
        .allocs_per_op => r.allocs_per_op,
        .bytes_alloc_per_op => r.bytes_alloc_per_op,
        .throughput_bps => if (r.bytes_per_op) |bytes| (if (r.ns_per_op > 0) bytes / r.ns_per_op * 1e9 else null) else null,
    };
}

/// The result named `name` in `f`, or null.
pub fn find(f: *const BenchFile, name: []const u8) ?*const BenchResult {
    for (f.results) |*r| if (std.mem.eql(u8, r.name, name)) return r;
    return null;
}

/// A budget bound to `f.package` whose bench is not in the file.
pub const Missing = struct { budget: *const schema.Budget };

/// Evaluates every registry budget whose bench suite is `f.package` and
/// whose result is present, appending to `out`. Budgets whose result is
/// absent are appended to `missing` when it is non-null.
pub fn evaluateBenchFile(f: *const BenchFile, machine_scale: f64, out: *std.ArrayList(check.Evaluation), gpa: std.mem.Allocator) !void {
    return evaluateBenchFileIn(registry.all, f, machine_scale, out, null, gpa);
}

/// `evaluateBenchFile` over an explicit budget list, reporting missing
/// benches.
pub fn evaluateBenchFileIn(
    budgets: []const schema.Budget,
    f: *const BenchFile,
    machine_scale: f64,
    out: *std.ArrayList(check.Evaluation),
    missing: ?*std.ArrayList(Missing),
    gpa: std.mem.Allocator,
) !void {
    // Bench binaries are always ReleaseFast, so no build-mode scaling.
    for (budgets) |*b| switch (b.source) {
        .bench => |s| {
            if (!std.mem.eql(u8, s.suite, f.package)) continue;
            const r = find(f, s.name) orelse {
                if (missing) |m| try m.append(gpa, .{ .budget = b });
                continue;
            };
            const v = extract(r, s.field) orelse continue;
            try out.append(gpa, check.evaluateScaled(b, v, machine_scale, 1.0));
        },
        else => {},
    };
}

const fixture_json = @embedFile("../testdata/bench_core.json");

test "bind: parse E00 schema fixture" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const f = try parseBenchFile(arena.allocator(), fixture_json);
    try std.testing.expectEqual(@as(u32, 1), f.schema);
    try std.testing.expectEqualStrings("zg_core", f.package);
    try std.testing.expectEqual(@as(usize, 3), f.results.len);
    try std.testing.expectEqual(@as(?f64, 79.7), extract(&f.results[0], .p99_ns));
    // 1 MiB in 100 us = 10.49 GB/s.
    const tp = extract(&f.results[1], .throughput_bps).?;
    try std.testing.expectApproxEqRel(@as(f64, 1048576.0 / 100000.0 * 1e9), tp, 1e-9);
    try std.testing.expectEqual(@as(?f64, null), extract(&f.results[0], .throughput_bps));
}

test "bind: unknown fields ignored" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"schema":1,"package":"p","zig":"0.16.0","target":"x86_64-linux","optimize":"ReleaseFast","future":{"x":1},
        \\ "results":[{"name":"a","iters":1,"ns_per_op":1,"p50_ns":1,"p99_ns":2,"allocs_per_op":0,"bytes_alloc_per_op":0,"new_field":3}]}
    ;
    const f = try parseBenchFile(arena.allocator(), json);
    try std.testing.expectEqualStrings("a", f.results[0].name);
    try std.testing.expectEqual(@as(?[]const u8, null), f.cpu);
}

test "bind: missing bench reported" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = std.testing.allocator;
    const f = try parseBenchFile(arena.allocator(), fixture_json);
    const budgets = [_]schema.Budget{
        .{ .id = "core.mailbox", .owner = "E00", .spec = "E00", .metric = .duration_ns, .stat = .p99, .limit = 1000, .source = .{ .bench = .{ .suite = "zg_core", .name = "mailbox post+drain (1 producer)", .field = .p99_ns } } },
        .{ .id = "core.gone", .owner = "E00", .spec = "E00", .metric = .duration_ns, .stat = .p99, .limit = 1000, .source = .{ .bench = .{ .suite = "zg_core", .name = "not here", .field = .p99_ns } } },
        .{ .id = "other.pkg", .owner = "E00", .spec = "E00", .metric = .duration_ns, .stat = .p99, .limit = 1, .source = .{ .bench = .{ .suite = "zg_net", .name = "x", .field = .p99_ns } } },
    };
    var out: std.ArrayList(check.Evaluation) = .empty;
    defer out.deinit(gpa);
    var missing: std.ArrayList(Missing) = .empty;
    defer missing.deinit(gpa);
    try evaluateBenchFileIn(&budgets, &f, 1, &out, &missing, gpa);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(check.Verdict.pass, out.items[0].verdict);
    try std.testing.expectEqual(@as(usize, 1), missing.items.len);
    try std.testing.expectEqualStrings("core.gone", missing.items[0].budget.id);
    // The real registry binds the mailbox budget too.
    out.clearRetainingCapacity();
    try evaluateBenchFile(&f, 1, &out, gpa);
    try std.testing.expect(out.items.len >= 1);
}

test "bind: samples_ns optional" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const f = try parseBenchFile(arena.allocator(), fixture_json);
    try std.testing.expectEqual(@as(?[]const f64, null), f.results[0].samples_ns);
    try std.testing.expectEqual(@as(usize, 4), f.results[2].samples_ns.?.len);
}
