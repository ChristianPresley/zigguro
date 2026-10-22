//! One frame's drawing commands, built by E04 on the UI thread and consumed
//! by a `Renderer` on the render thread.
//!
//! Inputs are logical pixels; the list multiplies them by `scale` and
//! stores physical-pixel `Prim`s in paint order. Colours are straight
//! alpha and are premultiplied on append. Capacity is kept across `reset`,
//! so a steady-state frame allocates nothing. Allocation failure never
//! surfaces as an error: the prim is dropped and `alloc_failed` is set, and
//! the renderer then repaints the whole frame once memory is available.
//!
//! Clips: `pushClip` intersects with the enclosing clip. A plain clip inside
//! a rounded one keeps only the corners it shares with it; a rounded clip
//! inside a rounded one is the inner clip cut to the outer bounds, which is
//! not exact where two different corners overlap (acceptable for UI).
//! Prims entirely outside their clip or the target are dropped on append.
//!
//! Layers: `beginLayer` .. `endLayer` record content into an offscreen
//! layer (layer-local coordinates, no nesting); `drawLayer` composites it.
//! Damage: `addDamage` lists changed physical rectangles (at most 64, more
//! means everything); `damageAll` repaints everything. A list without
//! damage repaints nothing unless the renderer itself needs a full frame.

const std = @import("std");
const types = @import("types.zig");
const prim_mod = @import("prim.zig");
const f16p = @import("f16.zig");
const Color = @import("color.zig").Color;

const Allocator = std.mem.Allocator;
const Prim = prim_mod.Prim;
const Kind = prim_mod.Kind;
const RectF = types.RectF;
const Radii = types.Radii;
const Insets = types.Insets;
const Vec2 = types.Vec2;
const Size = types.Size;
const PxRect = types.PxRect;
const ClipRect = types.ClipRect;
const TextureId = types.TextureId;
const LayerId = types.LayerId;
const GlyphQuad = types.GlyphQuad;
const TextAa = types.TextAa;
const Filter = types.Filter;

const DrawList = @This();

/// Maximum damage rectangles before the frame counts as fully damaged.
pub const max_damage = 64;

/// Structural markers between prim ranges.
pub const Cmd = struct {
    /// What happens before prim `at`.
    kind: enum(u8) { begin_layer, end_layer, subpixel_on, subpixel_off },
    /// Index of the first prim after the marker.
    at: u32,
    /// Index into `layers` for layer markers.
    layer: u16 = 0,
};

/// A layer referenced by this frame.
pub const LayerUse = struct {
    /// The caller's id.
    id: LayerId,
    /// Size in physical pixels.
    size: Size,
    /// Whether the content is recorded this frame (`beginLayer` returned true).
    drawn: bool,
    /// Range of `layer_damage` holding the content damage (empty = all).
    damage_start: u32 = 0,
    /// End of the damage range.
    damage_end: u32 = 0,
    /// Range of `prims` holding the content.
    prim_start: u32 = 0,
    /// End of the prim range.
    prim_end: u32 = 0,
};

/// Asks the renderer whether a layer's cached content is still valid.
pub const LayerQuery = struct {
    /// Renderer state.
    ctx: *anyopaque,
    /// True when the layer `id` of `size` is cached and complete.
    isValid: *const fn (ctx: *anyopaque, id: LayerId, size: Size) bool,
};

gpa: Allocator,
/// The prims, in paint order.
prims: std.ArrayList(Prim) = .empty,
/// Clip table; index 0 is "no clip".
clips: std.ArrayList(ClipRect) = .empty,
/// Structural markers, in order of `at`.
cmds: std.ArrayList(Cmd) = .empty,
/// Layers used this frame; a layer prim's `params` indexes this list.
layers: std.ArrayList(LayerUse) = .empty,
/// Content damage of the layers, in physical layer pixels.
layer_damage: std.ArrayList(PxRect) = .empty,
clip_stack: std.ArrayList(u16) = .empty,
/// Damage rectangles of the window, physical pixels.
damage: [max_damage]PxRect = undefined,
/// Number of valid entries in `damage`.
damage_len: u8 = 0,
/// Everything changed.
damage_full: bool = false,
/// Target size in physical pixels.
extent: Size = .{ .w = 0, .h = 0 },
/// Logical to physical scale.
scale: f32 = 1,
/// Maps `GlyphQuad.page` to a texture (see `setGlyphPages`).
glyph_pages: []const TextureId = &.{},
/// Answers `beginLayer`'s "still cached?" question; null means never cached.
layer_query: ?LayerQuery = null,
/// An append was dropped for lack of memory.
alloc_failed: bool = false,
subpixel_on: bool = false,
/// 1-based index of the open layer (0 = drawing to the window).
open_layer: u16 = 0,
clip_base: usize = 0,

/// An empty list using `gpa` for its arrays.
pub fn init(gpa: Allocator) DrawList {
    return .{ .gpa = gpa };
}

/// Frees the arrays.
pub fn deinit(self: *DrawList) void {
    self.prims.deinit(self.gpa);
    self.clips.deinit(self.gpa);
    self.cmds.deinit(self.gpa);
    self.layers.deinit(self.gpa);
    self.layer_damage.deinit(self.gpa);
    self.clip_stack.deinit(self.gpa);
    self.* = undefined;
}

/// Starts a new frame of `extent` physical pixels at `scale`, keeping
/// capacity, glyph pages and the layer query.
pub fn reset(self: *DrawList, extent: Size, scale: f32) void {
    self.prims.clearRetainingCapacity();
    self.clips.clearRetainingCapacity();
    self.cmds.clearRetainingCapacity();
    self.layers.clearRetainingCapacity();
    self.layer_damage.clearRetainingCapacity();
    self.clip_stack.clearRetainingCapacity();
    self.damage_len = 0;
    self.damage_full = false;
    self.extent = extent;
    self.scale = scale;
    self.alloc_failed = false;
    self.subpixel_on = false;
    self.open_layer = 0;
    self.clip_base = 0;
    self.clips.append(self.gpa, .{ .bounds = .{ -1e30, -1e30, 2e30, 2e30 } }) catch {
        self.alloc_failed = true;
    };
}

/// Sets the textures that `GlyphQuad.page` values index (from E02's
/// `AtlasBridge`). The slice must outlive the frame. Pages beyond the slice
/// map to `TextureId` equal to the page number.
pub fn setGlyphPages(self: *DrawList, pages: []const TextureId) void {
    self.glyph_pages = pages;
}

/// Fills `r` with `fill`.
pub fn rect(self: *DrawList, r: RectF, fill: Color, radii: Radii) void {
    const b = self.phys(r);
    self.push(.{ .bounds = b, .kind = .rect, .color0 = fill.premul().toU32(), .radii = self.packRadii(radii, b) });
}

/// Strokes the inside of `r` with per-edge `widths`.
pub fn border(self: *DrawList, r: RectF, widths: Insets, color: Color, radii: Radii) void {
    const b = self.phys(r);
    const s = self.scale;
    self.push(.{
        .bounds = b,
        .kind = .border,
        .uv = .{ widths.l * s, widths.t * s, widths.r * s, widths.b * s },
        .color0 = color.premul().toU32(),
        .radii = self.packRadii(radii, b),
    });
}

/// Draws a blurred shadow of `r` grown by `spread`, with Gaussian `sigma`.
pub fn shadow(self: *DrawList, r: RectF, radii: Radii, sigma: f32, spread: f32, color: Color) void {
    const s = self.scale;
    const sp = spread * s;
    var b = self.phys(r);
    b = .{ b[0] - sp, b[1] - sp, b[2] + 2 * sp, b[3] + 2 * sp };
    const grown: Radii = .{ .tl = @max(radii.tl + spread, 0), .tr = @max(radii.tr + spread, 0), .br = @max(radii.br + spread, 0), .bl = @max(radii.bl + spread, 0) };
    self.push(.{
        .bounds = b,
        .kind = .shadow,
        .color0 = color.premul().toU32(),
        .radii = self.packRadii(grown, b),
        .params = f16p.pack2(@max(sigma * s, 0), sp),
    });
}

/// Fills `r` with a gradient from `c0` at `p0` to `c1` at `p1` (logical
/// coordinates of the same space as `r`).
pub fn linearGradient(self: *DrawList, r: RectF, p0: Vec2, p1: Vec2, c0: Color, c1: Color, radii: Radii) void {
    const b = self.phys(r);
    const s = self.scale;
    self.push(.{
        .bounds = b,
        .kind = .linear_gradient,
        .uv = .{ p0.x * s, p0.y * s, p1.x * s, p1.y * s },
        .color0 = c0.premul().toU32(),
        .color1 = c1.premul().toU32(),
        .radii = self.packRadii(radii, b),
    });
}

/// Draws a run of glyphs in `color`. Subpixel modes apply only to
/// `rgb_subpixel` pages; the backend downgrades them to grayscale when
/// dual-source blending is unavailable.
pub fn glyphs(self: *DrawList, run: []const GlyphQuad, color: Color, aa: TextAa) void {
    const c = color.premul().toU32();
    for (run) |q| {
        const tex: u32 = if (q.page < self.glyph_pages.len) @intFromEnum(self.glyph_pages[q.page]) else q.page;
        var flags: prim_mod.Flags = .{ .aa_none = aa == .none };
        const kind: Kind = switch (q.format) {
            .r8 => .glyph_gray,
            .rgb_subpixel => switch (aa) {
                .subpixel_rgb => .glyph_subpixel,
                .subpixel_bgr => blk: {
                    flags.bgr = true;
                    break :blk .glyph_subpixel;
                },
                .grayscale, .none => blk: {
                    flags.rgb_avg = true;
                    break :blk .glyph_gray;
                },
            },
            .rgba_color => .glyph_color,
        };
        self.push(.{
            .bounds = self.phys(.{ .x = q.dst[0], .y = q.dst[1], .w = q.dst[2], .h = q.dst[3] }),
            .uv = q.uv,
            .kind = kind,
            .flags = flags,
            .color0 = c,
            .tex = @truncate(tex),
        });
    }
}

/// Draws texture `tex` (normalised `uv` rect) into `dst`, multiplied by
/// `tint`, with bilinear filtering.
pub fn image(self: *DrawList, tex: TextureId, dst: RectF, uv: RectF, tint: Color, radii: Radii) void {
    self.imageFiltered(tex, dst, uv, tint, radii, .linear);
}

/// `image` with an explicit filter.
pub fn imageFiltered(self: *DrawList, tex: TextureId, dst: RectF, uv: RectF, tint: Color, radii: Radii, filter: Filter) void {
    const b = self.phys(dst);
    self.push(.{
        .bounds = b,
        .kind = .image,
        .uv = .{ uv.x, uv.y, uv.x + uv.w, uv.y + uv.h },
        .color0 = tint.premul().toU32(),
        .radii = self.packRadii(radii, b),
        .tex = @truncate(@intFromEnum(tex)),
        .flags = .{ .nearest = filter == .nearest },
    });
}

/// Restricts later prims to `r` (with corner `radii`) until `popClip`.
pub fn pushClip(self: *DrawList, r: RectF, radii: Radii) void {
    const parent_idx = self.topClip();
    const parent = self.clips.items[parent_idx];
    const b = self.phys(r);
    const pb = parent.bounds;
    const x0 = @max(b[0], pb[0]);
    const y0 = @max(b[1], pb[1]);
    const x1 = @min(b[0] + b[2], pb[0] + pb[2]);
    const y1 = @min(b[1] + b[3], pb[1] + pb[3]);
    const ib = [4]f32{ x0, y0, @max(x1 - x0, 0), @max(y1 - y0, 0) };
    var rr: [4]f32 = undefined;
    if (radii.isZero()) {
        // Keep the parent's rounded corners that coincide with ours.
        const pr = parent.radii;
        rr = .{
            if (x0 == pb[0] and y0 == pb[1]) pr[0] else 0,
            if (x1 == pb[0] + pb[2] and y0 == pb[1]) pr[1] else 0,
            if (x1 == pb[0] + pb[2] and y1 == pb[1] + pb[3]) pr[2] else 0,
            if (x0 == pb[0] and y1 == pb[1] + pb[3]) pr[3] else 0,
        };
    } else {
        rr = self.clampRadii(radii, ib);
    }
    if (self.clips.items.len >= std.math.maxInt(u16)) {
        self.alloc_failed = true;
        return self.pushClipIndex(parent_idx);
    }
    self.clips.append(self.gpa, .{ .bounds = ib, .radii = rr, .parent = parent_idx }) catch {
        self.alloc_failed = true;
        return self.pushClipIndex(parent_idx);
    };
    self.pushClipIndex(@intCast(self.clips.items.len - 1));
}

/// Ends the innermost `pushClip`.
pub fn popClip(self: *DrawList) void {
    if (self.clip_stack.items.len > self.clip_base) _ = self.clip_stack.pop();
}

/// Starts recording the content of layer `id` (`size` physical pixels)
/// when it must be repainted, and returns true; returns false when the
/// renderer still holds it and `content_damage` is empty, in which case the
/// caller skips the content and does not call `endLayer`. `content_damage`
/// limits the repaint (empty = everything). Layers do not nest.
pub fn beginLayer(self: *DrawList, id: LayerId, size: Size, content_damage: []const PxRect) bool {
    std.debug.assert(self.open_layer == 0);
    const cached = content_damage.len == 0 and if (self.layer_query) |q| q.isValid(q.ctx, id, size) else false;
    const idx = self.useLayer(id, size) orelse return false;
    if (cached) return false;
    const l = &self.layers.items[idx];
    l.drawn = true;
    l.damage_start = @intCast(self.layer_damage.items.len);
    self.layer_damage.appendSlice(self.gpa, content_damage) catch {
        // Unknown damage: repaint the whole layer.
        self.alloc_failed = true;
        self.layer_damage.shrinkRetainingCapacity(l.damage_start);
    };
    l.damage_end = @intCast(self.layer_damage.items.len);
    l.prim_start = @intCast(self.prims.items.len);
    l.prim_end = l.prim_start;
    self.appendCmd(.{ .kind = .begin_layer, .at = l.prim_start, .layer = @intCast(idx) });
    self.open_layer = @intCast(idx + 1);
    self.clip_base = self.clip_stack.items.len;
    return true;
}

/// Ends the layer opened by `beginLayer`.
pub fn endLayer(self: *DrawList) void {
    std.debug.assert(self.open_layer != 0);
    if (self.open_layer == 0) return;
    const idx = self.open_layer - 1;
    self.closeSubpixel();
    self.layers.items[idx].prim_end = @intCast(self.prims.items.len);
    self.appendCmd(.{ .kind = .end_layer, .at = @intCast(self.prims.items.len), .layer = idx });
    self.clip_stack.shrinkRetainingCapacity(self.clip_base);
    self.clip_base = 0;
    self.open_layer = 0;
}

/// Composites layer `id` into `dst`, showing the layer from `scroll_px`
/// (physical layer pixels) at `opacity`.
pub fn drawLayer(self: *DrawList, id: LayerId, dst: RectF, scroll_px: Vec2, opacity: f32) void {
    const idx = for (self.layers.items, 0..) |l, i| {
        if (l.id == id) break i;
    } else self.useLayer(id, .{ .w = 0, .h = 0 }) orelse return;
    const b = self.phys(dst);
    self.push(.{
        .bounds = b,
        .kind = .layer,
        .uv = .{ scroll_px.x, scroll_px.y, 0, 0 },
        .color0 = Color.white.withOpacity(opacity).premul().toU32(),
        .params = @intCast(idx),
    });
}

/// Marks physical rectangle `r` of the window as changed this frame.
pub fn addDamage(self: *DrawList, r: PxRect) void {
    if (self.damage_full) return;
    const c = clipPx(r, self.extent) orelse return;
    if (self.damage_len == max_damage) {
        self.damage_full = true;
        return;
    }
    self.damage[self.damage_len] = c;
    self.damage_len += 1;
}

/// Marks the whole window as changed.
pub fn damageAll(self: *DrawList) void {
    self.damage_full = true;
}

/// The damage rectangles (meaningless when `damage_full`).
pub fn damageRects(self: *const DrawList) []const PxRect {
    return self.damage[0..self.damage_len];
}

/// The content damage of layer `l` (empty = all).
pub fn layerDamage(self: *const DrawList, l: LayerUse) []const PxRect {
    return self.layer_damage.items[l.damage_start..l.damage_end];
}

/// Clips `r` to `extent`; null if nothing is left.
pub fn clipPx(r: PxRect, extent: Size) ?PxRect {
    const x0 = @max(r.x, 0);
    const y0 = @max(r.y, 0);
    const x1 = @min(@as(i64, r.x) + r.w, extent.w);
    const y1 = @min(@as(i64, r.y) + r.h, extent.h);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
}

fn useLayer(self: *DrawList, id: LayerId, size: Size) ?usize {
    for (self.layers.items, 0..) |*l, i| if (l.id == id) {
        if (size.w != 0) l.size = size;
        return i;
    };
    if (self.layers.items.len >= std.math.maxInt(u16) - 1) return null;
    self.layers.append(self.gpa, .{ .id = id, .size = size, .drawn = false }) catch {
        self.alloc_failed = true;
        return null;
    };
    return self.layers.items.len - 1;
}

fn pushClipIndex(self: *DrawList, idx: u16) void {
    self.clip_stack.append(self.gpa, idx) catch {
        self.alloc_failed = true;
    };
}

fn topClip(self: *const DrawList) u16 {
    if (self.clip_stack.items.len > self.clip_base) return self.clip_stack.items[self.clip_stack.items.len - 1];
    return 0;
}

fn targetSize(self: *const DrawList) Size {
    if (self.open_layer != 0) return self.layers.items[self.open_layer - 1].size;
    return self.extent;
}

fn phys(self: *const DrawList, r: RectF) [4]f32 {
    const s = self.scale;
    return .{ r.x * s, r.y * s, r.w * s, r.h * s };
}

fn clampRadii(self: *const DrawList, radii: Radii, b: [4]f32) [4]f32 {
    const s = self.scale;
    const lim = @max(@min(b[2], b[3]) * 0.5, 0);
    return .{
        f16p.round(std.math.clamp(radii.tl * s, 0, lim)),
        f16p.round(std.math.clamp(radii.tr * s, 0, lim)),
        f16p.round(std.math.clamp(radii.br * s, 0, lim)),
        f16p.round(std.math.clamp(radii.bl * s, 0, lim)),
    };
}

fn packRadii(self: *const DrawList, radii: Radii, b: [4]f32) [2]u32 {
    if (radii.isZero()) return .{ 0, 0 };
    const r = self.clampRadii(radii, b);
    return .{ f16p.pack2(r[0], r[1]), f16p.pack2(r[2], r[3]) };
}

fn appendCmd(self: *DrawList, c: Cmd) void {
    self.cmds.append(self.gpa, c) catch {
        self.alloc_failed = true;
    };
}

fn closeSubpixel(self: *DrawList) void {
    if (!self.subpixel_on) return;
    self.subpixel_on = false;
    self.appendCmd(.{ .kind = .subpixel_off, .at = @intCast(self.prims.items.len) });
}

fn push(self: *DrawList, p_in: Prim) void {
    var p = p_in;
    const b = p.bounds;
    if (!(b[2] > 0 and b[3] > 0)) return;
    if (p.kind == .shadow and p.color0 == 0) return;
    const clip = self.topClip();
    p.clip = clip;
    p.layer_z = self.open_layer;
    // Cull against the clip and the target.
    const cr = p.coverRect();
    const cb = self.clips.items[clip].bounds;
    const t = self.targetSize();
    const x0 = @max(@max(cr[0], cb[0]), 0);
    const y0 = @max(@max(cr[1], cb[1]), 0);
    const x1 = @min(@min(cr[2], cb[0] + cb[2]), @as(f32, @floatFromInt(t.w)));
    const y1 = @min(@min(cr[3], cb[1] + cb[3]), @as(f32, @floatFromInt(t.h)));
    if (!(x1 > x0 and y1 > y0)) return;
    const sub = p.kind == .glyph_subpixel;
    if (sub != self.subpixel_on) {
        self.subpixel_on = sub;
        self.appendCmd(.{ .kind = if (sub) .subpixel_on else .subpixel_off, .at = @intCast(self.prims.items.len) });
    }
    self.prims.append(self.gpa, p) catch {
        self.alloc_failed = true;
    };
}

const testing = std.testing;

fn testList() DrawList {
    var dl = DrawList.init(testing.allocator);
    dl.reset(.{ .w = 100, .h = 100 }, 1);
    return dl;
}

test "drawlist: clip intersection and culling" {
    var dl = testList();
    defer dl.deinit();
    dl.pushClip(.{ .x = 10, .y = 10, .w = 50, .h = 50 }, .{});
    dl.pushClip(.{ .x = 40, .y = 0, .w = 50, .h = 30 }, .{});
    const c = dl.clips.items[2];
    try testing.expectEqual([4]f32{ 40, 10, 20, 20 }, c.bounds);
    try testing.expectEqual(@as(u16, 1), c.parent);
    dl.rect(.{ .x = 45, .y = 15, .w = 5, .h = 5 }, Color.black, .{});
    dl.rect(.{ .x = 0, .y = 70, .w = 5, .h = 5 }, Color.black, .{}); // outside the clip
    dl.popClip();
    dl.rect(.{ .x = 12, .y = 40, .w = 5, .h = 5 }, Color.black, .{});
    dl.popClip();
    dl.rect(.{ .x = 200, .y = 0, .w = 5, .h = 5 }, Color.black, .{}); // outside the target
    dl.rect(.{ .x = 1, .y = 1, .w = 0, .h = 5 }, Color.black, .{}); // empty
    try testing.expectEqual(@as(usize, 2), dl.prims.items.len);
    try testing.expectEqual(@as(u16, 2), dl.prims.items[0].clip);
    try testing.expectEqual(@as(u16, 1), dl.prims.items[1].clip);
    // Popping past the bottom is harmless.
    dl.popClip();
}

test "drawlist: rounded parent corners survive a plain inner clip" {
    var dl = testList();
    defer dl.deinit();
    dl.pushClip(.{ .x = 0, .y = 0, .w = 50, .h = 50 }, Radii.all(8));
    dl.pushClip(.{ .x = 0, .y = 0, .w = 50, .h = 20 }, .{});
    try testing.expectEqual([4]f32{ 8, 8, 0, 0 }, dl.clips.items[2].radii);
}

test "drawlist: scale and premultiply on append" {
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.reset(.{ .w = 200, .h = 200 }, 2);
    dl.rect(.{ .x = 1, .y = 2, .w = 3, .h = 4 }, .{ .r = 255, .g = 0, .b = 0, .a = 128 }, Radii.all(10));
    const p = dl.prims.items[0];
    try testing.expectEqual([4]f32{ 2, 4, 6, 8 }, p.bounds);
    try testing.expectEqual((Color{ .r = 128, .g = 0, .b = 0, .a = 128 }).toU32(), p.color0);
    // Radii clamp to half the smaller side.
    try testing.expectEqual([4]f32{ 3, 3, 3, 3 }, p.radiiF());
}

test "drawlist: reset keeps capacity, zero alloc steady state" {
    var fa = testing.FailingAllocator.init(testing.allocator, .{});
    var dl = DrawList.init(fa.allocator());
    defer dl.deinit();
    const frame = struct {
        fn f(d: *DrawList) void {
            d.reset(.{ .w = 640, .h = 480 }, 1);
            d.pushClip(.{ .x = 0, .y = 0, .w = 300, .h = 300 }, Radii.all(4));
            var i: u32 = 0;
            while (i < 500) : (i += 1) {
                const x: f32 = @floatFromInt(i % 50);
                d.rect(.{ .x = x * 6, .y = x * 5, .w = 5, .h = 5 }, Color.white, .{});
            }
            const q = [_]GlyphQuad{.{ .dst = .{ 1, 1, 8, 8 }, .uv = .{ 0, 0, 1, 1 }, .page = 0, .format = .rgb_subpixel }} ** 4;
            d.glyphs(&q, Color.black, .subpixel_rgb);
            d.glyphs(&q, Color.black, .grayscale);
            d.popClip();
            if (d.beginLayer(@enumFromInt(7), .{ .w = 64, .h = 64 }, &.{})) {
                d.rect(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, Color.white, .{});
                d.endLayer();
            }
            d.drawLayer(@enumFromInt(7), .{ .x = 0, .y = 0, .w = 64, .h = 64 }, .{}, 1);
            d.addDamage(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
        }
    }.f;
    frame(&dl);
    frame(&dl);
    try testing.expect(!dl.alloc_failed);
    fa.fail_index = fa.alloc_index; // any further allocation fails
    frame(&dl);
    try testing.expect(!dl.alloc_failed);
    try testing.expectEqual(@as(usize, 500 + 8 + 2), dl.prims.items.len);
}

test "drawlist: subpixel switch markers" {
    var dl = testList();
    defer dl.deinit();
    const q = [_]GlyphQuad{.{ .dst = .{ 1, 1, 8, 8 }, .uv = .{ 0, 0, 1, 1 }, .page = 3, .format = .rgb_subpixel }} ** 2;
    dl.rect(.{ .x = 0, .y = 0, .w = 5, .h = 5 }, Color.white, .{});
    dl.glyphs(&q, Color.black, .subpixel_bgr);
    dl.glyphs(&q, Color.black, .subpixel_rgb);
    dl.rect(.{ .x = 0, .y = 0, .w = 5, .h = 5 }, Color.white, .{});
    dl.glyphs(&q, Color.black, .grayscale);
    try testing.expectEqual(@as(usize, 2), dl.cmds.items.len);
    try testing.expectEqual(Cmd{ .kind = .subpixel_on, .at = 1 }, dl.cmds.items[0]);
    try testing.expectEqual(Cmd{ .kind = .subpixel_off, .at = 5 }, dl.cmds.items[1]);
    try testing.expect(dl.prims.items[1].flags.bgr);
    try testing.expect(!dl.prims.items[3].flags.bgr);
    try testing.expectEqual(Kind.glyph_gray, dl.prims.items[6].kind);
    try testing.expect(dl.prims.items[6].flags.rgb_avg);
    try testing.expectEqual(@as(u16, 3), dl.prims.items[6].tex);
}

test "drawlist: glyph pages map to textures" {
    var dl = testList();
    defer dl.deinit();
    const pages = [_]TextureId{ @enumFromInt(9), @enumFromInt(11) };
    dl.setGlyphPages(&pages);
    const q = [_]GlyphQuad{.{ .dst = .{ 1, 1, 8, 8 }, .uv = .{ 0, 0, 1, 1 }, .page = 1, .format = .r8 }};
    dl.glyphs(&q, Color.black, .grayscale);
    try testing.expectEqual(@as(u16, 11), dl.prims.items[0].tex);
}

test "drawlist: layers record ranges and honour the cache" {
    var dl = testList();
    defer dl.deinit();
    const Q = struct {
        fn valid(_: *anyopaque, id: LayerId, _: Size) bool {
            return @intFromEnum(id) == 1;
        }
    };
    var dummy: u8 = 0;
    dl.layer_query = .{ .ctx = &dummy, .isValid = Q.valid };
    try testing.expect(!dl.beginLayer(@enumFromInt(1), .{ .w = 20, .h = 20 }, &.{}));
    const dmg = [_]PxRect{.{ .x = 0, .y = 0, .w = 4, .h = 4 }};
    try testing.expect(dl.beginLayer(@enumFromInt(2), .{ .w = 20, .h = 20 }, &dmg));
    dl.rect(.{ .x = 0, .y = 0, .w = 5, .h = 5 }, Color.white, .{});
    dl.rect(.{ .x = 30, .y = 0, .w = 5, .h = 5 }, Color.white, .{}); // outside the layer
    dl.endLayer();
    dl.drawLayer(@enumFromInt(1), .{ .x = 0, .y = 0, .w = 20, .h = 20 }, .{}, 1);
    dl.drawLayer(@enumFromInt(2), .{ .x = 20, .y = 0, .w = 20, .h = 20 }, .{ .y = 3 }, 0.5);
    try testing.expectEqual(@as(usize, 2), dl.layers.items.len);
    const l2 = dl.layers.items[1];
    try testing.expect(l2.drawn and !dl.layers.items[0].drawn);
    try testing.expectEqual(@as(u32, 0), l2.prim_start);
    try testing.expectEqual(@as(u32, 1), l2.prim_end);
    try testing.expectEqual(@as(usize, 1), dl.layerDamage(l2).len);
    try testing.expectEqual(@as(u16, 2), dl.prims.items[0].layer_z);
    try testing.expectEqual(@as(u32, 1), dl.prims.items[2].params);
    try testing.expectEqual(@as(u16, 0), dl.prims.items[2].layer_z);
}

test "drawlist: damage clips and overflows to full" {
    var dl = testList();
    defer dl.deinit();
    dl.addDamage(.{ .x = -5, .y = 90, .w = 20, .h = 20 });
    try testing.expectEqual(PxRect{ .x = 0, .y = 90, .w = 15, .h = 10 }, dl.damageRects()[0]);
    dl.addDamage(.{ .x = 200, .y = 0, .w = 5, .h = 5 });
    try testing.expectEqual(@as(usize, 1), dl.damageRects().len);
    var i: u32 = 0;
    while (i < max_damage) : (i += 1) dl.addDamage(.{ .x = 0, .y = 0, .w = 1, .h = 1 });
    try testing.expect(dl.damage_full);
}
