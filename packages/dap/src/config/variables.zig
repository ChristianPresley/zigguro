//! VS Code-compatible `${...}` variable substitution for launch
//! configurations and tasks.
//!
//! Supported: the predefined variables (`${workspaceFolder}`, `${file}`,
//! `${relativeFile}`, ...), `${workspaceFolder:name}` for multi-root
//! workspaces, `${env:NAME}`, `${config:section.key}`, `${command:id}`
//! (allowlisted by the `command` callback) and `${input:id}`
//! (promptString / pickString through the `input` callback).
//!
//! Rules, as in VS Code: only string values are substituted (object keys
//! are not); an unset `${env:NAME}` is the empty string; an unknown
//! variable is an error; `$${` is not an escape; substitution is
//! single-pass, so substituted text is never re-scanned (an environment
//! value cannot inject another variable). Each `${input:id}` is asked
//! once per launch: pass the same `InputCache` to every call of a launch.
//!
//! The module is pure: no I/O except through the context callbacks.

const std = @import("std");
const zg_core = @import("zg_core");
const Allocator = std.mem.Allocator;
const Diagnostics = zg_core.report.Diagnostics;

/// A named workspace folder, for `${workspaceFolder:name}` and for finding
/// the folder that contains `${file}`.
pub const Folder = struct {
    name: []const u8,
    path: []const u8,
};

/// Answers already given to `${input:id}` prompts, keyed by input id.
/// Owned by the caller; keys and values live in the substitution arena.
pub const InputCache = std.StringHashMapUnmanaged([]const u8);

/// Everything substitution may read. Paths use the separators of `os`.
pub const VarContext = struct {
    /// The folder of the launch configuration or task (`${workspaceFolder}`).
    workspace_folder: ?[]const u8,
    /// Every folder of a multi-root workspace.
    workspace_folders: []const Folder = &.{},
    /// The active editor's file.
    file: ?[]const u8,
    /// 1-based cursor line and column in `file`.
    line: ?u32,
    column: ?u32,
    selected_text: ?[]const u8,
    cwd: []const u8,
    /// The path of the running zigguro executable.
    exec_path: []const u8,
    user_home: []const u8,
    /// The label of the default build task, if any.
    default_build_task: ?[]const u8,
    os: std.Target.Os.Tag,
    env: *const std.process.Environ.Map,
    /// Reads a setting (`${config:section.key}`); null when unset.
    config: *const fn (ctx: *anyopaque, key: []const u8, arena: Allocator) ?[]const u8,
    /// Runs an allowlisted command (`${command:id}`); returns
    /// `error.CommandNotAllowed` for anything else, null for no value.
    command: *const fn (ctx: *anyopaque, id: []const u8, arena: Allocator) anyerror!?[]const u8,
    /// Prompts for an input; null means the user cancelled.
    input: *const fn (ctx: *anyopaque, def: *const InputDef, arena: Allocator) anyerror!?[]const u8,
    ctx: *anyopaque,
    /// Shared answers to `${input:id}` across the calls of one launch.
    input_cache: ?*InputCache = null,
    /// Receives the name of the offending variable on error.
    diag: ?*Diagnostics = null,
};

/// An `inputs[]` entry of launch.json / tasks.json.
pub const InputDef = struct {
    id: []const u8,
    kind: enum { prompt_string, pick_string },
    description: []const u8,
    default: ?[]const u8,
    options: []const []const u8,
    password: bool = false,
};

/// Substitution failures.
pub const SubstError = error{ UnknownVariable, MissingContext, Cancelled, CommandNotAllowed, OutOfMemory };

/// Returns `s` with every `${...}` replaced. The result and any values it
/// contains are allocated in `arena`.
pub fn substituteString(arena: Allocator, s: []const u8, ctx: *const VarContext, inputs: []const InputDef) SubstError![]const u8 {
    var local: InputCache = .empty;
    const cache = ctx.input_cache orelse &local;
    return substitute(arena, s, ctx, inputs, cache);
}

/// Substitutes every string inside `v` in place, recursing into arrays and
/// object values (never keys).
pub fn substituteValue(arena: Allocator, v: *std.json.Value, ctx: *const VarContext, inputs: []const InputDef) SubstError!void {
    var local: InputCache = .empty;
    const cache = ctx.input_cache orelse &local;
    return substituteValueCached(arena, v, ctx, inputs, cache);
}

fn substituteValueCached(arena: Allocator, v: *std.json.Value, ctx: *const VarContext, inputs: []const InputDef, cache: *InputCache) SubstError!void {
    switch (v.*) {
        .string => |s| v.* = .{ .string = try substitute(arena, s, ctx, inputs, cache) },
        .array => |*a| for (a.items) |*item| try substituteValueCached(arena, item, ctx, inputs, cache),
        .object => |*o| {
            var it = o.iterator();
            while (it.next()) |e| try substituteValueCached(arena, e.value_ptr, ctx, inputs, cache);
        },
        else => {},
    }
}

fn substitute(arena: Allocator, s: []const u8, ctx: *const VarContext, inputs: []const InputDef, cache: *InputCache) SubstError![]const u8 {
    if (std.mem.indexOf(u8, s, "${") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const start = std.mem.indexOfPos(u8, s, i, "${") orelse break;
        const close = std.mem.indexOfScalarPos(u8, s, start + 2, '}') orelse break;
        try out.appendSlice(arena, s[i..start]);
        const name = s[start + 2 .. close];
        try out.appendSlice(arena, try resolve(arena, name, ctx, inputs, cache));
        i = close + 1;
    }
    try out.appendSlice(arena, s[i..]);
    return out.items;
}

fn fail(ctx: *const VarContext, err: SubstError, name: []const u8) SubstError {
    if (ctx.diag) |d| switch (err) {
        error.UnknownVariable => d.add(.err, "unknown variable ${{{s}}}", .{name}),
        error.MissingContext => d.add(.err, "variable ${{{s}}} has no value here (no workspace folder, file or selection)", .{name}),
        error.CommandNotAllowed => d.add(.err, "command in ${{{s}}} is not allowed in variable substitution", .{name}),
        error.Cancelled => d.add(.err, "input for ${{{s}}} was cancelled", .{name}),
        error.OutOfMemory => {},
    };
    return err;
}

fn need(ctx: *const VarContext, v: ?[]const u8, name: []const u8) SubstError![]const u8 {
    return v orelse fail(ctx, error.MissingContext, name);
}

fn resolve(arena: Allocator, name: []const u8, ctx: *const VarContext, inputs: []const InputDef, cache: *InputCache) SubstError![]const u8 {
    if (std.mem.indexOfScalar(u8, name, ':')) |colon| {
        const scope = name[0..colon];
        const arg = name[colon + 1 ..];
        if (std.mem.eql(u8, scope, "env")) return ctx.env.get(arg) orelse "";
        if (std.mem.eql(u8, scope, "config")) return ctx.config(ctx.ctx, arg, arena) orelse "";
        if (std.mem.eql(u8, scope, "command")) {
            const r = ctx.command(ctx.ctx, arg, arena) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.CommandNotAllowed => return fail(ctx, error.CommandNotAllowed, name),
                else => return fail(ctx, error.UnknownVariable, name),
            };
            return r orelse "";
        }
        if (std.mem.eql(u8, scope, "input")) return input(arena, name, arg, ctx, inputs, cache);
        if (std.mem.eql(u8, scope, "workspaceFolder") or std.mem.eql(u8, scope, "workspaceFolderBasename")) {
            for (ctx.workspace_folders) |f| {
                if (!std.mem.eql(u8, f.name, arg)) continue;
                return if (scope.len == "workspaceFolder".len) f.path else basename(ctx.os, f.path);
            }
            return fail(ctx, error.UnknownVariable, name);
        }
        return fail(ctx, error.UnknownVariable, name);
    }
    const P = Predefined;
    const which = std.meta.stringToEnum(P, name) orelse
        (if (std.mem.eql(u8, name, "/")) P.pathSeparator else return fail(ctx, error.UnknownVariable, name));
    const sep: []const u8 = if (ctx.os == .windows) "\\" else "/";
    return switch (which) {
        .workspaceFolder => need(ctx, ctx.workspace_folder, name),
        .workspaceFolderBasename => basename(ctx.os, try need(ctx, ctx.workspace_folder, name)),
        .file => need(ctx, ctx.file, name),
        .fileWorkspaceFolder => need(ctx, fileFolder(ctx), name),
        .relativeFile => relative(ctx, try need(ctx, ctx.file, name), try need(ctx, fileFolder(ctx), name)),
        .relativeFileDirname => relative(ctx, dirname(ctx.os, try need(ctx, ctx.file, name)), try need(ctx, fileFolder(ctx), name)),
        .fileBasename => basename(ctx.os, try need(ctx, ctx.file, name)),
        .fileBasenameNoExtension => stem(basename(ctx.os, try need(ctx, ctx.file, name))),
        .fileExtname => extname(basename(ctx.os, try need(ctx, ctx.file, name))),
        .fileDirname => dirname(ctx.os, try need(ctx, ctx.file, name)),
        .fileDirnameBasename => basename(ctx.os, dirname(ctx.os, try need(ctx, ctx.file, name))),
        .cwd => ctx.cwd,
        .lineNumber => if (ctx.line) |l| try std.fmt.allocPrint(arena, "{d}", .{l}) else fail(ctx, error.MissingContext, name),
        .columnNumber => if (ctx.column) |c| try std.fmt.allocPrint(arena, "{d}", .{c}) else fail(ctx, error.MissingContext, name),
        .selectedText => need(ctx, ctx.selected_text, name),
        .execPath => ctx.exec_path,
        .defaultBuildTask => need(ctx, ctx.default_build_task, name),
        .pathSeparator => sep,
        .userHome => ctx.user_home,
    };
}

const Predefined = enum {
    workspaceFolder,
    workspaceFolderBasename,
    file,
    fileWorkspaceFolder,
    relativeFile,
    relativeFileDirname,
    fileBasename,
    fileBasenameNoExtension,
    fileExtname,
    fileDirname,
    fileDirnameBasename,
    cwd,
    lineNumber,
    columnNumber,
    selectedText,
    execPath,
    defaultBuildTask,
    pathSeparator,
    userHome,
};

fn input(arena: Allocator, name: []const u8, id: []const u8, ctx: *const VarContext, inputs: []const InputDef, cache: *InputCache) SubstError![]const u8 {
    if (cache.get(id)) |v| return v;
    for (inputs) |*def| {
        if (!std.mem.eql(u8, def.id, id)) continue;
        const answer = ctx.input(ctx.ctx, def, arena) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return fail(ctx, error.Cancelled, name),
        } orelse return fail(ctx, error.Cancelled, name);
        try cache.put(arena, try arena.dupe(u8, id), answer);
        return answer;
    }
    return fail(ctx, error.UnknownVariable, name);
}

fn isSep(os: std.Target.Os.Tag, c: u8) bool {
    return c == '/' or (os == .windows and c == '\\');
}

fn trimTrailingSep(os: std.Target.Os.Tag, p: []const u8) []const u8 {
    var end = p.len;
    while (end > 1 and isSep(os, p[end - 1])) end -= 1;
    return p[0..end];
}

fn basename(os: std.Target.Os.Tag, p_in: []const u8) []const u8 {
    const p = trimTrailingSep(os, p_in);
    var i = p.len;
    while (i > 0) : (i -= 1) if (isSep(os, p[i - 1])) return p[i..];
    return p;
}

fn dirname(os: std.Target.Os.Tag, p_in: []const u8) []const u8 {
    const p = trimTrailingSep(os, p_in);
    var i = p.len;
    while (i > 0) : (i -= 1) {
        if (isSep(os, p[i - 1])) return if (i == 1) p[0..1] else p[0 .. i - 1];
    }
    return ".";
}

fn extname(base: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "";
    if (dot == 0) return "";
    return base[dot..];
}

fn stem(base: []const u8) []const u8 {
    return base[0 .. base.len - extname(base).len];
}

/// The workspace folder containing `file`: the longest matching folder of
/// `workspace_folders`, else `workspace_folder`.
fn fileFolder(ctx: *const VarContext) ?[]const u8 {
    const file = ctx.file orelse return ctx.workspace_folder;
    var best: ?[]const u8 = null;
    for (ctx.workspace_folders) |f| {
        if (isUnder(ctx.os, file, f.path) and (best == null or f.path.len > best.?.len)) best = f.path;
    }
    if (best) |b| return b;
    return ctx.workspace_folder;
}

fn eqlPathByte(os: std.Target.Os.Tag, a: u8, b: u8) bool {
    if (isSep(os, a) and isSep(os, b)) return true;
    if (os == .windows) return std.ascii.toLower(a) == std.ascii.toLower(b);
    return a == b;
}

fn isUnder(os: std.Target.Os.Tag, file: []const u8, folder_in: []const u8) bool {
    const folder = trimTrailingSep(os, folder_in);
    if (file.len <= folder.len) return false;
    for (folder, file[0..folder.len]) |a, b| if (!eqlPathByte(os, a, b)) return false;
    return isSep(os, file[folder.len]) or (folder.len > 0 and isSep(os, folder[folder.len - 1]));
}

/// `path` relative to `folder`, or `path` itself when it is outside.
fn relative(ctx: *const VarContext, path: []const u8, folder_in: []const u8) []const u8 {
    const folder = trimTrailingSep(ctx.os, folder_in);
    if (path.len == folder.len and isUnderOrEqual(ctx.os, path, folder)) return "";
    if (!isUnder(ctx.os, path, folder)) return path;
    var rest = path[folder.len..];
    while (rest.len > 0 and isSep(ctx.os, rest[0])) rest = rest[1..];
    return rest;
}

fn isUnderOrEqual(os: std.Target.Os.Tag, a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!eqlPathByte(os, x, y)) return false;
    return true;
}
