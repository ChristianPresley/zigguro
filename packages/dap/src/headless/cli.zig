//! `zg task` (E07.F05.S01.T04): the workspace's tasks from the command
//! line, with the renderings the agents' `task_list` and `task_run` give.
//!
//! ```
//! zg task list [--json]
//! zg task run LABEL [--timeout-ms N] [--json] [-- ARGS...]
//! ```
//!
//! Exit status: 0 the task succeeded (or the list was printed), 1 it
//! failed, was stopped or timed out, 2 bad usage or a task that could not
//! run (unknown, disabled, untrusted workspace). `--json` prints the
//! run's state, problems and output tail (or the task list) as JSON.
//! `Common` takes the flags `zg lsp` and `zg task` share before the
//! toolchain is composed.

const std = @import("std");
const HeadlessTasks = @import("HeadlessTasks.zig");
const TaskRunner = @import("../tasks/TaskRunner.zig");
const TaskList = @import("../tasks/TaskList.zig");
const agent_tool = @import("../tasks/agent_tool.zig");
const pm = @import("../tasks/matcher/ProblemMatcher.zig");
const zg_core = @import("zg_core");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const usage_text =
    \\Usage: zg task list [--json]
    \\       zg task run LABEL [--timeout-ms N] [--json] [-- ARGS...]
    \\
    \\Options: --workspace DIR   the workspace (default: the current directory)
    \\         --untrusted       treat the workspace as untrusted: its tasks do not run
    \\         --zig PATH        the Zig executable for `zig build` tasks
    \\
    \\Tasks come from build.zig steps, .zigguro/tasks.zon and .vscode/tasks.json.
    \\`run` prints the result, the problems found in the output and the last
    \\200 lines of output; exit status 0 on success, 1 on failure, 2 when the
    \\task could not run.
    \\
;

pub const untrusted_message = "The workspace is not trusted, so its tasks do not run. Run without --untrusted to trust it.";

/// The flags every `zg lsp` / `zg task` command takes, and the rest.
pub const Common = struct {
    workspace: ?[]const u8 = null,
    untrusted: bool = false,
    verbose: bool = false,
    zig: ?[]const u8 = null,
    rest: []const []const u8 = &.{},

    /// Null when a flag misses its value (`bad` names it).
    pub fn parse(arena: Allocator, args: []const []const u8, bad: *[]const u8) Allocator.Error!?Common {
        var c: Common = .{};
        var rest: std.ArrayList([]const u8) = .empty;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--")) {
                try rest.appendSlice(arena, args[i..]);
                break;
            }
            if (std.mem.eql(u8, a, "--untrusted")) {
                c.untrusted = true;
                continue;
            }
            if (std.mem.eql(u8, a, "--verbose")) {
                c.verbose = true;
                continue;
            }
            const slot: *?[]const u8 = if (flagIs(a, "--workspace")) &c.workspace else if (flagIs(a, "--zig")) &c.zig else {
                try rest.append(arena, a);
                continue;
            };
            if (std.mem.indexOfScalar(u8, a, '=')) |eq| {
                slot.* = a[eq + 1 ..];
            } else if (i + 1 < args.len) {
                i += 1;
                slot.* = args[i];
            } else {
                bad.* = a;
                return null;
            }
        }
        c.rest = rest.items;
        return c;
    }
};

fn flagIs(arg: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, arg, name) or (std.mem.startsWith(u8, arg, name) and arg.len > name.len and arg[name.len] == '=');
}

/// Runs `zg task ARGS` (after `Common.parse`).
pub fn cliMain(h: *HeadlessTasks, args: []const []const u8, out: *Io.Writer, err: *Io.Writer) !u8 {
    if (args.len == 0 or std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
        try (if (args.len > 0) out else err).writeAll(usage_text);
        return if (args.len > 0) 0 else 2;
    }
    var arena_state: std.heap.ArenaAllocator = .init(h.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var json = false;
    var timeout_ms: ?u32 = null;
    var label: ?[]const u8 = null;
    var extra: []const []const u8 = &.{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            extra = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, a, "--json")) {
            json = true;
        } else if (flagIs(a, "--timeout-ms")) {
            const v = if (std.mem.indexOfScalar(u8, a, '=')) |eq| a[eq + 1 ..] else if (i + 1 < args.len) blk: {
                i += 1;
                break :blk args[i];
            } else return usage(err, "--timeout-ms needs a value");
            timeout_ms = std.fmt.parseInt(u32, v, 10) catch return usage(err, "--timeout-ms takes milliseconds");
        } else if (std.mem.startsWith(u8, a, "--")) {
            try err.print("zg task: unknown option {s}\n", .{a});
            return 2;
        } else if (label == null) {
            label = a;
        } else return usage(err, "one task at a time");
    }

    if (std.mem.eql(u8, args[0], "list")) {
        if (label != null) return usage(err, "list takes no arguments");
        const l = h.load() catch |e| {
            try err.print("zg task: the tasks could not be loaded: {t}\n", .{e});
            return 2;
        };
        if (json) try writeListJson(arena, out, l) else try agent_tool.renderList(out, l);
        for (l.warnings) |w| try err.print("{s}: warning: {s}\n", .{ w.file, w.message });
        return 0;
    }
    if (!std.mem.eql(u8, args[0], "run")) {
        try err.print("zg task: unknown command '{s}'\n\n{s}", .{ args[0], usage_text });
        return 2;
    }
    const name = label orelse return usage(err, "run needs the label of a task (see zg task list)");
    if (!h.trusted) {
        try err.print("{s}\n", .{untrusted_message});
        return 2;
    }
    _ = h.load() catch |e| {
        try err.print("zg task: the tasks could not be loaded: {t}\n", .{e});
        return 2;
    };
    const timeout: Io.Duration = .fromMilliseconds(timeout_ms orelse agent_tool.default_timeout_ms);
    const run = try h.runner.run(name, .{
        .headless = true,
        .extra_args = extra,
        .deadline = zg_core.runtime.Deadline.after(h.io, timeout),
    });
    const s = try h.runner.wait(run, arena);
    if (json) try writeRunJson(arena, out, run.label, &s, h.root) else try agent_tool.renderSummary(out, run.label, &s, h.root);
    if (s.message != null) return 2;
    return if (s.state == .succeeded) 0 else 1;
}

fn usage(err: *Io.Writer, why: []const u8) !u8 {
    try err.print("zg task: {s}\n\n{s}", .{ why, usage_text });
    return 2;
}

fn writeListJson(arena: Allocator, out: *Io.Writer, l: *const TaskList) !void {
    const J = struct {
        label: []const u8,
        source: []const u8,
        group: ?[]const u8,
        is_default: bool,
        background: bool,
        enabled: bool,
        disabled_reason: ?[]const u8,
        detail: ?[]const u8,
    };
    const list = try arena.alloc(J, l.all().len);
    for (l.all(), list) |*t, *j| j.* = .{
        .label = t.label,
        .source = @tagName(t.source),
        .group = if (t.group) |g| (if (g.kind == .none) null else @tagName(g.kind)) else null,
        .is_default = if (t.group) |g| g.is_default else false,
        .background = t.is_background,
        .enabled = t.enabled,
        .disabled_reason = t.disabled_reason,
        .detail = t.detail,
    };
    try std.json.Stringify.value(list, .{}, out);
    try out.writeByte('\n');
}

fn writeRunJson(arena: Allocator, out: *Io.Writer, label: []const u8, s: *const TaskRunner.TaskRunSummary, root: []const u8) !void {
    const P = struct { path: []const u8, line: u32, column: u32, severity: []const u8, message: []const u8, code: []const u8, source: []const u8 };
    const ps = try arena.alloc(P, s.problems.len);
    for (s.problems, ps) |*p, *j| j.* = .{
        .path = relative(p.file, root),
        .line = p.line,
        .column = p.column,
        .severity = switch (p.severity) {
            .err => "error",
            .warning => "warning",
            .info => "info",
            .hint => "hint",
        },
        .message = p.message,
        .code = p.code,
        .source = p.source,
    };
    try std.json.Stringify.value(.{
        .label = label,
        .state = @tagName(s.state),
        .exit_code = s.exit_code,
        .timed_out = s.timed_out,
        .duration_ms = s.duration_ms,
        .message = s.message,
        .problems = ps,
        .tail = s.tail,
    }, .{}, out);
    try out.writeByte('\n');
}

fn relative(path: []const u8, root: []const u8) []const u8 {
    if (root.len > 0 and path.len > root.len + 1 and std.mem.startsWith(u8, path, root) and (path[root.len] == '/' or path[root.len] == '\\')) return path[root.len + 1 ..];
    return path;
}
