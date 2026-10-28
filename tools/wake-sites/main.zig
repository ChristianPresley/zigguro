//! wake-sites (E14.F05.S02.T01): keeps blocking waits annotated with
//! `zg_perf.idle.noteWake`, so the idle monitor can say who woke the
//! process. Run from the repository root (`zig build test-wake-sites`):
//!
//!   wake-sites [--write-baseline]
//!
//! Scans packages/**/*.zig (tests, testdata and testing helpers left out)
//! for the wait calls in `patterns`. A wait is annotated when `noteWake(`
//! appears on its line or within the `window` lines after it. Files that
//! predate the check keep their unannotated count in tools/wake-sites/
//! baseline.txt; the check fails when a file goes over its count, and
//! says when a count can come down. Std only.

const std = @import("std");

/// Calls that block until something wakes the thread.
pub const patterns = [_][]const u8{
    "waitEvents(",
    ".wait(io",
    "futexWait",
    "io.sleep(",
    "Event.wait",
    "Condition.wait",
    "Futex.wait",
};

/// Lines after a wait that may hold its `noteWake`.
pub const window = 5;

pub const baseline_path = "tools/wake-sites/baseline.txt";

/// The 1-based lines of unannotated waits in `src`.
pub fn unannotated(gpa: std.mem.Allocator, src: []const u8) ![]u32 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |l| try lines.append(gpa, l);

    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(gpa);
    // Brace depth at which the current test block ends (null: not in one).
    var test_end: ?usize = null;
    var depth: usize = 0;
    for (lines.items, 0..) |raw, i| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const code = if (std.mem.indexOf(u8, line, "//")) |c| line[0..c] else line;
        if (test_end == null and std.mem.startsWith(u8, line, "test ") and std.mem.endsWith(u8, code, "{")) test_end = depth;
        defer {
            for (code) |ch| switch (ch) {
                '{' => depth += 1,
                '}' => depth -|= 1,
                else => {},
            };
            if (test_end) |d| if (depth <= d and i > 0 and std.mem.indexOfScalar(u8, code, '}') != null) {
                test_end = null;
            };
        }
        if (test_end != null) continue;
        if (!isWait(code)) continue;
        const last = @min(lines.items.len, i + 1 + window);
        const annotated = for (lines.items[i..last]) |l| {
            if (std.mem.indexOf(u8, l, "noteWake(") != null) break true;
        } else false;
        if (!annotated) try out.append(gpa, @intCast(i + 1));
    }
    return out.toOwnedSlice(gpa);
}

fn isWait(code: []const u8) bool {
    // Declarations and string literals are not calls.
    if (std.mem.indexOf(u8, code, "fn ") != null) return false;
    for (patterns) |p| if (std.mem.indexOf(u8, code, p)) |at| {
        if (std.mem.count(u8, code[0..at], "\"") % 2 == 0) return true;
    };
    return false;
}

/// Whether `path` (relative to packages/) is test-only code.
pub fn skipped(path: []const u8) bool {
    if (std.mem.endsWith(u8, path, "_test.zig")) return true;
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |p| {
        for ([_][]const u8{ "testdata", "testing", "tests", "test", "fixtures", "bench" }) |s| if (std.mem.eql(u8, p, s)) return true;
    }
    return false;
}

/// Parses `count path` lines (`#` starts a comment).
pub fn parseBaseline(gpa: std.mem.Allocator, text: []const u8) !std.StringHashMapUnmanaged(u32) {
    var m: std.StringHashMapUnmanaged(u32) = .empty;
    errdefer m.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return error.BadBaseline;
        const n = std.fmt.parseInt(u32, line[0..sp], 10) catch return error.BadBaseline;
        try m.put(gpa, std.mem.trim(u8, line[sp + 1 ..], " "), n);
    }
    return m;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    const write = args.len > 1 and std.mem.eql(u8, args[1], "--write-baseline");
    const cwd = std.Io.Dir.cwd();

    var pkgs = try cwd.openDir(io, "packages", .{ .iterate = true });
    defer pkgs.close(io);
    var walker = try pkgs.walk(gpa);
    defer walker.deinit();
    var files: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.basename, ".zig") or skipped(e.path)) continue;
        try files.append(gpa, try gpa.dupe(u8, e.path));
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    const base_text = cwd.readFileAlloc(io, baseline_path, gpa, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return e,
    };
    const base = try parseBaseline(gpa, base_text);

    var out: std.Io.Writer.Allocating = .init(gpa);
    try out.writer.writeAll("# Unannotated waits per file (wake-sites, E14.F05.S02.T01).\n# Owners annotate them with zg_perf.idle.noteWake and lower the count.\n");
    var failed = false;
    for (files.items) |f| {
        const text = try pkgs.readFileAlloc(io, f, gpa, .limited(16 << 20));
        const bad = try unannotated(gpa, text);
        const path = try std.mem.replaceOwned(u8, gpa, f, "\\", "/");
        if (bad.len > 0) try out.writer.print("{d} packages/{s}\n", .{ bad.len, path });
        const allowed = base.get(try std.fmt.allocPrint(gpa, "packages/{s}", .{path})) orelse 0;
        if (write) continue;
        if (bad.len > allowed) {
            failed = true;
            for (bad) |l| std.debug.print("packages/{s}:{d}: wait without zg_perf.idle.noteWake within {d} lines (baseline {d}, found {d})\n", .{ path, l, window, allowed, bad.len });
        } else if (bad.len < allowed) {
            std.debug.print("wake-sites: packages/{s} has {d} unannotated waits, {s} allows {d}; lower it\n", .{ path, bad.len, baseline_path, allowed });
        }
    }
    if (write) {
        try cwd.writeFile(io, .{ .sub_path = baseline_path, .data = out.written() });
        return 0;
    }
    if (failed) std.debug.print("wake-sites: annotate new waits (docs/perf/threading.md, \"Idle\")\n", .{});
    return if (failed) 1 else 0;
}

test "wake-sites: finds unannotated waits outside tests" {
    const src =
        \\fn run(io: std.Io) void {
        \\    io.futexWait(u32, &x, 0);
        \\    noteWake("a", .signal);
        \\    h.platform.waitEvents(null);
        \\    const s = "io.sleep(";
        \\    // io.sleep( in a comment
        \\}
        \\pub fn waitEvents(p: *P) void {}
        \\test "x" {
        \\    try io.sleep(.fromMilliseconds(1), .awake);
        \\}
        \\fn after(io: std.Io) void {
        \\    try io.sleep(.fromMilliseconds(1), .awake);
        \\}
    ;
    const bad = try unannotated(std.testing.allocator, src);
    defer std.testing.allocator.free(bad);
    try std.testing.expectEqualSlices(u32, &.{ 4, 13 }, bad);
}

test "wake-sites: window and skipped paths" {
    const src = "cond.wait(io, &m);\n\n\n\n\nnoteWake(\"x\", .signal);\ncond.wait(io, &m);\n\n\n\n\n\nnoteWake(\"y\", .signal);\n";
    const bad = try unannotated(std.testing.allocator, src);
    defer std.testing.allocator.free(bad);
    try std.testing.expectEqualSlices(u32, &.{7}, bad);
    try std.testing.expect(skipped("lsp/testdata/fake_server.zig"));
    try std.testing.expect(skipped("platform/src/testing/conformance.zig"));
    try std.testing.expect(!skipped("gui/src/host.zig"));
}

test "wake-sites: baseline parse" {
    var m = try parseBaseline(std.testing.allocator, "# c\n3 packages/a.zig\n\n1 packages/b c.zig\n");
    defer m.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 3), m.get("packages/a.zig").?);
    try std.testing.expectEqual(@as(u32, 1), m.get("packages/b c.zig").?);
    try std.testing.expectError(error.BadBaseline, parseBaseline(std.testing.allocator, "x y\n"));
}
