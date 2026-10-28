//! Compound launches (E07.F06.S02.T02): one name starting several
//! configurations together.
//!
//! - The compound's `preLaunchTask` runs first; if it fails nothing
//!   starts.
//! - Each configuration starts in the listed order, without waiting for
//!   the previous one to stop at entry. A missing or disabled one, or one
//!   that cannot start, is reported and the others still start.
//! - With `stopAll`, stopping any member stops every member, and
//!   restarting one restarts them all. Without it members are
//!   independent.

const std = @import("std");
const ConfigSet = @import("../config/ConfigSet.zig");
const DebugManager = @import("DebugManager.zig");
const DebugSession = @import("DebugSession.zig");

const Allocator = std.mem.Allocator;

/// A started compound; owned by the manager.
pub const CompoundRun = struct {
    name: []const u8,
    stop_all: bool,
    /// Under the manager's lock.
    members: std.ArrayList(*DebugSession) = .empty,

    pub fn deinit(r: *CompoundRun, gpa: Allocator) void {
        r.members.deinit(gpa);
        gpa.free(r.name);
        gpa.destroy(r);
    }
};

pub const StartResult = struct {
    run: ?*CompoundRun = null,
    /// The started sessions, in order.
    sessions: []const *DebugSession = &.{},
    /// Why configurations did not start (or why nothing did).
    errors: []const []const u8 = &.{},
};

/// Starts `c` from `set`; results in `arena`. Blocks while the compound's
/// pre-launch task runs: off the UI thread.
pub fn startCompound(m: *DebugManager, c: *const ConfigSet.Compound, set: *const ConfigSet, arena: Allocator) Allocator.Error!StartResult {
    var errors: std.ArrayList([]const u8) = .empty;
    if (c.pre_launch_task) |label| if (m.cfg.tasks) |th| switch (th.run(th.ctx, label, arena)) {
        .ok => {},
        .failed => |msg| {
            try errors.append(arena, try std.fmt.allocPrint(arena, "preLaunchTask \"{s}\" failed: {s}", .{ label, msg }));
            return .{ .errors = errors.items };
        },
    };
    const run = try m.gpa.create(CompoundRun);
    run.* = .{ .name = m.gpa.dupe(u8, c.name) catch |e| {
        m.gpa.destroy(run);
        return e;
    }, .stop_all = c.stop_all };
    {
        m.mutex.lockUncancelable(m.rt.io);
        defer m.mutex.unlock(m.rt.io);
        m.compounds.append(m.gpa, run) catch |e| {
            run.deinit(m.gpa);
            return e;
        };
    }
    var sessions: std.ArrayList(*DebugSession) = .empty;
    for (c.configurations) |name| {
        const cfg = set.find(name) orelse {
            try errors.append(arena, try std.fmt.allocPrint(arena, "there is no configuration \"{s}\"", .{name}));
            continue;
        };
        if (!cfg.enabled) {
            try errors.append(arena, try std.fmt.allocPrint(arena, "\"{s}\" is disabled: {s}", .{ name, cfg.disabled_reason orelse "unavailable" }));
            continue;
        }
        const s = m.start(cfg, .{ .compound = run }) catch |e| {
            try errors.append(arena, try std.fmt.allocPrint(arena, "cannot start \"{s}\": {t}", .{ name, e }));
            continue;
        };
        try sessions.append(arena, s);
    }
    return .{ .run = run, .sessions = sessions.items, .errors = errors.items };
}

/// The members of `run`, copied under the manager's lock.
fn members(m: *DebugManager, run: *CompoundRun, buf: []*DebugSession) []*DebugSession {
    m.mutex.lockUncancelable(m.rt.io);
    defer m.mutex.unlock(m.rt.io);
    const n = @min(buf.len, run.members.items.len);
    @memcpy(buf[0..n], run.members.items[0..n]);
    return buf[0..n];
}

/// Stops every member that still runs.
pub fn stopMembers(m: *DebugManager, run: *CompoundRun) void {
    var buf: [64]*DebugSession = undefined;
    for (members(m, run, &buf)) |s| if (!s.ended_event.isSet()) s.stopOne();
}

/// Restarts every member.
pub fn restartMembers(m: *DebugManager, run: *CompoundRun) void {
    var buf: [64]*DebugSession = undefined;
    for (members(m, run, &buf)) |s| s.restartOne();
}
