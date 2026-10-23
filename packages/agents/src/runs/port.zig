//! The seams `RunHost` drives (E13.F01.S01.T02): the agent runtime (E10,
//! adapted in `bridge_e10.zig`), E09 lanes and E16 permission profiles.
//! zg_agents sits on the same layer as zg_scm and zg_security, so the app
//! binds those two through these vtables.

const std = @import("std");
const proto = @import("zg_ai_proto");
const run = @import("run.zig");

/// What an agent reports, already reduced to what a run needs.
pub const Signal = union(enum) {
    /// The agent is thinking, streaming or running tools.
    working,
    /// The agent waits for an approval or an answer (the question text).
    needs_input: ?[]const u8,
    cost: run.Cost,
    /// The last assistant text (any length; the host shortens it).
    summary: []const u8,
    output: run.Output,
    /// A tool call finished: the point where a pause takes effect.
    tool_boundary,
    turn_finished: TurnEnd,
    /// The agent hit an error it cannot continue from.
    failed: []const u8,
};

pub const TurnEnd = enum { end_turn, canceled, failed, other };

/// Receives an agent's signals, on any thread.
pub const Sink = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, s: Signal) void,

    pub fn send(s: Sink, sig: Signal) void {
        s.f(s.ctx, sig);
    }
};

pub const StartRequest = struct {
    model: ?[]const u8,
    agent_def: ?[]const u8,
    cwd: []const u8,
    budgets: run.Budgets,
    /// Resume this E10 session instead of starting a new one.
    session: ?u128 = null,
    profile: []const u8,
    /// Unattended profiles deny `ask` decisions instead of prompting.
    unattended: bool,
    sink: Sink,
};

pub const Started = struct { handle: usize, session: u128 };

pub const CancelWhat = enum { turn, everything };

/// An agent runtime. Every function may be called from any thread except
/// `dispose`, which the host only calls from its worker.
pub const AgentPort = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        start: *const fn (ctx: *anyopaque, req: StartRequest) anyerror!Started,
        submit: *const fn (ctx: *anyopaque, h: usize, text: []const u8) anyerror!void,
        cancel: *const fn (ctx: *anyopaque, h: usize, what: CancelWhat) void,
        dispose: *const fn (ctx: *anyopaque, h: usize) void,
        ref: *const fn (ctx: *anyopaque, h: usize) ?proto.AgentRef,
    };

    pub fn start(p: AgentPort, req: StartRequest) anyerror!Started {
        return p.vtable.start(p.ctx, req);
    }
    pub fn submit(p: AgentPort, h: usize, text: []const u8) anyerror!void {
        return p.vtable.submit(p.ctx, h, text);
    }
    pub fn cancel(p: AgentPort, h: usize, what: CancelWhat) void {
        p.vtable.cancel(p.ctx, h, what);
    }
    pub fn dispose(p: AgentPort, h: usize) void {
        p.vtable.dispose(p.ctx, h);
    }
    pub fn ref(p: AgentPort, h: usize) ?proto.AgentRef {
        return p.vtable.ref(p.ctx, h);
    }
};

/// E09 lanes for isolated writers (`ScmCommand.lane_create`).
pub const LanePort = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Creates lane `name` from revset `base`; returns its working
        /// directory, allocated with `gpa`.
        create: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8, base: []const u8) anyerror![]u8,
        /// The working directory of an existing lane, or null.
        find: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8) ?[]u8,
    };

    pub fn create(p: LanePort, gpa: std.mem.Allocator, name: []const u8, base: []const u8) anyerror![]u8 {
        return p.vtable.create(p.ctx, gpa, name, base);
    }
    pub fn find(p: LanePort, gpa: std.mem.Allocator, name: []const u8) ?[]u8 {
        return p.vtable.find(p.ctx, gpa, name);
    }
};

pub const Profile = struct {
    /// Never prompts: `ask` decisions become denials the model sees.
    unattended: bool = false,
};

/// E16 permission profiles.
pub const ProfilePort = struct {
    ctx: *anyopaque,
    resolve: *const fn (ctx: *anyopaque, name: []const u8) ?Profile,

    /// Knows "default" (attended), "unattended" and the profiles shipped
    /// for automations (E13.F02): `unattended-readonly`,
    /// `unattended-notes-write` and `unattended-lane-write`, all of which
    /// never prompt (their tool rules are E16's rule sets).
    pub const builtin: ProfilePort = .{ .ctx = undefined, .resolve = struct {
        fn f(_: *anyopaque, name: []const u8) ?Profile {
            if (std.mem.eql(u8, name, "default")) return .{};
            if (std.mem.eql(u8, name, "unattended")) return .{ .unattended = true };
            for ([_][]const u8{ "unattended-readonly", "unattended-notes-write", "unattended-lane-write" }) |p| {
                if (std.mem.eql(u8, name, p)) return .{ .unattended = true };
            }
            return null;
        }
    }.f };
};
