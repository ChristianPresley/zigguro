//! Binds the workflow engine's `WorkerPort` to `RunHost`
//! (E13.F08.S01.T03): every workflow agent becomes a child run
//! (`kind = .workflow_worker`, `parent` = the workflow run, origin
//! `.workflow{run, step}`), so it shows in Mission Control under its
//! parent with its own cost, lane and transcript. Activity and the full
//! final text come from the host's signal observer; the outcome from the
//! registry's terminal status.
//!
//! Setup: create `HostWorkers`, pass `observer()` in `HostConfig`, create
//! the host, then `attach(host, engine)`.

const std = @import("std");
const run = @import("../runs/run.zig");
const agent_port = @import("../runs/port.zig");
const RunHost = @import("../runs/host.zig");
const RunRegistry = @import("../runs/registry.zig");
const WorkflowEngine = @import("exec.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const RunId = run.RunId;

const Child = struct {
    /// The last assistant text (full length).
    text: []u8 = &.{},
    lane_sent: bool = false,
};

pub const HostWorkers = struct {
    gpa: Allocator,
    io: Io,
    reg: *RunRegistry,
    host: ?*RunHost = null,
    engine: ?*WorkflowEngine = null,
    mutex: Io.Mutex = .init,
    children: std.AutoHashMapUnmanaged(u128, Child) = .empty,
    listener: ?RunRegistry.ListenerId = null,

    pub fn init(gpa: Allocator, io: Io, reg: *RunRegistry) HostWorkers {
        return .{ .gpa = gpa, .io = io, .reg = reg };
    }

    /// Starts listening; `hw` must not move afterwards.
    pub fn attach(hw: *HostWorkers, host: *RunHost, engine: *WorkflowEngine) !void {
        hw.host = host;
        hw.engine = engine;
        hw.listener = try hw.reg.subscribe(.{ .ctx = hw, .on_event = onEvent });
    }

    pub fn deinit(hw: *HostWorkers) void {
        if (hw.listener) |l| hw.reg.unsubscribe(l);
        var it = hw.children.valueIterator();
        while (it.next()) |c| hw.gpa.free(c.text);
        hw.children.deinit(hw.gpa);
    }

    pub fn port(hw: *HostWorkers) WorkflowEngine.WorkerPort {
        return .{ .ctx = hw, .start = start, .stop = stop };
    }

    pub fn observer(hw: *HostWorkers) RunHost.Observer {
        return .{ .ctx = hw, .f = observe };
    }

    fn start(ctx: *anyopaque, req: *const WorkflowEngine.WorkerRequest) anyerror!void {
        const hw: *HostWorkers = @ptrCast(@alignCast(ctx));
        {
            hw.mutex.lockUncancelable(hw.io);
            defer hw.mutex.unlock(hw.io);
            try hw.children.put(hw.gpa, req.child.toInt(), .{});
        }
        errdefer hw.forget(req.child);
        _ = try hw.host.?.startWithId(req.child, .{
            .kind = .workflow_worker,
            .title = req.title,
            .prompt = req.prompt,
            .agent_def = req.agent_def,
            .model = req.model_role,
            .profile = req.profile,
            .isolation = req.isolation,
            .origin = .{ .workflow = .{ .run = req.parent, .step = req.step } },
            .budgets = req.budgets,
            .parent = req.parent,
        });
    }

    fn stop(ctx: *anyopaque, child: RunId) void {
        const hw: *HostWorkers = @ptrCast(@alignCast(ctx));
        hw.host.?.stop(child, .graceful);
    }

    fn forget(hw: *HostWorkers, child: RunId) void {
        hw.mutex.lockUncancelable(hw.io);
        defer hw.mutex.unlock(hw.io);
        if (hw.children.fetchRemove(child.toInt())) |kv| hw.gpa.free(kv.value.text);
    }

    fn tracked(hw: *HostWorkers, id: RunId) bool {
        hw.mutex.lockUncancelable(hw.io);
        defer hw.mutex.unlock(hw.io);
        return hw.children.contains(id.toInt());
    }

    fn observe(ctx: *anyopaque, id: RunId, s: agent_port.Signal) void {
        const hw: *HostWorkers = @ptrCast(@alignCast(ctx));
        const eng = hw.engine orelse return;
        if (!hw.tracked(id)) return;
        switch (s) {
            .summary => |text| {
                {
                    hw.mutex.lockUncancelable(hw.io);
                    defer hw.mutex.unlock(hw.io);
                    const c = hw.children.getPtr(id.toInt()) orelse return;
                    const copy = hw.gpa.dupe(u8, text) catch return;
                    hw.gpa.free(c.text);
                    c.text = copy;
                }
                eng.workerEvent(id, .activity);
            },
            .cost => |c| eng.workerEvent(id, .{ .cost = c }),
            .working, .tool_boundary, .output, .needs_input => eng.workerEvent(id, .activity),
            .turn_finished, .failed => {},
        }
    }

    fn onEvent(ctx: *anyopaque, ev: run.RunEvent) void {
        const hw: *HostWorkers = @ptrCast(@alignCast(ctx));
        const eng = hw.engine orelse return;
        if (ev.kind != .status and ev.kind != .changed) return;
        if (!hw.tracked(ev.run)) return;
        const v = hw.reg.snapshot();
        defer hw.reg.release(v);
        const rec = v.get(ev.run) orelse return;
        if (rec.lane) |lane| {
            const send = blk: {
                hw.mutex.lockUncancelable(hw.io);
                defer hw.mutex.unlock(hw.io);
                const c = hw.children.getPtr(ev.run.toInt()) orelse return;
                if (c.lane_sent) break :blk false;
                c.lane_sent = true;
                break :blk true;
            };
            if (send) eng.workerEvent(ev.run, .{ .lane = lane });
        }
        if (!rec.status.isTerminal()) return;
        const text = blk: {
            hw.mutex.lockUncancelable(hw.io);
            defer hw.mutex.unlock(hw.io);
            const kv = hw.children.fetchRemove(ev.run.toInt()) orelse return;
            break :blk kv.value.text;
        };
        defer hw.gpa.free(text);
        switch (rec.status) {
            .completed => eng.workerEvent(ev.run, .{ .result = text }),
            .failed => eng.workerEvent(ev.run, .{ .failed = rec.error_ orelse "the agent failed" }),
            else => eng.workerEvent(ev.run, .stopped),
        }
    }
};
