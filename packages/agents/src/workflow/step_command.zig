//! `command` and `builtin` steps (E13.F08.S01.T03). Commands run through
//! the E06 terminal service (`CommandPort`), which asks for approval
//! under the workflow's permission profile; a workflow without a profile
//! cannot run commands, and a refused approval fails the step with
//! "command denied". `{{$.path}}` placeholders in argv and cwd are filled
//! in. The result is `{"exit_code", "output"}`; an exit code other than
//! `expect_exit` fails the step. Builtins are looked up in the engine's
//! `BuiltinRegistry` and called with the value at their `input` path.

const std = @import("std");
const exec = @import("exec.zig");
const def = @import("def.zig");
const path_mod = @import("path.zig");
const interp = @import("interpolate.zig");
const builtins = @import("builtins.zig");

const Value = std.json.Value;
const Exec = exec.Exec;
const Abort = exec.Abort;
const Outcome = exec.Outcome;

pub const Ran = union(enum) { ok: exec.CommandResult, failed: []const u8 };

/// Runs `argv` (with placeholders filled in from `scope`).
pub fn runArgv(x: *Exec, id: []const u8, argv: []const []const u8, shell: bool, cwd: ?[]const u8, scope: Value) Abort!Ran {
    const a = x.allocator();
    const profile = x.def.profile orelse return .{ .failed = "command steps need a permission profile that allows commands" };
    const port = x.eng.svc.commands orelse return .{ .failed = "commands are not available here" };
    if (x.stopped()) return error.Stopped;
    const args = try a.alloc([]const u8, argv.len);
    for (argv, args) |s, *o| o.* = (interp.interpolate(a, s, scope, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failed = "invalid placeholder in argv" },
    }).text;
    var dir: ?[]const u8 = null;
    if (cwd) |c| dir = if (path_mod.isPath(c)) blk: {
        const p = path_mod.Path.compile(a, c) catch return .{ .failed = "invalid cwd path" };
        break :blk try interp.render(a, try p.value(scope, a));
    } else c;
    const r = port.exec(port.ctx, a, .{ .argv = args, .shell = shell, .cwd = dir, .profile = profile, .run = x.id, .step = id }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Denied => return .{ .failed = "command denied" },
        else => return .{ .failed = try std.fmt.allocPrint(a, "command failed: {t}", .{e}) },
    };
    return .{ .ok = r };
}

pub fn run(x: *Exec, id: []const u8, c: *const def.CommandStep, scope: Value) Abort!Outcome {
    const a = x.allocator();
    const r = switch (try runArgv(x, id, c.argv, c.shell, c.cwd, scope)) {
        .ok => |r| r,
        .failed => |m| return .{ .failed = m },
    };
    if (c.expect_exit) |want| if (r.exit_code != want) {
        const out = std.mem.trim(u8, r.output, " \t\r\n");
        return x.failf("exit code {d} (expected {d}): {s}", .{ r.exit_code, want, out[out.len -| 400..] });
    };
    var o: std.json.ObjectMap = .empty;
    try o.put(a, "exit_code", .{ .integer = r.exit_code });
    try o.put(a, "output", .{ .string = r.output });
    return .{ .ok = .{ .object = o } };
}

/// A builtin step.
pub fn runBuiltin(x: *Exec, id: []const u8, b: *const def.BuiltinStep, scope: Value, pos: []const u8) Abort!Outcome {
    _ = pos;
    x.tracker.setTotal(id, 1);
    const out = try callBuiltin(x, id, b, scope);
    x.tracker.agent(id, if (out == .ok) .item_ok else .item_failed);
    return out;
}

/// Calls builtin `b.name` with the value at `b.input`.
pub fn callBuiltin(x: *Exec, id: []const u8, b: *const def.BuiltinStep, scope: Value) Abort!Outcome {
    const a = x.allocator();
    const reg = x.eng.svc.builtins orelse return x.failf("builtin {s} is not available", .{b.name});
    if (x.stopped()) return error.Stopped;
    const p = path_mod.Path.compile(a, b.input) catch return x.failf("invalid input path {s}", .{b.input});
    const input = try p.value(scope, a);
    var ctx: builtins.BuiltinCtx = .{ .io = x.eng.io, .run = x.id, .step = id, .lanes = try x.lanesSnapshot(a) };
    const v = reg.call(b.name, &ctx, input, a) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnknownBuiltin => return x.failf("unknown builtin {s}", .{b.name}),
        else => return x.failf("{s} failed: {t}", .{ b.name, e }),
    };
    return .{ .ok = v };
}
