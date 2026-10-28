//! One task of the merged task list (E07.F08.S01.T01), from any of its
//! sources: `zig build` steps, `.zigguro/tasks.zon` or an imported
//! `.vscode/tasks.json`. Texts are not substituted yet: `${...}` in
//! `command`, `args`, `cwd`, `env` and `shell` is expanded when the task
//! runs (E07.F06.S01.T05), as VS Code does. Every slice lives in the
//! owning `TaskList`'s arena.

const std = @import("std");
const pm = @import("matcher/ProblemMatcher.zig");

pub const Source = enum { zig, zon, vscode };

/// `process` runs `command` with `args` directly; `shell` hands the
/// command line to the shell (`shell` below, else the platform's).
pub const Kind = enum { process, shell };

pub const GroupKind = enum { build, @"test", none };

pub const Group = struct {
    kind: GroupKind,
    is_default: bool = false,
};

pub const DependsOrder = enum { parallel, sequence };

pub const RunOn = enum { default, folder_open };

pub const Presentation = struct {
    reveal: enum { always, never, silent } = .always,
    reveal_problems: enum { always, on_problem, never } = .never,
    panel: enum { shared, dedicated, new } = .shared,
    clear: bool = false,
    focus: bool = false,
    echo: bool = true,
};

/// `$zig`, or a definition written in the task's file.
pub const MatcherRef = union(enum) {
    named: []const u8,
    inline_def: pm.MatcherDef,
};

pub const Shell = struct {
    executable: []const u8,
    args: []const []const u8 = &.{},
};

label: []const u8,
source: Source,
kind: Kind = .process,
/// Empty for a task that only runs its `depends_on`.
command: []const u8,
args: []const []const u8 = &.{},
/// Null: the workspace folder.
cwd: ?[]const u8 = null,
env: []const [2][]const u8 = &.{},
shell: ?Shell = null,
group: ?Group = null,
depends_on: []const []const u8 = &.{},
depends_order: DependsOrder = .parallel,
is_background: bool = false,
problem_matchers: []const MatcherRef = &.{},
presentation: Presentation = .{},
run_on: RunOn = .default,
/// `check` marks the step build-on-save falls back to (E07.F05).
tags: []const []const u8 = &.{},
/// A line for the task picker (a `zig build` step's description).
detail: ?[]const u8 = null,
enabled: bool = true,
/// Why `enabled` is false, for the picker.
disabled_reason: ?[]const u8 = null,

pub fn hasTag(t: *const @This(), tag: []const u8) bool {
    for (t.tags) |x| if (std.mem.eql(u8, x, tag)) return true;
    return false;
}
