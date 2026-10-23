const std = @import("std");
const n_mod = @import("notification.zig");
const policy = @import("policy.zig");

const testing = std.testing;
const RunId = n_mod.RunId;
const Route = policy.Route;

test "policy_table" {
    const shown: RunId = .fromInt(1);
    const hidden: RunId = .fromInt(2);
    const Case = struct {
        focused: bool,
        run: ?RunId,
        sev: n_mod.Severity = .success,
        dnd: bool = false,
        os: bool = true,
        toast: bool = true,
        off: ?n_mod.Severity = null,
        want: Route,
    };
    const cases = [_]Case{
        // Focus x visibility.
        .{ .focused = true, .run = shown, .want = .none },
        .{ .focused = true, .run = hidden, .want = .toast },
        .{ .focused = true, .run = null, .want = .toast },
        .{ .focused = false, .run = shown, .want = .os },
        .{ .focused = false, .run = hidden, .want = .os },
        .{ .focused = false, .run = null, .want = .os },
        // Severity and every severity reaches the OS unfocused.
        .{ .focused = false, .run = hidden, .sev = .needs_input, .want = .os },
        .{ .focused = false, .run = hidden, .sev = .error_, .want = .os },
        .{ .focused = true, .run = hidden, .sev = .warning, .want = .toast },
        .{ .focused = true, .run = shown, .sev = .needs_input, .want = .none },
        // DND drops everything.
        .{ .focused = false, .run = hidden, .dnd = true, .want = .none },
        .{ .focused = true, .run = hidden, .dnd = true, .want = .none },
        .{ .focused = false, .run = hidden, .sev = .needs_input, .dnd = true, .want = .none },
        // A severity turned off.
        .{ .focused = false, .run = hidden, .sev = .info, .off = .info, .want = .none },
        .{ .focused = false, .run = hidden, .sev = .success, .off = .info, .want = .os },
        // OS or toasts disabled.
        .{ .focused = false, .run = hidden, .os = false, .want = .toast },
        .{ .focused = false, .run = hidden, .os = false, .toast = false, .want = .none },
        .{ .focused = true, .run = hidden, .toast = false, .want = .none },
    };
    const visible = [_]RunId{shown};
    for (cases, 0..) |c, i| {
        var p: policy.Policy = .{ .dnd = c.dnd, .os_enabled = c.os, .toast_enabled = c.toast };
        if (c.off) |s| p.per_severity.set(s, false);
        const n: n_mod.Notification = .{ .key = "k", .run = c.run, .severity = c.sev, .title = "t" };
        errdefer std.debug.print("case {d}\n", .{i});
        try testing.expectEqual(c.want, policy.route(p, .{ .window_focused = c.focused, .visible_runs = &visible }, &n));
    }
}

test "rate_limit_per_key" {
    var c: policy.Coalescer = .init(testing.allocator);
    defer c.deinit();
    const p: policy.Policy = .{};
    const a = try c.admit(p, "run:a", null, 0);
    try testing.expect(!a.replace);
    // Within 10 s: the same slot, updated in place.
    for (1..5) |i| {
        const b = try c.admit(p, "run:a", null, @intCast(i * 2_000));
        try testing.expect(b.replace);
        try testing.expectEqual(a.slot, b.slot);
    }
    // Another key is independent.
    try testing.expect(!(try c.admit(p, "run:b", null, 8_000)).replace);
    // 10 s after the last post: a new notification.
    const d = try c.admit(p, "run:a", null, 18_000);
    try testing.expect(!d.replace);
    try testing.expect(d.slot != a.slot);
}

test "group window merges and expires" {
    var c: policy.Coalescer = .init(testing.allocator);
    defer c.deinit();
    const p: policy.Policy = .{};
    const a = try c.admit(p, "run:1", "wf:x", 0);
    const b = try c.admit(p, "run:2", "wf:x", 2_999);
    try testing.expect(b.replace);
    try testing.expectEqual(@as(u32, 2), b.count);
    try testing.expectEqual(a.slot, b.slot);
    const d = try c.admit(p, "run:3", "wf:x", 7_000);
    try testing.expect(!d.replace);
    try testing.expectEqual(@as(u32, 1), d.count);
}

test "coalescer forgets old keys" {
    var c: policy.Coalescer = .init(testing.allocator);
    defer c.deinit();
    const p: policy.Policy = .{};
    var buf: [16]u8 = undefined;
    for (0..2_000) |i| _ = try c.admit(p, try std.fmt.bufPrint(&buf, "k{d}", .{i}), null, @intCast(i * 100));
    try testing.expect(c.keys.count() < 700);
}
