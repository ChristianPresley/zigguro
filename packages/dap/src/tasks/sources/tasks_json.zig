//! Read-only import of `.vscode/tasks.json` (version 2.0.0, JSONC). The
//! file is never written back.
//!
//! - `shell` and `process` tasks map field for field; `cppbuild` (the
//!   C/C++ extension's build task) is a process task. Other types (`npm`,
//!   `cargo`, `gulp`...) come from VS Code extensions: they are listed
//!   disabled, with a hint.
//! - Top-level `options` and `presentation` apply to every task; the
//!   `windows`/`linux`/`osx` objects, at the top level and in a task,
//!   override the task's fields for that OS (`options`, `env` and
//!   `presentation` merge key by key).
//! - `problemMatcher` is a `$name`, an inline object or an array of
//!   either; an inline matcher may extend a built-in with `base`.
//! - `${...}` is left as written; it is substituted at run time.

const std = @import("std");
const Task = @import("../Task.zig");
const TaskList = @import("../TaskList.zig");
const pm = @import("../matcher/ProblemMatcher.zig");
const jsonc = @import("jsonc.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

pub const path = ".vscode/tasks.json";

const Ctx = struct {
    arena: Allocator,
    warnings: *std.ArrayList(TaskList.Warning),

    fn warn(c: Ctx, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try c.warnings.append(c.arena, .{ .file = path, .message = try std.fmt.allocPrint(c.arena, fmt, args) });
    }
};

/// The key of `os`'s override object, if VS Code has one.
fn osKey(os: std.Target.Os.Tag) ?[]const u8 {
    return switch (os) {
        .windows => "windows",
        .linux => "linux",
        .macos => "osx",
        else => null,
    };
}

/// Appends the tasks of `src` as seen on `os`.
pub fn appendTasks(arena: Allocator, src: []const u8, os: std.Target.Os.Tag, out: *std.ArrayList(Task), warnings: *std.ArrayList(TaskList.Warning)) Allocator.Error!void {
    const c: Ctx = .{ .arena = arena, .warnings = warnings };
    const text = jsonc.stripJsonc(arena, src) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnterminatedComment => return c.warn("unterminated /* comment", .{}),
    };
    var scanner: std.json.Scanner = .initCompleteInput(arena, text);
    var diag: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diag);
    const root = std.json.parseFromTokenSourceLeaky(Value, arena, &scanner, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return c.warn("{d}:{d}: not valid JSON ({s})", .{ diag.getLine(), diag.getColumn(), @errorName(e) }),
    };
    const top = object(root) orelse return c.warn("expected an object at the top level", .{});
    if (string(top.get("version"))) |v| {
        if (!std.mem.eql(u8, v, "2.0.0")) try c.warn("version \"{s}\" is not supported (expected \"2.0.0\"); reading it as 2.0.0", .{v});
    }
    const os_key = osKey(os);

    // The properties every task inherits.
    var globals: ObjectMap = .empty;
    for ([_][]const u8{ "options", "presentation" }) |k| {
        if (top.get(k)) |v| try globals.put(arena, k, v);
    }
    if (os_key) |k| if (object(top.get(k))) |o| {
        var only: ObjectMap = .empty;
        for ([_][]const u8{ "options", "presentation" }) |g| {
            if (o.get(g)) |v| try only.put(arena, g, v);
        }
        try mergeInto(arena, &globals, only);
    };

    const tasks = switch (top.get("tasks") orelse return) {
        .array => |a| a.items,
        else => return c.warn("\"tasks\" is not an array", .{}),
    };
    for (tasks, 0..) |tv, i| {
        const own = object(tv) orelse {
            try c.warn("task {d} is not an object", .{i + 1});
            continue;
        };
        var t: ObjectMap = .empty;
        try mergeInto(arena, &t, globals);
        try mergeInto(arena, &t, own);
        if (os_key) |k| if (object(own.get(k))) |o| try mergeInto(arena, &t, o);
        if (try taskFrom(c, t, i)) |task| try out.append(arena, task);
    }
}

fn taskFrom(c: Ctx, o: ObjectMap, index: usize) Allocator.Error!?Task {
    const a = c.arena;
    const type_name = string(o.get("type")) orelse "process";
    const command = string(o.get("command")) orelse "";
    const label = string(o.get("label")) orelse string(o.get("taskName")) orelse blk: {
        if (!isRunnable(type_name)) {
            const what = string(o.get("script")) orelse command;
            break :blk try std.fmt.allocPrint(a, "{s}: {s}", .{ type_name, what });
        }
        if (command.len > 0) break :blk command;
        try c.warn("task {d} has no label or command", .{index + 1});
        return null;
    };

    var t: Task = .{ .label = label, .source = .vscode, .command = command };
    if (std.mem.eql(u8, type_name, "shell")) {
        t.kind = .shell;
    } else if (!isRunnable(type_name)) {
        t.enabled = false;
        t.disabled_reason = try std.fmt.allocPrint(a, "'{s}' tasks come from a VS Code extension; zigguro runs shell and process tasks (write it as one in .zigguro/tasks.zon)", .{type_name});
    }
    t.args = try stringList(a, o.get("args"));
    if (string(o.get("detail"))) |d| t.detail = d;

    if (object(o.get("options"))) |opt| {
        t.cwd = string(opt.get("cwd"));
        if (object(opt.get("env"))) |env| {
            var pairs: std.ArrayList([2][]const u8) = .empty;
            var it = env.iterator();
            while (it.next()) |kv| {
                const v = string(kv.value_ptr.*) orelse continue;
                try pairs.append(a, .{ kv.key_ptr.*, v });
            }
            t.env = pairs.items;
        }
        if (object(opt.get("shell"))) |sh| {
            if (string(sh.get("executable"))) |exe| t.shell = .{ .executable = exe, .args = try stringList(a, sh.get("args")) };
        }
    }

    if (o.get("group")) |g| switch (g) {
        .string => |s| t.group = .{ .kind = groupKind(s) orelse .none },
        .object => |go| t.group = .{
            .kind = groupKind(string(go.get("kind")) orelse "none") orelse .none,
            // A glob string means default for matching files: still default.
            .is_default = switch (go.get("isDefault") orelse Value{ .bool = false }) {
                .bool => |b| b,
                .string => true,
                else => false,
            },
        },
        else => {},
    };
    t.depends_on = try stringList(a, o.get("dependsOn"));
    if (string(o.get("dependsOrder"))) |s| {
        if (std.mem.eql(u8, s, "sequence")) t.depends_order = .sequence;
    }
    if (o.get("isBackground")) |v| if (v == .bool) {
        t.is_background = v.bool;
    };
    if (object(o.get("runOptions"))) |ro| {
        if (string(ro.get("runOn"))) |s| {
            if (std.mem.eql(u8, s, "folderOpen")) t.run_on = .folder_open;
        }
    }
    if (object(o.get("presentation"))) |p| t.presentation = presentationFrom(p);

    if (o.get("problemMatcher")) |pmv| {
        var list: std.ArrayList(Task.MatcherRef) = .empty;
        switch (pmv) {
            .array => |arr| for (arr.items) |item| {
                if (try matcherFrom(c, t, item)) |m| try list.append(a, m);
            },
            else => if (try matcherFrom(c, t, pmv)) |m| try list.append(a, m),
        }
        t.problem_matchers = list.items;
    }
    return t;
}

fn isRunnable(type_name: []const u8) bool {
    return std.mem.eql(u8, type_name, "shell") or std.mem.eql(u8, type_name, "process") or std.mem.eql(u8, type_name, "cppbuild");
}

fn groupKind(s: []const u8) ?Task.GroupKind {
    return std.meta.stringToEnum(Task.GroupKind, s);
}

fn presentationFrom(o: ObjectMap) Task.Presentation {
    var p: Task.Presentation = .{};
    if (string(o.get("reveal"))) |s| p.reveal = std.meta.stringToEnum(@TypeOf(p.reveal), s) orelse p.reveal;
    if (string(o.get("revealProblems"))) |s| {
        p.reveal_problems = if (std.mem.eql(u8, s, "onProblem")) .on_problem else std.meta.stringToEnum(@TypeOf(p.reveal_problems), s) orelse p.reveal_problems;
    }
    if (string(o.get("panel"))) |s| p.panel = std.meta.stringToEnum(@TypeOf(p.panel), s) orelse p.panel;
    if (boolean(o.get("clear"))) |b| p.clear = b;
    if (boolean(o.get("focus"))) |b| p.focus = b;
    if (boolean(o.get("echo"))) |b| p.echo = b;
    return p;
}

// ------------------------------------------------------------ matchers

/// Names are not checked on a disabled task (an extension's matcher,
/// like `$tsc-watch` on an `npm` task, would only add noise).
fn matcherFrom(c: Ctx, t: Task, v: Value) Allocator.Error!?Task.MatcherRef {
    const label = t.label;
    switch (v) {
        .string => |name| {
            if (t.enabled and pm.builtinNamed(name) == null) {
                try c.warn("task '{s}': unknown problem matcher '{s}'", .{ label, name });
            }
            return .{ .named = name };
        },
        .object => |o| return if (try inlineMatcher(c, label, o)) |d| .{ .inline_def = d } else null,
        else => {
            try c.warn("task '{s}': a problem matcher is a name or an object", .{label});
            return null;
        },
    }
}

fn inlineMatcher(c: Ctx, label: []const u8, o: ObjectMap) Allocator.Error!?pm.MatcherDef {
    const a = c.arena;
    var d: pm.MatcherDef = .{ .owner = "external", .patterns = &.{} };
    if (string(o.get("base"))) |base| {
        if (pm.builtinNamed(base)) |b| {
            d = b.*;
            d.name = "";
        } else {
            try c.warn("task '{s}': unknown base problem matcher '{s}'", .{ label, base });
            return null;
        }
    }
    if (string(o.get("owner"))) |s| d.owner = s;
    if (string(o.get("source"))) |s| d.source = s;
    if (string(o.get("severity"))) |s| d.severity = severity(s) orelse d.severity;
    if (o.get("fileLocation")) |fl| d.file_location = fileLocation(fl) orelse d.file_location;
    if (o.get("pattern")) |pv| {
        var pats: std.ArrayList(pm.Pattern) = .empty;
        switch (pv) {
            .object => |po| try pats.append(a, patternFrom(po) orelse {
                try c.warn("task '{s}': a problem pattern needs a \"regexp\"", .{label});
                return null;
            }),
            .array => |arr| for (arr.items) |item| {
                const po = object(item) orelse continue;
                try pats.append(a, patternFrom(po) orelse {
                    try c.warn("task '{s}': a problem pattern needs a \"regexp\"", .{label});
                    return null;
                });
            },
            // A named pattern: the patterns of the built-in of that name.
            .string => |name| if (pm.builtinNamed(name)) |b| {
                try pats.appendSlice(a, b.patterns);
            } else {
                try c.warn("task '{s}': unknown problem pattern '{s}'", .{ label, name });
                return null;
            },
            else => {},
        }
        d.patterns = pats.items;
    }
    if (d.patterns.len == 0) {
        try c.warn("task '{s}': a problem matcher needs a \"pattern\"", .{label});
        return null;
    }
    if (!complete(d.patterns)) {
        try c.warn("task '{s}': a problem pattern needs file, message and line (or location) groups", .{label});
        return null;
    }
    if (object(o.get("background")) orelse object(o.get("watching"))) |bg| {
        d.background = .{
            .active_on_start = boolean(bg.get("activeBegins")) orelse false,
            .begins = regexpOf(bg.get("beginsPattern")) orelse ".^",
            .ends = regexpOf(bg.get("endsPattern")) orelse ".^",
        };
    }
    return d;
}

fn patternFrom(o: ObjectMap) ?pm.Pattern {
    var p: pm.Pattern = .{ .regexp = string(o.get("regexp")) orelse return null };
    p.file = groupIndex(o.get("file"));
    p.location = groupIndex(o.get("location"));
    p.line = groupIndex(o.get("line"));
    p.column = groupIndex(o.get("column"));
    p.end_line = groupIndex(o.get("endLine"));
    p.end_column = groupIndex(o.get("endColumn"));
    p.severity = groupIndex(o.get("severity"));
    p.code = groupIndex(o.get("code"));
    p.message = groupIndex(o.get("message"));
    p.loop = boolean(o.get("loop")) orelse false;
    if (string(o.get("kind"))) |k| {
        if (std.mem.eql(u8, k, "file")) p.kind = .file;
    }
    return p;
}

/// VS Code's rule: the patterns together give a file and a message, and
/// a line or location unless the first pattern is of kind `file`.
fn complete(pats: []const pm.Pattern) bool {
    var file = false;
    var message = false;
    var line = false;
    for (pats) |p| {
        if (p.file != null) file = true;
        if (p.message != null) message = true;
        if (p.line != null or p.location != null) line = true;
    }
    return file and message and (line or pats[0].kind == .file);
}

fn severity(s: []const u8) ?pm.Severity {
    if (std.mem.eql(u8, s, "error")) return .err;
    if (std.mem.eql(u8, s, "warning")) return .warning;
    if (std.mem.eql(u8, s, "info")) return .info;
    if (std.mem.eql(u8, s, "hint")) return .hint;
    return null;
}

/// `"absolute"`, `"relative"`, `"autoDetect"` or `"search"`, or an array
/// of one of them and a base folder.
fn fileLocation(v: Value) ?pm.FileLocation {
    const kind, const base: ?[]const u8 = switch (v) {
        .string => |s| .{ s, null },
        .array => |arr| .{ string(if (arr.items.len > 0) arr.items[0] else null) orelse return null, string(if (arr.items.len > 1) arr.items[1] else null) },
        else => return null,
    };
    if (std.mem.eql(u8, kind, "absolute")) return .absolute;
    if (std.mem.eql(u8, kind, "relative")) return .{ .relative = base };
    // `search` looks the name up under the workspace; auto-detection is
    // the nearest the matcher has.
    if (std.mem.eql(u8, kind, "autoDetect") or std.mem.eql(u8, kind, "search")) return .{ .auto_detect = base };
    return null;
}

fn regexpOf(v: ?Value) ?[]const u8 {
    if (string(v)) |s| return s;
    if (object(v)) |o| return string(o.get("regexp"));
    return null;
}

fn groupIndex(v: ?Value) ?u8 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |n| std.math.cast(u8, n),
        else => null,
    };
}

// ---------------------------------------------------------------- JSON

fn object(v: ?Value) ?ObjectMap {
    const x = v orelse return null;
    return if (x == .object) x.object else null;
}

/// A string, or the `value` of a `{ "value": ..., "quoting": ... }`.
fn string(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return switch (x) {
        .string => |s| s,
        .object => |o| if (o.get("value")) |inner| (if (inner == .string) inner.string else null) else null,
        else => null,
    };
}

fn boolean(v: ?Value) ?bool {
    const x = v orelse return null;
    return if (x == .bool) x.bool else null;
}

/// A string or an array of strings (others skipped).
fn stringList(a: Allocator, v: ?Value) Allocator.Error![]const []const u8 {
    const x = v orelse return &.{};
    switch (x) {
        .array => |arr| {
            var out: std.ArrayList([]const u8) = .empty;
            for (arr.items) |item| {
                if (string(item)) |s| try out.append(a, s);
            }
            return out.items;
        },
        else => {
            const s = string(x) orelse return &.{};
            const one = try a.alloc([]const u8, 1);
            one[0] = s;
            return one;
        },
    }
}

/// `over`'s keys replace `dst`'s; `options`, `env` and `presentation`
/// objects merge key by key.
fn mergeInto(a: Allocator, dst: *ObjectMap, over: ObjectMap) Allocator.Error!void {
    var it = over.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        const deep = std.mem.eql(u8, key, "options") or std.mem.eql(u8, key, "env") or std.mem.eql(u8, key, "presentation");
        if (deep) if (object(dst.get(key))) |old| if (object(kv.value_ptr.*)) |new| {
            var both: ObjectMap = .empty;
            try mergeInto(a, &both, old);
            try mergeInto(a, &both, new);
            try dst.put(a, key, .{ .object = both });
            continue;
        };
        try dst.put(a, key, kv.value_ptr.*);
    }
}
