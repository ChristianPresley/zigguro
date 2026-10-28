//! Inline images in the terminal view (E06.F08.S01.T01): each image a
//! placement on screen shows gets an app texture, uploaded once and kept
//! while the image lives (the texture borrows the image's pixels, which it
//! holds a reference to). `draw` paints the placements of one z band that
//! cross the viewport, clipped by the caller.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_terminal = @import("zg_terminal");

const Allocator = std.mem.Allocator;
const ImageTextures = zg_gui.image.ImageTextures;
const TextureId = zg_gui.paint.canvas.TextureId;
const PaintCx = zg_gui.paint.PaintCx;
const Rect = zg_gui.core.Rect;
const Terminal = zg_terminal.Terminal;
const Pixels = zg_terminal.graphics.Pixels;

pub const Images = struct {
    /// The app's allocator (the texture table's).
    gpa: Allocator,
    textures: *ImageTextures,
    entries: std.AutoHashMapUnmanaged(u32, Entry) = .empty,
    /// The store serial last synced.
    serial: u64 = std.math.maxInt(u64),

    const Entry = struct { tex: TextureId, pixels: *Pixels };

    pub fn init(gpa: Allocator, textures: *ImageTextures) Images {
        return .{ .gpa = gpa, .textures = textures };
    }

    pub fn deinit(im: *Images) void {
        var it = im.entries.valueIterator();
        while (it.next()) |e| im.drop(e.*);
        im.entries.deinit(im.gpa);
    }

    fn drop(im: *Images, e: Entry) void {
        im.textures.remove(im.gpa, e.tex);
        e.pixels.release();
    }

    /// Drops the textures of images the store no longer has (or replaced).
    pub fn sync(im: *Images, store: *zg_terminal.graphics.Store) void {
        if (store.serial == im.serial) return;
        im.serial = store.serial;
        var it = im.entries.iterator();
        var stale: [64]u32 = undefined;
        var n: usize = 0;
        while (it.next()) |kv| {
            const img = store.get(kv.key_ptr.*);
            if (img == null or img.?.pixels != kv.value_ptr.pixels) {
                if (n == stale.len) break;
                stale[n] = kv.key_ptr.*;
                n += 1;
            }
        }
        for (stale[0..n]) |id| if (im.entries.fetchRemove(id)) |kv| im.drop(kv.value);
        // More than fit in one pass: the next frame continues.
        if (n == stale.len) im.serial = std.math.maxInt(u64);
    }

    fn texture(im: *Images, img: *const zg_terminal.graphics.Image) ?TextureId {
        if (im.entries.get(img.id)) |e| if (e.pixels == img.pixels) return e.tex;
        const px = img.pixels;
        const tex = im.textures.add(im.gpa, px.w, px.h, px.rgba) catch return null;
        im.entries.put(im.gpa, img.id, .{ .tex = tex, .pixels = px.retain() }) catch {
            im.textures.remove(im.gpa, tex);
            px.release();
            return null;
        };
        return tex;
    }

    pub const Geometry = struct {
        /// The grid's top-left corner.
        left: f32,
        top: f32,
        cw: f32,
        ch: f32,
        /// The view's height (placements wholly below are skipped).
        height: f32,
    };

    /// Draws the placements on the active screen with `z < 0` (`below`)
    /// or `z >= 0`.
    pub fn draw(im: *Images, pc: *PaintCx, t: *Terminal, g: Geometry, below: bool) void {
        const store = &t.images;
        im.sync(store);
        if (store.placements.items.len == 0) return;
        const screen = t.screen();
        const sid: zg_terminal.graphics.store.ScreenId = if (t.alt_active) .alternate else .primary;
        const top_row = screen.pages.rowIndex(screen.pages.viewportRow(0));
        // Cell pixels to view units.
        const sx = if (t.cell_px.w > 0) g.cw / @as(f32, @floatFromInt(t.cell_px.w)) else 1;
        const sy = if (t.cell_px.h > 0) g.ch / @as(f32, @floatFromInt(t.cell_px.h)) else 1;
        for (store.placements.items) |*p| {
            if (p.screen != sid or p.virtual or p.pin.garbage) continue;
            if ((p.z < 0) != below) continue;
            const img = store.get(p.image_id) orelse continue;
            const row = @as(f64, @floatFromInt(screen.pages.rowIndex(p.pin.pin))) - @as(f64, @floatFromInt(top_row));
            const dst: Rect = .{
                .x = g.left + @as(f32, @floatFromInt(p.pin.pin.x)) * g.cw + @as(f32, @floatFromInt(p.off_x)) * sx,
                .y = g.top + @as(f32, @floatCast(row)) * g.ch + @as(f32, @floatFromInt(p.off_y)) * sy,
                .w = @as(f32, @floatFromInt(p.px_w)) * sx,
                .h = @as(f32, @floatFromInt(p.px_h)) * sy,
            };
            if (dst.y + dst.h <= 0 or dst.y >= g.height or dst.w <= 0 or dst.h <= 0) continue;
            const tex = im.texture(img) orelse continue;
            const iw: f32 = @floatFromInt(img.pixels.w);
            const ih: f32 = @floatFromInt(img.pixels.h);
            const uv: Rect = .{
                .x = @as(f32, @floatFromInt(p.src_x)) / iw,
                .y = @as(f32, @floatFromInt(p.src_y)) / ih,
                .w = @as(f32, @floatFromInt(p.src_w)) / iw,
                .h = @as(f32, @floatFromInt(p.src_h)) / ih,
            };
            pc.image(tex, dst, uv, .{ .r = 255, .g = 255, .b = 255 }, 0);
        }
    }
};
