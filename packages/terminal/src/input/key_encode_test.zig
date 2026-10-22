//! Legacy (xterm) key encoding tests: hand-checked rows from ctlseqs, then
//! a generated matrix of every functional, keypad and text key under each
//! modifier combination, DECCKM and DECKPAM, checked against an independent
//! reference built from the ctlseqs rules.

const std = @import("std");
const testing = std.testing;
const ke = @import("key_encode.zig");
const tables = @import("keytables.zig");
const Key = ke.Key;
const Mods = ke.Mods;

fn enc(st: ke.EncoderState, k: ke.KeyInput) []const u8 {
    const S = struct {
        var buf: [64]u8 = undefined;
    };
    return ke.encodeKey(&st, k, &S.buf);
}

fn expectKey(want: []const u8, st: ke.EncoderState, k: ke.KeyInput) !void {
    const got = enc(st, k);
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("key {t} mods {any}: want \"{f}\", got \"{f}\"\n", .{ k.key, k.mods, std.zig.fmtString(want), std.zig.fmtString(got) });
        return error.TestUnexpectedResult;
    }
}

const none: Mods = .{};
const shift: Mods = .{ .shift = true };
const ctrl: Mods = .{ .ctrl = true };
const alt: Mods = .{ .alt = true };
const ctrl_shift: Mods = .{ .ctrl = true, .shift = true };
const ctrl_alt: Mods = .{ .ctrl = true, .alt = true };

test "legacy: text and control keys" {
    const st: ke.EncoderState = .{};
    try expectKey("a", st, .{ .key = .key_a, .text = "a" });
    try expectKey("A", st, .{ .key = .key_a, .mods = shift, .text = "A" });
    try expectKey("\x01", st, .{ .key = .key_a, .mods = ctrl });
    try expectKey("\x01", st, .{ .key = .key_a, .mods = ctrl_shift });
    try expectKey("\x1ba", st, .{ .key = .key_a, .mods = alt, .text = "a" });
    try expectKey("\x1b\x01", st, .{ .key = .key_a, .mods = ctrl_alt });
    try expectKey("\x00", st, .{ .key = .space, .mods = ctrl });
    try expectKey("\x00", st, .{ .key = .digit_2, .mods = ctrl });
    try expectKey("\x1b", st, .{ .key = .bracket_left, .mods = ctrl });
    try expectKey("\x1c", st, .{ .key = .backslash, .mods = ctrl });
    try expectKey("\x1f", st, .{ .key = .slash, .mods = ctrl });
    try expectKey("\x7f", st, .{ .key = .digit_8, .mods = ctrl });
    try expectKey("1", st, .{ .key = .digit_1, .mods = ctrl });
    try expectKey("", st, .{ .key = .key_a, .action = .release, .text = "a" });
    try expectKey("a", st, .{ .key = .key_a, .action = .repeat, .text = "a" });
    try expectKey("", st, .{ .key = .left_shift, .mods = shift });
}

test "legacy: Enter, Tab, Backspace and Escape" {
    var st: ke.EncoderState = .{};
    try expectKey("\r", st, .{ .key = .enter });
    try expectKey("\x1b\r", st, .{ .key = .enter, .mods = alt });
    try expectKey("\t", st, .{ .key = .tab });
    try expectKey("\x1b[Z", st, .{ .key = .tab, .mods = shift });
    try expectKey("\x7f", st, .{ .key = .backspace });
    try expectKey("\x08", st, .{ .key = .backspace, .mods = ctrl });
    try expectKey("\x1b\x7f", st, .{ .key = .backspace, .mods = alt });
    try expectKey("\x1b", st, .{ .key = .escape });
    try expectKey("\x1b\x1b", st, .{ .key = .escape, .mods = alt });
    st.linefeed = true;
    try expectKey("\r\n", st, .{ .key = .enter });
    st.backarrow_bs = true;
    try expectKey("\x08", st, .{ .key = .backspace });
    try expectKey("\x7f", st, .{ .key = .backspace, .mods = ctrl });
}

test "legacy: cursor, editing and function keys" {
    var st: ke.EncoderState = .{};
    try expectKey("\x1b[A", st, .{ .key = .up });
    try expectKey("\x1b[1;2A", st, .{ .key = .up, .mods = shift });
    try expectKey("\x1b[1;5D", st, .{ .key = .left, .mods = ctrl });
    try expectKey("\x1b[H", st, .{ .key = .home });
    try expectKey("\x1b[2~", st, .{ .key = .insert });
    try expectKey("\x1b[3;5~", st, .{ .key = .delete, .mods = ctrl });
    try expectKey("\x1b[5;3~", st, .{ .key = .page_up, .mods = alt });
    try expectKey("\x1bOP", st, .{ .key = .f1 });
    try expectKey("\x1b[1;2P", st, .{ .key = .f1, .mods = shift });
    try expectKey("\x1bOR", st, .{ .key = .f3 });
    try expectKey("\x1b[15~", st, .{ .key = .f5 });
    try expectKey("\x1b[24;5~", st, .{ .key = .f12, .mods = ctrl });
    try expectKey("\x1b[1;2P", st, .{ .key = .f13 });
    try expectKey("\x1b[15;2~", st, .{ .key = .f17 });
    try expectKey("\x1b[15;6~", st, .{ .key = .f17, .mods = ctrl });
    st.decckm = true;
    try expectKey("\x1bOA", st, .{ .key = .up });
    try expectKey("\x1bOF", st, .{ .key = .end });
    try expectKey("\x1b[1;5A", st, .{ .key = .up, .mods = ctrl });
    try expectKey("\x1b[2~", st, .{ .key = .insert });
}

test "legacy: keypad in numeric and application mode" {
    var st: ke.EncoderState = .{};
    try expectKey("1", st, .{ .key = .kp_1, .text = "1" });
    try expectKey("\r", st, .{ .key = .kp_enter });
    try expectKey("+", st, .{ .key = .kp_add });
    st.deckpam = true;
    try expectKey("\x1bOq", st, .{ .key = .kp_1, .text = "1" });
    try expectKey("\x1bOM", st, .{ .key = .kp_enter });
    try expectKey("\x1bOk", st, .{ .key = .kp_add });
    try expectKey("\x1bOn", st, .{ .key = .kp_decimal });
}

test "legacy: AltGr text is not Alt, IME text is sent verbatim" {
    const st: ke.EncoderState = .{};
    // Windows reports AltGr as Ctrl+Alt; the layout's text wins.
    try expectKey("@", st, .{ .key = .key_q, .mods = .{ .ctrl = true, .alt = true, .alt_gr = true }, .text = "@" });
    try expectKey("日本", st, .{ .key = .unknown, .text = "日本" });
}

test "legacy: Alt without metaSendsEscape sets the 8th bit" {
    const st: ke.EncoderState = .{ .meta_sends_esc = false };
    try expectKey("\u{e1}", st, .{ .key = .key_a, .mods = alt, .text = "a" });
}

test "legacy: modifyOtherKeys" {
    var st: ke.EncoderState = .{ .modify_other_keys = 1 };
    try expectKey("\x01", st, .{ .key = .key_a, .mods = ctrl });
    try expectKey("\x1b[27;6;65~", st, .{ .key = .key_a, .mods = ctrl_shift });
    try expectKey("\x1b[27;5;49~", st, .{ .key = .digit_1, .mods = ctrl });
    st.modify_other_keys = 2;
    try expectKey("\x1b[27;5;97~", st, .{ .key = .key_a, .mods = ctrl });
    try expectKey("\x1b[27;6;65~", st, .{ .key = .key_a, .mods = ctrl_shift });
    try expectKey("\x1b[27;3;97~", st, .{ .key = .key_a, .mods = alt, .text = "a" });
    try expectKey("A", st, .{ .key = .key_a, .mods = shift, .text = "A" });
    try expectKey("\x1b[27;5;9~", st, .{ .key = .tab, .mods = ctrl });
    try expectKey("\x1b[27;5;13~", st, .{ .key = .enter, .mods = ctrl });
    try expectKey("\r", st, .{ .key = .enter });
}

// Reference encoder for the matrix, written from ctlseqs independently of
// key_encode.zig's structure.
fn reference(key: Key, m: Mods, decckm: bool, deckpam: bool, buf: []u8) []const u8 {
    const p: u8 = 1 + @as(u8, @intFromBool(m.shift)) + 2 * @as(u8, @intFromBool(m.alt)) + 4 * @as(u8, @intFromBool(m.ctrl));
    const letter: ?u8 = switch (key) {
        .up => 'A',
        .down => 'B',
        .right => 'C',
        .left => 'D',
        .home => 'H',
        .end => 'F',
        else => null,
    };
    if (letter) |c| {
        if (p > 1) return std.fmt.bufPrint(buf, "\x1b[1;{d}{c}", .{ p, c }) catch unreachable;
        return std.fmt.bufPrint(buf, "\x1b{c}{c}", .{ @as(u8, if (decckm) 'O' else '['), c }) catch unreachable;
    }
    const v = @intFromEnum(key);
    if (v >= @intFromEnum(Key.f1) and v <= @intFromEnum(Key.f4)) {
        const c: u8 = "PQRS"[v - @intFromEnum(Key.f1)];
        if (p > 1) return std.fmt.bufPrint(buf, "\x1b[1;{d}{c}", .{ p, c }) catch unreachable;
        return std.fmt.bufPrint(buf, "\x1bO{c}", .{c}) catch unreachable;
    }
    const tilde: ?u16 = switch (key) {
        .insert => 2,
        .delete => 3,
        .page_up => 5,
        .page_down => 6,
        .f5 => 15,
        .f6 => 17,
        .f7 => 18,
        .f8 => 19,
        .f9 => 20,
        .f10 => 21,
        .f11 => 23,
        .f12 => 24,
        else => null,
    };
    if (tilde) |n| {
        if (p > 1) return std.fmt.bufPrint(buf, "\x1b[{d};{d}~", .{ n, p }) catch unreachable;
        return std.fmt.bufPrint(buf, "\x1b[{d}~", .{n}) catch unreachable;
    }
    if (tables.keypad(key)) |kp| {
        if (deckpam) return std.fmt.bufPrint(buf, "\x1bO{c}", .{kp.ss3}) catch unreachable;
        var n: usize = 0;
        if (m.alt) {
            buf[0] = 0x1b;
            n = 1;
        }
        buf[n] = kp.text;
        return buf[0 .. n + 1];
    }
    // Letters.
    const cp = tables.usCodepoint(key);
    var n: usize = 0;
    if (m.alt) {
        buf[0] = 0x1b;
        n = 1;
    }
    if (m.ctrl) {
        buf[n] = @intCast(cp - 'a' + 1);
    } else {
        buf[n] = @intCast(if (m.shift) cp - 32 else cp);
    }
    return buf[0 .. n + 1];
}

test "legacy: generated matrix of keys, modifiers, DECCKM and DECKPAM" {
    var ks: std.ArrayList(Key) = .empty;
    defer ks.deinit(testing.allocator);
    for ([_]Key{ .up, .down, .right, .left, .home, .end, .insert, .delete, .page_up, .page_down }) |k| try ks.append(testing.allocator, k);
    for (@intFromEnum(Key.f1)..@intFromEnum(Key.f12) + 1) |v| try ks.append(testing.allocator, @enumFromInt(v));
    for (@intFromEnum(Key.kp_divide)..@intFromEnum(Key.kp_decimal) + 1) |v| try ks.append(testing.allocator, @enumFromInt(v));
    for (@intFromEnum(Key.key_a)..@intFromEnum(Key.key_z) + 1) |v| try ks.append(testing.allocator, @enumFromInt(v));
    const combos = [_]Mods{ none, shift, alt, ctrl, ctrl_shift, ctrl_alt };
    var rows: usize = 0;
    var buf: [32]u8 = undefined;
    for (ks.items) |k| for (combos) |m| for ([_]bool{ false, true }) |ckm| for ([_]bool{ false, true }) |kpam| {
        const st: ke.EncoderState = .{ .decckm = ckm, .deckpam = kpam };
        const cp = tables.usCodepoint(k);
        var tb: [4]u8 = undefined;
        // The layout's text for plain and shifted letters, as E01 reports it.
        const text: []const u8 = if (tables.keypad(k)) |kp| (if (kp.text == '\r') "" else blk: {
            tb[0] = kp.text;
            break :blk tb[0..1];
        }) else if (cp != 0 and !m.ctrl) blk: {
            tb[0] = @intCast(if (m.shift) cp - 32 else cp);
            break :blk tb[0..1];
        } else "";
        try expectKey(reference(k, m, ckm, kpam, &buf), st, .{ .key = k, .mods = m, .text = text });
        rows += 1;
    };
    try testing.expect(rows >= 1500);
}
