//! Mission Control's row actions (E13.F01.S02.T01): each is a palette
//! command (`agents.mc.*`) with a default key and a `zg runs` subcommand,
//! and the stop confirmation (a second press within 2 s). Pure.

const std = @import("std");

pub const Action = enum { attach, peek, stop, pause, resume_, outputs, pin, remove, rename };

pub const Entry = struct {
    action: Action,
    /// The palette command id.
    command: []const u8,
    title: []const u8,
    key: []const u8,
    /// The `zg runs` subcommand doing the same.
    cli: []const u8,
    /// Applies to every selected row (Shift multi-select).
    bulk: bool = false,
};

/// One entry per `Action`, in `Action` order.
pub const table = blk: {
    var t: [std.meta.fields(Action).len]Entry = undefined;
    for (&t, std.meta.fields(Action)) |*e, f| e.* = entryOf(@enumFromInt(f.value));
    break :blk t;
};

/// An exhaustive switch: a new action does not compile without its
/// command, key and CLI subcommand.
fn entryOf(a: Action) Entry {
    return switch (a) {
        .attach => .{ .action = a, .command = "agents.mc.attach", .title = "Agents: Attach to Run", .key = "enter", .cli = "attach" },
        .peek => .{ .action = a, .command = "agents.mc.peek", .title = "Agents: Peek at Run", .key = "space", .cli = "show" },
        .stop => .{ .action = a, .command = "agents.mc.stop", .title = "Agents: Stop Run", .key = "ctrl+x", .cli = "stop", .bulk = true },
        .pause => .{ .action = a, .command = "agents.mc.pause", .title = "Agents: Pause or Resume Run", .key = "p", .cli = "pause" },
        .resume_ => .{ .action = a, .command = "agents.mc.resume", .title = "Agents: Resume Interrupted Run", .key = "r", .cli = "resume" },
        .outputs => .{ .action = a, .command = "agents.mc.outputs", .title = "Agents: Show Run Outputs", .key = "o", .cli = "outputs" },
        .pin => .{ .action = a, .command = "agents.mc.pin", .title = "Agents: Pin Run", .key = "ctrl+t", .cli = "pin" },
        .remove => .{ .action = a, .command = "agents.mc.remove", .title = "Agents: Remove Run from List", .key = "delete", .cli = "remove", .bulk = true },
        .rename => .{ .action = a, .command = "agents.mc.rename", .title = "Agents: Rename Run", .key = "ctrl+r", .cli = "rename" },
    };
}

pub fn entry(a: Action) Entry {
    return table[@intFromEnum(a)];
}

/// The other commands of the panel.
pub const panel_commands = [_]struct { id: []const u8, title: []const u8, key: ?[]const u8 = null }{
    .{ .id = "agents.missionControl", .title = "Agents: Show Mission Control", .key = "ctrl+alt+m" },
    .{ .id = "agents.mc.dispatch", .title = "Agents: Dispatch Run" },
    .{ .id = "agents.mc.filter", .title = "Agents: Filter Runs" },
    .{ .id = "agents.mc.openPromptEditor", .title = "Agents: Edit Dispatch Prompt in Editor", .key = "ctrl+g" },
};

/// Stop needs two presses on the same target within `window_ms`; the
/// first one shows "press again".
pub const StopGuard = struct {
    window_ms: i64 = 2_000,
    armed: ?u128 = null,
    at_ms: i64 = 0,

    pub const Result = enum { armed, confirmed };

    /// `target` is a run id, or a hash of the selection for a bulk stop.
    pub fn press(g: *StopGuard, target: u128, now_ms: i64) Result {
        if (g.armed) |a| if (a == target and now_ms - g.at_ms <= g.window_ms) {
            g.armed = null;
            return .confirmed;
        };
        g.armed = target;
        g.at_ms = now_ms;
        return .armed;
    }

    /// Whether "press again" should still show.
    pub fn pending(g: *const StopGuard, target: u128, now_ms: i64) bool {
        const a = g.armed orelse return false;
        return a == target and now_ms - g.at_ms <= g.window_ms;
    }

    pub fn reset(g: *StopGuard) void {
        g.armed = null;
    }
};

const testing = std.testing;

test "stop_requires_double_press" {
    var g: StopGuard = .{};
    var clock: i64 = 10_000;
    try testing.expectEqual(StopGuard.Result.armed, g.press(1, clock));
    try testing.expect(g.pending(1, clock + 500));
    clock += 1_500;
    try testing.expectEqual(StopGuard.Result.confirmed, g.press(1, clock));
    try testing.expect(!g.pending(1, clock));
    // Too slow: the second press arms again.
    try testing.expectEqual(StopGuard.Result.armed, g.press(1, clock));
    clock += 2_001;
    try testing.expect(!g.pending(1, clock));
    try testing.expectEqual(StopGuard.Result.armed, g.press(1, clock));
    // Another target re-arms.
    try testing.expectEqual(StopGuard.Result.armed, g.press(2, clock + 10));
    try testing.expectEqual(StopGuard.Result.confirmed, g.press(2, clock + 20));
}

test "every action has a distinct command and key" {
    for (table, 0..) |a, i| {
        try testing.expectEqual(i, @intFromEnum(a.action));
        try testing.expect(std.mem.startsWith(u8, a.command, "agents.mc."));
        for (table[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.command, b.command));
            try testing.expect(!std.mem.eql(u8, a.key, b.key));
        }
    }
}
