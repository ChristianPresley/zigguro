//! Mouse encoding tests: every tracking mode and encoding, modifiers and
//! coordinate limits (ctlseqs "Mouse Tracking").

const std = @import("std");
const testing = std.testing;
const ke = @import("key_encode.zig");
const mouse = @import("mouse.zig");

fn expectMouse(want: []const u8, mode: mouse.MouseMode, enc: mouse.MouseEncoding, ev: mouse.MouseInput) !void {
    const st: ke.EncoderState = .{ .mouse = mode, .mouse_enc = enc };
    var buf: [32]u8 = undefined;
    const got = mouse.encodeMouse(&st, ev, &buf);
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("{t}/{t}: want \"{f}\", got \"{f}\"\n", .{ mode, enc, std.zig.fmtString(want), std.zig.fmtString(got) });
        return error.TestUnexpectedResult;
    }
}

const left_press: mouse.MouseInput = .{ .kind = .press, .button = 0, .cell = .{ 9, 4 } };
const left_release: mouse.MouseInput = .{ .kind = .release, .button = 0, .cell = .{ 9, 4 } };

test "modes decide which events are reported" {
    try expectMouse("", .none, .sgr, left_press);
    try expectMouse("\x1b[M *%", .x10, .default, left_press);
    try expectMouse("", .x10, .default, left_release);
    // X10 never reports modifiers.
    try expectMouse("\x1b[M *%", .x10, .default, .{ .kind = .press, .button = 0, .cell = .{ 9, 4 }, .mods = .{ .ctrl = true } });
    try expectMouse("\x1b[M *%", .normal, .default, left_press);
    try expectMouse("\x1b[M#*%", .normal, .default, left_release);
    const drag: mouse.MouseInput = .{ .kind = .motion, .button = 0, .cell = .{ 9, 4 }, .buttons_down = 1 };
    const hover: mouse.MouseInput = .{ .kind = .motion, .button = 3, .cell = .{ 9, 4 } };
    try expectMouse("", .normal, .default, drag);
    try expectMouse("\x1b[M@*%", .button, .default, drag);
    try expectMouse("", .button, .default, hover);
    try expectMouse("\x1b[MC*%", .any, .default, hover);
    try expectMouse("\x1b[<35;10;5M", .any, .sgr, hover);
}

test "buttons, wheel and modifiers" {
    try expectMouse("\x1b[<2;10;5M", .normal, .sgr, .{ .kind = .press, .button = 2, .cell = .{ 9, 4 } });
    try expectMouse("\x1b[<64;10;5M", .normal, .sgr, .{ .kind = .wheel, .button = 64, .cell = .{ 9, 4 } });
    try expectMouse("\x1b[<65;10;5M", .normal, .sgr, .{ .kind = .wheel, .button = 65, .cell = .{ 9, 4 } });
    try expectMouse("\x1b[<67;10;5M", .normal, .sgr, .{ .kind = .wheel, .button = 67, .cell = .{ 9, 4 } });
    try expectMouse("\x1b[<128;10;5M", .normal, .sgr, .{ .kind = .press, .button = 128, .cell = .{ 9, 4 } });
    try expectMouse("\x1b[<131;10;5m", .normal, .sgr, .{ .kind = .release, .button = 131, .cell = .{ 9, 4 } });
    try expectMouse("\x1b[<20;10;5M", .normal, .sgr, .{ .kind = .press, .button = 0, .cell = .{ 9, 4 }, .mods = .{ .ctrl = true, .shift = true } });
    try expectMouse("\x1b[<8;10;5M", .normal, .sgr, .{ .kind = .press, .button = 0, .cell = .{ 9, 4 }, .mods = .{ .alt = true } });
    try expectMouse("\x1b[M`*%", .normal, .default, .{ .kind = .wheel, .button = 64, .cell = .{ 9, 4 } });
}

test "encodings" {
    try expectMouse("\x1b[<0;10;5M", .normal, .sgr, left_press);
    try expectMouse("\x1b[<0;10;5m", .normal, .sgr, left_release);
    try expectMouse("\x1b[32;10;5M", .normal, .urxvt, left_press);
    try expectMouse("\x1b[35;10;5M", .normal, .urxvt, left_release);
    try expectMouse("\x1b[<0;101;51M", .normal, .sgr_pixels, .{ .kind = .press, .button = 0, .cell = .{ 9, 4 }, .px = .{ 100, 50 } });
    try expectMouse("\x1b[M *%", .normal, .utf8, left_press);
}

test "coordinate limits per encoding" {
    const at = struct {
        fn f(x: u16) mouse.MouseInput {
            return .{ .kind = .press, .button = 0, .cell = .{ x, 0 } };
        }
    }.f;
    try expectMouse("\x1b[M \xff!", .normal, .default, at(222));
    try expectMouse("", .normal, .default, at(223));
    try expectMouse("", .normal, .default, at(300));
    try expectMouse("\x1b[M \u{14d}!", .normal, .utf8, at(300));
    try expectMouse("\x1b[M \u{7ff}!", .normal, .utf8, at(2014));
    try expectMouse("", .normal, .utf8, at(2015));
    try expectMouse("\x1b[<0;301;1M", .normal, .sgr, at(300));
}

test "alternate scroll sends cursor keys on the alternate screen" {
    var st: ke.EncoderState = .{ .alt_scroll = true, .alt_screen = true };
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("\x1b[A\x1b[A\x1b[A", mouse.altScroll(&st, true, 3, &buf));
    st.decckm = true;
    try testing.expectEqualStrings("\x1bOB", mouse.altScroll(&st, false, 1, &buf));
    st.mouse = .normal;
    try testing.expectEqualStrings("", mouse.altScroll(&st, true, 3, &buf));
    st.mouse = .none;
    st.alt_screen = false;
    try testing.expectEqualStrings("", mouse.altScroll(&st, true, 3, &buf));
}
