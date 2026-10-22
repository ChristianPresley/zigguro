//! Mouse reporting: the tracking modes (9, 1000, 1002, 1003) and encodings
//! (default, 1005, 1006, 1015, 1016) of xterm ctlseqs, "Mouse Tracking"
//! (https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h2-Mouse-Tracking),
//! and alternate scroll (1007).

const std = @import("std");
const Mods = @import("keys.zig").Mods;
const key_encode = @import("key_encode.zig");

/// Which events are reported.
pub const MouseMode = enum { none, x10, normal, button, any };
/// How reports are written.
pub const MouseEncoding = enum { default, utf8, sgr, urxvt, sgr_pixels };

/// One pointer event in terminal coordinates.
pub const MouseInput = struct {
    kind: enum { press, release, motion, wheel },
    /// 0 left, 1 middle, 2 right, 64-67 wheel up/down/left/right,
    /// 128-131 buttons 8-11. For motion, the held button (or 3 for none).
    button: u8,
    /// 0-based column and row.
    cell: [2]u16,
    /// Pixel position in the text area (for 1016).
    px: [2]u32 = .{ 0, 0 },
    mods: Mods = .{},
    /// Bit mask of buttons held (bit 0 left, 1 middle, 2 right).
    buttons_down: u8 = 0,
};

/// Encodes `ev` for the active mode and encoding. Empty when the mode does
/// not report this event, or when the position cannot be encoded.
pub fn encodeMouse(st: *const key_encode.EncoderState, ev: MouseInput, out: *[32]u8) []const u8 {
    var w: std.Io.Writer = .fixed(out);
    write(st, ev, &w) catch return "";
    return w.buffered();
}

fn write(st: *const key_encode.EncoderState, ev: MouseInput, w: *std.Io.Writer) !void {
    switch (st.mouse) {
        .none => return,
        .x10 => if (ev.kind != .press) return,
        .normal => if (ev.kind == .motion) return,
        .button => if (ev.kind == .motion and ev.buttons_down == 0) return,
        .any => {},
    }
    var b: u16 = ev.button;
    if (ev.kind == .motion) {
        b = if (ev.buttons_down == 0) 3 else ev.button;
        b += 32;
    }
    const sgr = st.mouse_enc == .sgr or st.mouse_enc == .sgr_pixels;
    // Non-SGR encodings report a release as button 3.
    if (ev.kind == .release and !sgr) b = 3;
    if (st.mouse != .x10) {
        if (ev.mods.shift) b += 4;
        if (ev.mods.alt) b += 8;
        if (ev.mods.ctrl) b += 16;
    }
    const x: u32 = @as(u32, ev.cell[0]) + 1;
    const y: u32 = @as(u32, ev.cell[1]) + 1;
    switch (st.mouse_enc) {
        .default => {
            if (32 + x > 255 or 32 + y > 255 or 32 + b > 255) return;
            try w.writeAll("\x1b[M");
            try w.writeByte(@intCast(32 + b));
            try w.writeByte(@intCast(32 + x));
            try w.writeByte(@intCast(32 + y));
        },
        .utf8 => {
            // Values up to 2047 as UTF-8 (coordinates up to 2015).
            if (32 + x > 2047 or 32 + y > 2047) return;
            try w.writeAll("\x1b[M");
            for ([_]u32{ 32 + b, 32 + x, 32 + y }) |v| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(v), &buf) catch return;
                try w.writeAll(buf[0..n]);
            }
        },
        .sgr => try w.print("\x1b[<{d};{d};{d}{c}", .{ b, x, y, @as(u8, if (ev.kind == .release) 'm' else 'M') }),
        .sgr_pixels => try w.print("\x1b[<{d};{d};{d}{c}", .{ b, ev.px[0] + 1, ev.px[1] + 1, @as(u8, if (ev.kind == .release) 'm' else 'M') }),
        .urxvt => try w.print("\x1b[{d};{d};{d}M", .{ b + 32, x, y }),
    }
}

/// Alternate scroll (1007) on the alternate screen without a mouse mode:
/// one wheel notch becomes `lines` cursor-up or cursor-down keys (SS3 under
/// DECCKM). Empty when alternate scroll does not apply.
pub fn altScroll(st: *const key_encode.EncoderState, up: bool, lines: u8, out: []u8) []const u8 {
    if (!st.alt_scroll or !st.alt_screen or st.mouse != .none) return "";
    const seq: []const u8 = if (st.decckm) (if (up) "\x1bOA" else "\x1bOB") else (if (up) "\x1b[A" else "\x1b[B");
    var n: usize = 0;
    for (0..lines) |_| {
        if (n + seq.len > out.len) break;
        @memcpy(out[n..][0..seq.len], seq);
        n += seq.len;
    }
    return out[0..n];
}

test {
    _ = @import("mouse_test.zig");
}
