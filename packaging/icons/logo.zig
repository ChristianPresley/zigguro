//! The zigguro logo as vector data (E17.F01.S01.T03): a stepped ziggurat
//! on a rounded square, in a 1024x1024 design space with y down.
//! `zg-release icongen` rasterizes it into packaging/icons/out/; edit the
//! paths here and run `zig build icons` to regenerate.

pub const Fill = struct { rgba: [4]u8 };

pub const Cmd = union(enum) {
    move: [2]f32,
    line: [2]f32,
    quad: [2][2]f32,
    cubic: [3][2]f32,
    close,
};

/// One filled shape. Layers below `hint_min_px` are skipped, so small
/// sizes keep only the silhouette.
pub const Layer = struct {
    fill: Fill,
    cmds: []const Cmd,
    hint_min_px: u16 = 0,
};

/// The design space's width and height.
pub const design_size: f32 = 1024;

const slate: Fill = .{ .rgba = .{ 0x1f, 0x26, 0x33, 0xff } };
const sand: Fill = .{ .rgba = .{ 0xf2, 0xb5, 0x44, 0xff } };
const shade: Fill = .{ .rgba = .{ 0xc9, 0x86, 0x1e, 0xff } };
const teal: Fill = .{ .rgba = .{ 0x4f, 0xd1, 0xc5, 0xff } };

// Cubic approximation of a quarter circle: control points at k * r.
const k: f32 = 0.5523;

fn roundedSquare(comptime x0: f32, comptime y0: f32, comptime x1: f32, comptime y1: f32, comptime r: f32) [10]Cmd {
    const c = r * (1 - k);
    return .{
        .{ .move = .{ x0 + r, y0 } },
        .{ .line = .{ x1 - r, y0 } },
        .{ .cubic = .{ .{ x1 - c, y0 }, .{ x1, y0 + c }, .{ x1, y0 + r } } },
        .{ .line = .{ x1, y1 - r } },
        .{ .cubic = .{ .{ x1, y1 - c }, .{ x1 - c, y1 }, .{ x1 - r, y1 } } },
        .{ .line = .{ x0 + r, y1 } },
        .{ .cubic = .{ .{ x0 + c, y1 }, .{ x0, y1 - c }, .{ x0, y1 - r } } },
        .{ .line = .{ x0, y0 + r } },
        .{ .cubic = .{ .{ x0, y0 + c }, .{ x0 + c, y0 }, .{ x0 + r, y0 } } },
        .close,
    };
}

fn rect(comptime x0: f32, comptime y0: f32, comptime x1: f32, comptime y1: f32) [5]Cmd {
    return .{ .{ .move = .{ x0, y0 } }, .{ .line = .{ x1, y0 } }, .{ .line = .{ x1, y1 } }, .{ .line = .{ x0, y1 } }, .close };
}

const background = roundedSquare(48, 48, 976, 976, 200);

// Three tiers, widest at the bottom, as one stepped outline.
const tiers = [_]Cmd{
    .{ .move = .{ 400, 376 } },
    .{ .line = .{ 624, 376 } },
    .{ .line = .{ 624, 520 } },
    .{ .line = .{ 720, 520 } },
    .{ .line = .{ 720, 664 } },
    .{ .line = .{ 816, 664 } },
    .{ .line = .{ 816, 800 } },
    .{ .line = .{ 208, 800 } },
    .{ .line = .{ 208, 664 } },
    .{ .line = .{ 304, 664 } },
    .{ .line = .{ 304, 520 } },
    .{ .line = .{ 400, 520 } },
    .close,
};

// The shrine on top: the accent.
const shrine = rect(456, 256, 568, 376);

// The central stairway and the shadow under each ledge.
const stairs = rect(488, 376, 536, 800);
const ledge_mid = rect(304, 520, 720, 540);
const ledge_low = rect(208, 664, 816, 684);

pub const logo = [_]Layer{
    .{ .fill = slate, .cmds = &background },
    .{ .fill = sand, .cmds = &tiers },
    .{ .fill = teal, .cmds = &shrine },
    .{ .fill = shade, .cmds = &ledge_mid, .hint_min_px = 32 },
    .{ .fill = shade, .cmds = &ledge_low, .hint_min_px = 32 },
    .{ .fill = shade, .cmds = &stairs, .hint_min_px = 32 },
};
