//! Native message hooks (E01.F01.S03.T01): per-window tables of
//! `Win32MsgHook`s that the window procedure asks before its own handling,
//! for E04 UI Automation (`WM_GETOBJECT`) and similar. Tables are touched
//! only on the platform thread. Pure; builds and tests on every OS.

const std = @import("std");
const Win32MsgHook = @import("../api/native.zig").Win32MsgHook;

/// Hooks per window.
pub const max_hooks = 8;
/// Messages per hook.
pub const max_msgs = 8;

/// `WM_GETOBJECT`.
pub const WM_GETOBJECT: u32 = 0x003D;
/// `UiaRootObjectId` (-25), as `WM_GETOBJECT` sends it in the low 32 bits
/// of lParam.
pub const UiaRootObjectId: i32 = -25;

/// True when a `WM_GETOBJECT` lParam asks for the UIA root. The value is
/// a DWORD: on 64-bit Windows the upper half is not sign-extended, so the
/// low 32 bits are compared.
pub fn isUiaRoot(lp: isize) bool {
    const low: u32 = @truncate(@as(usize, @bitCast(lp)));
    return low == @as(u32, @bitCast(UiaRootObjectId));
}

/// One window's hooks.
pub const Table = struct {
    entries: [max_hooks]Entry = undefined,
    len: usize = 0,

    const Entry = struct {
        msgs: [max_msgs]u32,
        n: usize,
        hook: Win32MsgHook,
        ctx: *anyopaque,
    };

    /// Adds `hook` for `msgs`, replaces the entry with the same `ctx`, or
    /// removes it when `hook` is null.
    pub fn set(t: *Table, msgs: []const u32, hook: ?Win32MsgHook, ctx: *anyopaque) error{ TooManyHooks, TooManyMessages }!void {
        const at: ?usize = for (t.entries[0..t.len], 0..) |e, i| {
            if (e.ctx == ctx) break i;
        } else null;
        const h = hook orelse {
            if (at) |i| {
                std.mem.copyForwards(Entry, t.entries[i .. t.len - 1], t.entries[i + 1 .. t.len]);
                t.len -= 1;
            }
            return;
        };
        if (msgs.len > max_msgs) return error.TooManyMessages;
        var e: Entry = .{ .msgs = undefined, .n = msgs.len, .hook = h, .ctx = ctx };
        @memcpy(e.msgs[0..msgs.len], msgs);
        if (at) |i| {
            t.entries[i] = e;
            return;
        }
        if (t.len == max_hooks) return error.TooManyHooks;
        t.entries[t.len] = e;
        t.len += 1;
    }

    /// Runs the hooks registered for `msg` in order; the first non-null
    /// result is the message's `LRESULT`.
    pub fn dispatch(t: *const Table, hwnd: *anyopaque, msg: u32, wp: usize, lp: isize) ?isize {
        for (t.entries[0..t.len]) |e| {
            if (std.mem.indexOfScalar(u32, e.msgs[0..e.n], msg) == null) continue;
            if (e.hook(e.ctx, hwnd, msg, wp, lp)) |r| return r;
        }
        return null;
    }
};

const testing = std.testing;

const Probe = struct {
    calls: usize = 0,
    answer: ?isize,

    fn hook(ctx: *anyopaque, _: *anyopaque, _: u32, _: usize, _: isize) ?isize {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        p.calls += 1;
        return p.answer;
    }
};

test "hook table: add, replace, remove, max 8" {
    var t: Table = .{};
    var a: Probe = .{ .answer = null };
    var b: Probe = .{ .answer = 42 };
    var dummy: u8 = 0;
    const hwnd: *anyopaque = &dummy;
    try t.set(&.{ WM_GETOBJECT, 0x0401 }, Probe.hook, &a);
    try t.set(&.{WM_GETOBJECT}, Probe.hook, &b);
    // a declines, b answers.
    try testing.expectEqual(@as(?isize, 42), t.dispatch(hwnd, WM_GETOBJECT, 0, -25));
    try testing.expectEqual(1, a.calls);
    try testing.expectEqual(@as(?isize, null), t.dispatch(hwnd, 0x0401, 0, 0));
    try testing.expectEqual(2, a.calls);
    try testing.expectEqual(1, b.calls);
    // Replacing a's messages keeps one entry.
    try t.set(&.{0x0402}, Probe.hook, &a);
    try testing.expectEqual(2, t.len);
    try testing.expectEqual(@as(?isize, null), t.dispatch(hwnd, 0x0401, 0, 0));
    // 0x0401 no longer reaches a.
    try testing.expectEqual(2, a.calls);
    // Removing b leaves nothing for WM_GETOBJECT.
    try t.set(&.{}, null, &b);
    try testing.expectEqual(@as(?isize, null), t.dispatch(hwnd, WM_GETOBJECT, 0, 0));
    try testing.expectEqual(1, t.len);

    var many: [max_hooks]Probe = @splat(.{ .answer = null });
    t = .{};
    for (&many) |*p| try t.set(&.{1}, Probe.hook, p);
    var extra: Probe = .{ .answer = null };
    try testing.expectError(error.TooManyHooks, t.set(&.{1}, Probe.hook, &extra));
    try testing.expectError(error.TooManyMessages, t.set(&(.{1} ** (max_msgs + 1)), Probe.hook, &many[0]));
}

test "UiaRootObjectId compares the low 32 bits" {
    try testing.expect(isUiaRoot(-25));
    // A DWORD -25 zero-extended into a 64-bit lParam.
    if (@sizeOf(isize) == 8) try testing.expect(isUiaRoot(@bitCast(@as(usize, 0xFFFF_FFE7))));
    try testing.expect(!isUiaRoot(-4)); // OBJID_CLIENT
    try testing.expect(!isUiaRoot(25));
}
