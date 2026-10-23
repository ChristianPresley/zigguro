//! A test agent runtime (E13.F01 tests): signals are emitted by the test
//! through each agent's sink; `cancel(.turn)` ends the turn unless
//! `ignore_cancel`; `auto_complete` finishes every submitted turn.

const std = @import("std");
const proto = @import("zg_ai_proto");
const port = @import("port.zig");

const io = std.testing.io;
const gpa = std.testing.allocator;

pub const Fake = struct {
    mutex: std.Io.Mutex = .init,
    agents: std.ArrayList(*FakeAgent) = .empty,
    ignore_cancel: bool = false,
    /// Submitting the first prompt completes the turn at once.
    auto_complete: bool = false,

    pub const FakeAgent = struct {
        sink: port.Sink,
        cwd: []u8,
        unattended: bool,
        session: u128,
        resumed: ?u128,
        submits: std.ArrayList([]u8) = .empty,
        cancels: [2]u32 = .{ 0, 0 },
        disposed: bool = false,
    };

    pub fn deinit(f: *Fake) void {
        for (f.agents.items) |a| {
            for (a.submits.items) |s| gpa.free(s);
            a.submits.deinit(gpa);
            gpa.free(a.cwd);
            gpa.destroy(a);
        }
        f.agents.deinit(gpa);
    }

    pub fn agentPort(f: *Fake) port.AgentPort {
        return .{ .ctx = f, .vtable = &.{ .start = start, .submit = submit, .cancel = cancel, .dispose = dispose, .ref = ref } };
    }

    fn start(ctx: *anyopaque, req: port.StartRequest) anyerror!port.Started {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        const a = try gpa.create(FakeAgent);
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        a.* = .{
            .sink = req.sink,
            .cwd = try gpa.dupe(u8, req.cwd),
            .unattended = req.unattended,
            .session = 1000 + f.agents.items.len,
            .resumed = req.session,
        };
        try f.agents.append(gpa, a);
        return .{ .handle = @intFromPtr(a), .session = req.session orelse a.session };
    }

    fn submit(ctx: *anyopaque, h: usize, text: []const u8) anyerror!void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        const a: *FakeAgent = @ptrFromInt(h);
        {
            f.mutex.lockUncancelable(io);
            defer f.mutex.unlock(io);
            try a.submits.append(gpa, try gpa.dupe(u8, text));
        }
        if (f.auto_complete) {
            a.sink.send(.{ .summary = "done\nnow" });
            a.sink.send(.{ .turn_finished = .end_turn });
        }
    }

    fn cancel(ctx: *anyopaque, h: usize, what: port.CancelWhat) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        const a: *FakeAgent = @ptrFromInt(h);
        {
            f.mutex.lockUncancelable(io);
            defer f.mutex.unlock(io);
            a.cancels[@intFromEnum(what)] += 1;
        }
        if (!f.ignore_cancel and what == .turn) a.sink.send(.{ .turn_finished = .canceled });
    }

    fn dispose(ctx: *anyopaque, h: usize) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        const a: *FakeAgent = @ptrFromInt(h);
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        a.disposed = true;
    }

    fn ref(_: *anyopaque, h: usize) ?proto.AgentRef {
        const a: *FakeAgent = @ptrFromInt(h);
        return .{ .session = a.session };
    }

    pub fn agent(f: *Fake, i: usize) *FakeAgent {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        return f.agents.items[i];
    }

    pub fn count(f: *Fake) usize {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        return f.agents.items.len;
    }
};
