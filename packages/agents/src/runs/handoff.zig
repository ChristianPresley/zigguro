//! Handing runs between processes (E13.F01.S01.T03). On GUI exit with
//! `agents.host.keep_running`, the GUI pauses every live run at its next
//! tool boundary (an in-flight tool call finishes first), flushes its
//! journals, disposes the agents (which flushes their E10 sessions) and
//! asks the headless host to `runs.adopt` them; the host resumes each
//! from its session, so no tool call runs twice. Also the idle-exit timer
//! of `zg agents host`.

const std = @import("std");
const run = @import("run.zig");
const protocol = @import("protocol.zig");
const RunRegistry = @import("registry.zig");
const RunHost = @import("host.zig");
const ipc = @import("ipc.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const RunId = run.RunId;

pub const HandoffResult = struct { transferred: u32 = 0, failed: u32 = 0, left_running: u32 = 0 };

pub const Options = struct {
    /// How long to wait for runs to reach a tool boundary.
    pause_timeout_ms: u32 = 10_000,
};

/// Pauses `host`'s live runs and hands them to the host behind `client`.
/// Runs that do not pause in time stay with this process (the caller
/// decides whether to wait longer or stop them).
pub fn handoff(gpa: Allocator, io: Io, host: *RunHost, reg: *RunRegistry, client: *ipc.HostClient, opts: Options) !HandoffResult {
    var ids: std.ArrayList(RunId) = .empty;
    defer ids.deinit(gpa);
    try host.liveRuns(gpa, &ids);
    for (ids.items) |id| host.pause(id);

    // Wait until each is paused, queued or over.
    var ready: std.ArrayList(RunId) = .empty;
    defer ready.deinit(gpa);
    var res: HandoffResult = .{};
    var waited: u32 = 0;
    while (true) {
        ready.clearRetainingCapacity();
        var pending: u32 = 0;
        {
            const v = reg.snapshot();
            defer reg.release(v);
            for (ids.items) |id| {
                const r = v.get(id) orelse continue;
                switch (r.status) {
                    .paused, .queued => try ready.append(gpa, id),
                    .completed, .failed, .stopped, .interrupted => {},
                    else => pending += 1,
                }
            }
        }
        if (pending == 0 or waited >= opts.pause_timeout_ms) {
            res.left_running = pending;
            break;
        }
        io.sleep(.fromMilliseconds(5), .awake) catch break;
        waited += 5;
    }
    if (ready.items.len == 0) return res;
    for (ready.items) |id| host.forget(id);
    reg.flush();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const r = try client.call(protocol.methods.adopt, protocol.AdoptParams{ .ids = ready.items }, protocol.AdoptResult, arena.allocator());
    res.transferred = r.adopted;
    res.failed = r.failed;
    return res;
}

/// `zg agents host` exits after `idle_ms` with no active runs and no
/// clients.
pub const IdleTimer = struct {
    idle_ms: i64,
    since: ?i64 = null,

    /// Feeds the current state; true when the host should exit.
    pub fn tick(t: *IdleTimer, now_ms: i64, busy: bool) bool {
        if (busy) {
            t.since = null;
            return false;
        }
        const s = t.since orelse {
            t.since = now_ms;
            return false;
        };
        return now_ms - s >= t.idle_ms;
    }
};

test "idle_exit_after_timeout" {
    var t: IdleTimer = .{ .idle_ms = 600_000 };
    try std.testing.expect(!t.tick(0, false));
    try std.testing.expect(!t.tick(599_999, false));
    try std.testing.expect(!t.tick(600_000, true)); // a client came and went
    try std.testing.expect(!t.tick(700_000, false));
    try std.testing.expect(t.tick(1_300_000, false));
}
