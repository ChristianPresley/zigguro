//! The task runner without a GUI (E07.F05.S01.T04), for `zg task` and
//! the check task behind `zg lsp diagnostics`: the workspace's tasks
//! (`zig build -l`, `.zigguro/tasks.zon`, `.vscode/tasks.json`), loaded
//! on first use, and a `TaskRunner` with no terminals that runs them
//! headless with pipes. `${...}` variables see the workspace folder and
//! the environment; `${config:...}` is empty, `${command:...}` refused
//! and `${input:...}` takes its default (nobody can be asked).
//!
//! An untrusted workspace lists its tasks as not runnable and does not
//! run `zig build -l` (that runs build.zig).
//!
//! Must not move once `init` returned.

const HeadlessTasks = @This();
const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const TaskList = @import("../tasks/TaskList.zig");
const TaskRunner = @import("../tasks/TaskRunner.zig");
const variables = @import("../config/variables.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Options = struct {
    /// The workspace folder, absolute.
    root: []const u8,
    env: *const std.process.Environ.Map,
    /// The Zig executable for `zig build` tasks (null: `zig` on PATH).
    zig_exe: ?[]const u8 = null,
    trusted: bool,
    /// Problems as they are found (null: only in each run's summary).
    problems: ?TaskRunner.ProblemHost = null,
    policy: ?*const TaskRunner.SpawnPolicy = null,
    /// How `zig build -l` runs (tests).
    steps: ?TaskList.Cache.StepRunner = null,
};

gpa: Allocator,
io: Io,
root: []u8,
zig_exe: []u8,
trusted: bool,
cache: TaskList.Cache,
/// The list before the first load (and when loading fails).
empty: TaskList,
list: *const TaskList,
vars: variables.VarContext,
runner: TaskRunner,

pub fn init(h: *HeadlessTasks, rt: *zg_core.Runtime, opts: Options) !void {
    const gpa = rt.gpa;
    const root = try gpa.dupe(u8, opts.root);
    errdefer gpa.free(root);
    const zig_exe = try gpa.dupe(u8, opts.zig_exe orelse "zig");
    errdefer gpa.free(zig_exe);
    h.* = .{
        .gpa = gpa,
        .io = rt.io,
        .root = root,
        .zig_exe = zig_exe,
        .trusted = opts.trusted,
        .cache = .init(gpa, .{ .root = root, .trusted = opts.trusted }, builtin.os.tag, .{ .exe_path = zig_exe, .env = opts.env }),
        .empty = try TaskList.fromSources(gpa, .{ .os = builtin.os.tag, .trusted = opts.trusted }),
        .list = undefined,
        .vars = .{
            .workspace_folder = root,
            .file = null,
            .line = null,
            .column = null,
            .selected_text = null,
            .cwd = root,
            .exec_path = "",
            .user_home = opts.env.get("HOME") orelse opts.env.get("USERPROFILE") orelse "",
            .default_build_task = null,
            .os = builtin.os.tag,
            .env = opts.env,
            .config = noConfig,
            .command = noCommand,
            .input = defaultInput,
            .ctx = h,
        },
        .runner = undefined,
    };
    if (opts.steps) |s| h.cache.runner = s;
    h.list = &h.empty;
    h.runner = .init(rt, &h.empty, .{
        .problems = opts.problems,
        .policy = opts.policy,
        .env = opts.env,
        .root = root,
        .vars = &h.vars,
    });
}

/// Stops the running tasks and frees everything.
pub fn deinit(h: *HeadlessTasks) void {
    h.runner.deinit();
    h.cache.deinit();
    h.empty.deinit();
    h.gpa.free(h.zig_exe);
    h.gpa.free(h.root);
    h.* = undefined;
}

/// The tasks, loaded on the first call (and again after a watched file
/// changed). A list that cannot be loaded leaves the last one.
pub fn load(h: *HeadlessTasks) !*const TaskList {
    const l = try h.cache.get(h.io);
    if (l != h.list) {
        h.list = l;
        h.runner.setList(l);
    }
    return l;
}

fn noConfig(_: *anyopaque, _: []const u8, _: Allocator) ?[]const u8 {
    return null;
}

fn noCommand(_: *anyopaque, _: []const u8, _: Allocator) anyerror!?[]const u8 {
    return error.CommandNotAllowed;
}

fn defaultInput(_: *anyopaque, def: *const variables.InputDef, _: Allocator) anyerror!?[]const u8 {
    return def.default;
}
