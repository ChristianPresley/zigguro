//! Terminal-to-host replies: device attributes, XTVERSION, DSR/CPR, DECRQM,
//! XTWINOPS, the in-band resize report and the colour OSCs, plus the reply
//! limiter. No reply echoes host-controlled bytes: titles are never
//! reported and every value is formatted from terminal state.

const std = @import("std");
const Terminal = @import("Terminal.zig");
const Csi = @import("../vt/Parser.zig").Csi;
const StringTerm = @import("../vt/Parser.zig").StringTerm;
const modes_mod = @import("modes.zig");
const color = @import("color.zig");

/// Caps replies at `budget_bytes` per `per_input_bytes` of host output, so
/// that echoing programs cannot drive a feedback storm.
pub const ReplyLimiter = struct {
    budget_bytes: u32 = 64 * 1024,
    per_input_bytes: u32 = 1024 * 1024,
    window_in: u64 = 0,
    window_out: u64 = 0,
    /// Replies dropped in the current window (the warning fires at 1).
    dropped: u64 = 0,
    /// Replies dropped in total (debug stat).
    total_dropped: u64 = 0,

    /// Accounts `n` bytes of input, opening a new window every
    /// `per_input_bytes`.
    pub fn onInput(l: *ReplyLimiter, n: usize) void {
        l.window_in += n;
        if (l.window_in > l.per_input_bytes) {
            l.window_in %= l.per_input_bytes;
            l.window_out = 0;
            l.dropped = 0;
        }
    }

    /// Whether a reply of `n` bytes fits the current window.
    pub fn allow(l: *ReplyLimiter, n: usize) bool {
        if (l.window_out + n > l.budget_bytes) {
            l.dropped += 1;
            l.total_dropped += 1;
            return false;
        }
        l.window_out += n;
        return true;
    }
};

/// DA1: VT220-class with ANSI colour.
pub fn da1(t: *Terminal) void {
    t.reply("\x1b[?62;22c");
}

/// DA2: a low, stable firmware number (apps should use XTVERSION).
pub fn da2(t: *Terminal) void {
    t.reply("\x1b[>1;10;0c");
}

/// DA3: the unit id, hex of "zGUR".
pub fn da3(t: *Terminal) void {
    t.reply("\x1bP!|7A475552\x1b\\");
}

/// XTVERSION.
pub fn xtversion(t: *Terminal) void {
    t.replyFmt("\x1bP>|zigguro({s})\x1b\\", .{t.opts.version});
}

/// DSR (ANSI): status and CPR.
pub fn dsr(t: *Terminal, c: *const Csi) void {
    switch (c.get(0, 0)) {
        5 => t.reply("\x1b[0n"),
        6 => {
            const p = cursorReportPos(t);
            t.replyFmt("\x1b[{d};{d}R", .{ p[0], p[1] });
        },
        else => {},
    }
}

/// DSR (DEC private): DECXCPR, printer and keyboard status.
pub fn dsrPrivate(t: *Terminal, c: *const Csi) void {
    switch (c.get(0, 0)) {
        6 => {
            const p = cursorReportPos(t);
            t.replyFmt("\x1b[?{d};{d};1R", .{ p[0], p[1] });
        },
        15 => t.reply("\x1b[?13n"),
        26 => t.reply("\x1b[?27;1;0;0n"),
        else => {},
    }
}

/// The 1-based cursor position, relative to the margins in origin mode.
fn cursorReportPos(t: *Terminal) [2]u32 {
    const s = t.screen();
    var y: u32 = s.cursor.y;
    var x: u32 = s.cursor.x;
    if (t.modes.get(.origin)) {
        y -|= s.region.top;
        x -|= s.region.left;
    }
    return .{ y + 1, x + 1 };
}

/// DECRQM: `CSI [?] Pd ; Ps $ y`.
pub fn decrqm(t: *Terminal, kind: modes_mod.Kind, value: u16) void {
    const ps = t.modes.reportValue(kind, value);
    if (kind == .dec) {
        t.replyFmt("\x1b[?{d};{d}$y", .{ value, ps });
    } else t.replyFmt("\x1b[{d};{d}$y", .{ value, ps });
}

/// XTWINOPS: size reports and the title stack. Title reports (20/21) are
/// disabled; window manipulation (1-9) is ignored.
pub fn xtwinops(t: *Terminal, c: *const Csi) void {
    const r: u32 = t.rows();
    const k: u32 = t.cols();
    const cw: u32 = t.cell_px.w;
    const ch: u32 = t.cell_px.h;
    switch (c.get(0, 0)) {
        14 => t.replyFmt("\x1b[4;{d};{d}t", .{ r * ch, k * cw }),
        16 => t.replyFmt("\x1b[6;{d};{d}t", .{ ch, cw }),
        18 => t.replyFmt("\x1b[8;{d};{d}t", .{ r, k }),
        22 => t.pushTitle(),
        23 => t.popTitle(),
        else => {},
    }
}

/// Mode 2048 report: `CSI 48 ; rows ; cols ; height_px ; width_px t`.
pub fn inBandSize(t: *Terminal) void {
    const r: u32 = t.rows();
    const k: u32 = t.cols();
    t.replyFmt("\x1b[48;{d};{d};{d};{d}t", .{ r, k, r * t.cell_px.h, k * t.cell_px.w });
}

fn special(n: u16) ?color.Special {
    return switch (n) {
        10 => .fg,
        11 => .bg,
        12 => .cursor,
        17 => .sel_bg,
        19 => .sel_fg,
        else => null,
    };
}

fn colorReply(t: *Terminal, prefix: []const u8, rgb: color.Rgb, term: StringTerm) void {
    var buf: [64]u8 = undefined;
    const st = Terminal.stBytes(term);
    const s = std.fmt.bufPrint(&buf, "\x1b]{s};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}{s}", .{
        prefix, rgb[0], rgb[0], rgb[1], rgb[1], rgb[2], rgb[2], st,
    }) catch return;
    t.reply(s);
}

/// The colour OSCs: 4, 10-19, 104, 110-119. `ps` is the OSC number and
/// `rest` everything after its `;` (empty when absent).
pub fn colorOsc(t: *Terminal, ps: u16, rest: []const u8, term: StringTerm) void {
    var changed = false;
    switch (ps) {
        4 => {
            var it = std.mem.splitScalar(u8, rest, ';');
            while (it.next()) |idx_s| {
                const spec = it.next() orelse break;
                const idx = std.fmt.parseInt(u8, idx_s, 10) catch continue;
                if (std.mem.eql(u8, spec, "?")) {
                    var pb: [8]u8 = undefined;
                    colorReply(t, std.fmt.bufPrint(&pb, "4;{d}", .{idx}) catch continue, t.palette.ansi[idx], term);
                } else if (color.parseColorSpec(spec)) |rgb| {
                    t.palette.ansi[idx] = rgb;
                    changed = true;
                }
            }
        },
        10...19 => {
            // Successive specs apply to successive OSC numbers (xterm).
            var n = ps;
            var it = std.mem.splitScalar(u8, rest, ';');
            while (it.next()) |spec| : (n += 1) {
                if (n > 19) break;
                const sp = special(n) orelse continue;
                if (std.mem.eql(u8, spec, "?")) {
                    var pb: [4]u8 = undefined;
                    colorReply(t, std.fmt.bufPrint(&pb, "{d}", .{n}) catch continue, t.palette.special(sp), term);
                } else if (color.parseColorSpec(spec)) |rgb| {
                    t.palette.setSpecial(sp, rgb);
                    changed = true;
                }
            }
        },
        104 => {
            if (rest.len == 0) {
                t.palette.ansi = t.default_palette.ansi;
                changed = true;
            } else {
                var it = std.mem.splitScalar(u8, rest, ';');
                while (it.next()) |idx_s| {
                    const idx = std.fmt.parseInt(u8, idx_s, 10) catch continue;
                    t.palette.ansi[idx] = t.default_palette.ansi[idx];
                    changed = true;
                }
            }
        },
        110...119 => if (special(ps - 100)) |sp| {
            t.palette.resetSpecial(sp, &t.default_palette);
            changed = true;
        },
        else => {},
    }
    if (changed) t.effects.push(.palette_changed);
}

test "reply limiter windows" {
    var l: ReplyLimiter = .{};
    l.onInput(3);
    try std.testing.expect(l.allow(10));
    var sent: u64 = 10;
    for (0..200_000) |_| {
        if (l.allow(10)) sent += 10;
    }
    try std.testing.expect(sent <= 64 * 1024 and sent > 64 * 1024 - 10);
    l.onInput(1024 * 1024);
    try std.testing.expect(l.allow(10));
}
