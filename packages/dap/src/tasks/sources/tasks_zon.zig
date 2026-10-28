//! `.zigguro/tasks.zon`, the workspace's own task file:
//!
//! ```zon
//! .{
//!     .version = 1,
//!     .tasks = .{
//!         .{
//!             .label = "build release",
//!             .command = "zig",
//!             .args = .{ "build", "-Doptimize=ReleaseFast" },
//!             .group = .{ .kind = .build, .is_default = true },
//!             .problem_matcher = "$zig",
//!         },
//!     },
//! }
//! ```
//!
//! Field names are the `Task` fields; `.type` is `.process` (the
//! default) or `.shell`. `.problem_matcher = "$name"` names one matcher;
//! `.problem_matchers` lists several, each `.{ .named = "$gcc" }` or
//! `.{ .inline_def = .{ ... } }` with the matcher engine's own
//! `MatcherDef` schema. Unknown fields are ignored so newer files load.

const std = @import("std");
const Task = @import("../Task.zig");
const TaskList = @import("../TaskList.zig");
const pm = @import("../matcher/ProblemMatcher.zig");

const Allocator = std.mem.Allocator;

pub const path = ".zigguro/tasks.zon";

pub const TasksZon = struct {
    version: u32 = 1,
    tasks: []const TaskZon = &.{},
};

pub const TaskZon = struct {
    label: []const u8,
    type: Task.Kind = .process,
    command: []const u8 = "",
    args: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    env: []const [2][]const u8 = &.{},
    shell: ?Task.Shell = null,
    group: ?Task.Group = null,
    depends_on: []const []const u8 = &.{},
    depends_order: Task.DependsOrder = .parallel,
    is_background: bool = false,
    problem_matcher: ?[]const u8 = null,
    problem_matchers: []const Task.MatcherRef = &.{},
    presentation: Task.Presentation = .{},
    run_on: Task.RunOn = .default,
    tags: []const []const u8 = &.{},
    detail: ?[]const u8 = null,
};

/// Appends the tasks of `src`; a file that does not parse adds one
/// warning with the parser's messages and no tasks.
pub fn appendTasks(arena: Allocator, src: [:0]const u8, out: *std.ArrayList(Task), warnings: *std.ArrayList(TaskList.Warning)) Allocator.Error!void {
    var diag: std.zon.parse.Diagnostics = .{};
    const doc = std.zon.parse.fromSliceAlloc(TasksZon, arena, src, &diag, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            const text = try std.fmt.allocPrint(arena, "{f}", .{&diag});
            try warnings.append(arena, .{ .file = path, .message = std.mem.trimEnd(u8, text, "\n") });
            return;
        },
    };
    if (doc.version != 1) {
        try warnings.append(arena, .{ .file = path, .message = try std.fmt.allocPrint(arena, "version {d} is not supported (expected 1)", .{doc.version}) });
        return;
    }
    for (doc.tasks) |z| {
        var matchers = z.problem_matchers;
        if (z.problem_matcher) |name| {
            const all = try arena.alloc(Task.MatcherRef, matchers.len + 1);
            all[0] = .{ .named = name };
            @memcpy(all[1..], matchers);
            matchers = all;
        }
        for (matchers) |m| switch (m) {
            .named => |n| if (pm.builtinNamed(n) == null) {
                try warnings.append(arena, .{ .file = path, .message = try std.fmt.allocPrint(arena, "task '{s}': unknown problem matcher '{s}'", .{ z.label, n }) });
            },
            .inline_def => {},
        };
        try out.append(arena, .{
            .label = z.label,
            .source = .zon,
            .kind = z.type,
            .command = z.command,
            .args = z.args,
            .cwd = z.cwd,
            .env = z.env,
            .shell = z.shell,
            .group = z.group,
            .depends_on = z.depends_on,
            .depends_order = z.depends_order,
            .is_background = z.is_background,
            .problem_matchers = matchers,
            .presentation = z.presentation,
            .run_on = z.run_on,
            .tags = z.tags,
            .detail = z.detail,
        });
    }
}
