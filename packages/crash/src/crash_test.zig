//! End-to-end crash capture tests (Linux): spawn `test/crasher.zig` in
//! ReleaseFast and ReleaseSafe for every crash kind and check the report.

const std = @import("std");
const builtin = @import("builtin");
const format = @import("format.zig");
const annotations = @import("annotations.zig");
const lx = @import("linux.zig");
const test_exes = @import("zg_test_exes");

const testing = std.testing;
const SIG = std.posix.SIG;

const Expect = struct {
    kind: []const u8,
    /// Expected report kind and terminating signal; null skips the case.
    fast: ?struct { format.ReportKind, SIG },
    safe: ?struct { format.ReportKind, SIG },
    /// The trace must contain an address inside the crasher image.
    trace_in_image: bool = true,
};

const is_x86 = builtin.cpu.arch == .x86_64;
const trap_case: struct { format.ReportKind, SIG } = if (is_x86) .{ .illegal_instruction, .ILL } else .{ .trap, .TRAP };

const cases = [_]Expect{
    .{ .kind = "null_deref", .fast = .{ .segfault, .SEGV }, .safe = .{ .segfault, .SEGV } },
    .{ .kind = "stack_overflow", .fast = .{ .stack_overflow, .SEGV }, .safe = .{ .stack_overflow, .SEGV }, .trace_in_image = false },
    .{ .kind = "panic", .fast = .{ .panic, .ABRT }, .safe = .{ .panic, .ABRT } },
    .{ .kind = "unreachable", .fast = trap_case, .safe = .{ .panic, .ABRT } },
    .{ .kind = "ill", .fast = trap_case, .safe = trap_case },
    .{ .kind = "breakpoint", .fast = .{ .trap, .TRAP }, .safe = .{ .trap, .TRAP } },
    .{ .kind = "abort", .fast = .{ .abort, .ABRT }, .safe = .{ .abort, .ABRT } },
    // aarch64 integer division does not trap.
    .{ .kind = "div_by_zero", .fast = if (is_x86) .{ .arithmetic, .FPE } else null, .safe = .{ .panic, .ABRT } },
    .{ .kind = "sigsys", .fast = .{ .bad_syscall, .SYS }, .safe = .{ .bad_syscall, .SYS }, .trace_in_image = false },
    .{ .kind = "two_threads", .fast = .{ .segfault, .SEGV }, .safe = .{ .segfault, .SEGV } },
};

fn runCase(gpa: std.mem.Allocator, exe: []const u8, case: Expect, want: struct { format.ReportKind, SIG }) !i64 {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const state = path_buf[0..n];

    var arg_buf: [64]u8 = undefined;
    const crash_arg = try std.fmt.bufPrint(&arg_buf, "--crash={s}", .{case.kind});
    const t0 = std.Io.Clock.awake.now(io);
    var child = try std.process.spawn(io, .{
        .argv = &.{ exe, "--state-dir", state, crash_arg },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    const elapsed_ms = t0.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    errdefer std.debug.print("crasher {s} --crash={s}: term {any}\n", .{ std.fs.path.basename(exe), case.kind, term });
    try testing.expectEqual(std.process.Child.Term{ .signal = want[1] }, term);

    var crashes = try tmp.dir.openDir(io, "crashes", .{ .iterate = true });
    defer crashes.close(io);
    var report_name: ?[]u8 = null;
    defer if (report_name) |r| gpa.free(r);
    var dit = crashes.iterate();
    while (try dit.next(io)) |e| {
        try testing.expect(std.mem.endsWith(u8, e.name, ".zgcrash"));
        try testing.expect(report_name == null);
        report_name = try gpa.dupe(u8, e.name);
    }
    const bytes = try crashes.readFileAlloc(io, report_name orelse return error.NoReport, gpa, .limited(4 << 20));
    defer gpa.free(bytes);

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_abs = exe_buf[0..try std.Io.Dir.cwd().realPathFile(io, exe, &exe_buf)];

    var r = try format.Reader.init(bytes);
    var exc: ?format.Exception = null;
    var trace: ?format.Trace = null;
    var crasher_mod: ?format.Module = null;
    var have_threads = false;
    var have_annotations = false;
    while (r.next()) |s| switch (s.kind) {
        .exception => exc = format.decodeException(s.data),
        .trace => trace = format.decodeTrace(s.data),
        .modules => {
            var mit = format.ModuleIterator.init(s.data);
            while (mit.next()) |m| {
                if (std.mem.eql(u8, m.path, exe_abs)) crasher_mod = m;
            }
        },
        .threads => have_threads = true,
        .annotations => {
            var pairs: [annotations.max_keys]annotations.Pair = undefined;
            const np = annotations.decode(s.data, &pairs);
            for (pairs[0..np]) |p| {
                if (std.mem.eql(u8, p.key, "ui.view") and std.mem.eql(u8, p.value, "crasher")) have_annotations = true;
            }
        },
        else => {},
    };
    try testing.expect(!r.truncated);
    try testing.expectEqual(@intFromEnum(want[0]), exc.?.kind);
    try testing.expect(have_threads and have_annotations);

    const m = crasher_mod orelse return error.CrasherModuleMissing;
    const file = try std.Io.Dir.cwd().readFileAlloc(io, exe, gpa, .limited(256 << 20));
    defer gpa.free(file);
    try testing.expectEqual(format.ModuleIdKind.gnu_build_id, m.id_kind);
    try testing.expectEqualSlices(u8, lx.buildIdFromFile(file).?, m.id);

    const t = trace.?;
    try testing.expect(t.count > 0);
    if (case.trace_in_image) {
        var found = false;
        for (0..t.count) |i| {
            const a = t.at(i);
            if (a >= m.base and a < m.base + m.size) found = true;
        }
        try testing.expect(found);
    }

    // boot_pending=1 writes the boot marker with the version.
    const marker = try tmp.dir.readFileAlloc(io, "update/boot-crashed", gpa, .limited(256));
    defer gpa.free(marker);
    try testing.expect(marker.len > 0);
    return elapsed_ms;
}

test "crash: every kind writes one complete report (ReleaseFast and ReleaseSafe)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var times: [cases.len * 2]i64 = undefined;
    var nt: usize = 0;
    for (cases) |case| {
        if (case.fast) |w| {
            times[nt] = try runCase(gpa, test_exes.crasher_fast, case, w);
            nt += 1;
        }
        if (case.safe) |w| {
            times[nt] = try runCase(gpa, test_exes.crasher_safe, case, w);
            nt += 1;
        }
    }
    // Spawn to exit, which bounds the report write time.
    std.mem.sort(i64, times[0..nt], {}, std.sort.asc(i64));
    const p95 = times[@min(nt - 1, (nt * 95) / 100)];
    try testing.expect(p95 < 1000);
}
