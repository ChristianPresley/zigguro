//! Helpers shared by the vector tests: whole-image renders through the
//! tile rasterizer, a single-bitmap reference render, and PGM encoding.

const std = @import("std");
const zg_text = @import("zg_text");
const vector = @import("root.zig");

const Allocator = std.mem.Allocator;
const tiles = vector.tiles;
const Accumulator = zg_text.raster.coverage.Accumulator;

/// `dl` at `scale` as `w`×`h` premultiplied RGBA, assembled from tiles.
pub fn renderTiled(gpa: Allocator, dl: *const vector.DisplayList, scale: f32, w: u32, h: u32) ![]u8 {
    const out = try gpa.alloc(u8, @as(usize, w) * h * 4);
    errdefer gpa.free(out);
    @memset(out, 0);
    var s: tiles.Scratch = .init(gpa);
    defer s.deinit(gpa);
    const px = try gpa.alloc(u8, tiles.tile_bytes);
    defer gpa.free(px);
    const nx = (w + tiles.tile_size - 1) / tiles.tile_size;
    const ny = (h + tiles.tile_size - 1) / tiles.tile_size;
    for (0..ny) |ty| for (0..nx) |tx| {
        try tiles.rasterizeTile(gpa, &s, dl, scale, @intCast(tx), @intCast(ty), px);
        for (0..tiles.tile_size) |row| {
            const y = ty * tiles.tile_size + row;
            if (y >= h) break;
            const x0 = tx * tiles.tile_size;
            const n: usize = @min(tiles.tile_size, w - x0);
            @memcpy(out[(y * w + x0) * 4 ..][0 .. n * 4], px[row * tiles.tile_size * 4 ..][0 .. n * 4]);
        }
    };
    return out;
}

/// The same fills drawn into one `w`×`h` bitmap with no tiling (the
/// reference for seams). Clips are ignored.
pub fn renderWhole(gpa: Allocator, dl: *const vector.DisplayList, scale: f32, w: u32, h: u32) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try gpa.alloc(u8, @as(usize, w) * h * 4);
    errdefer gpa.free(out);
    @memset(out, 0);
    const cov = try a.alloc(u8, @as(usize, w) * h);
    var acc: Accumulator = .{};
    defer acc.deinit(gpa);
    const m: vector.Affine = .scaleTranslate(scale, 0, 0);
    for (dl.items) |it| {
        const p, const color = switch (it) {
            .fill => |f| .{ f.path, f.color },
            .stroke => |st| .{ st.outline, st.color },
            else => continue,
        };
        try acc.reset(gpa, w, h);
        for (try vector.flatten.flatten(a, p, m, tiles.device_tolerance)) |pl| {
            if (pl.points.len < 2) continue;
            for (pl.points[0 .. pl.points.len - 1], pl.points[1..]) |p0, p1| tiles.clipLine(&acc, p0, p1);
            tiles.clipLine(&acc, pl.points[pl.points.len - 1], pl.points[0]);
        }
        acc.integrate(cov, w);
        vector.composite.srcOver(out, w * 4, cov, w, color, .{ .x0 = 0, .y0 = 0, .x1 = w, .y1 = h });
    }
    return out;
}

/// The alpha channel as a binary PGM (P5).
pub fn pgm(gpa: Allocator, rgba: []const u8, w: u32, h: u32) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.print("P5\n{d} {d}\n255\n", .{ w, h });
    for (0..@as(usize, w) * h) |i| try out.writer.writeByte(rgba[i * 4 + 3]);
    return out.toOwnedSlice();
}
