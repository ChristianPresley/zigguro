//! The glyph atlas: CPU copies of the GPU texture pages that hold glyph
//! bitmaps, packed with a skyline per page, evicted a whole page at a time
//! (least recently used first), with dirty regions handed to E02 for
//! upload.
//!
//! Contract with E02 (`AtlasBridge.apply`): pages are only appended to,
//! or cleared whole on eviction (which re-uploads the whole page). A
//! region already uploaded and sampled is never rewritten in place.
//! Texels outside every uploaded region are never sampled (each glyph's
//! region includes its 1 px transparent border), so a new page's texture
//! needs no initial upload.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bitmap = @import("../raster/rasterizer.zig").Bitmap;
const skyline = @import("skyline.zig");
const Skyline = skyline.Skyline;

/// Texture formats of atlas pages (identical to E02's `AtlasFormat`).
/// `rgb_subpixel` texels are 4 bytes: r, g, b coverage and their max.
pub const AtlasFormat = enum(u8) { r8, rgb_subpixel, rgba_color };

/// The page format a bitmap goes to.
pub fn formatOf(f: Bitmap.Format) AtlasFormat {
    return switch (f) {
        .gray8, .sdf8 => .r8,
        .lcd_rgb8x3 => .rgb_subpixel,
        .rgba8_premul => .rgba_color,
    };
}

/// Bytes per texel of a page format.
pub fn bytesPerPixel(f: AtlasFormat) u8 {
    return switch (f) {
        .r8 => 1,
        .rgb_subpixel, .rgba_color => 4,
    };
}

/// A rectangle of texels.
pub const PxRect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,

    fn area(r: PxRect) u64 {
        return @as(u64, r.w) * r.h;
    }

    fn unite(a: PxRect, b: PxRect) PxRect {
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        const x1 = @max(a.x + a.w, b.x + b.w);
        const y1 = @max(a.y + a.h, b.y + b.h);
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
};

/// Where a glyph bitmap lives: its texels (without the border) on a page,
/// and the bitmap's placement relative to the pen. An empty glyph has
/// w = h = 0 and no page storage.
pub const AtlasEntry = struct {
    page: u16 = 0,
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,
    left: i16 = 0,
    top: i16 = 0,
    format: Bitmap.Format = .gray8,

    /// True for a glyph with no texels.
    pub fn isEmpty(e: AtlasEntry) bool {
        return e.w == 0 or e.h == 0;
    }
};

/// One glyph to draw, laid out exactly as E02's `GlyphQuad` (zg_vulkan
/// cannot be imported here; E04 converts with a comptime layout check).
pub const GlyphQuad = extern struct {
    /// x, y, w, h in pixels.
    dst: [4]f32,
    /// x, y, w, h in texels of the page.
    uv: [4]f32,
    page: u16,
    format: AtlasFormat,
    _p: u8 = 0,
};

comptime {
    std.debug.assert(@sizeOf(GlyphQuad) == 36);
    std.debug.assert(@offsetOf(GlyphQuad, "uv") == 16);
    std.debug.assert(@offsetOf(GlyphQuad, "page") == 32);
    std.debug.assert(@offsetOf(GlyphQuad, "format") == 34);
}

/// The quad for `e` with the pen at (`pen_x`, `baseline_y`), the bitmap
/// drawn at `scale` (1 for pixel-exact glyphs; SDF and downscaled strikes
/// use others).
pub fn quadFor(e: AtlasEntry, pen_x: f32, baseline_y: f32, scale: f32) GlyphQuad {
    const w: f32 = @floatFromInt(e.w);
    const h: f32 = @floatFromInt(e.h);
    return .{
        .dst = .{ pen_x + @as(f32, @floatFromInt(e.left)) * scale, baseline_y + @as(f32, @floatFromInt(e.top)) * scale, w * scale, h * scale },
        .uv = .{ @floatFromInt(e.x), @floatFromInt(e.y), w, h },
        .page = e.page,
        .format = formatOf(e.format),
    };
}

/// Page sizes and how many pages each format may use.
pub const AtlasOptions = struct {
    /// Texels per side; clamped to `max_texture_dim`.
    page_size: u16 = 2048,
    /// E02's largest texture side.
    max_texture_dim: u16 = 2048,
    max_gray_pages: u16 = 4,
    max_lcd_pages: u16 = 2,
    max_color_pages: u16 = 2,
};

/// A region of a page to upload: valid until the next `insert`.
pub const AtlasUpdate = struct {
    page: u16,
    format: AtlasFormat,
    page_size: u16,
    rect: PxRect,
    /// The rect's first texel onwards; rows are `row_pitch` bytes apart.
    pixels: []const u8,
    row_pitch: u32,
};

/// Dirty regions kept per page before they collapse into one.
const max_dirty = 16;

const Page = struct {
    format: AtlasFormat,
    pixels: []u8,
    sky: Skyline,
    last_used: u32 = 0,
    dirty: [max_dirty]PxRect = undefined,
    n_dirty: u8 = 0,

    /// Adds `r`, merging regions whose union is at most 1.3× their areas
    /// (the extra upload is cheaper than another copy), and collapsing to
    /// the bounding box past `max_dirty`.
    fn markDirty(p: *Page, r_in: PxRect) void {
        var r = r_in;
        var i: usize = 0;
        while (i < p.n_dirty) {
            const u = r.unite(p.dirty[i]);
            if (u.area() * 10 <= (r.area() + p.dirty[i].area()) * 13) {
                r = u;
                p.n_dirty -= 1;
                p.dirty[i] = p.dirty[p.n_dirty];
                i = 0; // the grown region may now merge with others
            } else i += 1;
        }
        if (p.n_dirty == max_dirty) {
            for (p.dirty[0..p.n_dirty]) |d| r = r.unite(d);
            p.n_dirty = 0;
        }
        p.dirty[p.n_dirty] = r;
        p.n_dirty += 1;
    }
};

/// The atlas. Page ids are unique across formats.
pub const Atlas = struct {
    gpa: Allocator,
    opts: AtlasOptions,
    page_size: u16,
    pages: std.ArrayList(Page) = .empty,
    /// The page each format inserted into last, tried first.
    last: [3]?u16 = @splat(null),
    evict_ctx: ?*anyopaque = null,
    evict_cb: ?*const fn (*anyopaque, page: u16) void = null,

    /// An empty atlas; pages are added as glyphs arrive.
    pub fn init(gpa: Allocator, opts: AtlasOptions) Allocator.Error!Atlas {
        const n = @as(usize, opts.max_gray_pages) + opts.max_lcd_pages + opts.max_color_pages;
        var a: Atlas = .{ .gpa = gpa, .opts = opts, .page_size = @max(1, @min(opts.page_size, opts.max_texture_dim)) };
        try a.pages.ensureTotalCapacity(gpa, n);
        return a;
    }

    /// Frees every page.
    pub fn deinit(a: *Atlas) void {
        for (a.pages.items) |*p| {
            a.gpa.free(p.pixels);
            p.sky.deinit();
        }
        a.pages.deinit(a.gpa);
        a.* = undefined;
    }

    /// `cb(ctx, page)` runs when `page` is about to be cleared, so the
    /// glyph cache can drop the entries on it.
    pub fn setEvictCallback(a: *Atlas, ctx: *anyopaque, cb: *const fn (*anyopaque, page: u16) void) void {
        a.evict_ctx = ctx;
        a.evict_cb = cb;
    }

    /// Records that `page` was drawn from in `frame` (one store; the glyph
    /// cache calls it on every hit).
    pub inline fn touch(a: *Atlas, page: u16, frame: u32) void {
        a.pages.items[page].last_used = frame;
    }

    /// Copies `bmp` into a page of its format with a 1 px transparent
    /// border (none for SDF, whose spread is its border). When no page has
    /// room, a new page is added up to the format's limit, else the least
    /// recently used page not used in `frame` is evicted. `AtlasFull` means
    /// every page was used this frame; `TooLarge`, that the bitmap exceeds
    /// a page.
    pub fn insert(a: *Atlas, bmp: *const Bitmap, frame: u32) error{ AtlasFull, TooLarge, OutOfMemory }!AtlasEntry {
        var e: AtlasEntry = .{ .left = bmp.left, .top = bmp.top, .format = bmp.format };
        if (bmp.isEmpty()) return e;
        const fmt = formatOf(bmp.format);
        const pad: u16 = if (bmp.format == .sdf8) 0 else 1;
        if (@as(u32, bmp.width) + 2 * pad > a.page_size or @as(u32, bmp.height) + 2 * pad > a.page_size) return error.TooLarge;
        const w = bmp.width + 2 * pad;
        const h = bmp.height + 2 * pad;
        const fi = @intFromEnum(fmt);
        const id, const pos = a.place(fmt, w, h) orelse blk: {
            // No page of this format has room: add one, or evict.
            const id = if (a.count(fmt) < a.limit(fmt)) try a.addPage(fmt) else try a.evictFor(fmt, frame);
            const pos = a.pages.items[id].sky.alloc(w, h) orelse return error.TooLarge;
            break :blk .{ id, pos };
        };
        a.last[fi] = id;
        const p = &a.pages.items[id];
        p.last_used = @max(p.last_used, frame);
        e.page = id;
        e.x = pos.x + pad;
        e.y = pos.y + pad;
        e.w = bmp.width;
        e.h = bmp.height;
        a.copyIn(p, bmp, e.x, e.y);
        p.markDirty(.{ .x = pos.x, .y = pos.y, .w = w, .h = h });
        return e;
    }

    /// Appends the dirty regions of every page to `out` and clears them.
    /// Their pixels stay valid until the next `insert`.
    pub fn takeUpdates(a: *Atlas, out: *std.ArrayList(AtlasUpdate), gpa: Allocator) Allocator.Error!void {
        for (a.pages.items, 0..) |*p, id| {
            const bpp = bytesPerPixel(p.format);
            const pitch = @as(u32, a.page_size) * bpp;
            try out.ensureUnusedCapacity(gpa, p.n_dirty);
            for (p.dirty[0..p.n_dirty]) |r| {
                const start = @as(usize, r.y) * pitch + @as(usize, r.x) * bpp;
                const len = @as(usize, r.h - 1) * pitch + @as(usize, r.w) * bpp;
                out.appendAssumeCapacity(.{ .page = @intCast(id), .format = p.format, .page_size = a.page_size, .rect = r, .pixels = p.pixels[start..][0..len], .row_pitch = pitch });
            }
            p.n_dirty = 0;
        }
    }

    /// Marks every page dirty in full (after E02 loses its device).
    pub fn markAllDirty(a: *Atlas) void {
        for (a.pages.items) |*p| {
            p.n_dirty = 1;
            p.dirty[0] = .{ .x = 0, .y = 0, .w = a.page_size, .h = a.page_size };
        }
    }

    /// The format of page `id`.
    pub fn pageFormat(a: *const Atlas, id: u16) AtlasFormat {
        return a.pages.items[id].format;
    }

    fn limit(a: *const Atlas, fmt: AtlasFormat) u16 {
        return switch (fmt) {
            .r8 => a.opts.max_gray_pages,
            .rgb_subpixel => a.opts.max_lcd_pages,
            .rgba_color => a.opts.max_color_pages,
        };
    }

    fn count(a: *const Atlas, fmt: AtlasFormat) u16 {
        var n: u16 = 0;
        for (a.pages.items) |p| n += @intFromBool(p.format == fmt);
        return n;
    }

    /// A spot in an existing page of `fmt`, trying the last one used first.
    fn place(a: *Atlas, fmt: AtlasFormat, w: u16, h: u16) ?struct { u16, skyline.Pos } {
        if (a.last[@intFromEnum(fmt)]) |id| {
            if (a.pages.items[id].sky.alloc(w, h)) |pos| return .{ id, pos };
        }
        for (a.pages.items, 0..) |*p, id| {
            if (p.format != fmt or a.last[@intFromEnum(fmt)] == @as(u16, @intCast(id))) continue;
            if (p.sky.alloc(w, h)) |pos| return .{ @intCast(id), pos };
        }
        return null;
    }

    fn addPage(a: *Atlas, fmt: AtlasFormat) error{OutOfMemory}!u16 {
        const side: usize = a.page_size;
        const pixels = try a.gpa.alloc(u8, side * side * bytesPerPixel(fmt));
        errdefer a.gpa.free(pixels);
        @memset(pixels, 0);
        const sky = try Skyline.init(a.gpa, a.page_size, a.page_size);
        a.pages.appendAssumeCapacity(.{ .format = fmt, .pixels = pixels, .sky = sky });
        return @intCast(a.pages.items.len - 1);
    }

    /// Clears the least recently used page of `fmt` not used in `frame`.
    fn evictFor(a: *Atlas, fmt: AtlasFormat, frame: u32) error{AtlasFull}!u16 {
        var best: ?u16 = null;
        for (a.pages.items, 0..) |p, id| {
            if (p.format != fmt or p.last_used >= frame) continue;
            if (best == null or p.last_used < a.pages.items[best.?].last_used) best = @intCast(id);
        }
        const id = best orelse return error.AtlasFull;
        if (a.evict_cb) |cb| cb(a.evict_ctx.?, id);
        const p = &a.pages.items[id];
        p.sky.reset();
        @memset(p.pixels, 0);
        p.n_dirty = 1;
        p.dirty[0] = .{ .x = 0, .y = 0, .w = a.page_size, .h = a.page_size };
        if (a.last[@intFromEnum(fmt)] == id) a.last[@intFromEnum(fmt)] = null;
        return id;
    }

    fn copyIn(a: *const Atlas, p: *Page, bmp: *const Bitmap, x: u16, y: u16) void {
        const bpp = bytesPerPixel(p.format);
        const pitch = @as(usize, a.page_size) * bpp;
        for (0..bmp.height) |row| {
            const src = bmp.row(row);
            const dst = p.pixels[(y + row) * pitch + @as(usize, x) * bpp ..][0 .. @as(usize, bmp.width) * bpp];
            switch (bmp.format) {
                .gray8, .sdf8, .rgba8_premul => @memcpy(dst, src),
                .lcd_rgb8x3 => for (0..bmp.width) |i| {
                    const c = src[i * 3 ..][0..3];
                    dst[i * 4 ..][0..4].* = .{ c[0], c[1], c[2], @max(c[0], c[1], c[2]) };
                },
            }
        }
    }
};
