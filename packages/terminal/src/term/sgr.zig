//! SGR (Select Graphic Rendition): applies `CSI ... m` to a cell `Style`,
//! supporting both semicolon and colon extended-colour forms and kitty
//! underline styles; `format` renders a style back as canonical SGR
//! parameters for DECRQSS.

const std = @import("std");
const Csi = @import("../vt/params.zig").Csi;
const style_mod = @import("../screen/style.zig");
const Style = style_mod.Style;
const Color = style_mod.Color;

fn clamp8(v: u16) u8 {
    return @intCast(@min(v, 255));
}

/// Number of sub-parameters following param `i` (params introduced by ':').
fn subCount(c: *const Csi, i: usize) usize {
    var n: usize = 0;
    while (i + 1 + n < c.count and c.isSub(i + 1 + n)) n += 1;
    return n;
}

const Ext = struct { color: ?Color, consumed: usize };

/// Parses an extended colour starting at param `i` (the 38/48/58 itself).
fn extColor(c: *const Csi, i: usize) Ext {
    const subs = if (c.colon_mask == 0) 0 else subCount(c, i);
    if (subs > 0) {
        // Colon form: everything is in the sub-params.
        const kind = c.get(i + 1, 0);
        switch (kind) {
            5 => return .{ .color = if (subs >= 2) .palette(clamp8(c.get(i + 2, 0))) else null, .consumed = subs },
            2 => {
                // 38:2:r:g:b or 38:2:cs:r:g:b (colour-space id, possibly empty).
                const off: usize = if (subs >= 5) 3 else 2;
                if (subs < 4) return .{ .color = null, .consumed = subs };
                return .{ .color = .rgb(clamp8(c.get(i + off, 0)), clamp8(c.get(i + off + 1, 0)), clamp8(c.get(i + off + 2, 0))), .consumed = subs };
            },
            else => return .{ .color = null, .consumed = subs },
        }
    }
    // Semicolon form consumes following params.
    if (i + 1 >= c.count) return .{ .color = null, .consumed = 0 };
    switch (c.get(i + 1, 0)) {
        5 => {
            if (i + 2 >= c.count) return .{ .color = null, .consumed = c.count - i - 1 };
            return .{ .color = .palette(clamp8(c.get(i + 2, 0))), .consumed = 2 };
        },
        2 => {
            // Too few params: ignore the rest of this SGR (xterm).
            if (i + 4 >= c.count) return .{ .color = null, .consumed = c.count - i - 1 };
            return .{ .color = .rgb(clamp8(c.get(i + 2, 0)), clamp8(c.get(i + 3, 0)), clamp8(c.get(i + 4, 0))), .consumed = 4 };
        },
        else => return .{ .color = null, .consumed = 1 },
    }
}

/// Applies an SGR sequence to `st`. Never fails; unknown attributes are
/// ignored one by one.
pub fn applySgr(st: *Style, c: *const Csi) void {
    if (c.count == 0) {
        st.* = .{};
        return;
    }
    var i: usize = 0;
    while (i < c.count) : (i += 1) {
        const p = c.get(i, 0);
        // Most sequences have no sub-parameters at all.
        const subs = if (c.colon_mask == 0) 0 else subCount(c, i);
        switch (p) {
            0 => st.* = .{},
            1 => st.flags.bold = true,
            2 => st.flags.faint = true,
            3 => st.flags.italic = true,
            4 => {
                if (subs > 0) {
                    st.underline = switch (c.get(i + 1, 0)) {
                        0 => .none,
                        1 => .single,
                        2 => .double,
                        3 => .curly,
                        4 => .dotted,
                        5 => .dashed,
                        else => st.underline,
                    };
                } else st.underline = .single;
            },
            5, 6 => st.flags.blink = true,
            7 => st.flags.inverse = true,
            8 => st.flags.invisible = true,
            9 => st.flags.strike = true,
            21 => st.underline = .double,
            22 => {
                st.flags.bold = false;
                st.flags.faint = false;
            },
            23 => st.flags.italic = false,
            24 => st.underline = .none,
            25 => st.flags.blink = false,
            27 => st.flags.inverse = false,
            28 => st.flags.invisible = false,
            29 => st.flags.strike = false,
            30...37 => st.fg = .palette(@intCast(p - 30)),
            38, 48, 58 => {
                const e = extColor(c, i);
                if (e.color) |col| switch (p) {
                    38 => st.fg = col,
                    48 => st.bg = col,
                    else => st.ul_color = col,
                };
                i += e.consumed;
                continue;
            },
            39 => st.fg = .default,
            40...47 => st.bg = .palette(@intCast(p - 40)),
            49 => st.bg = .default,
            53 => st.flags.overline = true,
            55 => st.flags.overline = false,
            59 => st.ul_color = .default,
            90...97 => st.fg = .palette(@intCast(p - 90 + 8)),
            100...107 => st.bg = .palette(@intCast(p - 100 + 8)),
            else => {},
        }
        i += subs;
    }
}

fn writeColor(w: *std.Io.Writer, base: u8, col: Color) !void {
    switch (col.tag) {
        .default => {},
        .palette => {
            if (base != 58 and col.r < 8) {
                try w.print(";{d}", .{@as(u16, if (base == 38) 30 else 40) + col.r});
            } else if (base != 58 and col.r < 16) {
                try w.print(";{d}", .{@as(u16, if (base == 38) 90 else 100) + col.r - 8});
            } else try w.print(";{d}:5:{d}", .{ base, col.r });
        },
        .rgb => try w.print(";{d}:2::{d}:{d}:{d}", .{ base, col.r, col.g, col.b }),
    }
}

/// Writes `st` as canonical SGR params starting with `0`, e.g.
/// `0;1;38:2::255:0:0` (the DECRQSS `m` reply body).
pub fn format(st: Style, w: *std.Io.Writer) !void {
    try w.writeAll("0");
    const f = st.flags;
    if (f.bold) try w.writeAll(";1");
    if (f.faint) try w.writeAll(";2");
    if (f.italic) try w.writeAll(";3");
    switch (st.underline) {
        .none => {},
        .single => try w.writeAll(";4"),
        .double => try w.writeAll(";4:2"),
        .curly => try w.writeAll(";4:3"),
        .dotted => try w.writeAll(";4:4"),
        .dashed => try w.writeAll(";4:5"),
    }
    if (f.blink) try w.writeAll(";5");
    if (f.inverse) try w.writeAll(";7");
    if (f.invisible) try w.writeAll(";8");
    if (f.strike) try w.writeAll(";9");
    if (f.overline) try w.writeAll(";53");
    try writeColor(w, 38, st.fg);
    try writeColor(w, 48, st.bg);
    try writeColor(w, 58, st.ul_color);
}

const testing = std.testing;
const Parser = @import("../vt/Parser.zig");

fn sgrOf(seq: []const u8) Style {
    var st: Style = .{};
    sgrOn(&st, seq);
    return st;
}

fn sgrOn(st: *Style, seq: []const u8) void {
    const H = struct {
        st: *Style,
        pub fn csiDispatch(h: *@This(), c: *const Csi) void {
            if (c.final == 'm') applySgr(h.st, c);
        }
        pub fn printAscii(_: *@This(), _: []const u8) void {}
        pub fn printCodepoints(_: *@This(), _: []const u21) void {}
        pub fn execute(_: *@This(), _: u8) void {}
        pub fn escDispatch(_: *@This(), _: @import("../vt/params.zig").Esc) void {}
        pub fn oscDispatch(_: *@This(), _: []const u8, _: @import("../vt/params.zig").StringTerm) void {}
        pub fn dcsHook(_: *@This(), _: *const Csi) bool {
            return false;
        }
        pub fn dcsPut(_: *@This(), _: []const u8) void {}
        pub fn dcsUnhook(_: *@This()) void {}
        pub fn apcStart(_: *@This()) bool {
            return false;
        }
        pub fn apcPut(_: *@This(), _: []const u8) void {}
        pub fn apcEnd(_: *@This()) void {}
    };
    var p: Parser = .init(testing.allocator, .{});
    defer p.deinit();
    var h: H = .{ .st = st };
    p.feed(seq, &h);
}

test "SGR table" {
    const T = struct { []const u8, Style };
    const red: Color = .palette(1);
    const cases = [_]T{
        .{ "\x1b[m", .{} },
        .{ "\x1b[1m", .{ .flags = .{ .bold = true } } },
        .{ "\x1b[2m", .{ .flags = .{ .faint = true } } },
        .{ "\x1b[3m", .{ .flags = .{ .italic = true } } },
        .{ "\x1b[4m", .{ .underline = .single } },
        .{ "\x1b[4:0m", .{} },
        .{ "\x1b[4:2m", .{ .underline = .double } },
        .{ "\x1b[4:3m", .{ .underline = .curly } },
        .{ "\x1b[4:4m", .{ .underline = .dotted } },
        .{ "\x1b[4:5m", .{ .underline = .dashed } },
        .{ "\x1b[5m", .{ .flags = .{ .blink = true } } },
        .{ "\x1b[6m", .{ .flags = .{ .blink = true } } },
        .{ "\x1b[7m", .{ .flags = .{ .inverse = true } } },
        .{ "\x1b[8m", .{ .flags = .{ .invisible = true } } },
        .{ "\x1b[9m", .{ .flags = .{ .strike = true } } },
        .{ "\x1b[21m", .{ .underline = .double } },
        .{ "\x1b[1;2;22m", .{} },
        .{ "\x1b[3;23m", .{} },
        .{ "\x1b[4;24m", .{} },
        .{ "\x1b[5;25m", .{} },
        .{ "\x1b[7;27m", .{} },
        .{ "\x1b[8;28m", .{} },
        .{ "\x1b[9;29m", .{} },
        .{ "\x1b[31m", .{ .fg = red } },
        .{ "\x1b[41m", .{ .bg = red } },
        .{ "\x1b[91m", .{ .fg = .palette(9) } },
        .{ "\x1b[101m", .{ .bg = .palette(9) } },
        .{ "\x1b[31;39m", .{} },
        .{ "\x1b[41;49m", .{} },
        .{ "\x1b[53m", .{ .flags = .{ .overline = true } } },
        .{ "\x1b[53;55m", .{} },
        .{ "\x1b[38;5;196m", .{ .fg = .palette(196) } },
        .{ "\x1b[48;5;21m", .{ .bg = .palette(21) } },
        .{ "\x1b[38;2;1;2;3m", .{ .fg = .rgb(1, 2, 3) } },
        .{ "\x1b[48;2;300;2;3m", .{ .bg = .rgb(255, 2, 3) } },
        .{ "\x1b[38:5:196m", .{ .fg = .palette(196) } },
        .{ "\x1b[38:2:1:2:3m", .{ .fg = .rgb(1, 2, 3) } },
        .{ "\x1b[38:2::1:2:3m", .{ .fg = .rgb(1, 2, 3) } },
        .{ "\x1b[38:2:0:1:2:3m", .{ .fg = .rgb(1, 2, 3) } },
        .{ "\x1b[58:2::1:2:3m", .{ .ul_color = .rgb(1, 2, 3) } },
        .{ "\x1b[58;5;9m", .{ .ul_color = .palette(9) } },
        .{ "\x1b[58;5;9;59m", .{} },
        .{ "\x1b[38;2;1m", .{} }, // truncated: rest ignored
        .{ "\x1b[38;2;1;2m", .{} },
        .{ "\x1b[38;5m", .{} },
        .{ "\x1b[38;2;1;2;3;1m", .{ .fg = .rgb(1, 2, 3), .flags = .{ .bold = true } } },
        .{ "\x1b[1;4:3;38:5:196m", .{ .fg = .palette(196), .underline = .curly, .flags = .{ .bold = true } } },
        .{ "\x1b[38:2:1m", .{} }, // malformed colon form consumes its sub-params
        .{ "\x1b[38:9:1;1m", .{ .flags = .{ .bold = true } } },
        .{ "\x1b[38;9;1m", .{ .flags = .{ .bold = true } } }, // 38;9 unknown: consumes 9, then 1 = bold
        .{ "\x1b[1;0m", .{} },
        .{ "\x1b[;1m", .{ .flags = .{ .bold = true } } },
        .{ "\x1b[999m", .{} },
        .{ "\x1b[4:99m", .{} },
        .{ "\x1b[30;47m", .{ .fg = .palette(0), .bg = .palette(7) } },
        .{ "\x1b[97;107m", .{ .fg = .palette(15), .bg = .palette(15) } },
    };
    for (cases) |c| {
        const got = sgrOf(c[0]);
        if (!got.eql(c[1])) {
            std.debug.print("SGR {s} mismatch: {any}\n", .{ c[0][1..], got });
            return error.TestUnexpectedResult;
        }
    }
}

test "DECRQSS m round-trips through applySgr" {
    const seqs = [_][]const u8{ "\x1b[1;3;4:3;7;38:2::255:0:0;48;5;200;58:5:3m", "\x1b[2;9;53;31;102m", "\x1b[21;5;8m" };
    for (seqs) |s| {
        const st = sgrOf(s);
        var buf: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try format(st, &w);
        var again: Style = .{ .fg = .palette(3) };
        var seq_buf: [140]u8 = undefined;
        sgrOn(&again, try std.fmt.bufPrint(&seq_buf, "\x1b[{s}m", .{w.buffered()}));
        try testing.expect(again.eql(st));
    }
}
