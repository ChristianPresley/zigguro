//! `bench-latency` keystrokes through `SendInput` with scancodes
//! (E14.F03.S02.T02). UIPI allows it because the target is our own window
//! at the same integrity level; the window must be in the foreground.

const std = @import("std");
const keys = @import("keys.zig");
const Injector = @import("injector.zig").Injector;

const INPUT_KEYBOARD: u32 = 1;
const KEYEVENTF_KEYUP: u32 = 0x0002;
const KEYEVENTF_SCANCODE: u32 = 0x0008;

const KEYBDINPUT = extern struct { wVk: u16, wScan: u16, dwFlags: u32, time: u32, dwExtraInfo: usize };
const MOUSEINPUT = extern struct { dx: i32, dy: i32, mouseData: u32, dwFlags: u32, time: u32, dwExtraInfo: usize };
const INPUT = extern struct {
    type: u32,
    u: extern union { ki: KEYBDINPUT, mi: MOUSEINPUT },
};

extern "user32" fn SendInput(cInputs: u32, pInputs: [*]const INPUT, cbSize: i32) callconv(.winapi) u32;

const State = struct { gpa: std.mem.Allocator };

pub fn create(gpa: std.mem.Allocator) !Injector {
    const s = try gpa.create(State);
    s.* = .{ .gpa = gpa };
    return .{ .ptr = s, .vtable = &.{ .keyTap = keyTap, .deinit = deinit } };
}

fn key(sc: u16, up: bool) INPUT {
    return .{ .type = INPUT_KEYBOARD, .u = .{ .ki = .{ .wVk = 0, .wScan = sc, .dwFlags = KEYEVENTF_SCANCODE | if (up) KEYEVENTF_KEYUP else 0, .time = 0, .dwExtraInfo = 0 } } };
}

fn keyTap(_: *anyopaque, ch: u8) anyerror!void {
    // Set-1 scancodes equal evdev codes for these keys.
    const sc = keys.keyFor(ch).evdev;
    const in = [2]INPUT{ key(sc, false), key(sc, true) };
    if (SendInput(in.len, &in, @sizeOf(INPUT)) != in.len) return error.SendInputBlocked;
}

fn deinit(ptr: *anyopaque) void {
    const s: *State = @ptrCast(@alignCast(ptr));
    s.gpa.destroy(s);
}
