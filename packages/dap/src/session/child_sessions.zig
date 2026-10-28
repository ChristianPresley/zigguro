//! The `startDebugging` reverse request (E07.F06.S02.T02): the adapter
//! asks for a child session (js-debug starts one per worker and child
//! process).
//!
//! - The request is answered at once; the child then runs its own start
//!   sequence (`DebugSession.run`) with `configuration` as its
//!   launch/attach arguments, as they are: no `${...}` substitution, no
//!   normalize hook, no pre-launch task.
//! - The child has the parent's adapter type and controller and is listed
//!   under the parent. A stdio adapter gets a new process; a TCP adapter
//!   (js-debug's server) gets a second connection to the same port.
//! - Stopping the parent stops its children first; a child ending does
//!   not end the parent. A child that cannot start is reported in the
//!   parent's console and the parent keeps running.

const std = @import("std");
const DapConnection = @import("../conn/DapConnection.zig");
const LaunchConfig = @import("../config/LaunchConfig.zig");
const DebugSession = @import("DebugSession.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The request's arguments as sent.
const Wire = struct {
    configuration: std.json.Value,
    request: []const u8,
};

/// The child configuration of a `startDebugging` request from `parent`;
/// strings in `a`.
pub fn childConfig(a: Allocator, parent: *const LaunchConfig, bytes: []const u8) error{ OutOfMemory, InvalidArguments }!LaunchConfig {
    const w = std.json.parseFromSliceLeaky(Wire, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArguments,
    };
    if (w.configuration != .object) return error.InvalidArguments;
    const request = std.meta.stringToEnum(LaunchConfig.Request, w.request) orelse return error.InvalidArguments;
    const name = if (w.configuration.object.get("name")) |n| switch (n) {
        .string => |s| s,
        else => parent.name,
    } else parent.name;
    return .{
        .name = name,
        .type = parent.type,
        .request = request,
        .args = w.configuration.object,
        .source = parent.source,
        .origin_path = parent.origin_path,
    };
}

/// The reverse request handler (on the dispatcher).
pub fn handle(ctx: ?*anyopaque, c: *DapConnection, req: DapConnection.ReverseRequest, _: Allocator) void {
    const s: *DebugSession = @ptrCast(@alignCast(ctx.?));
    const job = s.gpa.create(Job) catch return refuse(c, req.seq, "out of memory");
    job.* = .{ .s = s, .arena = .init(s.gpa), .cfg = undefined };
    const bytes = if (req.arguments) |r| r.bytes else "{}";
    job.cfg = childConfig(job.arena.allocator(), &s.cfg, bytes) catch |e| {
        job.destroy();
        return refuse(c, req.seq, if (e == error.OutOfMemory) "out of memory" else "invalid startDebugging arguments");
    };
    c.respond(req.seq, "startDebugging", true, null, null) catch {};
    s.work.spawnLoop(Job.run, .{job}) catch {
        s.note("Cannot start the child session \"{s}\"", .{job.cfg.name});
        job.destroy();
    };
}

fn refuse(c: *DapConnection, seq: u32, msg: []const u8) void {
    c.respond(seq, "startDebugging", false, null, msg) catch {};
}

const Job = struct {
    s: *DebugSession,
    arena: std.heap.ArenaAllocator,
    cfg: LaunchConfig,

    fn destroy(j: *Job) void {
        j.arena.deinit();
        j.s.gpa.destroy(j);
    }

    fn run(j: *Job) Io.Cancelable!void {
        defer j.destroy();
        const s = j.s;
        const reach = s.adapterReach();
        _ = s.manager.start(&j.cfg, .{
            .parent = s,
            .controller = s.controller(),
            .connect = if (reach.port != 0) .{ .port = reach.port, .adapter_id = reach.adapter_id } else null,
        }) catch |e| s.note("Cannot start the child session \"{s}\": {t}", .{ j.cfg.name, e });
    }
};

/// Stops `s`'s children and waits for them. On a session worker.
pub fn stopChildren(s: *DebugSession) void {
    var buf: [32]*DebugSession = undefined;
    var list: std.ArrayList(*DebugSession) = .initBuffer(&buf);
    {
        const m = s.manager;
        m.mutex.lockUncancelable(m.rt.io);
        defer m.mutex.unlock(m.rt.io);
        for (s.children_.items) |ch| if (list.items.len < buf.len) list.appendAssumeCapacity(ch);
    }
    for (list.items) |ch| if (!ch.ended_event.isSet()) ch.stopAndWait();
}
