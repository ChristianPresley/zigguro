//! IMM32 composition (E01.F02.S03.T01): `WM_IME_*` → `ime_preedit` and
//! `text_input`, `set_ime_state` → context association and composition
//! and candidate window placement. We draw the preedit inline, so the
//! default composition window is suppressed. The conversions are pure and
//! tested on every OS; `Ime` runs on the window's thread on Windows.
//!
//! No heap allocation per message: composition strings are read into a
//! fixed buffer (longer ones are truncated at a code point boundary).

const std = @import("std");
const types = @import("../api/types.zig");
const ImePurpose = @import("../api/ime.zig").ImePurpose;
const is_windows = @import("builtin").os.tag == .windows;

/// `WM_IME_*` messages.
pub const WM_IME = struct {
    /// WM_IME_STARTCOMPOSITION.
    pub const STARTCOMPOSITION: u32 = 0x010D;
    /// WM_IME_ENDCOMPOSITION.
    pub const ENDCOMPOSITION: u32 = 0x010E;
    /// WM_IME_COMPOSITION.
    pub const COMPOSITION: u32 = 0x010F;
    /// WM_IME_SETCONTEXT.
    pub const SETCONTEXT: u32 = 0x0281;
    /// WM_IME_CHAR.
    pub const CHAR: u32 = 0x0286;
};

/// `VK_PROCESSKEY`: a key the IME consumed.
pub const VK_PROCESSKEY: u16 = 0xE5;
/// `ISC_SHOWUICOMPOSITIONWINDOW`.
pub const ISC_SHOWUICOMPOSITIONWINDOW: usize = 0x8000_0000;
/// `GCS_COMPATTR`.
pub const GCS_COMPATTR: u32 = 0x0010;
/// `ATTR_TARGET_CONVERTED`.
pub const ATTR_TARGET_CONVERTED: u8 = 1;
/// `ATTR_TARGET_NOTCONVERTED`.
pub const ATTR_TARGET_NOTCONVERTED: u8 = 3;
/// `NI_COMPOSITIONSTR`.
pub const NI_COMPOSITIONSTR: u32 = 0x0015;
/// `CPS_COMPLETE`.
pub const CPS_COMPLETE: u32 = 0x0001;
/// `IACE_DEFAULT`.
pub const IACE_DEFAULT: u32 = 0x0010;

/// Longest composition string read, in UTF-16 units.
pub const max_units = 512;

/// The UTF-8 byte offset of UTF-16 index `idx` in `units`. An index in
/// the middle of a surrogate pair counts as the pair's end.
pub fn utf8Offset(units: []const u16, idx: usize) u32 {
    var off: u32 = 0;
    var i: usize = 0;
    while (i < units.len and i < idx) {
        const u = units[i];
        if (u >= 0xD800 and u < 0xDC00 and i + 1 < units.len and units[i + 1] >= 0xDC00 and units[i + 1] < 0xE000) {
            off += 4;
            i += 2;
        } else {
            off += if (u < 0x80) 1 else if (u < 0x800) 2 else 3;
            i += 1;
        }
    }
    return off;
}

/// UTF-16 → UTF-8 into `out`, stopping before a code point that does not
/// fit. Unpaired surrogates become U+FFFD.
pub fn toUtf8(units: []const u16, out: []u8) []u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < units.len) {
        var cp: u21 = units[i];
        i += 1;
        if (cp >= 0xD800 and cp < 0xDC00 and i < units.len and units[i] >= 0xDC00 and units[i] < 0xE000) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (units[i] - 0xDC00);
            i += 1;
        } else if (cp >= 0xD800 and cp < 0xE000) cp = 0xFFFD;
        const len = std.unicode.utf8CodepointSequenceLength(cp) catch unreachable;
        if (n + len > out.len) break;
        _ = std.unicode.utf8Encode(cp, out[n..]) catch unreachable;
        n += len;
    }
    return out[0..n];
}

/// The selected clause in a `GCS_COMPATTR` array: the first run of
/// target attributes, as UTF-16 indices [begin, end). Null when no clause
/// is selected (still typing): the caret alone marks the position.
pub fn selectedClause(attrs: []const u8) ?[2]usize {
    var begin: ?usize = null;
    for (attrs, 0..) |a, i| {
        const target = a == ATTR_TARGET_CONVERTED or a == ATTR_TARGET_NOTCONVERTED;
        if (target and begin == null) begin = i;
        if (!target and begin != null) return .{ begin.?, i };
    }
    return if (begin) |b| .{ b, attrs.len } else null;
}

/// The preedit cursor range in UTF-8 bytes: the selected clause, or
/// [cursor, cursor] at the composition caret.
pub fn preeditRange(units: []const u16, attrs: []const u8, cursor: usize) [2]i32 {
    if (selectedClause(attrs)) |c| return .{ @intCast(utf8Offset(units, c[0])), @intCast(utf8Offset(units, c[1])) };
    const at: i32 = @intCast(utf8Offset(units, cursor));
    return .{ at, at };
}

/// Where the IME events go.
pub const Sink = struct {
    ctx: *anyopaque,
    /// An `ime_preedit`; empty text ends the preedit.
    preedit: *const fn (ctx: *anyopaque, text: []const u8, begin: i32, end: i32) void,
    /// A `text_input` commit.
    commit: *const fn (ctx: *anyopaque, text: []const u8) void,
};

/// The IME state of one window. Window thread only.
pub const Ime = if (is_windows) struct {
    const t = @import("bindings/types.zig");
    const imm32 = @import("bindings/imm32.zig");
    const user32 = @import("bindings/user32.zig");

    enabled: bool = true,
    caret: types.PxRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    composing: bool = false,

    /// Handles an IME message; null means pass it to `DefWindowProcW`.
    /// `lp_out` receives a modified lParam for that call.
    pub fn onMessage(s: *@This(), hwnd: t.HWND, msg: u32, wp: usize, lp: isize, sink: Sink, lp_out: *isize) ?isize {
        _ = wp;
        lp_out.* = lp;
        switch (msg) {
            WM_IME.SETCONTEXT => {
                // We draw the preedit; keep the candidate list UI.
                lp_out.* = @bitCast(@as(usize, @bitCast(lp)) & ~ISC_SHOWUICOMPOSITIONWINDOW);
                return null;
            },
            WM_IME.STARTCOMPOSITION => {
                s.composing = true;
                s.place(hwnd);
                return 0;
            },
            WM_IME.ENDCOMPOSITION => {
                s.composing = false;
                sink.preedit(sink.ctx, "", -1, -1);
                return 0;
            },
            WM_IME.COMPOSITION => {
                const flags: u32 = @truncate(@as(usize, @bitCast(lp)));
                const himc = imm32.ImmGetContext(hwnd) orelse return 0;
                defer _ = imm32.ImmReleaseContext(hwnd, himc);
                var units: [max_units]u16 = undefined;
                var utf8: [max_units * 3]u8 = undefined;
                if (flags & imm32.GCS_RESULTSTR != 0) {
                    const u = read(himc, imm32.GCS_RESULTSTR, &units);
                    if (u.len > 0) sink.commit(sink.ctx, toUtf8(u, &utf8));
                }
                if (flags & imm32.GCS_COMPSTR != 0) {
                    const u = read(himc, imm32.GCS_COMPSTR, &units);
                    var attrs: [max_units]u8 = undefined;
                    const an = imm32.ImmGetCompositionStringW(himc, GCS_COMPATTR, &attrs, attrs.len);
                    const cursor = imm32.ImmGetCompositionStringW(himc, imm32.GCS_CURSORPOS, null, 0);
                    const range = preeditRange(u, attrs[0..@intCast(std.math.clamp(an, 0, @as(i32, @intCast(u.len))))], @intCast(std.math.clamp(cursor, 0, @as(i32, @intCast(u.len)))));
                    sink.preedit(sink.ctx, toUtf8(u, &utf8), range[0], range[1]);
                } else if (flags & imm32.GCS_RESULTSTR == 0) {
                    // Neither: the composition was cancelled.
                    sink.preedit(sink.ctx, "", -1, -1);
                }
                // Handled: DefWindowProc would send WM_IME_CHAR as well.
                return 0;
            },
            // Results arrive through GCS_RESULTSTR.
            WM_IME.CHAR => return 0,
            else => return null,
        }
    }

    fn read(himc: t.HIMC, index: u32, buf: *[max_units]u16) []const u16 {
        const bytes = imm32.ImmGetCompositionStringW(himc, index, buf, @sizeOf(@TypeOf(buf.*)));
        if (bytes <= 0) return buf[0..0];
        return buf[0..@min(@as(usize, @intCast(bytes)) / 2, max_units)];
    }

    /// Applies `set_ime_state`: association, then window placement. Turning
    /// the IME off while composing commits the composition.
    pub fn apply(s: *@This(), hwnd: t.HWND, enabled: bool, purpose: ImePurpose, caret: types.PxRect) void {
        const on = enabled and purpose != .password and purpose != .pin;
        s.caret = caret;
        if (!on and s.composing) {
            if (imm32.ImmGetContext(hwnd)) |himc| {
                _ = imm32.ImmNotifyIME(himc, NI_COMPOSITIONSTR, CPS_COMPLETE, 0);
                _ = imm32.ImmReleaseContext(hwnd, himc);
            }
        }
        if (on != s.enabled) {
            _ = imm32.ImmAssociateContextEx(hwnd, null, if (on) IACE_DEFAULT else 0);
            s.enabled = on;
        }
        if (on) s.place(hwnd);
    }

    /// Puts the composition window at the caret and the candidate list
    /// below it, never over the caret line.
    fn place(s: *@This(), hwnd: t.HWND) void {
        const himc = imm32.ImmGetContext(hwnd) orelse return;
        defer _ = imm32.ImmReleaseContext(hwnd, himc);
        const c = s.caret;
        const rc: t.RECT = .{ .left = c.x, .top = c.y, .right = c.x + @as(i32, @intCast(@max(c.w, 1))), .bottom = c.y + @as(i32, @intCast(@max(c.h, 1))) };
        const cf: t.COMPOSITIONFORM = .{ .dwStyle = imm32.CFS_POINT, .ptCurrentPos = .{ .x = c.x, .y = c.y }, .rcArea = rc };
        _ = imm32.ImmSetCompositionWindow(himc, &cf);
        const cand: t.CANDIDATEFORM = .{ .dwIndex = 0, .dwStyle = imm32.CFS_EXCLUDE, .ptCurrentPos = .{ .x = c.x, .y = rc.bottom }, .rcArea = rc };
        _ = imm32.ImmSetCandidateWindow(himc, &cand);
    }
} else void;

const testing = std.testing;

test "utf16 cursor index → utf8 offset with surrogates" {
    // "aé日😀b": 1 + 2 + 3 + 4 + 1 bytes; 😀 is two UTF-16 units.
    const units = [_]u16{ 'a', 0xE9, 0x65E5, 0xD83D, 0xDE00, 'b' };
    const want = [_]u32{ 0, 1, 3, 6, 10, 10, 11 };
    try testing.expectEqual(want[0], utf8Offset(&units, 0));
    try testing.expectEqual(want[1], utf8Offset(&units, 1));
    try testing.expectEqual(want[2], utf8Offset(&units, 2));
    try testing.expectEqual(want[3], utf8Offset(&units, 3));
    try testing.expectEqual(want[5], utf8Offset(&units, 5));
    try testing.expectEqual(want[6], utf8Offset(&units, 6));
    try testing.expectEqual(@as(u32, 11), utf8Offset(&units, 99));
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("aé日😀b", toUtf8(&units, &buf));
    // Truncation keeps whole code points; lone surrogates become U+FFFD.
    try testing.expectEqualStrings("aé", toUtf8(&units, buf[0..5]));
    try testing.expectEqualStrings("x\u{FFFD}", toUtf8(&[_]u16{ 'x', 0xDC00 }, &buf));
}

test "attr array → selected clause range" {
    // にほんごを|へんかん: input, then the converted target clause.
    try testing.expectEqual(@as(?[2]usize, .{ 3, 5 }), selectedClause(&.{ 2, 2, 2, 1, 1, 2 }));
    try testing.expectEqual(@as(?[2]usize, .{ 0, 2 }), selectedClause(&.{ 3, 3 }));
    try testing.expectEqual(@as(?[2]usize, null), selectedClause(&.{ 0, 0, 0 }));
    const units = [_]u16{ 0x65E5, 0x672C, 0x8A9E };
    try testing.expectEqual([2]i32{ 3, 9 }, preeditRange(&units, &.{ 2, 1, 1 }, 3));
    try testing.expectEqual([2]i32{ 6, 6 }, preeditRange(&units, &.{ 0, 0, 0 }, 2));
}
