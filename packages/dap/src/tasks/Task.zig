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

/// A deep copy in `a`, so a run outlives a task list reload.
pub fn clone(t: *const @This(), a: std.mem.Allocator) std.mem.Allocator.Error!@This() {
    var c = t.*;
    c.label = try a.dupe(u8, t.label);
    c.command = try a.dupe(u8, t.command);
    c.args = try dupeList(a, t.args);
    if (t.cwd) |s| c.cwd = try a.dupe(u8, s);
    const env = try a.alloc([2][]const u8, t.env.len);
    for (t.env, env) |kv, *o| o.* = .{ try a.dupe(u8, kv[0]), try a.dupe(u8, kv[1]) };
    c.env = env;
    if (t.shell) |sh| c.shell = .{ .executable = try a.dupe(u8, sh.executable), .args = try dupeList(a, sh.args) };
    c.depends_on = try dupeList(a, t.depends_on);
    c.tags = try dupeList(a, t.tags);
    if (t.detail) |s| c.detail = try a.dupe(u8, s);
    if (t.disabled_reason) |s| c.disabled_reason = try a.dupe(u8, s);
    const ms = try a.alloc(MatcherRef, t.problem_matchers.len);
    for (t.problem_matchers, ms) |m, *o| o.* = switch (m) {
        .named => |s| .{ .named = try a.dupe(u8, s) },
        .inline_def => |d| .{ .inline_def = try cloneMatcher(a, d) },
    };
    c.problem_matchers = ms;
    return c;
}

fn dupeList(a: std.mem.Allocator, list: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, list.len);
    for (list, out) |s, *o| o.* = try a.dupe(u8, s);
    return out;
}

pub fn cloneMatcher(a: std.mem.Allocator, d: pm.MatcherDef) std.mem.Allocator.Error!pm.MatcherDef {
    var c = d;
    c.name = try a.dupe(u8, d.name);
    c.owner = try a.dupe(u8, d.owner);
    if (d.source) |s| c.source = try a.dupe(u8, s);
    c.file_location = switch (d.file_location) {
        .absolute => .absolute,
        .relative => |b| .{ .relative = if (b) |s| try a.dupe(u8, s) else null },
        .auto_detect => |b| .{ .auto_detect = if (b) |s| try a.dupe(u8, s) else null },
    };
    const pats = try a.alloc(pm.Pattern, d.patterns.len);
    for (d.patterns, pats) |p, *o| {
        o.* = p;
        o.regexp = try a.dupe(u8, p.regexp);
        o.requires = try dupeList(a, p.requires);
        if (p.shape) |sh| o.shape = .{ .words = try dupeList(a, sh.words) };
    }
    c.patterns = pats;
    if (d.background) |bg| c.background = .{
        .active_on_start = bg.active_on_start,
        .begins = try a.dupe(u8, bg.begins),
        .ends = try a.dupe(u8, bg.ends),
        .implicit_begin_after_end = bg.implicit_begin_after_end,
        .begin_on_clear = bg.begin_on_clear,
    };
    if (d.related_note) |r| c.related_note = .{ .word = try a.dupe(u8, r.word) };
    if (d.trailer) |tr| c.trailer = .{ .regexp = try a.dupe(u8, tr.regexp), .message = tr.message };
    return c;
}
