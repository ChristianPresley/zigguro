//! The paint contract between zg_gui and a renderer.
//!
//! `Canvas` mirrors E02's `r2d.DrawList` builder method for method (same
//! names, argument order and value types), so the production adapter is a
//! thin forwarder; see "zg_gui.paint.Canvas" in docs/interfaces.md.
//! Coordinates are logical pixels; `begin` passes the window scale.
//!
//! `OpList` is the retained per-window prim cache: widgets paint into it in
//! node-local coordinates, and clean nodes are replayed from it by range.

const std = @import("std");
const zg_text = @import("zg_text");
const geom = @import("../core/geom.zig");

const Rect = geom.Rect;
const Vec2 = geom.Vec2;
const Color = geom.Color;
const Radii = geom.Radii;
const Insets = geom.Insets;
const Size = geom.Size;

/// One positioned glyph bitmap from E03's glyph atlas.
pub const GlyphQuad = zg_text.cache.GlyphQuad;

/// Text antialiasing mode (matches `r2d.TextAa`).
pub const TextAa = enum(u2) { grayscale, subpixel_rgb, subpixel_bgr, none };

/// A renderer texture (matches `r2d.TextureId`).
pub const TextureId = enum(u32) { none = 0, _ };

/// A renderer that accepts one frame of prims at a time.
pub const Canvas = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// The operations; `begin`/`end` bracket every frame.
    pub const VTable = struct {
        begin: *const fn (*anyopaque, size: Size, scale: f32) void,
        rect: *const fn (*anyopaque, r: Rect, fill: Color, radii: Radii) void,
        border: *const fn (*anyopaque, r: Rect, widths: Insets, color: Color, radii: Radii) void,
        shadow: *const fn (*anyopaque, r: Rect, radii: Radii, sigma: f32, spread: f32, color: Color) void,
        linearGradient: *const fn (*anyopaque, r: Rect, p0: Vec2, p1: Vec2, c0: Color, c1: Color, radii: Radii) void,
        glyphs: *const fn (*anyopaque, run: []const GlyphQuad, color: Color, aa: TextAa) void,
        image: *const fn (*anyopaque, tex: TextureId, dst: Rect, uv: Rect, tint: Color, radii: Radii) void,
        pushClip: *const fn (*anyopaque, r: Rect, radii: Radii) void,
        popClip: *const fn (*anyopaque) void,
        addDamage: *const fn (*anyopaque, r: Rect) void,
        end: *const fn (*anyopaque) void,
    };

    /// Starts a frame of `size` logical pixels at `scale` physical/logical.
    pub fn begin(c: Canvas, size: Size, scale: f32) void {
        c.vtable.begin(c.ptr, size, scale);
    }
    /// A filled rounded rectangle.
    pub fn rect(c: Canvas, r: Rect, fill: Color, radii: Radii) void {
        c.vtable.rect(c.ptr, r, fill, radii);
    }
    /// A rounded rectangle outline with per-edge widths.
    pub fn border(c: Canvas, r: Rect, widths: Insets, color: Color, radii: Radii) void {
        c.vtable.border(c.ptr, r, widths, color, radii);
    }
    /// A blurred drop shadow of a rounded rectangle.
    pub fn shadow(c: Canvas, r: Rect, radii: Radii, sigma: f32, spread: f32, color: Color) void {
        c.vtable.shadow(c.ptr, r, radii, sigma, spread, color);
    }
    /// A linear gradient from `p0` (`c0`) to `p1` (`c1`).
    pub fn linearGradient(c: Canvas, r: Rect, p0: Vec2, p1: Vec2, c0: Color, c1: Color, radii: Radii) void {
        c.vtable.linearGradient(c.ptr, r, p0, p1, c0, c1, radii);
    }
    /// A run of glyph quads in one colour.
    pub fn glyphs(c: Canvas, run: []const GlyphQuad, color: Color, aa: TextAa) void {
        c.vtable.glyphs(c.ptr, run, color, aa);
    }
    /// A textured rectangle.
    pub fn image(c: Canvas, tex: TextureId, dst: Rect, uv: Rect, tint: Color, radii: Radii) void {
        c.vtable.image(c.ptr, tex, dst, uv, tint, radii);
    }
    /// Intersects the clip with `r` until the matching `popClip`.
    pub fn pushClip(c: Canvas, r: Rect, radii: Radii) void {
        c.vtable.pushClip(c.ptr, r, radii);
    }
    /// Restores the clip of the matching `pushClip`.
    pub fn popClip(c: Canvas) void {
        c.vtable.popClip(c.ptr);
    }
    /// Marks `r` as changed since the previous frame.
    pub fn addDamage(c: Canvas, r: Rect) void {
        c.vtable.addDamage(c.ptr, r);
    }
    /// Ends the frame; the renderer may present it.
    pub fn end(c: Canvas) void {
        c.vtable.end(c.ptr);
    }
};

/// One recorded paint operation (glyph runs index `OpList.quads`).
pub const Op = union(enum) {
    rect: struct { r: Rect, fill: Color, radii: Radii },
    border: struct { r: Rect, widths: Insets, color: Color, radii: Radii },
    shadow: struct { r: Rect, radii: Radii, sigma: f32, spread: f32, color: Color },
    gradient: struct { r: Rect, p0: Vec2, p1: Vec2, c0: Color, c1: Color, radii: Radii },
    glyphs: struct { start: u32, len: u32, color: Color, aa: TextAa },
    image: struct { tex: TextureId, dst: Rect, uv: Rect, tint: Color, radii: Radii },
    /// Clips the node's following ops to `r` until `pop_clip`.
    push_clip: struct { r: Rect, radii: Radii },
    pop_clip,
};

/// A half-open range of ops (and the glyph quads they reference).
pub const Range = struct {
    op_start: u32 = 0,
    op_end: u32 = 0,
    quad_start: u32 = 0,
    quad_end: u32 = 0,

    /// True when the range holds no ops.
    pub fn isEmpty(r: Range) bool {
        return r.op_start == r.op_end;
    }
};

/// A growable list of ops in node-local coordinates. Capacity is kept
/// across `clearRetainingCapacity`, so steady-state frames do not allocate.
pub const OpList = struct {
    ops: std.ArrayList(Op) = .empty,
    quads: std.ArrayList(GlyphQuad) = .empty,

    /// Frees the lists.
    pub fn deinit(l: *OpList, gpa: std.mem.Allocator) void {
        l.ops.deinit(gpa);
        l.quads.deinit(gpa);
    }

    /// Empties the lists, keeping capacity.
    pub fn clearRetainingCapacity(l: *OpList) void {
        l.ops.clearRetainingCapacity();
        l.quads.clearRetainingCapacity();
    }

    /// The current end, for starting a range.
    pub fn mark(l: *const OpList) Range {
        const o: u32 = @intCast(l.ops.items.len);
        const q: u32 = @intCast(l.quads.items.len);
        return .{ .op_start = o, .op_end = o, .quad_start = q, .quad_end = q };
    }

    /// Closes a range started with `mark`.
    pub fn close(l: *const OpList, r: Range) Range {
        var out = r;
        out.op_end = @intCast(l.ops.items.len);
        out.quad_end = @intCast(l.quads.items.len);
        return out;
    }

    /// Copies `r` of `src` to the end of `l`, rebasing glyph indices, and
    /// returns the new range.
    pub fn copyRange(l: *OpList, gpa: std.mem.Allocator, src: *const OpList, r: Range) !Range {
        const start = l.mark();
        try l.ops.appendSlice(gpa, src.ops.items[r.op_start..r.op_end]);
        try l.quads.appendSlice(gpa, src.quads.items[r.quad_start..r.quad_end]);
        const delta: i64 = @as(i64, start.quad_start) - @as(i64, r.quad_start);
        if (delta != 0) {
            for (l.ops.items[start.op_start..]) |*op| switch (op.*) {
                .glyphs => |*g| g.start = @intCast(@as(i64, g.start) + delta),
                else => {},
            };
        }
        return l.close(start);
    }

    /// Replays `r` into `c`, translated by `offset`.
    pub fn replay(l: *const OpList, r: Range, offset: Vec2, c: Canvas, scratch: *std.ArrayList(GlyphQuad), gpa: std.mem.Allocator) void {
        for (l.ops.items[r.op_start..r.op_end]) |op| switch (op) {
            .rect => |x| c.rect(x.r.translate(offset), x.fill, x.radii),
            .border => |x| c.border(x.r.translate(offset), x.widths, x.color, x.radii),
            .shadow => |x| c.shadow(x.r.translate(offset), x.radii, x.sigma, x.spread, x.color),
            .gradient => |x| c.linearGradient(x.r.translate(offset), x.p0.add(offset), x.p1.add(offset), x.c0, x.c1, x.radii),
            .image => |x| c.image(x.tex, x.dst.translate(offset), x.uv, x.tint, x.radii),
            .push_clip => |x| c.pushClip(x.r.translate(offset), x.radii),
            .pop_clip => c.popClip(),
            .glyphs => |x| {
                const src = l.quads.items[x.start..][0..x.len];
                if (offset.x == 0 and offset.y == 0) {
                    c.glyphs(src, x.color, x.aa);
                } else {
                    scratch.clearRetainingCapacity();
                    scratch.appendSlice(gpa, src) catch {
                        // Out of memory: draw untranslated rather than not at all.
                        c.glyphs(src, x.color, x.aa);
                        continue;
                    };
                    for (scratch.items) |*q| {
                        q.dst[0] += offset.x;
                        q.dst[1] += offset.y;
                    }
                    c.glyphs(scratch.items, x.color, x.aa);
                }
            },
        };
    }
};

/// A `Canvas` that records every call as text, for snapshot tests and
/// debugging. Coordinates are printed rounded to 0.01.
pub const Recorder = struct {
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    frames: u32 = 0,
    damage: std.ArrayList(Rect) = .empty,
    failed: bool = false,

    /// A recorder backed by `gpa`.
    pub fn init(gpa: std.mem.Allocator) Recorder {
        return .{ .gpa = gpa };
    }

    /// Frees the recording.
    pub fn deinit(r: *Recorder) void {
        r.out.deinit(r.gpa);
        r.damage.deinit(r.gpa);
    }

    /// The canvas interface.
    pub fn canvas(r: *Recorder) Canvas {
        return .{ .ptr = r, .vtable = &vtable };
    }

    /// The text of the last frame.
    pub fn text(r: *const Recorder) []const u8 {
        return r.out.items;
    }

    const vtable: Canvas.VTable = .{
        .begin = begin,
        .rect = rect,
        .border = border,
        .shadow = shadow,
        .linearGradient = linearGradient,
        .glyphs = glyphs,
        .image = image,
        .pushClip = pushClip,
        .popClip = popClip,
        .addDamage = addDamage,
        .end = end,
    };

    fn self(p: *anyopaque) *Recorder {
        return @ptrCast(@alignCast(p));
    }

    fn print(r: *Recorder, comptime fmt: []const u8, args: anytype) void {
        r.out.print(r.gpa, fmt ++ "\n", args) catch {
            r.failed = true;
        };
    }

    fn begin(p: *anyopaque, size: Size, scale: f32) void {
        const r = self(p);
        r.out.clearRetainingCapacity();
        r.damage.clearRetainingCapacity();
        r.frames += 1;
        r.print("begin {d}x{d} @{d}", .{ size.w, size.h, scale });
    }
    fn rect(p: *anyopaque, rc: Rect, fill: Color, radii: Radii) void {
        self(p).print("rect {f} #{x:0>8} r{d}", .{ fmtRect(rc), hexOf(fill), radii.tl });
    }
    fn border(p: *anyopaque, rc: Rect, w: Insets, color: Color, radii: Radii) void {
        self(p).print("border {f} w{d} #{x:0>8} r{d}", .{ fmtRect(rc), w.l, hexOf(color), radii.tl });
    }
    fn shadow(p: *anyopaque, rc: Rect, radii: Radii, sigma: f32, spread: f32, color: Color) void {
        self(p).print("shadow {f} r{d} s{d} sp{d} #{x:0>8}", .{ fmtRect(rc), radii.tl, sigma, spread, hexOf(color) });
    }
    fn linearGradient(p: *anyopaque, rc: Rect, p0: Vec2, p1: Vec2, c0: Color, c1: Color, radii: Radii) void {
        _ = p0;
        _ = p1;
        self(p).print("gradient {f} #{x:0>8}..#{x:0>8} r{d}", .{ fmtRect(rc), hexOf(c0), hexOf(c1), radii.tl });
    }
    fn glyphs(p: *anyopaque, run: []const GlyphQuad, color: Color, aa: TextAa) void {
        _ = aa;
        var b: Rect = .empty;
        for (run) |q| b = b.unite(.{ .x = q.dst[0], .y = q.dst[1], .w = q.dst[2], .h = q.dst[3] });
        self(p).print("glyphs {d} {f} #{x:0>8}", .{ run.len, fmtRect(b), hexOf(color) });
    }
    fn image(p: *anyopaque, tex: TextureId, dst: Rect, uv: Rect, tint: Color, radii: Radii) void {
        _ = uv;
        _ = radii;
        self(p).print("image {d} {f} #{x:0>8}", .{ @intFromEnum(tex), fmtRect(dst), hexOf(tint) });
    }
    fn pushClip(p: *anyopaque, rc: Rect, radii: Radii) void {
        self(p).print("clip {f} r{d}", .{ fmtRect(rc), radii.tl });
    }
    fn popClip(p: *anyopaque) void {
        self(p).print("unclip", .{});
    }
    fn addDamage(p: *anyopaque, rc: Rect) void {
        const r = self(p);
        r.damage.append(r.gpa, rc) catch {
            r.failed = true;
        };
        r.print("damage {f}", .{fmtRect(rc)});
    }
    fn end(p: *anyopaque) void {
        self(p).print("end", .{});
    }
};

fn hexOf(c: Color) u32 {
    return (@as(u32, c.r) << 24) | (@as(u32, c.g) << 16) | (@as(u32, c.b) << 8) | c.a;
}

/// Formats a rectangle as `x,y wxh` with at most two decimals.
pub fn fmtRect(r: Rect) RectFmt {
    return .{ .r = r };
}

/// See `fmtRect`.
pub const RectFmt = struct {
    r: Rect,

    /// `std.fmt` hook.
    pub fn format(f: RectFmt, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d},{d} {d}x{d}", .{ round2(f.r.x), round2(f.r.y), round2(f.r.w), round2(f.r.h) });
    }

    fn round2(v: f32) f32 {
        return @round(v * 100) / 100;
    }
};

test "op list copy rebases glyph indices" {
    const gpa = std.testing.allocator;
    var a: OpList = .{};
    defer a.deinit(gpa);
    var b: OpList = .{};
    defer b.deinit(gpa);
    const q: GlyphQuad = .{ .dst = .{ 0, 0, 1, 1 }, .uv = .{ 0, 0, 1, 1 }, .page = 0, .format = .r8 };
    try b.quads.append(gpa, q); // offset b's quads so indices differ
    var r = a.mark();
    try a.quads.append(gpa, q);
    try a.ops.append(gpa, .{ .glyphs = .{ .start = 0, .len = 1, .color = Color.hex(0), .aa = .grayscale } });
    r = a.close(r);
    const nr = try b.copyRange(gpa, &a, r);
    try std.testing.expectEqual(@as(u32, 1), nr.quad_start);
    try std.testing.expectEqual(@as(u32, 1), b.ops.items[0].glyphs.start);
}

test "recorder prints a frame" {
    var rec = Recorder.init(std.testing.allocator);
    defer rec.deinit();
    const c = rec.canvas();
    c.begin(.{ .w = 10, .h = 10 }, 1);
    c.rect(.{ .x = 1, .y = 2, .w = 3, .h = 4 }, Color.hex(0xff0000), .{});
    c.end();
    try std.testing.expectEqualStrings("begin 10x10 @1\nrect 1,2 3x4 #ff0000ff r0\nend\n", rec.text());
}
