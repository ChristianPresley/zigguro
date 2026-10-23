//! SVG export (E13.F07.S01.T02): a display list as a standalone SVG
//! document. Fills become `<path d>`, strokes keep their original path
//! with native `stroke` attributes, text becomes `<text>`, clips become
//! `<clipPath>` groups. Numbers are written with at most 3 decimals and
//! the output is deterministic.

const std = @import("std");
const path_mod = @import("path.zig");
const dl_mod = @import("display_list.zig");
const stroke_mod = @import("stroke.zig");

const Writer = std.Io.Writer;
const Path = path_mod.Path;
const Rect = path_mod.Rect;
const Color = dl_mod.Color;
const DisplayList = dl_mod.DisplayList;

pub const SvgOpts = struct {
    /// The viewBox; default: the display list's bounds.
    view: ?Rect = null,
    /// Width and height attributes; default: the viewBox's size.
    size: ?[2]f32 = null,
    font_family: []const u8 = "sans-serif",
    background: ?Color = null,
};

pub fn writeSvg(w: *Writer, dl: *const DisplayList, opts: SvgOpts) Writer.Error!void {
    const view = opts.view orelse if (dl.bounds.isEmpty()) Rect{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 } else dl.bounds;
    const size = opts.size orelse [2]f32{ view.width(), view.height() };
    try w.writeAll("<svg xmlns=\"http://www.w3.org/2000/svg\"");
    try w.print(" width=\"{f}\" height=\"{f}\" viewBox=\"{f} {f} {f} {f}\"", .{ num(size[0]), num(size[1]), num(view.x0), num(view.y0), num(view.width()), num(view.height()) });
    try w.writeAll(" font-family=\"");
    try escape(w, opts.font_family);
    try w.writeAll("\">\n");
    if (opts.background) |bg| {
        try w.print("<rect x=\"{f}\" y=\"{f}\" width=\"{f}\" height=\"{f}\"", .{ num(view.x0), num(view.y0), num(view.width()), num(view.height()) });
        try paint(w, "fill", bg);
        try w.writeAll("/>\n");
    }
    var clip_id: u32 = 0;
    var depth: u32 = 0;
    for (dl.items) |it| switch (it) {
        .fill => |f| {
            try w.writeAll("<path d=\"");
            try pathData(w, f.path);
            try w.writeByte('"');
            try paint(w, "fill", f.color);
            try w.writeAll("/>\n");
        },
        .stroke => |s| {
            try w.writeAll("<path d=\"");
            try pathData(w, s.path);
            try w.writeAll("\" fill=\"none\"");
            try paint(w, "stroke", s.color);
            try w.print(" stroke-width=\"{f}\"", .{num(s.style.width)});
            if (s.style.join != .miter) try w.print(" stroke-linejoin=\"{t}\"", .{s.style.join});
            if (s.style.join == .miter and s.style.miter_limit != 4) try w.print(" stroke-miterlimit=\"{f}\"", .{num(s.style.miter_limit)});
            if (s.style.cap != .butt) try w.print(" stroke-linecap=\"{t}\"", .{s.style.cap});
            if (s.style.dash.len > 0) {
                try w.writeAll(" stroke-dasharray=\"");
                for (s.style.dash, 0..) |d, i| try w.print("{s}{f}", .{ if (i > 0) " " else "", num(d) });
                try w.writeByte('"');
                if (s.style.dash_offset != 0) try w.print(" stroke-dashoffset=\"{f}\"", .{num(s.style.dash_offset)});
            }
            try w.writeAll("/>\n");
        },
        .text => |t| {
            try w.print("<text x=\"{f}\" y=\"{f}\" font-size=\"{f}\"", .{ num(t.x), num(t.y), num(t.size) });
            try paint(w, "fill", t.color);
            if (t.anchor != .start) try w.print(" text-anchor=\"{t}\"", .{t.anchor});
            switch (t.baseline) {
                .alphabetic => {},
                .middle => try w.writeAll(" dominant-baseline=\"middle\""),
                .top => try w.writeAll(" dominant-baseline=\"hanging\""),
                .bottom => try w.writeAll(" dominant-baseline=\"text-after-edge\""),
            }
            if (t.bold) try w.writeAll(" font-weight=\"bold\"");
            if (t.family) |fam| {
                try w.writeAll(" font-family=\"");
                try escape(w, fam);
                try w.writeByte('"');
            }
            if (t.rotate == .ccw90) try w.print(" transform=\"rotate(-90 {f} {f})\"", .{ num(t.x), num(t.y) });
            try w.writeByte('>');
            try escape(w, t.text);
            try w.writeAll("</text>\n");
        },
        .clip_push => |r| {
            clip_id += 1;
            depth += 1;
            try w.print("<clipPath id=\"c{d}\"><rect x=\"{f}\" y=\"{f}\" width=\"{f}\" height=\"{f}\"/></clipPath>\n<g clip-path=\"url(#c{d})\">\n", .{ clip_id, num(r.x0), num(r.y0), num(r.width()), num(r.height()), clip_id });
        },
        .clip_pop => if (depth > 0) {
            depth -= 1;
            try w.writeAll("</g>\n");
        },
    };
    while (depth > 0) : (depth -= 1) try w.writeAll("</g>\n");
    try w.writeAll("</svg>\n");
}

fn paint(w: *Writer, attr: []const u8, c: Color) Writer.Error!void {
    try w.print(" {s}=\"#{x:0>2}{x:0>2}{x:0>2}\"", .{ attr, c.r, c.g, c.b });
    if (c.a != 255) try w.print(" {s}-opacity=\"{f}\"", .{ attr, num(@as(f32, @floatFromInt(c.a)) / 255) });
}

pub fn pathData(w: *Writer, p: *const Path) Writer.Error!void {
    var i: usize = 0;
    var first = true;
    for (p.verbs.items) |v| {
        if (!first) try w.writeByte(' ');
        first = false;
        const pts = p.points.items;
        switch (v) {
            .move => try w.print("M{f} {f}", .{ num(pts[i][0]), num(pts[i][1]) }),
            .line => try w.print("L{f} {f}", .{ num(pts[i][0]), num(pts[i][1]) }),
            .quad => try w.print("Q{f} {f} {f} {f}", .{ num(pts[i][0]), num(pts[i][1]), num(pts[i + 1][0]), num(pts[i + 1][1]) }),
            .cubic => try w.print("C{f} {f} {f} {f} {f} {f}", .{ num(pts[i][0]), num(pts[i][1]), num(pts[i + 1][0]), num(pts[i + 1][1]), num(pts[i + 2][0]), num(pts[i + 2][1]) }),
            .close => try w.writeByte('Z'),
        }
        i += Path.pointCount(v);
    }
}

/// XML text and attribute escaping.
pub fn escape(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |ch| switch (ch) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&apos;"),
        // Control characters are not allowed in XML 1.0.
        0...8, 11, 12, 14...31 => {},
        else => try w.writeByte(ch),
    };
}

/// A number with at most 3 decimals, trailing zeros dropped.
pub fn num(x: f32) Num {
    return .{ .x = x };
}

pub const Num = struct {
    x: f32,

    pub fn format(n: Num, w: *Writer) Writer.Error!void {
        if (!std.math.isFinite(n.x)) return w.writeByte('0');
        const scaled = @round(@as(f64, n.x) * 1000);
        if (scaled == 0) return w.writeByte('0');
        const neg = scaled < 0;
        const v: u64 = @intFromFloat(@abs(scaled));
        if (neg) try w.writeByte('-');
        try w.print("{d}", .{v / 1000});
        var frac = v % 1000;
        if (frac == 0) return;
        var digits: u8 = 3;
        while (frac % 10 == 0) {
            frac /= 10;
            digits -= 1;
        }
        try w.writeByte('.');
        switch (digits) {
            1 => try w.print("{d}", .{frac}),
            2 => try w.print("{d:0>2}", .{frac}),
            else => try w.print("{d:0>3}", .{frac}),
        }
    }
};
