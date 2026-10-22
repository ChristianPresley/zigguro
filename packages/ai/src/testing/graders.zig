//! Graders for the evaluation runner (E10.F10.S02.T02): each one checks
//! one fact about a finished scenario, from the workspace it left behind
//! or from the stream-json transcript of the run.

const std = @import("std");
const zg_regex = @import("zg_regex");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Grader = union(enum) {
    /// The file (relative to the workspace) contains `needle`.
    file_contains: struct { path: []const u8, needle: []const u8 },
    /// The file still has its fixture content (or is still missing).
    file_unchanged: []const u8,
    /// The command exits 0 in the workspace within 60 s.
    command_succeeds: struct { argv: []const []const u8 },
    tool_used: []const u8,
    tool_not_used: []const u8,
    /// At most this many model calls.
    max_turns: u32,
    max_cost_usd: f64,
    /// A `zg_regex` pattern searched in the final answer.
    final_text_matches: []const u8,
    no_permission_denials: void,
};

/// What a run produced, for the graders.
pub const Facts = struct {
    /// The scenario's workspace (absolute).
    workspace: []const u8,
    /// The pristine fixture it was copied from.
    fixture: []const u8,
    /// Replaces a `zig` argv[0] in `command_succeeds`.
    zig_exe: ?[]const u8 = null,
    /// The commands' environment; null inherits.
    environ: ?*const std.process.Environ.Map = null,
    tools_used: []const []const u8 = &.{},
    turns: u32 = 0,
    cost_usd: f64 = 0,
    denials: u32 = 0,
    final_text: []const u8 = "",
};

pub const Verdict = struct {
    ok: bool,
    /// Why it failed, or what was checked.
    detail: []const u8,
};

pub const command_timeout_s = 60;

/// Runs one grader. Details are allocated in `arena`.
pub fn grade(io: Io, arena: Allocator, g: Grader, f: *const Facts) Allocator.Error!Verdict {
    switch (g) {
        .file_contains => |fc| {
            const text = readIn(io, arena, f.workspace, fc.path) orelse
                return fail(arena, "{s} does not exist", .{fc.path});
            if (std.mem.indexOf(u8, text, fc.needle) == null) return fail(arena, "{s} does not contain \"{s}\"", .{ fc.path, fc.needle });
            return pass(arena, "{s} contains \"{s}\"", .{ fc.path, fc.needle });
        },
        .file_unchanged => |path| {
            const before = readIn(io, arena, f.fixture, path);
            const after = readIn(io, arena, f.workspace, path);
            const same = if (before) |b| (if (after) |x| std.mem.eql(u8, b, x) else false) else after == null;
            if (!same) return fail(arena, "{s} changed", .{path});
            return pass(arena, "{s} unchanged", .{path});
        },
        .command_succeeds => |c| {
            const joined = try std.mem.join(arena, " ", c.argv);
            var argv = c.argv;
            if (f.zig_exe) |z| if (argv.len > 0 and std.mem.eql(u8, argv[0], "zig")) {
                const v = try arena.dupe([]const u8, argv);
                v[0] = z;
                argv = v;
            };
            const r = std.process.run(arena, io, .{
                .argv = argv,
                .cwd = .{ .path = f.workspace },
                .environ_map = f.environ,
                .stdout_limit = .limited(1 << 20),
                .stderr_limit = .limited(1 << 20),
                .timeout = .{ .duration = .{ .raw = .fromSeconds(command_timeout_s), .clock = .awake } },
            }) catch |e| return fail(arena, "{s}: {s}", .{ joined, @errorName(e) });
            switch (r.term) {
                .exited => |code| if (code == 0) return pass(arena, "{s} exited 0", .{joined}) else {
                    const tail = r.stderr[r.stderr.len -| 400..];
                    return fail(arena, "{s} exited {d}: {s}", .{ joined, code, tail });
                },
                else => return fail(arena, "{s} did not exit normally", .{joined}),
            }
        },
        .tool_used => |name| {
            if (used(f, name)) return pass(arena, "{s} used", .{name});
            return fail(arena, "{s} not used", .{name});
        },
        .tool_not_used => |name| {
            if (used(f, name)) return fail(arena, "{s} used", .{name});
            return pass(arena, "{s} not used", .{name});
        },
        .max_turns => |n| {
            if (f.turns > n) return fail(arena, "{d} turns > {d}", .{ f.turns, n });
            return pass(arena, "{d} turns <= {d}", .{ f.turns, n });
        },
        .max_cost_usd => |x| {
            if (f.cost_usd > x) return fail(arena, "${d:.4} > ${d:.4}", .{ f.cost_usd, x });
            return pass(arena, "${d:.4} <= ${d:.4}", .{ f.cost_usd, x });
        },
        .final_text_matches => |pattern| {
            var re = zg_regex.Regex.compile(arena, pattern, .{}) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return fail(arena, "bad pattern /{s}/: {s}", .{ pattern, @errorName(e) }),
            };
            var cache = try re.newCache(arena);
            if (!re.isMatch(&cache, .fromSlice(f.final_text))) return fail(arena, "final text does not match /{s}/", .{pattern});
            return pass(arena, "final text matches /{s}/", .{pattern});
        },
        .no_permission_denials => {
            if (f.denials > 0) return fail(arena, "{d} permission denials", .{f.denials});
            return pass(arena, "no permission denials", .{});
        },
    }
}

/// A short label for reports: the tag and its main argument.
pub fn label(arena: Allocator, g: Grader) Allocator.Error![]const u8 {
    return switch (g) {
        .file_contains => |fc| std.fmt.allocPrint(arena, "file_contains {s}", .{fc.path}),
        .file_unchanged => |p| std.fmt.allocPrint(arena, "file_unchanged {s}", .{p}),
        .command_succeeds => |c| std.fmt.allocPrint(arena, "command_succeeds {s}", .{if (c.argv.len > 0) c.argv[0] else ""}),
        .tool_used => |n| std.fmt.allocPrint(arena, "tool_used {s}", .{n}),
        .tool_not_used => |n| std.fmt.allocPrint(arena, "tool_not_used {s}", .{n}),
        .max_turns => |n| std.fmt.allocPrint(arena, "max_turns {d}", .{n}),
        .max_cost_usd => |x| std.fmt.allocPrint(arena, "max_cost_usd {d}", .{x}),
        .final_text_matches => |p| std.fmt.allocPrint(arena, "final_text_matches /{s}/", .{p}),
        .no_permission_denials => "no_permission_denials",
    };
}

fn used(f: *const Facts, name: []const u8) bool {
    for (f.tools_used) |t| if (std.mem.eql(u8, t, name)) return true;
    return false;
}

fn readIn(io: Io, arena: Allocator, root: []const u8, rel: []const u8) ?[]const u8 {
    const path = std.fs.path.join(arena, &.{ root, rel }) catch return null;
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20)) catch null;
}

fn pass(arena: Allocator, comptime fmt: []const u8, a: anytype) Allocator.Error!Verdict {
    return .{ .ok = true, .detail = try std.fmt.allocPrint(arena, fmt, a) };
}

fn fail(arena: Allocator, comptime fmt: []const u8, a: anytype) Allocator.Error!Verdict {
    return .{ .ok = false, .detail = try std.fmt.allocPrint(arena, fmt, a) };
}
