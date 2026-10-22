//! Benchmarks for zg_vulkan; run with `zig build bench` at the repo root
//! (`-Dbench-filter=drawlist|sw|tlsf`).

const std = @import("std");
const zg_core = @import("zg_core");
const zg_vulkan = @import("zg_vulkan");
const platform = @import("zg_platform");
const bench = zg_core.bench;
const r2d = zg_vulkan.r2d;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

const DlCtx = struct { dl: *r2d.DrawList };

fn register(b: *bench.Bench) !void {
    const gpa = std.heap.page_allocator;
    var dl = r2d.DrawList.init(gpa);
    // Budget: < 15 ns per appended prim.
    try b.run("drawlist append 100k prims", DlCtx{ .dl = &dl }, struct {
        fn f(c: DlCtx, s: *bench.State) void {
            var i: u64 = 0;
            while (i < s.iterations()) : (i += 1) {
                c.dl.reset(.{ .w = 2560, .h = 1600 }, 1);
                var k: u32 = 0;
                while (k < 100_000) : (k += 1) {
                    const x: f32 = @floatFromInt(k % 400);
                    const y: f32 = @floatFromInt(k / 400);
                    c.dl.rect(.{ .x = x * 6, .y = y * 6, .w = 5, .h = 5 }, r2d.Color.white, .{});
                }
                bench.doNotOptimizeAway(c.dl.prims.items.len);
            }
        }
    }.f);

    // Budget: 1080p full redraw < 8 ms on 8 threads; keystroke damage < 1 ms.
    var sink: platform.surface.HeadlessSink = .{ .ptr = undefined, .write = undefined };
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const sw = try zg_vulkan.sw.SwRenderer.create(gpa, io, .{ .target = .{ .headless = &sink }, .sw_threads = 8 });
    const tex = try zg_vulkan.testing.parity.Textures.create(gpa, sw.renderer());
    var img = try zg_vulkan.testing.CpuImage.init(gpa, 1920, 1080);
    var scene = r2d.DrawList.init(gpa);
    scene.setGlyphPages(&tex.pages);
    buildEditor(&scene);
    const Sw = struct { sw: *zg_vulkan.sw.SwRenderer, dl: *r2d.DrawList, img: *zg_vulkan.testing.CpuImage };
    const ctx: Sw = .{ .sw = sw, .dl = &scene, .img = &img };
    try b.run("sw 1080p full redraw", ctx, struct {
        fn f(c: Sw, s: *bench.State) void {
            c.dl.damageAll();
            var i: u64 = 0;
            while (i < s.iterations()) : (i += 1) _ = c.sw.renderToImage(c.dl, c.img) catch unreachable;
        }
    }.f);
    try b.run("sw 1080p keystroke damage", ctx, struct {
        fn f(c: Sw, s: *bench.State) void {
            c.dl.damage_full = false;
            c.dl.damage_len = 0;
            c.dl.addDamage(.{ .x = 300, .y = 400, .w = 400, .h = 14 });
            c.dl.addDamage(.{ .x = 0, .y = 400, .w = 48, .h = 14 });
            var i: u64 = 0;
            while (i < s.iterations()) : (i += 1) _ = c.sw.renderToImage(c.dl, c.img) catch unreachable;
        }
    }.f);

    try b.run("tlsf alloc/free mix", {}, struct {
        fn f(_: void, s: *bench.State) void {
            var t = zg_vulkan.mem.Tlsf.init(std.heap.page_allocator, 256 << 20, .{}) catch unreachable;
            defer t.deinit();
            var live: [256]u32 = undefined;
            var n: usize = 0;
            var x: u64 = 0x9e3779b97f4a7c15;
            var i: u64 = 0;
            while (i < s.iterations()) : (i += 1) {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                if (n == live.len or (n > 0 and x & 1 == 1)) {
                    const k = (x >> 8) % n;
                    t.free(live[k]);
                    live[k] = live[n - 1];
                    n -= 1;
                } else if (t.alloc(256 + (x >> 20) % 65536, 256) catch unreachable) |r| {
                    live[n] = r.handle;
                    n += 1;
                }
            }
        }
    }.f);
}

/// The reference editor frame: gutter, ~25k glyphs, ~3k rects, shadows.
fn buildEditor(dl: *r2d.DrawList) void {
    dl.reset(.{ .w = 1920, .h = 1080 }, 1);
    dl.rect(.{ .x = 0, .y = 0, .w = 1920, .h = 1080 }, r2d.Color.fromHex("#1e1f24"), .{});
    var i: u32 = 0;
    while (i < 50) : (i += 1) dl.shadow(.{ .x = @floatFromInt((i * 37) % 1800), .y = @floatFromInt((i * 53) % 1000), .w = 80, .h = 40 }, r2d.Radii.all(6), 6, 0, .{ .r = 0, .g = 0, .b = 0, .a = 90 });
    var row: u32 = 0;
    while (row < 77) : (row += 1) {
        const y: f32 = @floatFromInt(row * 14);
        dl.rect(.{ .x = 0, .y = y, .w = 48, .h = 14 }, r2d.Color.fromHex("#25262c"), .{});
        var col: u32 = 0;
        var buf: [320]r2d.GlyphQuad = undefined;
        while (col < 320) : (col += 1) buf[col] = zg_vulkan.testing.synthetic_atlas.quad(row + col, 52 + @as(f32, @floatFromInt(col)) * 5.8, y, 12, 0, .r8);
        dl.glyphs(&buf, r2d.Color.fromHex("#c8ccd4"), .grayscale);
        var k: u32 = 0;
        while (k < 38) : (k += 1) dl.rect(.{ .x = @floatFromInt(60 + k * 48), .y = y + 12, .w = 30, .h = 1 }, r2d.Color.fromHex("#3e4452"), .{});
    }
}
