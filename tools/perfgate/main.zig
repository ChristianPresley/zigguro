//! perfgate (E14.F06.S02.T01): compares bench results of a PR head
//! against its base and gates on regressions and budgets.
//!
//!   perfgate merge --out FILE INPUT...
//!   perfgate compare --base FILE --head FILE [--baseline DIR]
//!            [--machine CLASS] [--calibration FILE] [--accepted]
//!            [--changed-baselines FILE] [--json FILE] [--markdown FILE]
//!            [--base-ref REF] [--head-ref REF]
//!   perfgate baseline --from FILE --machine CLASS --out DIR
//!   perfgate list-gated
//!   perfgate calibrate [--reference FILE] [--out FILE] [--kernel-ms N]
//!   perfgate env
//!
//! Inputs are E00 bench files or merged sets. `--calibration` is a JSON
//! `{"scale": x}`; `--changed-baselines` lists the PR's changed paths one
//! per line. `calibrate` runs the four calibration kernels (build it
//! optimized: `zig build perf-calibrate`) and writes the scale against the
//! reference file; its output also serves as a new reference. `env` prints
//! the captured environment and its variance warnings. Exit status: 0
//! pass, 1 blocking rows, 2 usage or input errors. See
//! perf/baselines/README.md.

const std = @import("std");
const zg_perf = @import("zg_perf");
const stats = @import("stats.zig");
const baseline = @import("baseline.zig");
const compare = @import("compare.zig");
const summary = @import("summary.zig");

test {
    _ = stats;
    _ = baseline;
    _ = compare;
    _ = summary;
}

const max_input = 256 << 20;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buf);
    const w = &out.interface;
    defer w.flush() catch {};
    if (args.len < 2) return usage();
    const cmd = args[1];
    const rest = args[2..];
    const r = if (std.mem.eql(u8, cmd, "merge"))
        cmdMerge(arena, io, rest)
    else if (std.mem.eql(u8, cmd, "compare"))
        cmdCompare(arena, io, w, rest)
    else if (std.mem.eql(u8, cmd, "baseline"))
        cmdBaseline(arena, io, rest)
    else if (std.mem.eql(u8, cmd, "list-gated"))
        cmdListGated(w)
    else if (std.mem.eql(u8, cmd, "calibrate"))
        cmdCalibrate(arena, io, w, rest)
    else if (std.mem.eql(u8, cmd, "env"))
        cmdEnv(arena, io, w)
    else
        return usage();
    return r catch |e| {
        std.log.err("perfgate {s}: {t}", .{ cmd, e });
        return 2;
    };
}

fn usage() u8 {
    std.log.err("usage: perfgate merge|compare|baseline|list-gated|calibrate|env ... (see tools/perfgate/main.zig)", .{});
    return 2;
}

/// `--name value` lookup over `args`.
fn opt(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args, 0..) |a, i| if (std.mem.eql(u8, a, name) and i + 1 < args.len) return args[i + 1];
    return null;
}

fn flag(args: []const []const u8, name: []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, name)) return true;
    return false;
}

fn readSet(arena: std.mem.Allocator, io: std.Io, path: []const u8) !baseline.Set {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_input));
    return baseline.merge(arena, try baseline.parseAny(arena, bytes));
}

fn writeOut(io: std.Io, path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn cmdMerge(arena: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    const out_path = opt(args, "--out") orelse return usage();
    var files: std.ArrayList(baseline.BenchFile) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out")) {
            i += 1;
            continue;
        }
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, args[i], arena, .limited(max_input));
        try files.appendSlice(arena, try baseline.parseAny(arena, bytes));
    }
    if (files.items.len == 0) return usage();
    const set = try baseline.merge(arena, files.items);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(set, .{ .emit_null_optional_fields = false }, &aw.writer);
    try aw.writer.writeAll("\n");
    try writeOut(io, out_path, aw.written());
    return 0;
}

fn parseMachine(s: []const u8) !zg_perf.budget.schema.MachineClass {
    return std.meta.stringToEnum(zg_perf.budget.schema.MachineClass, s) orelse error.UnknownMachineClass;
}

fn cmdCompare(arena: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, args: []const []const u8) !u8 {
    const base = try readSet(arena, io, opt(args, "--base") orelse return usage());
    const head = try readSet(arena, io, opt(args, "--head") orelse return usage());
    const machine_name = opt(args, "--machine") orelse "ci_linux_x64";
    var opts: compare.Options = .{ .machine = try parseMachine(machine_name), .accepted = flag(args, "--accepted") };
    if (opt(args, "--calibration")) |p| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(1 << 20));
        opts.scale = (try std.json.parseFromSliceLeaky(struct { scale: f64 }, arena, bytes, .{ .ignore_unknown_fields = true })).scale;
    }
    if (opt(args, "--baseline")) |d| opts.baselines = try baseline.readDir(arena, io, d);
    if (opt(args, "--changed-baselines")) |p| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(16 << 20));
        var list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, bytes, "\r\n");
        while (it.next()) |line| try list.append(arena, line);
        opts.changed_baselines = list.items;
    }
    const rows = try compare.compare(arena, base, head, opts);
    const zig = if (head.files.len > 0) head.files[0].zig else "";
    const md = try summary.render(arena, rows, .{
        .machine = machine_name,
        .scale = opts.scale,
        .base_ref = opt(args, "--base-ref") orelse "",
        .head_ref = opt(args, "--head-ref") orelse "",
        .zig = zig,
    }, summary.max_bytes);
    if (opt(args, "--markdown")) |p| try writeOut(io, p, md) else try w.writeAll(md);
    if (opt(args, "--json")) |p| {
        var aw: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(.{ .schema = @as(u32, 1), .machine = machine_name, .scale = opts.scale, .blocking = compare.blockingCount(rows), .rows = rows }, .{ .whitespace = .indent_2 }, &aw.writer);
        try aw.writer.writeAll("\n");
        try writeOut(io, p, aw.written());
    }
    return if (compare.blockingCount(rows) > 0) 1 else 0;
}

fn cmdBaseline(arena: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    const set = try readSet(arena, io, opt(args, "--from") orelse return usage());
    const machine = opt(args, "--machine") orelse return usage();
    _ = try parseMachine(machine);
    const out_path = opt(args, "--out") orelse return usage();
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, out_path);
    var dir = try cwd.openDir(io, out_path, .{});
    defer dir.close(io);
    try baseline.writeAll(io, dir, try baseline.fromSet(arena, set, machine), arena);
    return 0;
}

/// Prints the bench-bound budgets and their gate, blocking ones first.
fn cmdListGated(w: *std.Io.Writer) !u8 {
    inline for (.{ .block, .warn, .track }) |gate| {
        for (zg_perf.budget.all) |b| if (b.gate == gate) switch (b.source) {
            .bench => |s| try w.print("{t}\t{s}\t{s}/{s}\t{t}\n", .{ b.gate, b.id, s.suite, s.name, b.machine }),
            else => {},
        };
    }
    return 0;
}

fn cmdCalibrate(arena: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, args: []const []const u8) !u8 {
    const cal = zg_perf.scenario.calibrate;
    var opts: cal.Options = .{};
    if (opt(args, "--kernel-ms")) |v| opts.kernel_ns = try std.fmt.parseInt(u64, v, 10) * std.time.ns_per_ms;
    if (opt(args, "--reference")) |p| {
        if (std.Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(1 << 20))) |bytes| {
            opts.reference = try cal.parseReference(arena, bytes);
        } else |e| std.log.warn("calibrate: no reference ({s}: {t}); scale stays 1", .{ p, e });
    }
    const env = try zg_perf.scenario.captureEnv(io, arena);
    _ = try zg_perf.scenario.env.warnings(env, w);
    const st = zg_perf.scenario.stabilize(.{});
    try w.writeAll("calibrate: ");
    try st.describe(w);
    try w.flush();
    const c = try cal.calibrateWith(io, std.heap.smp_allocator, opts);
    try w.print("calibrate: scale {d:.3} (int_alu {d:.3} ns/op, mem_bw {d:.2} ms/64 MiB, branchy {d:.2} ns/op, alloc {d:.2} ns/op)\n", .{ c.scale, c.ns_per_op.int_alu, c.ns_per_op.mem_bw / 1e6, c.ns_per_op.branchy, c.ns_per_op.alloc });
    var aw: std.Io.Writer.Allocating = .init(arena);
    try cal.writeJson(c, &aw.writer);
    if (opt(args, "--out")) |p| try writeOut(io, p, aw.written()) else try w.writeAll(aw.written());
    return 0;
}

fn cmdEnv(arena: std.mem.Allocator, io: std.Io, w: *std.Io.Writer) !u8 {
    const env = try zg_perf.scenario.captureEnv(io, arena);
    try std.json.Stringify.value(env, .{ .whitespace = .indent_2 }, w);
    try w.writeAll("\n");
    _ = try zg_perf.scenario.env.warnings(env, w);
    return 0;
}
