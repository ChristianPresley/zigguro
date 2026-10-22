//! X11 cursors (E01.F05.S02.T01): Xcursor theme images (shared with
//! Wayland, `linux/xcursor.zig`) become ARGB cursors through RENDER
//! (`CreateCursor`, and `CreateAnimCursor` for animated ones); without
//! RENDER or a theme image, core glyph cursors from the "cursor" font.
//! `hidden` is a transparent 1×1 cursor. Cursors are created on first use
//! and cached per shape and size.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("proto.zig");
const Conn = @import("conn.zig").Conn;
const FdQueue = @import("../wayland/wire/fdqueue.zig").FdQueue;
const CursorShape = @import("../api/cursor.zig").CursorShape;
const xcursor = @import("../linux/xcursor.zig");
const Theme = @import("../wayland/cursor.zig").Theme;

const log = std.log.scoped(.x11);

/// OpenFont (45).
pub const OpenFont = struct {
    /// The major opcode.
    pub const opcode = 45;
    fid: u32,
    name_len: u16,
    _pad: [2]u8 = .{ 0, 0 },
    name: []const u8,
};

/// CloseFont (46).
pub const CloseFont = struct {
    /// The major opcode.
    pub const opcode = 46;
    font: u32,
};

/// CreatePixmap (53); `data` is the depth.
pub const CreatePixmap = struct {
    /// The major opcode.
    pub const opcode = 53;
    data: u8,
    pid: u32,
    drawable: u32,
    width: u16,
    height: u16,
};

/// CreateGlyphCursor (94): black on white.
pub const CreateGlyphCursor = struct {
    /// The major opcode.
    pub const opcode = 94;
    cid: u32,
    source_font: u32,
    mask_font: u32,
    source_char: u16,
    mask_char: u16,
    fore_red: u16 = 0,
    fore_green: u16 = 0,
    fore_blue: u16 = 0,
    back_red: u16 = 0xffff,
    back_green: u16 = 0xffff,
    back_blue: u16 = 0xffff,
};

/// FreeCursor (95).
pub const FreeCursor = struct {
    /// The major opcode.
    pub const opcode = 95;
    cursor: u32,
};

/// RENDER QueryVersion; required before other RENDER requests.
pub const RenderQueryVersion = struct {
    /// The extension that owns this request.
    pub const extension = "RENDER";
    /// The minor opcode.
    pub const minor = 0;
    client_major: u32 = 0,
    client_minor: u32 = 11,

    /// The server's version.
    pub const Reply = struct {
        major: u32,
        minor: u32,
        /// Decodes the reply from its wire bytes.
        pub fn decode(b: []const u8, _: *FdQueue) proto.DecodeError!Reply {
            if (b.len < 32) return error.Malformed;
            return .{ .major = std.mem.readInt(u32, b[8..12], .little), .minor = std.mem.readInt(u32, b[12..16], .little) };
        }
    };
};

/// RENDER QueryPictFormats; the reply keeps only the ARGB32 format.
pub const RenderQueryPictFormats = struct {
    /// The extension that owns this request.
    pub const extension = "RENDER";
    /// The minor opcode.
    pub const minor = 1;

    /// The ARGB32 picture format, if the server has one.
    pub const Reply = struct {
        argb32: ?u32,
        /// Decodes the reply from its wire bytes.
        pub fn decode(b: []const u8, _: *FdQueue) proto.DecodeError!Reply {
            return .{ .argb32 = try findArgb32(b) };
        }
    };
};

/// RENDER CreatePicture with no attributes.
pub const RenderCreatePicture = struct {
    /// The extension that owns this request.
    pub const extension = "RENDER";
    /// The minor opcode.
    pub const minor = 4;
    pid: u32,
    drawable: u32,
    format: u32,
    value_mask: u32 = 0,
};

/// RENDER FreePicture.
pub const RenderFreePicture = struct {
    /// The extension that owns this request.
    pub const extension = "RENDER";
    /// The minor opcode.
    pub const minor = 7;
    picture: u32,
};

/// RENDER CreateCursor (0.5+): a cursor from an ARGB picture.
pub const RenderCreateCursor = struct {
    /// The extension that owns this request.
    pub const extension = "RENDER";
    /// The minor opcode.
    pub const minor = 27;
    cid: u32,
    source: u32,
    x: u16,
    y: u16,
};

/// RENDER CreateAnimCursor (0.8+): `frames` is (cursor, delay ms) pairs.
pub const RenderCreateAnimCursor = struct {
    /// The extension that owns this request.
    pub const extension = "RENDER";
    /// The minor opcode.
    pub const minor = 31;
    cid: u32,
    frames: []const u32,
};

/// The ARGB32 format in a QueryPictFormats reply: direct, depth 32, alpha
/// at 24, red 16, green 8, blue 0, 8 bits each.
pub fn findArgb32(b: []const u8) proto.DecodeError!?u32 {
    if (b.len < 32) return error.Malformed;
    const n = std.mem.readInt(u32, b[8..12], .little);
    if (n > (b.len - 32) / 28) return error.Malformed;
    for (0..n) |i| {
        const f = b[32 + i * 28 ..][0..28];
        const h = struct {
            fn at(x: *const [28]u8, o: usize) u16 {
                return std.mem.readInt(u16, x[o..][0..2], .little);
            }
        };
        if (f[4] != 1 or f[5] != 32) continue; // Direct, depth 32
        if (h.at(f, 8) == 16 and h.at(f, 10) == 0xff and h.at(f, 12) == 8 and h.at(f, 14) == 0xff and
            h.at(f, 16) == 0 and h.at(f, 18) == 0xff and h.at(f, 20) == 24 and h.at(f, 22) == 0xff)
            return std.mem.readInt(u32, f[0..4], .little);
    }
    return null;
}

/// The "cursor" font glyph for `shape` (X11 cursorfont.h); the mask is
/// the next glyph.
pub fn glyphFor(shape: CursorShape) u16 {
    return switch (shape) {
        .default, .context_menu, .copy, .alias, .hidden => 68, // left_ptr
        .text, .vertical_text => 152, // xterm
        .pointer => 60, // hand2
        .wait, .progress => 150, // watch
        .crosshair => 34, // crosshair
        .cell, .zoom_in, .zoom_out => 90, // plus
        .not_allowed, .no_drop => 0, // X_cursor
        .grab => 58, // hand1
        .grabbing, .move, .all_scroll => 52, // fleur
        .ew_resize, .col_resize => 108, // sb_h_double_arrow
        .ns_resize, .row_resize => 116, // sb_v_double_arrow
        .nesw_resize => 136, // top_right_corner
        .nwse_resize => 14, // bottom_right_corner
        .help => 92, // question_arrow
    };
}

/// Created cursors, by shape and size.
pub const Cursors = struct {
    theme: ?Theme,
    /// RENDER state: probed once.
    probed: bool = false,
    argb: ?u32 = null,
    anim: bool = false,
    /// The "cursor" font, once opened.
    font: u32 = 0,
    cache: std.ArrayList(Entry) = .empty,

    const Entry = struct { shape: CursorShape, size_px: u32, xid: u32 };

    /// Reads the theme settings (`XCURSOR_THEME`, `XCURSOR_SIZE`,
    /// `XCURSOR_PATH`).
    pub fn init(gpa: Allocator, env: ?*const std.process.Environ.Map) Cursors {
        return .{ .theme = Theme.fromEnv(gpa, env) catch null };
    }

    /// Frees the cursors and the font.
    pub fn deinit(c: *Cursors, gpa: Allocator, conn: *Conn) void {
        for (c.cache.items) |e| _ = conn.request(FreeCursor, .{ .cursor = e.xid }, &.{}) catch {};
        if (c.font != 0) _ = conn.request(CloseFont, .{ .font = c.font }, &.{}) catch {};
        c.cache.deinit(gpa);
        if (c.theme) |*t| t.deinit(gpa);
        c.* = undefined;
    }

    /// The theme's logical cursor size.
    pub fn baseSize(c: *const Cursors) u32 {
        return if (c.theme) |t| t.size else 24;
    }

    /// The cursor for `shape` at `size_px`, created on first use.
    pub fn get(c: *Cursors, gpa: Allocator, io: std.Io, conn: *Conn, shape: CursorShape, size_px: u32) !u32 {
        for (c.cache.items) |e| if (e.shape == shape and e.size_px == size_px) return e.xid;
        try c.cache.ensureUnusedCapacity(gpa, 1);
        c.probe(conn);
        const xid = try c.create(gpa, io, conn, shape, size_px);
        c.cache.appendAssumeCapacity(.{ .shape = shape, .size_px = size_px, .xid = xid });
        return xid;
    }

    fn probe(c: *Cursors, conn: *Conn) void {
        if (c.probed) return;
        c.probed = true;
        if (conn.extension("RENDER") == null) return;
        const v = conn.reply(conn.request(RenderQueryVersion, .{}, &.{}) catch return) catch return;
        if (v.major == 0 and v.minor < 5) return;
        c.anim = v.major > 0 or v.minor >= 8;
        const f = conn.reply(conn.request(RenderQueryPictFormats, .{}, &.{}) catch return) catch return;
        c.argb = f.argb32;
    }

    fn create(c: *Cursors, gpa: Allocator, io: std.Io, conn: *Conn, shape: CursorShape, size_px: u32) !u32 {
        if (c.argb != null) {
            if (shape == .hidden) {
                var clear = [_]u32{0};
                return c.imageCursor(conn, .{ .width = 1, .height = 1, .hot_x = 0, .hot_y = 0, .delay_ms = 0, .pixels = &clear });
            }
            if (c.theme) |*t| if (t.load(gpa, io, shape, size_px)) |frames_in| {
                var frames = frames_in;
                defer frames.deinit(gpa);
                return c.framesCursor(gpa, conn, frames.frames);
            };
        }
        if (shape == .hidden) log.info("no RENDER: hidden shows the arrow", .{});
        return c.glyphCursor(conn, glyphFor(shape));
    }

    fn framesCursor(c: *Cursors, gpa: Allocator, conn: *Conn, frames: []const xcursor.CursorImage) !u32 {
        if (frames.len == 1 or !c.anim) return c.imageCursor(conn, frames[0]);
        const pairs = try gpa.alloc(u32, frames.len * 2);
        defer gpa.free(pairs);
        var made: usize = 0;
        defer for (0..made) |i| {
            _ = conn.request(FreeCursor, .{ .cursor = pairs[i * 2] }, &.{}) catch {};
        };
        for (frames, 0..) |f, i| {
            pairs[i * 2] = try c.imageCursor(conn, f);
            pairs[i * 2 + 1] = f.delay_ms;
            made += 1;
        }
        const cid = try conn.newXid();
        _ = try conn.request(RenderCreateAnimCursor, .{ .cid = cid, .frames = pairs }, &.{});
        return cid;
    }

    /// An ARGB cursor from `img` (premultiplied, as Xcursor stores it).
    fn imageCursor(c: *Cursors, conn: *Conn, img: xcursor.CursorImage) !u32 {
        const root = conn.screen().root;
        const pixmap = try conn.newXid();
        const gc = try conn.newXid();
        const pic = try conn.newXid();
        const cid = try conn.newXid();
        const w: u16 = @intCast(img.width);
        const h: u16 = @intCast(img.height);
        _ = try conn.request(CreatePixmap, .{ .data = 32, .pid = pixmap, .drawable = root, .width = w, .height = h }, &.{});
        defer _ = conn.request(proto.FreePixmap, .{ .pixmap = pixmap }, &.{}) catch {};
        _ = try conn.request(proto.CreateGC, .{ .cid = gc, .drawable = pixmap }, &.{});
        defer _ = conn.request(proto.FreeGC, .{ .gc = gc }, &.{}) catch {};
        _ = try conn.request(proto.PutImage, .{ .drawable = pixmap, .gc = gc, .width = w, .height = h, .dst_x = 0, .dst_y = 0, .depth = 32, .pixels = std.mem.sliceAsBytes(img.pixels) }, &.{});
        _ = try conn.request(RenderCreatePicture, .{ .pid = pic, .drawable = pixmap, .format = c.argb.? }, &.{});
        defer _ = conn.request(RenderFreePicture, .{ .picture = pic }, &.{}) catch {};
        _ = try conn.request(RenderCreateCursor, .{ .cid = cid, .source = pic, .x = @intCast(@min(img.hot_x, img.width - 1)), .y = @intCast(@min(img.hot_y, img.height - 1)) }, &.{});
        return cid;
    }

    fn glyphCursor(c: *Cursors, conn: *Conn, glyph: u16) !u32 {
        if (c.font == 0) {
            const fid = try conn.newXid();
            const name = "cursor";
            _ = try conn.request(OpenFont, .{ .fid = fid, .name_len = name.len, .name = name }, &.{});
            c.font = fid;
        }
        const cid = try conn.newXid();
        _ = try conn.request(CreateGlyphCursor, .{ .cid = cid, .source_font = c.font, .mask_font = c.font, .source_char = glyph, .mask_char = glyph + 1 }, &.{});
        return cid;
    }
};

const testing = std.testing;

test "ARGB32 picture format lookup" {
    var b: [32 + 3 * 28]u8 = @splat(0);
    std.mem.writeInt(u32, b[8..12], 3, .little);
    const put = struct {
        fn f(buf: []u8, i: usize, id: u32, depth: u8, shifts: [4]u16) void {
            const e = buf[32 + i * 28 ..][0..28];
            std.mem.writeInt(u32, e[0..4], id, .little);
            e[4] = 1;
            e[5] = depth;
            for (shifts, 0..) |s, k| {
                std.mem.writeInt(u16, e[8 + k * 4 ..][0..2], s, .little);
                std.mem.writeInt(u16, e[10 + k * 4 ..][0..2], 0xff, .little);
            }
        }
    }.f;
    put(&b, 0, 0x20, 24, .{ 16, 8, 0, 0 });
    put(&b, 1, 0x21, 32, .{ 0, 8, 16, 24 }); // ABGR
    put(&b, 2, 0x22, 32, .{ 16, 8, 0, 24 });
    try testing.expectEqual(@as(?u32, 0x22), try findArgb32(&b));
    std.mem.writeInt(u32, b[8..12], 2, .little);
    try testing.expectEqual(@as(?u32, null), try findArgb32(&b));
    std.mem.writeInt(u32, b[8..12], 4, .little);
    try testing.expectError(error.Malformed, findArgb32(&b));
}

test "every shape has a cursor-font glyph" {
    for (std.enums.values(CursorShape)) |s| {
        const g = glyphFor(s);
        try testing.expect(g % 2 == 0 and g <= 152);
    }
    try testing.expectEqual(152, glyphFor(.text));
    try testing.expectEqual(108, glyphFor(.ew_resize));
}
