//! Cursors (E01.F02.S01.T03): `CursorShape` → a system `IDC_*` cursor, or
//! for the shapes Windows lacks, a cursor built at runtime from an
//! embedded 16×16 mask scaled to 32, 48 or 64 px by DPI. The mapping and
//! the rasterizer are pure and tested on every OS; `Cache` creates and
//! frees the `HCURSOR`s on Windows.

const std = @import("std");
const CursorShape = @import("../api/cursor.zig").CursorShape;
const is_windows = @import("builtin").os.tag == .windows;

/// System cursor ids (`IDC_*`).
pub const IDC = struct {
    /// IDC_ARROW.
    pub const ARROW: u16 = 32512;
    /// IDC_IBEAM.
    pub const IBEAM: u16 = 32513;
    /// IDC_WAIT.
    pub const WAIT: u16 = 32514;
    /// IDC_CROSS.
    pub const CROSS: u16 = 32515;
    /// IDC_SIZENWSE.
    pub const SIZENWSE: u16 = 32642;
    /// IDC_SIZENESW.
    pub const SIZENESW: u16 = 32643;
    /// IDC_SIZEWE.
    pub const SIZEWE: u16 = 32644;
    /// IDC_SIZENS.
    pub const SIZENS: u16 = 32645;
    /// IDC_SIZEALL.
    pub const SIZEALL: u16 = 32646;
    /// IDC_NO.
    pub const NO: u16 = 32648;
    /// IDC_HAND.
    pub const HAND: u16 = 32649;
    /// IDC_APPSTARTING.
    pub const APPSTARTING: u16 = 32650;
    /// IDC_HELP.
    pub const HELP: u16 = 32651;
};

/// A 16×16 cursor drawing: `#` black, `.` white, space transparent.
pub const Art = struct {
    rows: [16]*const [16]u8,
    hot_x: u8,
    hot_y: u8,
};

/// How a shape is shown on Windows.
pub const Native = union(enum) {
    /// A system cursor.
    system: u16,
    /// A cursor built from an embedded drawing.
    custom: *const Art,
    /// No cursor.
    hidden,
};

/// The Windows cursor for `shape`.
pub fn nativeOf(shape: CursorShape) Native {
    return switch (shape) {
        .default => .{ .system = IDC.ARROW },
        .text => .{ .system = IDC.IBEAM },
        .pointer => .{ .system = IDC.HAND },
        .wait => .{ .system = IDC.WAIT },
        .progress => .{ .system = IDC.APPSTARTING },
        .crosshair => .{ .system = IDC.CROSS },
        .not_allowed, .no_drop => .{ .system = IDC.NO },
        .move, .all_scroll => .{ .system = IDC.SIZEALL },
        .ew_resize => .{ .system = IDC.SIZEWE },
        .ns_resize => .{ .system = IDC.SIZENS },
        .nesw_resize => .{ .system = IDC.SIZENESW },
        .nwse_resize => .{ .system = IDC.SIZENWSE },
        .help => .{ .system = IDC.HELP },
        .grab => .{ .custom = &art.grab },
        .grabbing => .{ .custom = &art.grabbing },
        .copy => .{ .custom = &art.copy },
        .alias => .{ .custom = &art.alias },
        .context_menu => .{ .custom = &art.context_menu },
        .col_resize => .{ .custom = &art.col_resize },
        .row_resize => .{ .custom = &art.row_resize },
        .zoom_in => .{ .custom = &art.zoom_in },
        .zoom_out => .{ .custom = &art.zoom_out },
        .cell => .{ .custom = &art.cell },
        .vertical_text => .{ .custom = &art.vertical_text },
        .hidden => .hidden,
    };
}

/// The cursor edge in pixels for `dpi`: 32 at 100%, 48 up to 150%, then 64.
pub fn sizeForDpi(dpi: u32) u32 {
    if (dpi <= 96) return 32;
    if (dpi <= 144) return 48;
    return 64;
}

/// Scales `a` to `size`×`size` ARGB pixels (rows top-down, nearest
/// neighbour) and returns the scaled hotspot.
pub fn rasterize(a: *const Art, size: u32, out: []u32) [2]u32 {
    std.debug.assert(out.len >= size * size);
    for (0..size) |y| for (0..size) |x| {
        const c = a.rows[y * 16 / size][x * 16 / size];
        out[y * size + x] = switch (c) {
            '#' => 0xFF000000,
            '.' => 0xFFFFFFFF,
            else => 0,
        };
    };
    const f = size / 16;
    return .{ a.hot_x * f + f / 2, a.hot_y * f + f / 2 };
}

fn mk(comptime rows: [16]*const [16]u8, hx: u8, hy: u8) Art {
    return .{ .rows = rows, .hot_x = hx, .hot_y = hy };
}

/// An arrow with a 7×7 badge in the bottom-right corner.
fn badged(comptime badge: [7]*const [7]u8) Art {
    const arrow = [11]*const [8]u8{
        "#       ",
        "##      ",
        "#.#     ",
        "#..#    ",
        "#...#   ",
        "#....#  ",
        "#.....# ",
        "#..#### ",
        "#.#     ",
        "##      ",
        "#       ",
    };
    var rows: [16][16]u8 = @splat(@splat(' '));
    for (arrow, 0..) |r, y| @memcpy(rows[y][0..8], r);
    for (badge, 0..) |r, y| @memcpy(rows[9 + y][9..16], r);
    const final = rows;
    var ptrs: [16]*const [16]u8 = undefined;
    for (&ptrs, 0..) |*p, i| p.* = &final[i];
    return mk(ptrs, 0, 0);
}

/// The transpose of `a` (a column cursor becomes a row cursor).
fn transposed(comptime a: Art) Art {
    var rows: [16][16]u8 = undefined;
    for (0..16) |y| for (0..16) |x| {
        rows[y][x] = a.rows[x][y];
    };
    const final = rows;
    var ptrs: [16]*const [16]u8 = undefined;
    for (&ptrs, 0..) |*p, i| p.* = &final[i];
    return mk(ptrs, a.hot_y, a.hot_x);
}

/// The embedded drawings.
pub const art = struct {
    /// Open hand.
    pub const grab = mk(.{
        "       ##       ",
        "   ## #..##     ",
        "  #..##..#..#   ",
        "  #..##..#..# # ",
        "   #..#..#..##.#",
        "   #..#..#..#..#",
        " ## #.......#..#",
        "#..##..........#",
        "#...#.........# ",
        " #............# ",
        "  #...........# ",
        "  #..........#  ",
        "   #.........#  ",
        "    #.......#   ",
        "     #......#   ",
        "     ########   ",
    }, 8, 8);
    /// Closed hand.
    pub const grabbing = mk(.{
        "                ",
        "                ",
        "                ",
        "                ",
        "    ## ## ##    ",
        "   #..#..#..##  ",
        "   #........#.# ",
        "  ##..........# ",
        " #.#..........# ",
        " #............# ",
        "  #...........# ",
        "  #..........#  ",
        "   #.........#  ",
        "    #.......#   ",
        "     #......#   ",
        "     ########   ",
    }, 8, 8);
    /// Arrow with a plus.
    pub const copy = badged(.{
        "#######",
        "#.....#",
        "#..#..#",
        "#.###.#",
        "#..#..#",
        "#.....#",
        "#######",
    });
    /// Arrow with a shortcut arrow.
    pub const alias = badged(.{
        "#######",
        "#.###.#",
        "#...#.#",
        "#..#..#",
        "#.#...#",
        "#.....#",
        "#######",
    });
    /// Arrow with a menu.
    pub const context_menu = badged(.{
        "#######",
        "#.....#",
        "#.###.#",
        "#.....#",
        "#.###.#",
        "#.....#",
        "#######",
    });
    /// A column splitter with left and right arrows.
    pub const col_resize = mk(.{
        "                ",
        "      #  #      ",
        "      #..#      ",
        "      #..#      ",
        "   #  #..#  #   ",
        "  ##  #..#  ##  ",
        " #.####..####.# ",
        "#..............#",
        " #.####..####.# ",
        "  ##  #..#  ##  ",
        "   #  #..#  #   ",
        "      #..#      ",
        "      #..#      ",
        "      #  #      ",
        "                ",
        "                ",
    }, 8, 7);
    /// A row splitter with up and down arrows.
    pub const row_resize = transposed(col_resize);
    /// Magnifier with a plus.
    pub const zoom_in = mk(.{
        "   #####        ",
        "  #.....#       ",
        " #...#...#      ",
        "#....#....#     ",
        "#..#####..#     ",
        "#....#....#     ",
        " #...#...#      ",
        "  #.....##      ",
        "   #####.##     ",
        "        #..#    ",
        "         #..#   ",
        "          #..#  ",
        "           #..# ",
        "            ##  ",
        "                ",
        "                ",
    }, 5, 4);
    /// Magnifier with a minus.
    pub const zoom_out = mk(.{
        "   #####        ",
        "  #.....#       ",
        " #.......#      ",
        "#.........#     ",
        "#..#####..#     ",
        "#.........#     ",
        " #.......#      ",
        "  #.....##      ",
        "   #####.##     ",
        "        #..#    ",
        "         #..#   ",
        "          #..#  ",
        "           #..# ",
        "            ##  ",
        "                ",
        "                ",
    }, 5, 4);
    /// A thick plus for cell selection.
    pub const cell = mk(.{
        "     ######     ",
        "     #....#     ",
        "     #....#     ",
        "     #....#     ",
        "     #....#     ",
        "######....######",
        "#..............#",
        "#..............#",
        "#..............#",
        "#..............#",
        "######....######",
        "     #....#     ",
        "     #....#     ",
        "     #....#     ",
        "     #....#     ",
        "     ######     ",
    }, 8, 8);
    /// A horizontal I-beam.
    pub const vertical_text = mk(.{
        "                ",
        "                ",
        "                ",
        "                ",
        "                ",
        "...          ...",
        ".#.          .#.",
        ".#............#.",
        ".##############.",
        ".#............#.",
        ".#.          .#.",
        "...          ...",
        "                ",
        "                ",
        "                ",
        "                ",
    }, 8, 8);
};

/// System and built cursors by shape and size, created on first use and
/// destroyed by `deinit`. Platform thread only.
pub const Cache = if (is_windows) struct {
    const t = @import("bindings/types.zig");
    const user32 = @import("bindings/user32.zig");
    const gdi32 = @import("bindings/gdi32.zig");
    const n_shapes = std.enums.values(CursorShape).len;

    /// Built cursors at 32, 48 and 64 px.
    built: [3][n_shapes]?t.HCURSOR = @splat(@splat(null)),

    /// The cursor for `shape` at `dpi`; null for `hidden`, and the arrow
    /// when building fails.
    pub fn get(c: *@This(), shape: CursorShape, dpi: u32) ?t.HCURSOR {
        switch (nativeOf(shape)) {
            .hidden => return null,
            .system => |id| return user32.LoadCursorW(null, user32.makeIntResource(id)),
            .custom => |a| {
                const size = sizeForDpi(dpi);
                const slot = &c.built[size / 16 - 2][@intFromEnum(shape)];
                if (slot.* == null) slot.* = build(a, size);
                return slot.* orelse user32.LoadCursorW(null, user32.makeIntResource(IDC.ARROW));
            },
        }
    }

    fn build(a: *const Art, size: u32) ?t.HCURSOR {
        const bmi = @import("cpu_present.zig").dibInfo(size, size);
        var bits: ?*anyopaque = null;
        const color = gdi32.CreateDIBSection(null, &bmi, 0, &bits, null, 0) orelse return null;
        defer _ = gdi32.DeleteObject(@ptrCast(color));
        const px: [*]u32 = @ptrCast(@alignCast(bits.?));
        const hot = rasterize(a, size, px[0 .. size * size]);
        // The AND mask is unused for 32 bpp cursors with alpha; all zero.
        const zeros: [64 * 64 / 8]u8 = @splat(0);
        const mask = gdi32.CreateBitmap(@intCast(size), @intCast(size), 1, 1, &zeros) orelse return null;
        defer _ = gdi32.DeleteObject(@ptrCast(mask));
        const ii: t.ICONINFO = .{ .fIcon = t.FALSE, .xHotspot = hot[0], .yHotspot = hot[1], .hbmMask = mask, .hbmColor = color };
        return user32.CreateIconIndirect(&ii);
    }

    /// Destroys the built cursors.
    pub fn deinit(c: *@This()) void {
        for (&c.built) |*row| for (row) |*h| if (h.*) |x| {
            _ = user32.DestroyCursor(x);
            h.* = null;
        };
    }
} else void;

const testing = std.testing;

test "cursor mapping table complete" {
    for (std.enums.values(CursorShape)) |s| switch (nativeOf(s)) {
        .system => |id| try testing.expect(id >= IDC.ARROW and id <= IDC.HELP),
        .custom => |a| {
            try testing.expect(a.hot_x < 16 and a.hot_y < 16);
            // The hotspot is on the drawing, or next to it.
            var opaque_px: usize = 0;
            for (a.rows) |r| for (r) |c| {
                try testing.expect(c == '#' or c == '.' or c == ' ');
                if (c != ' ') opaque_px += 1;
            };
            try testing.expect(opaque_px > 16);
        },
        .hidden => try testing.expectEqual(CursorShape.hidden, s),
    };
}

test "cursor size by DPI and rasterized hotspot" {
    try testing.expectEqual(@as(u32, 32), sizeForDpi(96));
    try testing.expectEqual(@as(u32, 48), sizeForDpi(144));
    try testing.expectEqual(@as(u32, 64), sizeForDpi(192));
    var px: [64 * 64]u32 = undefined;
    const hot = rasterize(&art.cell, 48, &px);
    try testing.expectEqual([2]u32{ 25, 25 }, hot);
    // Pixel (0,0) of the drawing is transparent, (5,0) is black and (6,1)
    // white; each covers a 3×3 block at 48 px.
    try testing.expectEqual(@as(u32, 0), px[0]);
    try testing.expectEqual(@as(u32, 0xFF000000), px[0 * 48 + 5 * 3 + 2]);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), px[(1 * 3 + 1) * 48 + 6 * 3]);
}

test "row_resize is the transpose of col_resize" {
    for (0..16) |y| for (0..16) |x| {
        try testing.expectEqual(art.col_resize.rows[y][x], art.row_resize.rows[x][y]);
    };
    try testing.expectEqual(art.col_resize.hot_x, art.row_resize.hot_y);
    // Badged arrows keep the arrow's tip as the hotspot.
    try testing.expectEqual(@as(u8, '#'), art.copy.rows[0][0]);
    try testing.expectEqual(@as(u8, '#'), art.copy.rows[15][15]);
}
