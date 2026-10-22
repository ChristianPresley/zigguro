//! `zg-release icongen --out <dir> [--check true]` (E17.F01.S01.T03):
//! rasterizes packaging/icons/logo.zig into
//! `dev.zigguro.zigguro-<N>.png` for every size in `png_sizes` and
//! `zigguro.ico` (16 to 256 px, PNG-embedded). With `--check true` it
//! compares instead of writing and fails when a file is stale.
//!
//! Layers are rasterized with zg_text's coverage accumulator and
//! composited in linear premultiplied light (sRGB to linear, source over,
//! back to sRGB), so edges between colours have no dark fringe. All
//! arithmetic is std software math: the output is byte-identical on every
//! host.

const std = @import("std");
const Allocator = std.mem.Allocator;
const raster = @import("zg_text").raster;
const logo = @import("zg_logo");
const png = @import("png.zig");
const ico = @import("ico.zig");
const args = @import("args.zig");

pub const png_sizes = [_]u16{ 16, 24, 32, 48, 64, 128, 256, 512 };
pub const ico_sizes = [_]u16{ 16, 24, 32, 48, 64, 256 };
pub const ico_name = "zigguro.ico";

pub fn run(ctx: *const args.Context) !u8 {
    const out_path = try ctx.opts.need("out");
    const check = if (ctx.opts.get("check")) |v| std.mem.eql(u8, v, "true") else false;
    const files = try generate(ctx.gpa);
    var dir = if (check)
        std.Io.Dir.cwd().openDir(ctx.io, out_path, .{}) catch {
            std.debug.print("icongen: {s} is missing; run `zig build icons`\n", .{out_path});
            return 1;
        }
    else blk: {
        try std.Io.Dir.cwd().createDirPath(ctx.io, out_path);
        break :blk try std.Io.Dir.cwd().openDir(ctx.io, out_path, .{});
    };
    defer dir.close(ctx.io);
    var stale: usize = 0;
    for (files) |f| {
        if (check) {
            const have = dir.readFileAlloc(ctx.io, f.name, ctx.gpa, .limited(16 * 1024 * 1024)) catch "";
            if (!std.mem.eql(u8, have, f.bytes)) {
                std.debug.print("icongen: {s}/{s} is stale; run `zig build icons`\n", .{ out_path, f.name });
                stale += 1;
            }
        } else try dir.writeFile(ctx.io, .{ .sub_path = f.name, .data = f.bytes });
    }
    return if (stale == 0) 0 else 1;
}

pub const File = struct { name: []const u8, bytes: []const u8 };

/// Every output file, in a fixed order. Allocations go to `gpa` (an arena
/// in the tool).
pub fn generate(gpa: Allocator) ![]File {
    var files: std.ArrayList(File) = .empty;
    var pngs: [png_sizes.len][]const u8 = undefined;
    for (png_sizes, 0..) |s, i| {
        pngs[i] = try renderPng(gpa, s);
        try files.append(gpa, .{ .name = try std.fmt.allocPrint(gpa, "dev.zigguro.zigguro-{d}.png", .{s}), .bytes = pngs[i] });
    }
    var images: [ico_sizes.len]ico.Image = undefined;
    for (ico_sizes, 0..) |s, i| {
        const at = std.mem.indexOfScalar(u16, &png_sizes, s).?;
        images[i] = .{ .size = s, .png = pngs[at] };
    }
    var aw: std.Io.Writer.Allocating = .init(gpa);
    try ico.write(&aw.writer, &images);
    try files.append(gpa, .{ .name = ico_name, .bytes = aw.written() });
    return files.items;
}

/// The logo at `size` px as a PNG.
pub fn renderPng(gpa: Allocator, size: u16) ![]const u8 {
    const px = try render(gpa, size);
    defer gpa.free(px);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    try png.writeRgba(gpa, &aw.writer, size, size, px);
    return aw.written();
}

/// The logo at `size` px as straight-alpha sRGB RGBA8.
pub fn render(gpa: Allocator, size: u16) ![]u8 {
    const n = @as(usize, size) * size;
    // Linear premultiplied RGBA.
    const canvas = try gpa.alloc([4]f32, n);
    defer gpa.free(canvas);
    @memset(canvas, .{ 0, 0, 0, 0 });
    const cov = try gpa.alloc(f32, n);
    defer gpa.free(cov);
    var acc: raster.coverage.Accumulator = .{};
    defer acc.deinit(gpa);

    const scale = @as(f32, @floatFromInt(size)) / logo.design_size;
    for (logo.logo) |layer| {
        if (size < layer.hint_min_px) continue;
        try acc.reset(gpa, size, size);
        fill(&acc, layer.cmds, scale);
        acc.integrateF32(cov);
        const a = @as(f32, @floatFromInt(layer.fill.rgba[3])) / 255;
        const lin = [3]f32{ toLinear(layer.fill.rgba[0]), toLinear(layer.fill.rgba[1]), toLinear(layer.fill.rgba[2]) };
        for (canvas, cov) |*d, c| {
            const sa = a * c;
            if (sa == 0) continue;
            const keep = 1 - sa;
            d.* = .{ lin[0] * sa + d[0] * keep, lin[1] * sa + d[1] * keep, lin[2] * sa + d[2] * keep, sa + d[3] * keep };
        }
    }

    const out = try gpa.alloc(u8, n * 4);
    for (canvas, 0..) |p, i| {
        const o = out[i * 4 ..][0..4];
        if (p[3] <= 0) {
            o.* = .{ 0, 0, 0, 0 };
            continue;
        }
        o.* = .{ toSrgb(p[0] / p[3]), toSrgb(p[1] / p[3]), toSrgb(p[2] / p[3]), unit8(p[3]) };
    }
    return out;
}

/// Adds every contour of `cmds`, scaled into pixels, to `acc`.
fn fill(acc: *raster.coverage.Accumulator, cmds: []const logo.Cmd, scale: f32) void {
    const tol = raster.flatten.tol_gray;
    var start: [2]f32 = .{ 0, 0 };
    var pen: [2]f32 = .{ 0, 0 };
    for (cmds) |c| switch (c) {
        .move => |p| {
            if (pen[0] != start[0] or pen[1] != start[1]) acc.line(pen, start);
            start = sc(p, scale);
            pen = start;
        },
        .line => |p| {
            const q = sc(p, scale);
            acc.line(pen, q);
            pen = q;
        },
        .quad => |q| {
            const e = sc(q[1], scale);
            raster.flatten.quad(acc, pen, sc(q[0], scale), e, tol);
            pen = e;
        },
        .cubic => |q| {
            const e = sc(q[2], scale);
            raster.flatten.cubic(acc, pen, sc(q[0], scale), sc(q[1], scale), e, tol);
            pen = e;
        },
        .close => {
            if (pen[0] != start[0] or pen[1] != start[1]) acc.line(pen, start);
            pen = start;
        },
    };
    if (pen[0] != start[0] or pen[1] != start[1]) acc.line(pen, start);
}

fn sc(p: [2]f32, s: f32) [2]f32 {
    return .{ p[0] * s, p[1] * s };
}

fn toLinear(v: u8) f32 {
    const c = @as(f32, @floatFromInt(v)) / 255;
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

fn toSrgb(l: f32) u8 {
    const c = std.math.clamp(l, 0, 1);
    return unit8(if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055);
}

fn unit8(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

const testing = std.testing;

test "icongen: deterministic" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = try generate(arena.allocator());
    const b = try generate(arena.allocator());
    try testing.expectEqual(png_sizes.len + 1, a.len);
    for (a, b) |x, y| {
        try testing.expectEqualStrings(x.name, y.name);
        try testing.expectEqualSlices(u8, x.bytes, y.bytes);
    }
}

test "icongen: corners transparent, centre opaque, colours exact" {
    const px = try render(testing.allocator, 64);
    defer testing.allocator.free(px);
    // The rounded corner leaves the pixel at (0,0) empty.
    try testing.expectEqual(@as(u8, 0), px[3]);
    // The background near the top left edge, inside the corner radius.
    const bg = px[(32 * 64 + 6) * 4 ..][0..4];
    try testing.expectEqualSlices(u8, &.{ 0x1f, 0x26, 0x33, 0xff }, bg);
    // The bottom tier, left of the stairs.
    const tier = px[(46 * 64 + 20) * 4 ..][0..4];
    try testing.expectEqualSlices(u8, &.{ 0xf2, 0xb5, 0x44, 0xff }, tier);
}

test "icongen: detail layers only from 32 px" {
    const small = try render(testing.allocator, 16);
    defer testing.allocator.free(small);
    // The stairway column (x = 512/1024) on the bottom tier is sand at 16 px.
    const s = small[(11 * 16 + 8) * 4 ..][0..4];
    try testing.expectEqualSlices(u8, &.{ 0xf2, 0xb5, 0x44, 0xff }, s);
}
