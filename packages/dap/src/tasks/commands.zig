//! The task commands (E15), as data for the app's command registry, and
//! the `tasks.zon` that "Tasks: Configure Task" proposes.

pub const Command = struct {
    id: []const u8,
    title: []const u8,
    /// Default keybinding in the keymap's syntax.
    key: ?[]const u8 = null,
};

pub const commands = [_]Command{
    .{ .id = "tasks.run", .title = "Tasks: Run Task" },
    .{ .id = "tasks.runBuild", .title = "Tasks: Run Build Task", .key = "ctrl+shift+b" },
    .{ .id = "tasks.runTest", .title = "Tasks: Run Test Task" },
    .{ .id = "tasks.terminate", .title = "Tasks: Terminate Task" },
    .{ .id = "tasks.restart", .title = "Tasks: Restart Running Task" },
    .{ .id = "tasks.configure", .title = "Tasks: Configure Task" },
};

/// `.zigguro/tasks.zon` for a workspace that has none: Configure Task
/// writes it (it starts no process) and opens it.
pub const configure_template =
    \\// Workspace tasks: Tasks: Run Task lists them with the zig build steps.
    \\// Fields: label, type (.process or .shell), command, args, cwd, env,
    \\// group (.build or .@"test", is_default), depends_on, depends_order,
    \\// is_background, problem_matcher ("$zig", "$gcc", ...), presentation.
    \\.{
    \\    .version = 1,
    \\    .tasks = .{
    \\        .{
    \\            .label = "build",
    \\            .command = "zig",
    \\            .args = .{"build"},
    \\            .group = .{ .kind = .build, .is_default = true },
    \\            .problem_matcher = "$zig",
    \\        },
    \\        .{
    \\            .label = "test",
    \\            .command = "zig",
    \\            .args = .{ "build", "test" },
    \\            .group = .{ .kind = .@"test", .is_default = true },
    \\            .problem_matcher = "$zig",
    \\        },
    \\    },
    \\}
    \\
;
