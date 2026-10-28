//! Workflow builtins (E13.F08.S01.T03): Zig functions a `builtin` step
//! (or a map body) calls with the value at its `input` path. Shipped here:
//! `files.glob` (workspace files matching a glob, through `GlobPort`),
//! `scm.changed_files` (files changed in a revset, through `ScmPort`),
//! `lanes.collect` (the lanes this run's writers worked in, for E12
//! review; nothing lands automatically) and `artifact.write_table` (an
//! E13.F07 table artifact, through `ArtifactPort`). Research mode
//! registers `research.verify` and `research.write_report`.

const std = @import("std");
const run = @import("../runs/run.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;
const RunId = run.RunId;

/// A writer lane: the worker that used it and the lane name.
pub const LaneUse = struct { step: []const u8, pos: []const u8, child: RunId, lane: []const u8 };

pub const BuiltinCtx = struct {
    io: Io,
    run: RunId,
    step: []const u8,
    /// Lanes the run's writers used so far (in start order).
    lanes: []const LaneUse,
    /// Set by the registry that owns the builtin.
    user: ?*anyopaque = null,
};

pub const BuiltinFn = *const fn (ctx: *BuiltinCtx, input: Value, arena: Allocator) anyerror!Value;

pub const GlobPort = struct {
    ctx: *anyopaque,
    /// Workspace-relative paths matching `pattern`, sorted.
    glob: *const fn (ctx: *anyopaque, arena: Allocator, pattern: []const u8) anyerror![]const []const u8,
};

pub const ScmPort = struct {
    ctx: *anyopaque,
    /// Files changed by the commits in `revset` (default `@`).
    changed_files: *const fn (ctx: *anyopaque, arena: Allocator, revset: []const u8) anyerror![]const []const u8,
};

pub const ArtifactPort = struct {
    ctx: *anyopaque,
    /// Writes a table artifact; returns its id.
    write_table: *const fn (ctx: *anyopaque, arena: Allocator, title: []const u8, rows: Value) anyerror![]const u8,
};

pub const Ports = struct {
    glob: ?GlobPort = null,
    scm: ?ScmPort = null,
    artifacts: ?ArtifactPort = null,
};

const Entry = struct { f: BuiltinFn, user: ?*anyopaque };

gpa: Allocator,
map: std.StringArrayHashMapUnmanaged(Entry) = .empty,
ports: Ports = .{},

const BuiltinRegistry = @This();

pub fn init(gpa: Allocator) BuiltinRegistry {
    return .{ .gpa = gpa };
}

/// The four shipped builtins over `ports` (a missing port makes its
/// builtin fail with "not available").
pub fn standard(gpa: Allocator, ports: Ports) !BuiltinRegistry {
    var r: BuiltinRegistry = .{ .gpa = gpa, .ports = ports };
    errdefer r.deinit();
    try r.register("files.glob", filesGlob);
    try r.register("scm.changed_files", scmChanged);
    try r.register("lanes.collect", lanesCollect);
    try r.register("artifact.write_table", writeTable);
    return r;
}

pub fn deinit(r: *BuiltinRegistry) void {
    r.map.deinit(r.gpa);
}

/// Adds or replaces builtin `name`. `name` must outlive the registry.
pub fn register(r: *BuiltinRegistry, name: []const u8, f: BuiltinFn) !void {
    try r.registerWith(name, f, null);
}

/// `register` with a context the function finds in `BuiltinCtx.user`.
pub fn registerWith(r: *BuiltinRegistry, name: []const u8, f: BuiltinFn, user: ?*anyopaque) !void {
    try r.map.put(r.gpa, name, .{ .f = f, .user = user });
}

/// Registered names, for `ValidateEnv.builtins`.
pub fn names(r: *const BuiltinRegistry) []const []const u8 {
    return r.map.keys();
}

/// Runs builtin `name`; error.UnknownBuiltin if there is none.
pub fn call(r: *BuiltinRegistry, name: []const u8, ctx: *BuiltinCtx, input: Value, arena: Allocator) anyerror!Value {
    const e = r.map.get(name) orelse return error.UnknownBuiltin;
    ctx.user = e.user orelse r;
    return e.f(ctx, input, arena);
}

fn self(ctx: *BuiltinCtx) *BuiltinRegistry {
    return @ptrCast(@alignCast(ctx.user.?));
}

fn stringArray(arena: Allocator, items: []const []const u8) !Value {
    var arr: std.json.Array = .init(arena);
    try arr.ensureTotalCapacity(items.len);
    for (items) |s| arr.appendAssumeCapacity(.{ .string = s });
    return .{ .array = arr };
}

fn stringField(v: Value, key: []const u8) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        .object => |o| if (o.get(key)) |x| switch (x) {
            .string => |s| s,
            else => null,
        } else null,
        else => null,
    };
}

/// Input: a glob string, or `{"glob": "…"}`. Output: the paths.
fn filesGlob(ctx: *BuiltinCtx, input: Value, arena: Allocator) anyerror!Value {
    const p = self(ctx).ports.glob orelse return error.GlobNotAvailable;
    const pattern = stringField(input, "glob") orelse return error.ExpectedGlob;
    return stringArray(arena, try p.glob(p.ctx, arena, pattern));
}

/// Input: a revset string, `{"revset": "…"}` or nothing (`@`).
fn scmChanged(ctx: *BuiltinCtx, input: Value, arena: Allocator) anyerror!Value {
    const p = self(ctx).ports.scm orelse return error.ScmNotAvailable;
    const revset = stringField(input, "revset") orelse "@";
    return stringArray(arena, try p.changed_files(p.ctx, arena, revset));
}

/// Output: `[{"step","pos","child","lane"}]` for every writer lane.
fn lanesCollect(ctx: *BuiltinCtx, _: Value, arena: Allocator) anyerror!Value {
    var arr: std.json.Array = .init(arena);
    for (ctx.lanes) |l| {
        var o: std.json.ObjectMap = .empty;
        try o.put(arena, "step", .{ .string = l.step });
        try o.put(arena, "pos", .{ .string = l.pos });
        try o.put(arena, "child", .{ .string = try arena.dupe(u8, &l.child.text()) });
        try o.put(arena, "lane", .{ .string = l.lane });
        try arr.append(.{ .object = o });
    }
    return .{ .array = arr };
}

/// Input: `{"title": "…", "rows": [...]}` or the rows. Output: `{"artifact": id}`.
fn writeTable(ctx: *BuiltinCtx, input: Value, arena: Allocator) anyerror!Value {
    const p = self(ctx).ports.artifacts orelse return error.ArtifactsNotAvailable;
    const title = stringField(input, "title") orelse ctx.step;
    const rows: Value = switch (input) {
        .object => |o| o.get("rows") orelse return error.ExpectedRows,
        .array => input,
        else => return error.ExpectedRows,
    };
    const id = try p.write_table(p.ctx, arena, title, rows);
    var o: std.json.ObjectMap = .empty;
    try o.put(arena, "artifact", .{ .string = id });
    return .{ .object = o };
}
