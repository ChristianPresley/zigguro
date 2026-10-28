//! A scripted `WorkerPort` for workflow tests and benches: every start is
//! recorded, then answered on a responder task by `script` (a result, a
//! failure, cost or lane reports first, or no answer at all until the
//! child is stopped). `running`/`max_running` count children started but
//! not yet answered.

const std = @import("std");
const run = @import("../runs/run.zig");
const WorkflowEngine = @import("exec.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const RunId = run.RunId;

pub const Job = struct {
    child: RunId,
    step: []const u8,
    pos: []const u8,
    prompt: []const u8,
    attempt: u8,
    seed: u64,
    isolation: run.Isolation,
    budgets: run.Budgets,
};

pub const Reply = union(enum) {
    text: []const u8,
    fail: []const u8,
    /// No answer until stopped.
    hang,
    cost_then_text: struct { cost: run.Cost, text: []const u8 },
    lane_then_text: struct { lane: []const u8, text: []const u8 },
};

pub const Script = *const fn (f: *Fake, job: Job) Reply;

pub const Fake = struct {
    gpa: Allocator,
    io: Io,
    eng: *WorkflowEngine = undefined,
    script: Script,
    /// Sleep before each answer.
    delay_ms: u32 = 0,
    user: ?*anyopaque = null,

    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    /// Owns job strings.
    arena: std.heap.ArenaAllocator,
    queue: std.ArrayList(Job) = .empty,
    starts: std.ArrayList(Job) = .empty,
    hanging: std.ArrayList(RunId) = .empty,
    stops: std.ArrayList(RunId) = .empty,
    running: u32 = 0,
    max_running: u32 = 0,
    closing: bool = false,
    group: Io.Group = .init,

    pub fn init(f: *Fake, gpa: Allocator, io: Io, script: Script) !void {
        f.* = .{ .gpa = gpa, .io = io, .script = script, .arena = .init(gpa) };
        try f.group.concurrent(io, responder, .{f});
    }

    pub fn deinit(f: *Fake) void {
        f.mutex.lockUncancelable(f.io);
        f.closing = true;
        f.cond.broadcast(f.io);
        f.mutex.unlock(f.io);
        f.group.cancel(f.io);
        f.queue.deinit(f.gpa);
        f.starts.deinit(f.gpa);
        f.hanging.deinit(f.gpa);
        f.stops.deinit(f.gpa);
        f.arena.deinit();
    }

    pub fn port(f: *Fake) WorkflowEngine.WorkerPort {
        return .{ .ctx = f, .start = start, .stop = stop };
    }

    fn start(ctx: *anyopaque, req: *const WorkflowEngine.WorkerRequest) anyerror!void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        const a = f.arena.allocator();
        const job: Job = .{
            .child = req.child,
            .step = try a.dupe(u8, req.step),
            .pos = try a.dupe(u8, req.pos),
            .prompt = try a.dupe(u8, req.prompt),
            .attempt = req.attempt,
            .seed = req.seed,
            .isolation = req.isolation,
            .budgets = req.budgets,
        };
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        try f.starts.append(f.gpa, job);
        try f.queue.append(f.gpa, job);
        f.running += 1;
        f.max_running = @max(f.max_running, f.running);
        f.cond.signal(f.io);
    }

    fn stop(ctx: *anyopaque, child: RunId) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        const was_hanging = blk: {
            f.mutex.lockUncancelable(f.io);
            defer f.mutex.unlock(f.io);
            f.stops.append(f.gpa, child) catch {};
            for (f.hanging.items, 0..) |h, i| if (h.eql(child)) {
                _ = f.hanging.swapRemove(i);
                f.running -= 1;
                break :blk true;
            };
            // Not answered yet: it never will be.
            for (f.queue.items, 0..) |j, i| if (j.child.eql(child)) {
                _ = f.queue.orderedRemove(i);
                f.running -= 1;
                break :blk true;
            };
            break :blk false;
        };
        if (was_hanging) f.eng.workerEvent(child, .stopped);
    }

    fn responder(f: *Fake) Io.Cancelable!void {
        while (true) {
            const job = blk: {
                f.mutex.lockUncancelable(f.io);
                defer f.mutex.unlock(f.io);
                while (f.queue.items.len == 0) {
                    if (f.closing) return;
                    try f.cond.wait(f.io, &f.mutex);
                }
                break :blk f.queue.orderedRemove(0);
            };
            if (f.delay_ms > 0) try f.io.sleep(.fromMilliseconds(f.delay_ms), .awake);
            const r = f.script(f, job);
            if (r == .hang) {
                f.mutex.lockUncancelable(f.io);
                defer f.mutex.unlock(f.io);
                f.hanging.append(f.gpa, job.child) catch {};
                continue;
            }
            {
                f.mutex.lockUncancelable(f.io);
                defer f.mutex.unlock(f.io);
                f.running -= 1;
            }
            switch (r) {
                .text => |t| f.eng.workerEvent(job.child, .{ .result = t }),
                .fail => |m| f.eng.workerEvent(job.child, .{ .failed = m }),
                .cost_then_text => |c| {
                    f.eng.workerEvent(job.child, .{ .cost = c.cost });
                    f.eng.workerEvent(job.child, .{ .result = c.text });
                },
                .lane_then_text => |l| {
                    f.eng.workerEvent(job.child, .{ .lane = l.lane });
                    f.eng.workerEvent(job.child, .{ .result = l.text });
                },
                .hang => unreachable,
            }
        }
    }

    /// Starts so far whose step is `step` (all when null).
    pub fn count(f: *Fake, step: ?[]const u8) usize {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        if (step == null) return f.starts.items.len;
        var n: usize = 0;
        for (f.starts.items) |j| {
            if (std.mem.eql(u8, j.step, step.?)) n += 1;
        }
        return n;
    }

    pub fn started(f: *Fake, i: usize) Job {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        return f.starts.items[i];
    }

    /// Whether some start had plan position `pos`.
    pub fn hasPos(f: *Fake, pos: []const u8) bool {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        for (f.starts.items) |j| if (std.mem.eql(u8, j.pos, pos)) return true;
        return false;
    }
};

/// Answers every agent with its prompt.
pub fn echo(_: *Fake, job: Job) Reply {
    return .{ .text = job.prompt };
}
