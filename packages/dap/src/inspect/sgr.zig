//! A minimal, stateless SGR reader for the debug console (E07.F07.S01.T02):
//! program output with `CSI … m` styling becomes plain text plus styled
//! spans. 16, 256 and truecolor foregrounds and backgrounds (semicolon
//! and colon forms), bold, faint, italic, underline, inverse and resets
//! are read; every other escape sequence (cursor moves, OSC titles and
//! links, charset selection) and C0 controls but tab are dropped.
//!
//! The style at a line's end carries into the next line (`parse` takes
//! and returns it), as a terminal would.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Color = union(enum) {
    default,
    /// 0–7 normal, 8–15 bright, 16–255 the xterm cube and greys.
    palette: u8,
    rgb: [3]u8,

    /// The colour as RGB (the xterm palette for indexes).
    pub fn toRgb(c: Color) ?[3]u8 {
        return switch (c) {
            .default => null,
            .rgb => |v| v,
            .palette => |i| paletteRgb(i),
        };
    }
};

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    faint: bool = false,
    italic: bool = false,
    underline: bool = false,
    inverse: bool = false,

    pub fn isPlain(s: Style) bool {
        return std.meta.eql(s, Style{});
    }
};

/// Bytes `[start, end)` of the plain text, in `style`.
pub const Span = struct { start: u32, end: u32, style: Style };

/// Appends `text` without escapes to `out` and its styled runs to
/// `spans` (plain runs are not listed), starting in `style`; returns the
/// style at the end.
pub fn parse(gpa: Allocator, text: []const u8, style: Style, out: *std.ArrayList(u8), spans: *std.ArrayList(Span)) Allocator.Error!Style {
    var st = style;
    var run_start: u32 = @intCast(out.items.len);
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == 0x1b) {
            const seq = escapeEnd(text, i);
            if (seq.sgr) |params| {
                const next = apply(st, params);
                if (!std.meta.eql(next, st)) {
                    try closeRun(gpa, spans, run_start, @intCast(out.items.len), st);
                    run_start = @intCast(out.items.len);
                    st = next;
                }
            }
            i = seq.end;
            continue;
        }
        if (c < 0x20 and c != '\t' and c != '\n') {
            i += 1;
            continue;
        }
        if (c == 0x7f) {
            i += 1;
            continue;
        }
        try out.append(gpa, c);
        i += 1;
    }
    try closeRun(gpa, spans, run_start, @intCast(out.items.len), st);
    return st;
}

fn closeRun(gpa: Allocator, spans: *std.ArrayList(Span), start: u32, end: u32, st: Style) Allocator.Error!void {
    if (end <= start or st.isPlain()) return;
    // Merge with an adjacent run of the same style.
    if (spans.items.len > 0) {
        const last = &spans.items[spans.items.len - 1];
        if (last.end == start and std.meta.eql(last.style, st)) {
            last.end = end;
            return;
        }
    }
    try spans.append(gpa, .{ .start = start, .end = end, .style = st });
}

const Seq = struct { end: usize, sgr: ?[]const u8 = null };

/// Where the escape sequence at `i` ends; its parameters when it is SGR.
fn escapeEnd(text: []const u8, i: usize) Seq {
    if (i + 1 >= text.len) return .{ .end = text.len };
    switch (text[i + 1]) {
        '[' => {
            var j = i + 2;
            while (j < text.len and !(text[j] >= 0x40 and text[j] <= 0x7e)) : (j += 1) {}
            if (j >= text.len) return .{ .end = text.len };
            return .{ .end = j + 1, .sgr = if (text[j] == 'm') text[i + 2 .. j] else null };
        },
        // OSC, DCS, SOS, PM, APC: up to BEL or ST.
        ']', 'P', 'X', '^', '_' => {
            var j = i + 2;
            while (j < text.len) : (j += 1) {
                if (text[j] == 0x07) return .{ .end = j + 1 };
                if (text[j] == 0x1b and j + 1 < text.len and text[j + 1] == '\\') return .{ .end = j + 2 };
            }
            return .{ .end = text.len };
        },
        // Charset selection and the like take one more byte.
        '(', ')', '*', '+', '#', '%' => return .{ .end = @min(text.len, i + 3) },
        else => return .{ .end = i + 2 },
    }
}

/// `st` after the SGR parameters `params` ("1;31", "38:2::1:2:3", "").
fn apply(st: Style, params: []const u8) Style {
    var s = st;
    // Private forms (`CSI ? … m`, `CSI > … m`) are not SGR.
    if (params.len > 0 and (params[0] == '?' or params[0] == '>' or params[0] == '<' or params[0] == '=')) return s;
    var vals: [32]?u16 = undefined;
    var subs: [32]bool = undefined;
    var n: usize = 0;
    var it_start: usize = 0;
    var k: usize = 0;
    var sub = false;
    while (k <= params.len) : (k += 1) {
        if (k == params.len or params[k] == ';' or params[k] == ':') {
            if (n < vals.len) {
                const field = params[it_start..k];
                vals[n] = if (field.len == 0) null else std.fmt.parseInt(u16, field, 10) catch null;
                subs[n] = sub;
                n += 1;
            }
            sub = k < params.len and params[k] == ':';
            it_start = k + 1;
        }
    }
    if (n == 0) return .{};
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const v = vals[i] orelse 0;
        switch (v) {
            0 => s = .{},
            1 => s.bold = true,
            2 => s.faint = true,
            3 => s.italic = true,
            4 => s.underline = !(i + 1 < n and subs[i + 1] and (vals[i + 1] orelse 0) == 0),
            7 => s.inverse = true,
            21 => s.underline = true,
            22 => {
                s.bold = false;
                s.faint = false;
            },
            23 => s.italic = false,
            24 => s.underline = false,
            27 => s.inverse = false,
            30...37 => s.fg = .{ .palette = @intCast(v - 30) },
            39 => s.fg = .default,
            40...47 => s.bg = .{ .palette = @intCast(v - 40) },
            49 => s.bg = .default,
            90...97 => s.fg = .{ .palette = @intCast(v - 90 + 8) },
            100...107 => s.bg = .{ .palette = @intCast(v - 100 + 8) },
            38, 48 => {
                const ext = extended(vals[0..n], subs[0..n], i);
                if (ext.color) |c| {
                    if (v == 38) s.fg = c else s.bg = c;
                }
                i += ext.used;
            },
            58 => i += extended(vals[0..n], subs[0..n], i).used,
            else => {},
        }
        // Sub-parameters of an attribute not read above.
        while (i + 1 < n and subs[i + 1] and v != 38 and v != 48 and v != 58) i += 1;
    }
    return s;
}

/// An extended colour after `38`/`48` at `i`: the colour and how many
/// more parameters it took.
fn extended(vals: []const ?u16, subs: []const bool, i: usize) struct { color: ?Color, used: usize } {
    if (i + 1 >= vals.len) return .{ .color = null, .used = 0 };
    const kind = vals[i + 1] orelse 0;
    const colon = subs[i + 1];
    switch (kind) {
        5 => {
            if (i + 2 >= vals.len) return .{ .color = null, .used = 1 };
            return .{ .color = .{ .palette = @intCast(@min(vals[i + 2] orelse 0, 255)) }, .used = 2 };
        },
        2 => {
            // `38:2:cs:r:g:b` (colour space, maybe empty) or `38;2;r;g;b`.
            var count: usize = 0;
            if (colon) {
                while (i + 2 + count < vals.len and subs[i + 2 + count]) count += 1;
            } else count = @min(3, vals.len - (i + 2));
            const off: usize = if (colon and count >= 4) 1 else 0;
            if (count < off + 3) return .{ .color = null, .used = 1 + count };
            const r = vals[i + 2 + off] orelse 0;
            const g = vals[i + 3 + off] orelse 0;
            const b = vals[i + 4 + off] orelse 0;
            return .{ .color = .{ .rgb = .{ @intCast(@min(r, 255)), @intCast(@min(g, 255)), @intCast(@min(b, 255)) } }, .used = 1 + count };
        },
        else => return .{ .color = null, .used = 1 },
    }
}

/// The xterm palette.
pub fn paletteRgb(i: u8) [3]u8 {
    const base = [16][3]u8{
        .{ 0, 0, 0 },       .{ 205, 0, 0 },   .{ 0, 205, 0 },   .{ 205, 205, 0 },
        .{ 0, 0, 238 },     .{ 205, 0, 205 }, .{ 0, 205, 205 }, .{ 229, 229, 229 },
        .{ 127, 127, 127 }, .{ 255, 0, 0 },   .{ 0, 255, 0 },   .{ 255, 255, 0 },
        .{ 92, 92, 255 },   .{ 255, 0, 255 }, .{ 0, 255, 255 }, .{ 255, 255, 255 },
    };
    if (i < 16) return base[i];
    if (i < 232) {
        const n = i - 16;
        const steps = [6]u8{ 0, 95, 135, 175, 215, 255 };
        return .{ steps[n / 36], steps[(n / 6) % 6], steps[n % 6] };
    }
    const g: u8 = 8 + (i - 232) * 10;
    return .{ g, g, g };
}

test "sgr: 16, 256 and truecolor, attributes and reset" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(gpa);
    const end = try parse(gpa, "a\x1b[1;31mred\x1b[0m b \x1b[38;5;196mx\x1b[38:2::10:20:30my\x1b[48;2;1;2;3mz\x1b[m.", .{}, &out, &spans);
    try testing.expectEqualStrings("ared b xyz.", out.items);
    try testing.expect(end.isPlain());
    try testing.expectEqual(@as(usize, 4), spans.items.len);
    try testing.expectEqual(@as(u32, 1), spans.items[0].start);
    try testing.expectEqual(@as(u32, 4), spans.items[0].end);
    try testing.expect(spans.items[0].style.bold);
    try testing.expectEqual(Color{ .palette = 1 }, spans.items[0].style.fg);
    try testing.expectEqual(Color{ .palette = 196 }, spans.items[1].style.fg);
    try testing.expectEqual(Color{ .rgb = .{ 10, 20, 30 } }, spans.items[2].style.fg);
    try testing.expectEqual(Color{ .rgb = .{ 1, 2, 3 } }, spans.items[3].style.bg);
    try testing.expectEqual(Color{ .rgb = .{ 10, 20, 30 } }, spans.items[3].style.fg);
}

test "sgr: other escapes and controls are stripped; the style carries over" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(gpa);
    const end = try parse(gpa, "\x1b]0;title\x07\x1b[2K\x1b(Bok\r\x08\t\x1b]8;;http://x\x1b\\link\x1b]8;;\x1b\\\x1b[32mgo", .{}, &out, &spans);
    try testing.expectEqualStrings("ok\tlinkgo", out.items);
    try testing.expectEqual(Color{ .palette = 2 }, end.fg);
    // The next line starts green.
    out.clearRetainingCapacity();
    spans.clearRetainingCapacity();
    _ = try parse(gpa, "more\x1b[39m!", end, &out, &spans);
    try testing.expectEqual(@as(usize, 1), spans.items.len);
    try testing.expectEqual(@as(u32, 4), spans.items[0].end);
    // A sequence cut off at the end is dropped.
    out.clearRetainingCapacity();
    _ = try parse(gpa, "x\x1b[3", .{}, &out, &spans);
    try testing.expectEqualStrings("x", out.items);
    try testing.expectEqual([3]u8{ 255, 0, 0 }, paletteRgb(196));
    try testing.expectEqual([3]u8{ 238, 238, 238 }, paletteRgb(255));
}
