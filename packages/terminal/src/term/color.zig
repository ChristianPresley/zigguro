//! The colour palette (256 indexed colours plus the special colours) with
//! XParseColor-style spec parsing and `rgb:rrrr/gggg/bbbb` replies for the
//! colour OSCs (4, 10-19, 104, 110-119).

const std = @import("std");
const Allocator = std.mem.Allocator;
const StringTerm = @import("../vt/params.zig").StringTerm;

/// An 8-bit-per-channel colour.
pub const Rgb = [3]u8;

/// The xterm default 256-colour palette.
pub const xterm_256: [256]Rgb = blk: {
    var p: [256]Rgb = undefined;
    const base16 = [16]Rgb{
        .{ 0x00, 0x00, 0x00 }, .{ 0xcd, 0x00, 0x00 }, .{ 0x00, 0xcd, 0x00 }, .{ 0xcd, 0xcd, 0x00 },
        .{ 0x00, 0x00, 0xee }, .{ 0xcd, 0x00, 0xcd }, .{ 0x00, 0xcd, 0xcd }, .{ 0xe5, 0xe5, 0xe5 },
        .{ 0x7f, 0x7f, 0x7f }, .{ 0xff, 0x00, 0x00 }, .{ 0x00, 0xff, 0x00 }, .{ 0xff, 0xff, 0x00 },
        .{ 0x5c, 0x5c, 0xff }, .{ 0xff, 0x00, 0xff }, .{ 0x00, 0xff, 0xff }, .{ 0xff, 0xff, 0xff },
    };
    for (base16, 0..) |c, i| p[i] = c;
    const steps = [6]u8{ 0, 0x5f, 0x87, 0xaf, 0xd7, 0xff };
    for (0..216) |i| p[16 + i] = .{ steps[i / 36], steps[(i / 6) % 6], steps[i % 6] };
    for (0..24) |i| {
        const v: u8 = @intCast(8 + i * 10);
        p[232 + i] = .{ v, v, v };
    }
    break :blk p;
};

/// The special (dynamic) colours, by OSC number.
pub const Special = enum(u8) { fg = 10, bg = 11, cursor = 12, sel_bg = 17, sel_fg = 19 };

/// A palette; `defaults` is restored by the reset OSCs.
pub const Palette = struct {
    ansi: [256]Rgb = xterm_256,
    fg: Rgb = .{ 0xe5, 0xe5, 0xe5 },
    bg: Rgb = .{ 0x00, 0x00, 0x00 },
    cursor: ?Rgb = null,
    sel_fg: ?Rgb = null,
    sel_bg: ?Rgb = null,

    /// The value of a special colour (unset cursor/selection colours report
    /// the foreground/background they render with).
    pub fn special(p: *const Palette, s: Special) Rgb {
        return switch (s) {
            .fg => p.fg,
            .bg => p.bg,
            .cursor => p.cursor orelse p.fg,
            .sel_bg => p.sel_bg orelse p.fg,
            .sel_fg => p.sel_fg orelse p.bg,
        };
    }

    /// Sets a special colour.
    pub fn setSpecial(p: *Palette, s: Special, c: Rgb) void {
        switch (s) {
            .fg => p.fg = c,
            .bg => p.bg = c,
            .cursor => p.cursor = c,
            .sel_bg => p.sel_bg = c,
            .sel_fg => p.sel_fg = c,
        }
    }

    /// Restores a special colour from `d`.
    pub fn resetSpecial(p: *Palette, s: Special, d: *const Palette) void {
        switch (s) {
            .fg => p.fg = d.fg,
            .bg => p.bg = d.bg,
            .cursor => p.cursor = d.cursor,
            .sel_bg => p.sel_bg = d.sel_bg,
            .sel_fg => p.sel_fg = d.sel_fg,
        }
    }
};

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Scales a 1-4 digit hex component to 8 bits (XParseColor).
fn component(s: []const u8) ?u8 {
    if (s.len == 0 or s.len > 4) return null;
    var v: u32 = 0;
    for (s) |c| v = v * 16 + (hexVal(c) orelse return null);
    const max: u32 = (@as(u32, 1) << @intCast(4 * s.len)) - 1;
    return @intCast((v * 255 + max / 2) / max);
}

const names = [_]struct { []const u8, Rgb }{
    .{ "black", .{ 0, 0, 0 } },      .{ "red", .{ 255, 0, 0 } },
    .{ "green", .{ 0, 255, 0 } },    .{ "blue", .{ 0, 0, 255 } },
    .{ "yellow", .{ 255, 255, 0 } }, .{ "magenta", .{ 255, 0, 255 } },
    .{ "cyan", .{ 0, 255, 255 } },   .{ "white", .{ 255, 255, 255 } },
    .{ "gray", .{ 190, 190, 190 } }, .{ "grey", .{ 190, 190, 190 } },
    .{ "orange", .{ 255, 165, 0 } }, .{ "purple", .{ 160, 32, 240 } },
    .{ "brown", .{ 165, 42, 42 } },  .{ "pink", .{ 255, 192, 203 } },
};

/// Parses `rgb:R/G/B` (1-4 hex digits each), `#RGB`, `#RRGGBB`,
/// `#RRRGGGBBB`, `#RRRRGGGGBBBB` and a small set of X11 colour names.
pub fn parseColorSpec(s: []const u8) ?Rgb {
    if (std.mem.startsWith(u8, s, "rgb:")) {
        var it = std.mem.splitScalar(u8, s[4..], '/');
        var out: Rgb = undefined;
        for (&out) |*c| c.* = component(it.next() orelse return null) orelse return null;
        if (it.next() != null) return null;
        return out;
    }
    if (s.len > 1 and s[0] == '#') {
        const h = s[1..];
        if (h.len % 3 != 0 or h.len > 12) return null;
        const n = h.len / 3;
        var out: Rgb = undefined;
        for (&out, 0..) |*c, i| {
            // `#` forms keep the high bits (XParseColor), unlike `rgb:`.
            var v: u32 = 0;
            for (h[i * n ..][0..n]) |d| v = v * 16 + (hexVal(d) orelse return null);
            c.* = @intCast(if (n >= 2) v >> @intCast(4 * (n - 2)) else v * 17);
        }
        return out;
    }
    for (names) |e| if (std.ascii.eqlIgnoreCase(e[0], s)) return e[1];
    return null;
}

/// Appends `OSC <prefix> ; rgb:rrrr/gggg/bbbb <term>`; `prefix` is e.g.
/// "4;12" or "11".
pub fn formatColorReply(out: *std.ArrayList(u8), gpa: Allocator, prefix: []const u8, rgb: Rgb, term: StringTerm) !void {
    try out.print(gpa, "\x1b]{s};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}{s}", .{
        prefix, rgb[0], rgb[0], rgb[1], rgb[1], rgb[2], rgb[2], if (term == .bel) "\x07" else "\x1b\\",
    });
}

test "parseColorSpec" {
    const T = struct { []const u8, ?Rgb };
    const cases = [_]T{
        .{ "rgb:f/0/0", .{ 255, 0, 0 } },
        .{ "rgb:ffff/8000/0000", .{ 255, 128, 0 } },
        .{ "rgb:80/40/20", .{ 0x80, 0x40, 0x20 } },
        .{ "#abc", .{ 0xaa, 0xbb, 0xcc } },
        .{ "#aabbcc", .{ 0xaa, 0xbb, 0xcc } },
        .{ "#aaabbbccc", .{ 0xaa, 0xbb, 0xcc } },
        .{ "#aaaabbbbcccc", .{ 0xaa, 0xbb, 0xcc } },
        .{ "Red", .{ 255, 0, 0 } },
        .{ "rgb:f/0", null },
        .{ "rgb:fffff/0/0", null },
        .{ "#ab", null },
        .{ "#zzz", null },
        .{ "nonsense", null },
    };
    for (cases) |c| {
        const got = parseColorSpec(c[0]);
        if (c[1]) |want| {
            try std.testing.expectEqual(want, got.?);
        } else try std.testing.expect(got == null);
    }
}

test "formatColorReply" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try formatColorReply(&out, std.testing.allocator, "4;1", .{ 0xcd, 0, 0x10 }, .bel);
    try std.testing.expectEqualStrings("\x1b]4;1;rgb:cdcd/0000/1010\x07", out.items);
}

test "palette cube and grays" {
    try std.testing.expectEqual(Rgb{ 0xff, 0xff, 0xff }, xterm_256[231]);
    try std.testing.expectEqual(Rgb{ 0x08, 0x08, 0x08 }, xterm_256[232]);
    try std.testing.expectEqual(Rgb{ 0x5f, 0x87, 0xaf }, xterm_256[16 + 36 + 12 + 3]);
}
