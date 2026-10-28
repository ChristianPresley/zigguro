//! The task tools for agents (E10/E11), exported like zg_codeintel's
//! language tools through `zg_ai.tools.adapters.foreign`:
//!
//! - `task_run { name, extra_args?, timeout_ms? }` (permission `execute`):
//!   runs a task headless and answers with its result, its problems
//!   compiler-style and the last 200 lines of output.
//! - `task_list {}` (`read`): the workspace's tasks.
//!
//! ```zig
//! const X = zg_dap.tasks.agent_tool.ToolExporter(zg_ai.tools.adapters.foreign);
//! ```

const std = @import("std");
const TaskRunner = @import("TaskRunner.zig");
const Task = @import("Task.zig");
const TaskList = @import("TaskList.zig");
const pm = @import("matcher/ProblemMatcher.zig");
const zg_core = @import("zg_core");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const PermissionClass = enum { read, execute };

pub const Spec = struct {
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8,
    permission: PermissionClass,
};

/// The default `timeout_ms`, under the adapter's 120 s deadline for task
/// tools so the answer arrives before the call is cut off.
pub const default_timeout_ms = 110_000;

pub const specs = [_]Spec{
    .{
        .name = "task_run",
        .permission = .execute,
        .description = "Runs a workspace task (see task_list; e.g. \"zig build test\") with the tasks it depends on, and waits for it: the exit code, problems found in its output as file:line:column: severity: message, and the last 200 lines of output. Prefer it to a shell command for builds and tests: problems are parsed and also shown in the editor.",
        .input_schema_json =
        \\{"type":"object","properties":{"name":{"type":"string","description":"The task's label, as task_list prints it."},"extra_args":{"type":"array","items":{"type":"string"},"description":"Arguments appended to the task's own."},"timeout_ms":{"type":"integer","minimum":1,"description":"Stop the task after this long (default 110000)."}},"required":["name"],"additionalProperties":false}
        ,
    },
    .{
        .name = "task_list",
        .permission = .read,
        .description = "The workspace's tasks: zig build steps, .zigguro/tasks.zon and .vscode/tasks.json, with their group (build, test), whether they are the default and why one cannot run.",
        .input_schema_json =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
    },
};

pub fn ToolExporter(comptime Foreign: type) type {
    return struct {
        const Self = @This();

        runner: *TaskRunner,

        pub fn exporter(self: *Self) Foreign.Exporter {
            return .{ .name = "tasks", .kind = .tasks, .ctx = self, .list = list, .call = call };
        }

        fn list(_: *anyopaque, arena: Allocator) anyerror![]const Foreign.ForeignTool {
            const out = try arena.alloc(Foreign.ForeignTool, specs.len);
            for (specs, out) |s, *t| t.* = .{
                .name = s.name,
                .description = s.description,
                .input_schema_json = s.input_schema_json,
                .read_only = s.permission == .read,
            };
            return out;
        }

        fn call(ctx: *anyopaque, _: Io, arena: Allocator, tool: []const u8, input_json: []const u8) anyerror!Foreign.Result {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var text: Io.Writer.Allocating = .init(arena);
            const out = runTool(self.runner, arena, tool, input_json, &text.writer) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => blk: {
                    text.clearRetainingCapacity();
                    try text.writer.print("{s} failed: {t}", .{ tool, e });
                    break :blk Outcome{ .ok = false };
                },
            };
            return .{ .json = try resultJson(arena, text.written(), !out.ok, out.status) };
        }
    };
}

pub const Outcome = struct {
    /// False: the arguments were bad or the task did not run.
    ok: bool,
    /// `structuredContent` for `task_run`.
    status: ?[]const u8 = null,
};

const Input = struct {
    name: ?[]const u8 = null,
    extra_args: []const []const u8 = &.{},
    timeout_ms: ?u32 = null,
};

/// Runs `tool`, writing its text to `w`.
pub fn runTool(r: *TaskRunner, arena: Allocator, tool: []const u8, input_json: []const u8, w: *Io.Writer) !Outcome {
    const in = std.json.parseFromSliceLeaky(Input, arena, if (input_json.len == 0) "{}" else input_json, .{ .ignore_unknown_fields = true }) catch {
        try w.writeAll("The arguments are not valid for this tool (check names and types against its schema).");
        return .{ .ok = false };
    };
    if (std.mem.eql(u8, tool, "task_list")) {
        try renderList(w, r.list);
        return .{ .ok = true };
    }
    if (!std.mem.eql(u8, tool, "task_run")) return error.UnknownTool;
    const name = in.name orelse {
        try w.writeAll("task_run needs the name of a task (see task_list).");
        return .{ .ok = false };
    };
    const timeout: Io.Duration = .fromMilliseconds(in.timeout_ms orelse default_timeout_ms);
    const run = try r.run(name, .{
        .headless = true,
        .extra_args = in.extra_args,
        .deadline = zg_core.runtime.Deadline.after(r.io, timeout),
    });
    const s = try r.wait(run, arena);
    try renderSummary(w, run.label, &s, r.cfg.root);
    const status = try std.json.Stringify.valueAlloc(arena, .{
        .state = @tagName(s.state),
        .exit_code = s.exit_code,
        .timed_out = s.timed_out,
        .problems = s.problems.len,
        .duration_ms = s.duration_ms,
    }, .{});
    // A failed build is an answer, not a tool error; a task that did not
    // start is one.
    return .{ .ok = s.message == null, .status = status };
}

/// `task_run`'s text: what happened, the problems, the output's tail.
pub fn renderSummary(w: *Io.Writer, label: []const u8, s: *const TaskRunner.TaskRunSummary, root: []const u8) Io.Writer.Error!void {
    if (s.timed_out) {
        try w.print("'{s}' timed out after {d} ms and was stopped.\n", .{ label, s.duration_ms });
    } else switch (s.state) {
        .succeeded => try w.print("'{s}' succeeded in {d} ms.\n", .{ label, s.duration_ms }),
        .terminated => try w.print("'{s}' was stopped after {d} ms.\n", .{ label, s.duration_ms }),
        else => if (s.message) |m| {
            try w.print("'{s}' did not run: {s}\n", .{ label, m });
        } else if (s.exit_code) |c| {
            try w.print("'{s}' failed with exit code {d} after {d} ms.\n", .{ label, c, s.duration_ms });
        } else {
            try w.print("'{s}' crashed after {d} ms.\n", .{ label, s.duration_ms });
        },
    }
    if (s.problems.len > 0) {
        try w.print("\n{d} problem{s}:\n", .{ s.problems.len, if (s.problems.len == 1) "" else "s" });
        for (s.problems) |*p| {
            try writeLocation(w, p.file, p.line, p.column, root);
            try w.print(": {s}: {s}", .{ severityWord(p.severity), p.message });
            if (p.code.len > 0) try w.print(" [{s}]", .{p.code});
            try w.writeByte('\n');
            for (p.related) |rel| {
                try w.writeAll("    ");
                try writeLocation(w, rel.file, rel.line, rel.column, root);
                try w.print(": note: {s}\n", .{rel.message});
            }
        }
    }
    if (s.tail.len > 0) {
        try w.writeAll("\nOutput (last lines):\n");
        try w.writeAll(s.tail);
        if (s.tail[s.tail.len - 1] != '\n') try w.writeByte('\n');
    }
}

fn writeLocation(w: *Io.Writer, file: []const u8, line: u32, column: u32, root: []const u8) Io.Writer.Error!void {
    var path = file;
    if (root.len > 0 and path.len > root.len + 1 and std.mem.startsWith(u8, path, root) and (path[root.len] == '/' or path[root.len] == '\\')) {
        path = path[root.len + 1 ..];
    }
    for (path) |c| try w.writeByte(if (c == '\\') '/' else c);
    if (line > 0) try w.print(":{d}", .{line});
    if (column > 0) try w.print(":{d}", .{column});
}

fn severityWord(s: pm.Severity) []const u8 {
    return switch (s) {
        .err => "error",
        .warning => "warning",
        .info => "info",
        .hint => "hint",
    };
}

/// `task_list`'s text: one task per line.
pub fn renderList(w: *Io.Writer, l: *const TaskList) Io.Writer.Error!void {
    if (l.all().len == 0) return w.writeAll("No tasks: the workspace has no build.zig steps, .zigguro/tasks.zon or .vscode/tasks.json.\n");
    for (l.all()) |*t| {
        try w.writeAll(t.label);
        if (t.group) |g| if (g.kind != .none) {
            try w.print(" [{t}{s}]", .{ g.kind, if (g.is_default) ", default" else "" });
        };
        if (t.is_background) try w.writeAll(" [background]");
        if (!t.enabled) try w.print(" (cannot run: {s})", .{t.disabled_reason orelse "disabled"});
        if (t.detail) |d| try w.print(": {s}", .{d});
        try w.writeByte('\n');
    }
}

fn resultJson(arena: Allocator, text: []const u8, is_error: bool, status: ?[]const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const Content = struct { content: []const struct { type: []const u8 = "text", text: []const u8 } };
    const head = try std.json.Stringify.valueAlloc(arena, Content{ .content = &.{.{ .text = text }} }, .{});
    try out.appendSlice(arena, head[0 .. head.len - 1]);
    if (status) |s| try out.print(arena, ",\"structuredContent\":{s}", .{s});
    try out.print(arena, ",\"isError\":{}}}", .{is_error});
    return out.items;
}
