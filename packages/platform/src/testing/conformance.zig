//! The backend conformance suite. Every backend (headless, Win32, Wayland,
//! X11) runs it from its own tests against a live `Platform`, so all of them
//! behave the same way where the API promises it. This is the skeleton from
//! E01.F01.S01.T01 (#210); the headless backend (E01.F01.S02.T01, #215)
//! adds the input and presentation cases.

const std = @import("std");
const api = @import("../root.zig");

/// One conformance check.
pub const Case = struct {
    /// Shown when the case fails.
    name: []const u8,
    /// Runs the check against a fresh platform.
    run: *const fn (p: api.Platform) anyerror!void,
};

/// Every case, in the order they run.
pub const cases = [_]Case{
    .{ .name = "pollEvents with an empty buffer returns 0", .run = pollEmpty },
    .{ .name = "wake delivers exactly one Event.wake", .run = wakeOnce },
    .{ .name = "createWindow returns distinct ids", .run = distinctIds },
};

/// Runs every case. `fresh` creates a new platform per case and the suite
/// deinits it afterwards. Returns the first failure after logging its name.
pub fn runAll(ctx: anytype, comptime fresh: fn (@TypeOf(ctx)) anyerror!api.Platform) !void {
    for (cases) |c| {
        const p = try fresh(ctx);
        defer p.deinit();
        c.run(p) catch |err| {
            std.log.err("conformance case failed: {s}: {t}", .{ c.name, err });
            return err;
        };
    }
}

fn pollEmpty(p: api.Platform) !void {
    var none: [0]api.Event = .{};
    try std.testing.expectEqual(0, p.pollEvents(&none));
}

fn wakeOnce(p: api.Platform) !void {
    var evs: [16]api.Event = undefined;
    _ = p.pollEvents(&evs);
    p.wake();
    p.waitEvents(null);
    var wakes: usize = 0;
    const n = p.pollEvents(&evs);
    for (evs[0..n]) |e| {
        if (e == .wake) wakes += 1;
    }
    try std.testing.expectEqual(1, wakes);
}

fn distinctIds(p: api.Platform) !void {
    const a = try p.createWindow(.{ .title = "a", .size = .{ .w = 64, .h = 48 } });
    defer p.destroyWindow(a);
    const b = try p.createWindow(.{ .title = "b", .size = .{ .w = 64, .h = 48 } });
    defer p.destroyWindow(b);
    try std.testing.expect(a != b);
}
