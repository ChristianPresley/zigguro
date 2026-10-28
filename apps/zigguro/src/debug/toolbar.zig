//! The debug toolbar's state (E07.F07.S01.T01): which buttons show and
//! which are enabled, from the active session's state, request, adapter
//! capabilities and controller. Pure, so the matrix is tested without a
//! window; `DebugPanel` draws it.
//!
//! - Continue and Pause share a place: Pause while the program runs,
//!   Continue otherwise. Stop becomes Disconnect for an attach session.
//! - Step Back and Reverse Continue show only with `supportsStepBack`.
//! - While the agent controls the session (E07.F05.S02) the badge says
//!   so and only Stop stays enabled: "Take control" hands the buttons to
//!   the user, and after a takeover "Hand back to agent" returns them.

const std = @import("std");
const zg_dap = @import("zg_dap");

const DebugSession = zg_dap.session.DebugSession;
const SessionState = DebugSession.SessionState;
const Request = zg_dap.config.LaunchConfig.Request;

pub const Button = enum {
    @"continue",
    pause,
    step_over,
    step_into,
    step_out,
    step_back,
    reverse_continue,
    restart,
    stop,
    disconnect,

    /// The button's text (and accessible name).
    pub fn label(b: Button) []const u8 {
        return switch (b) {
            .@"continue" => "Continue",
            .pause => "Pause",
            .step_over => "Step Over",
            .step_into => "Step Into",
            .step_out => "Step Out",
            .step_back => "Step Back",
            .reverse_continue => "Reverse",
            .restart => "Restart",
            .stop => "Stop",
            .disconnect => "Disconnect",
        };
    }

    /// The command the button runs.
    pub fn command(b: Button) []const u8 {
        return switch (b) {
            .@"continue" => "debug.continue",
            .pause => "debug.pause",
            .step_over => "debug.stepOver",
            .step_into => "debug.stepInto",
            .step_out => "debug.stepOut",
            .step_back => "debug.stepBack",
            .reverse_continue => "debug.reverseContinue",
            .restart => "debug.restart",
            .stop, .disconnect => "debug.stop",
        };
    }
};

pub const Badge = enum {
    none,
    /// The agent drives the session: "Take control".
    agent,
    /// The user took it from the agent: "Hand back to agent".
    taken,
};

pub const Input = struct {
    /// Null: no session.
    state: ?SessionState,
    request: Request = .launch,
    step_back: bool = false,
    controller: DebugSession.Controller = .user,
    /// The user took this session from the agent.
    taken: bool = false,
    /// Live sessions (a session picker shows with more than one).
    sessions: usize = 1,
};

pub const State = struct {
    /// In order; empty without a session.
    shown: std.EnumSet(Button) = .initEmpty(),
    enabled: std.EnumSet(Button) = .initEmpty(),
    badge: Badge = .none,
    session_picker: bool = false,

    pub fn isShown(s: State, b: Button) bool {
        return s.shown.contains(b);
    }

    pub fn isEnabled(s: State, b: Button) bool {
        return s.enabled.contains(b);
    }
};

pub fn compute(in: Input) State {
    var out: State = .{};
    const st = in.state orelse return out;
    out.session_picker = in.sessions > 1;
    const running = st == .running;
    out.shown.insert(if (running) .pause else .@"continue");
    for ([_]Button{ .step_over, .step_into, .step_out }) |b| out.shown.insert(b);
    if (in.step_back) {
        out.shown.insert(.step_back);
        out.shown.insert(.reverse_continue);
    }
    out.shown.insert(.restart);
    out.shown.insert(if (in.request == .attach) .disconnect else .stop);

    const end: Button = if (in.request == .attach) .disconnect else .stop;
    switch (st) {
        .initializing, .configuring, .launching => out.enabled.insert(end),
        .running => {
            out.enabled.insert(.pause);
            out.enabled.insert(.restart);
            out.enabled.insert(end);
        },
        .stopped => {
            var it = out.shown.iterator();
            while (it.next()) |b| out.enabled.insert(b);
        },
        .terminating => {},
        .terminated, .failed => out.enabled.insert(.restart),
    }

    if (in.controller == .agent) {
        out.badge = .agent;
        // The agent drives: only ending the session stays with the user.
        const keep = out.enabled.contains(end);
        out.enabled = .initEmpty();
        if (keep) out.enabled.insert(end);
    } else if (in.taken) out.badge = .taken;
    return out;
}

const testing = std.testing;

fn expectButtons(s: State, comptime shown: []const Button, comptime enabled: []const Button) !void {
    var want_shown: std.EnumSet(Button) = .initEmpty();
    for (shown) |b| want_shown.insert(b);
    var want_enabled: std.EnumSet(Button) = .initEmpty();
    for (enabled) |b| want_enabled.insert(b);
    try testing.expect(s.shown.eql(want_shown));
    try testing.expect(s.enabled.eql(want_enabled));
}

test "ui: toolbar state matrix" {
    // No session: nothing.
    try expectButtons(compute(.{ .state = null }), &.{}, &.{});
    const base = [_]Button{ .step_over, .step_into, .step_out, .restart };
    for ([_]SessionState{ .initializing, .configuring, .launching }) |st| {
        try expectButtons(compute(.{ .state = st }), &(.{.@"continue"} ++ base ++ .{.stop}), &.{.stop});
    }
    try expectButtons(compute(.{ .state = .running }), &(.{.pause} ++ base ++ .{.stop}), &.{ .pause, .restart, .stop });
    try expectButtons(compute(.{ .state = .stopped }), &(.{.@"continue"} ++ base ++ .{.stop}), &(.{.@"continue"} ++ base ++ .{.stop}));
    try expectButtons(compute(.{ .state = .terminating }), &(.{.@"continue"} ++ base ++ .{.stop}), &.{});
    try expectButtons(compute(.{ .state = .terminated }), &(.{.@"continue"} ++ base ++ .{.stop}), &.{.restart});
    try expectButtons(compute(.{ .state = .failed }), &(.{.@"continue"} ++ base ++ .{.stop}), &.{.restart});
    // × capabilities: step back shows its two buttons, enabled when
    // stopped.
    const back = compute(.{ .state = .stopped, .step_back = true });
    try testing.expect(back.isEnabled(.step_back) and back.isEnabled(.reverse_continue));
    try testing.expect(!compute(.{ .state = .running, .step_back = true }).isEnabled(.step_back));
    // An attach session disconnects instead of stopping.
    const att = compute(.{ .state = .running, .request = .attach });
    try testing.expect(att.isShown(.disconnect) and !att.isShown(.stop));
    try testing.expect(att.isEnabled(.disconnect));
    // Several sessions: the picker.
    try testing.expect(compute(.{ .state = .running, .sessions = 2 }).session_picker);
    try testing.expect(!compute(.{ .state = .running }).session_picker);
}

test "ui: agent badge, take control and hand back" {
    const agent = compute(.{ .state = .stopped, .controller = .agent });
    try testing.expectEqual(Badge.agent, agent.badge);
    // Only Stop is the user's while the agent drives.
    try expectButtons(agent, &.{ .@"continue", .step_over, .step_into, .step_out, .restart, .stop }, &.{.stop});
    // After "Take control": every button, and the hand-back badge.
    const taken = compute(.{ .state = .stopped, .controller = .user, .taken = true });
    try testing.expectEqual(Badge.taken, taken.badge);
    try testing.expect(taken.isEnabled(.step_over));
    try testing.expectEqual(Badge.none, compute(.{ .state = .stopped }).badge);
    try testing.expectEqualStrings("debug.stop", Button.disconnect.command());
}
