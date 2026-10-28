//! Tasks from the workspace's `zig build` steps (`zig build -l`): one
//! process task per step with the `$zig` matcher, `install` the default
//! build task and `test` the default test task, a `check` step tagged
//! `check`, and a `zig build --watch` background task (`$zig-watch`,
//! tagged `watch`). Listing the steps runs `build.zig`, so the caller only
//! does it in a trusted workspace.

const std = @import("std");
const Task = @import("../Task.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Step = struct {
    name: []const u8,
    description: []const u8,
    default: bool = false,
};

/// `zig build -l` output: one step per line, its name padded, then its
/// description; the default step says `(default)` after its name. The
/// same format zg_codeintel's ZLS setup reads. Slices point into `text`.
pub fn parseSteps(arena: Allocator, text: []const u8) Allocator.Error![]Step {
    var out: std.ArrayList(Step) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const name_end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
        var rest = std.mem.trimStart(u8, line[name_end..], " \t");
        var default = false;
        if (std.mem.startsWith(u8, rest, "(default)")) {
            default = true;
            rest = std.mem.trimStart(u8, rest["(default)".len..], " \t");
        }
        try out.append(arena, .{ .name = line[0..name_end], .description = rest, .default = default });
    }
    return out.items;
}

const zig_matcher: []const Task.MatcherRef = &.{.{ .named = "$zig" }};
const watch_matcher: []const Task.MatcherRef = &.{.{ .named = "$zig-watch" }};

/// Appends the tasks for `steps`, run with `zig_exe`.
pub fn appendTasks(arena: Allocator, steps: []const Step, zig_exe: []const u8, out: *std.ArrayList(Task)) Allocator.Error!void {
    if (steps.len == 0) return;
    var has_install = false;
    for (steps) |s| {
        if (std.mem.eql(u8, s.name, "install")) has_install = true;
    }
    for (steps) |s| {
        const args = try arena.alloc([]const u8, 2);
        args[0] = "build";
        args[1] = s.name;
        var t: Task = .{
            .label = try std.fmt.allocPrint(arena, "zig build {s}", .{s.name}),
            .source = .zig,
            .command = zig_exe,
            .args = args,
            .problem_matchers = zig_matcher,
            .detail = if (s.description.len > 0) s.description else null,
        };
        const default_build = if (has_install) std.mem.eql(u8, s.name, "install") else s.default;
        if (default_build) {
            t.group = .{ .kind = .build, .is_default = true };
        } else if (std.mem.eql(u8, s.name, "test")) {
            t.group = .{ .kind = .@"test", .is_default = true };
        }
        if (std.mem.eql(u8, s.name, "check")) t.tags = &.{"check"};
        try out.append(arena, t);
    }
    try out.append(arena, .{
        .label = "zig build --watch",
        .source = .zig,
        .command = zig_exe,
        .args = &.{ "build", "--watch" },
        .is_background = true,
        .problem_matchers = watch_matcher,
        .tags = &.{"watch"},
        .detail = "Rebuild the default step on every change",
    });
}

/// Runs `zig build -l` in `build_root` (10 s at most; it may fetch lazy
/// dependencies) and returns its output, owned by `gpa`. Null when it
/// fails.
pub fn listSteps(gpa: Allocator, io: Io, zig_exe: []const u8, build_root: []const u8, env: ?*const std.process.Environ.Map) ?[]u8 {
    const r = std.process.run(gpa, io, .{
        .argv = &.{ zig_exe, "build", "-l" },
        .cwd = .{ .path = build_root },
        .environ_map = env,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    }) catch return null;
    gpa.free(r.stderr);
    switch (r.term) {
        .exited => |c| if (c == 0) return r.stdout,
        else => {},
    }
    gpa.free(r.stdout);
    return null;
}
