//! The backend conformance suite. Every backend (headless, Win32, Wayland,
//! X11) runs it from its own tests, so all of them behave the same way
//! where the API promises it.
//!
//! `runConformance(B, harness)` takes a harness type `B` with
//! `pub fn create(*B) !Platform` and a field `io: std.Io`. Input cases run
//! only when `B` can synthesise input: `injectKey(*B, WindowId, Key,
//! KeyAction) !void` and `requestClose(*B, WindowId) !void` are optional.
//! Each case gets a fresh platform, which the suite deinits.

const std = @import("std");
const types = @import("../api/types.zig");
const keys = @import("../api/keys.zig");
const Event = @import("../api/event.zig").Event;
const Platform = @import("../api/platform.zig").Platform;
const WindowId = types.WindowId;

/// How long a case waits for an expected event.
pub const timeout_ns: u64 = 2 * std.time.ns_per_s;

/// Runs every case against platforms from `harness`; logs and returns the
/// first failure.
pub fn runConformance(comptime B: type, harness: *B) !void {
    const cases = .{
        .{ "pollEvents with an empty buffer returns 0", pollEmpty },
        .{ "create sends a configure, destroy succeeds", createConfigure },
        .{ "createWindow returns distinct ids", distinctIds },
        .{ "close request, then destroy", closeRequest },
        .{ "set title and cursor", titleCursor },
        .{ "clipboard round trip through our own selection", clipboardRoundTrip },
        .{ "key press and release arrive paired and in order", keyPairing },
        .{ "IME enable and disable are accepted", imeToggle },
        .{ "monitors reports at least one", monitorsAtLeastOne },
        .{ "wake delivers exactly one Event.wake", wakeOnce },
    };
    inline for (cases) |c| {
        const p = try B.create(harness);
        defer p.deinit();
        c[1](B, harness, p) catch |err| {
            std.log.err("conformance case failed: {s}: {t}", .{ c[0], err });
            return err;
        };
    }
}

fn nowNs(io: std.Io) u64 {
    return @intCast(@max(0, std.Io.Clock.awake.now(io).nanoseconds));
}

/// Polls until `match(ctx, p, ev)` accepts an event or the timeout passes.
fn pump(io: std.Io, p: Platform, ctx: anytype, comptime match: fn (@TypeOf(ctx), Platform, Event) bool) !void {
    const deadline = nowNs(io) + timeout_ns;
    var evs: [64]Event = undefined;
    while (true) {
        const n = p.pollEvents(&evs);
        for (evs[0..n]) |e| if (match(ctx, p, e)) return;
        if (nowNs(io) >= deadline) return error.Timeout;
        p.waitEvents(deadline);
    }
}

fn testWindow(p: Platform) !WindowId {
    return p.createWindow(.{ .title = "zg conformance", .size = .{ .w = 320, .h = 240 } });
}

fn pollEmpty(comptime B: type, _: *B, p: Platform) !void {
    var none: [0]Event = .{};
    try std.testing.expectEqual(0, p.pollEvents(&none));
}

fn createConfigure(comptime B: type, h: *B, p: Platform) !void {
    const win = try testWindow(p);
    defer p.destroyWindow(win);
    try pump(h.io, p, win, struct {
        fn f(w: WindowId, _: Platform, e: Event) bool {
            return e == .window_configure and e.window_configure.win == w and e.window_configure.size.w > 0;
        }
    }.f);
}

fn distinctIds(comptime B: type, _: *B, p: Platform) !void {
    const a = try testWindow(p);
    defer p.destroyWindow(a);
    const b = try testWindow(p);
    defer p.destroyWindow(b);
    try std.testing.expect(a != b);
}

fn closeRequest(comptime B: type, h: *B, p: Platform) !void {
    const win = try testWindow(p);
    if (!@hasDecl(B, "requestClose")) return p.destroyWindow(win);
    try B.requestClose(h, win);
    try pump(h.io, p, win, struct {
        fn f(w: WindowId, _: Platform, e: Event) bool {
            return e == .window_close_requested and e.window_close_requested == w;
        }
    }.f);
    p.destroyWindow(win);
    try std.testing.expectError(error.InvalidWindow, p.submit(.{ .set_title = .{ .win = win, .title = "gone" } }));
}

fn titleCursor(comptime B: type, _: *B, p: Platform) !void {
    const win = try testWindow(p);
    defer p.destroyWindow(win);
    try p.submit(.{ .set_title = .{ .win = win, .title = "renamed ✓" } });
    try p.submit(.{ .set_cursor = .{ .win = win, .shape = .text } });
    try p.submit(.{ .set_cursor = .{ .win = win, .shape = .hidden } });
}

fn clipboardRoundTrip(comptime B: type, h: *B, p: Platform) !void {
    const win = try testWindow(p);
    defer p.destroyWindow(win);
    const text: []const u8 = "zg conformance clipboard";
    try p.submit(.{ .clipboard_write = .{ .which = .clipboard, .items = &.{.{ .mime = .text_utf8, .data = text }} } });
    try p.submit(.{ .clipboard_read = .{ .which = .clipboard, .mime = .text_utf8, .request = 0x5eed } });
    try pump(h.io, p, text, struct {
        fn f(want: []const u8, plat: Platform, e: Event) bool {
            if (e != .clipboard_data or e.clipboard_data.request != 0x5eed) return false;
            const got = plat.payload(e.clipboard_data.data);
            const ok = std.mem.eql(u8, got, want);
            if (e.clipboard_data.data.large) plat.release(e.clipboard_data.data);
            return ok;
        }
    }.f);
}

fn keyPairing(comptime B: type, h: *B, p: Platform) !void {
    if (!@hasDecl(B, "injectKey")) return;
    const win = try testWindow(p);
    defer p.destroyWindow(win);
    try B.injectKey(h, win, .key_q, .press);
    try B.injectKey(h, win, .key_q, .release);
    var seen: u8 = 0;
    try pump(h.io, p, &seen, struct {
        fn f(s: *u8, _: Platform, e: Event) bool {
            if (e != .key or e.key.ev.key != .key_q) return false;
            const want: keys.KeyAction = if (s.* == 0) .press else .release;
            if (e.key.ev.action != want) {
                s.* = 0xff;
                return true;
            }
            s.* += 1;
            return s.* == 2;
        }
    }.f);
    try std.testing.expectEqual(2, seen);
}

fn imeToggle(comptime B: type, _: *B, p: Platform) !void {
    const win = try testWindow(p);
    defer p.destroyWindow(win);
    const caret: types.PxRect = .{ .x = 10, .y = 10, .w = 1, .h = 16 };
    try p.submit(.{ .set_ime_state = .{ .win = win, .enabled = true, .purpose = .normal, .caret_rect_px = caret, .surrounding = .{ .text = "abc", .cursor_byte = 3, .anchor_byte = 3 } } });
    try p.submit(.{ .set_ime_state = .{ .win = win, .enabled = false, .purpose = .normal, .caret_rect_px = caret, .surrounding = null } });
}

fn monitorsAtLeastOne(comptime B: type, _: *B, p: Platform) !void {
    var out: [8]types.MonitorInfo = undefined;
    const n = p.monitors(&out);
    try std.testing.expect(n >= 1);
    try std.testing.expect(out[0].rect_px.w > 0 and out[0].rect_px.h > 0);
}

fn wakeOnce(comptime B: type, h: *B, p: Platform) !void {
    var evs: [16]Event = undefined;
    while (p.pollEvents(&evs) > 0) {}
    p.wake();
    var wakes: usize = 0;
    const deadline = nowNs(h.io) + timeout_ns;
    while (wakes == 0 and nowNs(h.io) < deadline) {
        p.waitEvents(deadline);
        const n = p.pollEvents(&evs);
        for (evs[0..n]) |e| {
            if (e == .wake) wakes += 1;
        }
    }
    // A second poll must not repeat it.
    const n = p.pollEvents(&evs);
    for (evs[0..n]) |e| {
        if (e == .wake) wakes += 1;
    }
    try std.testing.expectEqual(1, wakes);
}
