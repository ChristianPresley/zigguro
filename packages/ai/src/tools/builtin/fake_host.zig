//! A scripted `TerminalHost` for tests: each command plays a list of
//! steps (lines, virtual delays, an exit) against its own virtual clock,
//! so timeouts are deterministic. A `hang` step blocks on the real clock
//! until the waiter is canceled.

const std = @import("std");
const proto = @import("zg_ai_proto");
const host_mod = @import("terminal_host.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Step = union(enum) {
    line: []const u8,
    delay_ms: u64,
    exit: i32,
    /// Blocks (cancelably) until interrupted.
    hang,
};

pub const Script = struct {
    command: []const u8,
    steps: []const Step,
};

const Job = struct {
    steps: []const Step,
    at: usize = 0,
    /// Virtual time left in the current delay step.
    delay_left: ?u64 = null,
    lines: std.ArrayList([]const u8) = .empty,
    status: host_mod.Status = .running,
};

pub const FakeHost = struct {
    gpa: Allocator,
    scripts: []const Script,
    mutex: Io.Mutex = .init,
    jobs: std.ArrayList(*Job) = .empty,
    /// Recorded calls.
    sessions: std.ArrayList(struct { owner: proto.AgentRef, visible: bool }) = .empty,
    started: std.ArrayList(struct { command: []const u8, cwd: ?[]const u8 }) = .empty,
    interrupts: u32 = 0,

    pub fn init(gpa: Allocator, scripts: []const Script) FakeHost {
        return .{ .gpa = gpa, .scripts = scripts };
    }

    pub fn deinit(f: *FakeHost) void {
        for (f.jobs.items) |j| {
            j.lines.deinit(f.gpa);
            f.gpa.destroy(j);
        }
        f.jobs.deinit(f.gpa);
        f.sessions.deinit(f.gpa);
        f.started.deinit(f.gpa);
    }

    pub fn host(f: *FakeHost) host_mod.TerminalHost {
        return .{ .ctx = f, .vtable = &.{
            .create = create,
            .start = start,
            .wait = wait,
            .lines = lines,
            .status = status,
            .interrupt = interrupt,
        } };
    }

    fn create(ctx: *anyopaque, io: Io, owner: proto.AgentRef, visible: bool) host_mod.Error!host_mod.SessionId {
        const f: *FakeHost = @ptrCast(@alignCast(ctx));
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        try f.sessions.append(f.gpa, .{ .owner = owner, .visible = visible });
        return @intCast(f.sessions.items.len);
    }

    fn start(ctx: *anyopaque, io: Io, _: host_mod.SessionId, command: []const u8, cwd: ?[]const u8) host_mod.Error!host_mod.JobId {
        const f: *FakeHost = @ptrCast(@alignCast(ctx));
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        try f.started.append(f.gpa, .{ .command = command, .cwd = cwd });
        const steps = for (f.scripts) |s| {
            if (std.mem.eql(u8, s.command, command)) break s.steps;
        } else return error.SpawnFailed;
        const j = try f.gpa.create(Job);
        j.* = .{ .steps = steps };
        try f.jobs.append(f.gpa, j);
        return @intCast(f.jobs.items.len - 1);
    }

    fn wait(ctx: *anyopaque, io: Io, id: host_mod.JobId, timeout_ms: u64, sink: ?host_mod.LineSink) Io.Cancelable!host_mod.Status {
        const f: *FakeHost = @ptrCast(@alignCast(ctx));
        const j = f.jobs.items[id];
        var budget = timeout_ms;
        while (j.status == .running and j.at < j.steps.len) {
            switch (j.steps[j.at]) {
                .line => |l| {
                    f.mutex.lockUncancelable(io);
                    j.lines.append(f.gpa, l) catch {};
                    f.mutex.unlock(io);
                    if (sink) |s| s.line(s.ctx, l);
                },
                .delay_ms => |ms| {
                    const left = j.delay_left orelse ms;
                    if (left > budget) {
                        j.delay_left = left - budget;
                        return .running;
                    }
                    budget -= left;
                    j.delay_left = null;
                },
                .exit => |code| j.status = .{ .exited = code },
                .hang => {
                    try io.sleep(.fromSeconds(60), .awake);
                    return .running;
                },
            }
            j.at += 1;
        }
        return j.status;
    }

    fn lines(ctx: *anyopaque, arena: Allocator, id: host_mod.JobId, since: usize) Allocator.Error![]const []const u8 {
        const f: *FakeHost = @ptrCast(@alignCast(ctx));
        const all = f.jobs.items[id].lines.items;
        if (since >= all.len) return &.{};
        return arena.dupe([]const u8, all[since..]);
    }

    fn status(ctx: *anyopaque, id: host_mod.JobId) host_mod.Status {
        const f: *FakeHost = @ptrCast(@alignCast(ctx));
        return f.jobs.items[id].status;
    }

    fn interrupt(ctx: *anyopaque, _: Io, id: host_mod.JobId) void {
        const f: *FakeHost = @ptrCast(@alignCast(ctx));
        f.interrupts += 1;
        const j = f.jobs.items[id];
        if (j.status == .running) j.status = .killed;
    }
};
