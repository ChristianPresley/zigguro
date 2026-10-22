//! Draw batching for the Vulkan backend (E02.F06.S01.T02): contiguous
//! runs of prims that share a pipeline, optionally culled to one repaint
//! rect. Runs are drawn with `vkCmdDraw(4, count, 0, first)`, so paint
//! order is the prim order.

const std = @import("std");
const r2d = @import("../root.zig");
const bin = @import("../../sw/bin.zig");

const Prim = r2d.prim.Prim;
const PxRect = r2d.PxRect;

pub const Pipeline = enum(u1) { prim, text_subpixel };

pub const Batch = struct { pipeline: Pipeline, first: u32, count: u32 };

/// Above this many runs for one rect, culling is dropped for that rect
/// (the scissor still limits fill).
pub const max_runs_per_rect = 64;

/// The pipeline `p` draws with.
pub fn pipelineOf(p: *const Prim, dual_src: bool) Pipeline {
    return if (dual_src and p.kind == .glyph_subpixel) .text_subpixel else .prim;
}

/// Whether `p` is drawn in the pass of layer `z` (0 = the window). Layer
/// composites are drawn only when their layer has a texture slot
/// (`layer_slots[params] != 0`).
pub fn inPass(p: *const Prim, z: u16, layer_slots: []const u32) bool {
    if (p.layer_z != z) return false;
    if (p.kind == .layer) return p.params < layer_slots.len and layer_slots[p.params] != 0;
    return true;
}

/// What `buildBatches` draws.
pub const Filter = struct {
    /// The pass: 0 = window, n = layer n - 1.
    z: u16 = 0,
    /// Texture slot per layer of the frame (0 = none).
    layer_slots: []const u32 = &.{},
    /// Added to every batch's `first`.
    base: u32 = 0,
};

/// Whether `p` can touch a pixel of `rect`.
pub fn touches(p: *const Prim, clips: []const r2d.ClipRect, rect: PxRect) bool {
    const s = bin.primSpan(p, clips);
    if (s.empty()) return false;
    return s.x0 < @as(i64, rect.x) + rect.w and s.x1 > rect.x and s.y0 < @as(i64, rect.y) + rect.h and s.y1 > rect.y;
}

/// Appends the batches of the pass `f.z` to `out`, culled to `rect` when
/// given. Pure.
pub fn buildBatches(gpa: std.mem.Allocator, prims: []const Prim, clips: []const r2d.ClipRect, f: Filter, rect: ?PxRect, dual_src: bool, out: *std.ArrayList(Batch)) !void {
    const start = out.items.len;
    if (rect) |r| {
        try runs(gpa, prims, clips, f, r, dual_src, out);
        if (out.items.len - start <= max_runs_per_rect) return;
        out.shrinkRetainingCapacity(start);
    }
    try runs(gpa, prims, clips, f, null, dual_src, out);
}

fn runs(gpa: std.mem.Allocator, prims: []const Prim, clips: []const r2d.ClipRect, f: Filter, rect: ?PxRect, dual_src: bool, out: *std.ArrayList(Batch)) !void {
    var open: ?Batch = null;
    for (prims, 0..) |*p, i| {
        const keep = inPass(p, f.z, f.layer_slots) and (rect == null or touches(p, clips, rect.?));
        if (!keep) {
            if (open) |b| try out.append(gpa, b);
            open = null;
            continue;
        }
        const pl = pipelineOf(p, dual_src);
        if (open) |*b| {
            if (b.pipeline == pl) {
                b.count += 1;
                continue;
            }
            try out.append(gpa, b.*);
        }
        open = .{ .pipeline = pl, .first = f.base + @as(u32, @intCast(i)), .count = 1 };
    }
    if (open) |b| try out.append(gpa, b);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn rectPrim(x: f32, y: f32, kind: r2d.prim.Kind) Prim {
    return .{ .bounds = .{ x, y, 4, 4 }, .kind = kind };
}

test "batch: splits only on pipeline/layer" {
    const gpa = testing.allocator;
    var prims = [_]Prim{
        rectPrim(0, 0, .rect),
        rectPrim(10, 0, .glyph_gray),
        rectPrim(20, 0, .glyph_subpixel),
        rectPrim(30, 0, .glyph_subpixel),
        rectPrim(40, 0, .rect),
        rectPrim(50, 0, .rect),
        rectPrim(60, 0, .rect),
    };
    prims[5].layer_z = 1;
    var out: std.ArrayList(Batch) = .empty;
    defer out.deinit(gpa);
    try buildBatches(gpa, &prims, &.{.{ .bounds = .{ 0, 0, 0, 0 } }}, .{}, null, true, &out);
    try testing.expectEqualSlices(Batch, &.{
        .{ .pipeline = .prim, .first = 0, .count = 2 },
        .{ .pipeline = .text_subpixel, .first = 2, .count = 2 },
        .{ .pipeline = .prim, .first = 4, .count = 1 },
        .{ .pipeline = .prim, .first = 6, .count = 1 },
    }, out.items);
    // Without dual-source blending subpixel glyphs join the prim runs.
    out.clearRetainingCapacity();
    try buildBatches(gpa, prims[0..5], &.{}, .{}, null, false, &out);
    try testing.expectEqualSlices(Batch, &.{.{ .pipeline = .prim, .first = 0, .count = 5 }}, out.items);
}

test "batch: per-rect culling keeps paint order" {
    const gpa = testing.allocator;
    var prims: [8]Prim = undefined;
    for (&prims, 0..) |*p, i| p.* = rectPrim(@floatFromInt((i % 4) * 20), @floatFromInt((i / 4) * 20), .rect);
    var out: std.ArrayList(Batch) = .empty;
    defer out.deinit(gpa);
    // Rect around column 1 (prims 1 and 5).
    try buildBatches(gpa, &prims, &.{}, .{}, .{ .x = 18, .y = 0, .w = 8, .h = 40 }, false, &out);
    try testing.expectEqualSlices(Batch, &.{
        .{ .pipeline = .prim, .first = 1, .count = 1 },
        .{ .pipeline = .prim, .first = 5, .count = 1 },
    }, out.items);
    // Too many runs: the whole range is drawn instead.
    var many: [200]Prim = undefined;
    for (&many, 0..) |*p, i| p.* = rectPrim(if (i % 2 == 0) 0 else 100, 0, .rect);
    out.clearRetainingCapacity();
    try buildBatches(gpa, &many, &.{}, .{}, .{ .x = 0, .y = 0, .w = 8, .h = 8 }, false, &out);
    try testing.expectEqualSlices(Batch, &.{.{ .pipeline = .prim, .first = 0, .count = 200 }}, out.items);
}

test "batch: layer passes and composites" {
    const gpa = testing.allocator;
    var prims = [_]Prim{
        rectPrim(0, 0, .rect), // layer 1 content
        rectPrim(0, 0, .rect),
        rectPrim(0, 0, .layer), // composite of layer 0
        rectPrim(0, 0, .layer), // composite of layer 1 (no texture)
    };
    prims[0].layer_z = 1;
    prims[3].params = 1;
    var out: std.ArrayList(Batch) = .empty;
    defer out.deinit(gpa);
    const slots = [_]u32{ 7, 0 };
    try buildBatches(gpa, &prims, &.{}, .{ .z = 1, .layer_slots = &slots, .base = 100 }, null, false, &out);
    try testing.expectEqualSlices(Batch, &.{.{ .pipeline = .prim, .first = 100, .count = 1 }}, out.items);
    out.clearRetainingCapacity();
    try buildBatches(gpa, &prims, &.{}, .{ .layer_slots = &slots }, null, false, &out);
    try testing.expectEqualSlices(Batch, &.{.{ .pipeline = .prim, .first = 1, .count = 2 }}, out.items);
}
