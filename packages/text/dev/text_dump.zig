//! `text-dump`: writes every golden format from zg_text itself so goldens
//! can be produced and reviewed without third-party tools. Output goes to
//! stdout, is deterministic and uses LF line endings.
//!
//!   text-dump metrics <font> [--index N]
//!   text-dump outline <font> <gid|U+XXXX|all>... [--coords wght=700,...]
//!   text-dump shape   <font> <text> [--features ...] [--dir rtl] [--script arab]
//!   text-dump raster  <font> <gid> <px> [--mode gray|lcd_rgb|sdf]
//!
//! Subcommands whose engine is not merged yet print "not implemented" and
//! exit with status 2.

const std = @import("std");
const zg_text = @import("zg_text");
const ot = zg_text.ot;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const out = &fw.interface;
    defer out.flush() catch {};
    if (args.len < 3) return usage();
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "metrics")) {
        var index: u32 = 0;
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--index") and i + 1 < args.len) {
                i += 1;
                index = try std.fmt.parseInt(u32, args[i], 10);
            } else return usage();
        }
        var font = try ot.MappedFont.openAlloc(io, std.Io.Dir.cwd(), args[2], gpa);
        defer font.close(io);
        const face = ot.Face.init(font.bytes(), index) catch |e| {
            std.debug.print("text-dump: cannot open face: {t}\n", .{e});
            return 1;
        };
        try dumpMetrics(out, &face);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "outline")) {
        var font = try ot.MappedFont.openAlloc(io, std.Io.Dir.cwd(), args[2], gpa);
        defer font.close(io);
        const face = ot.Face.init(font.bytes(), 0) catch |e| {
            std.debug.print("text-dump: cannot open face: {t}\n", .{e});
            return 1;
        };
        return dumpOutlines(out, gpa, &face, args[3..]);
    }
    if (std.mem.eql(u8, cmd, "shape") or std.mem.eql(u8, cmd, "raster")) {
        std.debug.print("text-dump {s}: not implemented\n", .{cmd});
        return 2;
    }
    return usage();
}

fn usage() u8 {
    std.debug.print(
        \\usage: text-dump metrics <font> [--index N]
        \\       text-dump outline <font> <gid|U+XXXX|all>... [--coords wght=700,...]
        \\       text-dump shape   <font> <text> [--features "liga=0,ss01"] [--dir rtl] [--script arab]
        \\       text-dump raster  <font> <gid> <px> [--mode gray|lcd_rgb|sdf]
        \\
    , .{});
    return 2;
}

/// Writes "<gid> <path>" per requested glyph, in the `Path.format`
/// grammar of the outline goldens. "all" means every glyph.
fn dumpOutlines(w: *std.Io.Writer, gpa: std.mem.Allocator, face: *const ot.Face, specs: []const []const u8) !u8 {
    if (specs.len == 0) return usage();
    const g = face.glyf() orelse {
        std.debug.print("text-dump outline: {t} outlines: not implemented\n", .{face.outline_kind});
        return 2;
    };
    var scratch: ot.glyf.Scratch = .{};
    var path: zg_text.outline.Path = .{};
    for (specs) |spec| {
        if (std.mem.startsWith(u8, spec, "--")) {
            std.debug.print("text-dump outline: {s}: not implemented\n", .{spec});
            return 2;
        }
        var lo: u32 = undefined;
        var hi: u32 = undefined;
        if (std.mem.eql(u8, spec, "all")) {
            lo = 0;
            hi = face.num_glyphs;
        } else {
            lo = if (std.mem.startsWith(u8, spec, "U+"))
                face.glyphIndex(try std.fmt.parseInt(u21, spec[2..], 16))
            else
                try std.fmt.parseInt(u16, spec, 10);
            hi = lo + 1;
        }
        for (lo..hi) |gid| {
            path.reset();
            try w.print("{d} ", .{gid});
            if (g.outline(gpa, @intCast(gid), &scratch, null, &path)) |_| {
                try path.format(w);
            } else |e| try w.print("error.{t}", .{e});
            try w.writeByte('\n');
        }
    }
    return 0;
}

/// Writes `.{ .metrics = FontMetrics, .style = Style, ... }` as ZON.
pub fn dumpMetrics(w: *std.Io.Writer, face: *const ot.Face) !void {
    var nb: [256]u8 = undefined;
    try w.writeAll(".{\n");
    try w.print("    .family = \"{f}\",\n", .{std.zig.fmtString(face.names().get(.family, &nb) orelse "")});
    try w.print("    .subfamily = \"{f}\",\n", .{std.zig.fmtString(face.names().get(.subfamily, &nb) orelse "")});
    try w.print("    .num_glyphs = {d},\n", .{face.num_glyphs});
    try w.print("    .outline = .{t},\n", .{face.outline_kind});
    try w.print("    .metrics = ", .{});
    try writeStruct(w, face.metrics());
    try w.print(",\n    .style = ", .{});
    try writeStruct(w, face.style());
    try w.writeAll(",\n}\n");
}

fn writeStruct(w: *std.Io.Writer, v: anytype) !void {
    try w.writeAll(".{ ");
    inline for (@typeInfo(@TypeOf(v)).@"struct".fields, 0..) |f, i| {
        if (i != 0) try w.writeAll(", ");
        try w.print(".{s} = {any}", .{ f.name, @field(v, f.name) });
    }
    try w.writeAll(" }");
}
