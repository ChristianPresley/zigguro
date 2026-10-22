//! `Theme`: resolved token values, the four built-in themes and the WCAG
//! contrast pairs every built-in must pass.

const std = @import("std");
const geom = @import("../core/geom.zig");
const tokens = @import("tokens.zig");

const Color = geom.Color;
const Token = tokens.Token;
const Dim = tokens.Dim;

/// A fully resolved theme: one colour per token and one value per
/// dimension token.
pub const Theme = struct {
    name: []const u8,
    kind: Kind,
    colors: [Token.count]Color,
    dims: [Dim.count]f32,

    /// Light, dark or a high-contrast variant.
    pub const Kind = enum(u8) { dark, light, hc_dark, hc_light };

    /// The colour of `t`.
    pub fn color(th: *const Theme, t: Token) Color {
        return th.colors[@intFromEnum(t)];
    }

    /// The value of dimension token `d`.
    pub fn dim(th: *const Theme, d: Dim) f32 {
        return th.dims[@intFromEnum(d)];
    }

    /// True for the high-contrast variants (AAA contrast, outlined controls).
    pub fn isHighContrast(th: *const Theme) bool {
        return th.kind == .hc_dark or th.kind == .hc_light;
    }
};

/// One foreground/background pair the contrast lint checks.
pub const ContrastPair = struct {
    fg: Token,
    bg: Token,
    /// WCAG AA minimum; high-contrast themes use `hc_min`.
    min: f64,
    hc_min: f64,
};

/// The pairs checked by `lint` (WCAG 1.4.3 text, 1.4.11 non-text).
pub const contrast_pairs = [_]ContrastPair{
    .{ .fg = .fg, .bg = .bg_base, .min = 4.5, .hc_min = 7 },
    .{ .fg = .fg, .bg = .bg_elevated, .min = 4.5, .hc_min = 7 },
    .{ .fg = .fg, .bg = .bg_sunken, .min = 4.5, .hc_min = 7 },
    .{ .fg = .fg, .bg = .bg_overlay, .min = 4.5, .hc_min = 7 },
    .{ .fg = .fg_muted, .bg = .bg_base, .min = 4.5, .hc_min = 7 },
    .{ .fg = .fg_muted, .bg = .bg_elevated, .min = 4.5, .hc_min = 7 },
    .{ .fg = .fg_link, .bg = .bg_base, .min = 4.5, .hc_min = 7 },
    .{ .fg = .fg_on_accent, .bg = .accent, .min = 4.5, .hc_min = 7 },
    .{ .fg = .fg_on_accent, .bg = .accent_hover, .min = 4.5, .hc_min = 7 },
    .{ .fg = .button_fg, .bg = .button_bg, .min = 4.5, .hc_min = 7 },
    .{ .fg = .button_fg, .bg = .button_bg_hover, .min = 4.5, .hc_min = 7 },
    .{ .fg = .badge_fg, .bg = .badge_bg, .min = 4.5, .hc_min = 7 },
    .{ .fg = .fg, .bg = .selection_bg, .min = 4.5, .hc_min = 7 },
    .{ .fg = .focus_ring, .bg = .bg_base, .min = 3, .hc_min = 3 },
    .{ .fg = .focus_ring, .bg = .bg_elevated, .min = 3, .hc_min = 3 },
    .{ .fg = .border_strong, .bg = .bg_base, .min = 3, .hc_min = 3 },
    .{ .fg = .control_border, .bg = .bg_base, .min = 3, .hc_min = 3 },
    .{ .fg = .control_checked, .bg = .bg_base, .min = 3, .hc_min = 3 },
    .{ .fg = .accent, .bg = .bg_base, .min = 3, .hc_min = 3 },
};

/// A failed contrast check.
pub const LintIssue = struct { pair: ContrastPair, ratio: f64, required: f64 };

/// Checks every pair in `contrast_pairs`; returns how many failed and
/// writes up to `out.len` of them.
pub fn lint(th: *const Theme, out: []LintIssue) usize {
    var n: usize = 0;
    for (contrast_pairs) |p| {
        const req = if (th.isHighContrast()) p.hc_min else p.min;
        const r = Color.contrast(th.color(p.fg), th.color(p.bg));
        if (r + 1e-9 < req) {
            if (n < out.len) out[n] = .{ .pair = p, .ratio = r, .required = req };
            n += 1;
        }
    }
    return n;
}

const Entry = struct { Token, u32 };

fn build(comptime name: []const u8, comptime kind: Theme.Kind, comptime entries: []const Entry, comptime dims: [Dim.count]f32) Theme {
    @setEvalBranchQuota(20_000);
    var colors: [Token.count]Color = undefined;
    var set = [_]bool{false} ** Token.count;
    for (entries) |e| {
        colors[@intFromEnum(e[0])] = Color.hexa(e[1]);
        set[@intFromEnum(e[0])] = true;
    }
    for (set, 0..) |s, i| {
        if (!s) @compileError("theme " ++ name ++ " misses token " ++ @tagName(@as(Token, @enumFromInt(i))));
    }
    return .{ .name = name, .kind = kind, .colors = colors, .dims = dims };
}

const default_dims: [Dim.count]f32 = .{
    3, // radius_sm
    5, // radius_md
    8, // radius_lg
    2, // space_xs
    4, // space_sm
    8, // space_md
    16, // space_lg
    26, // control_h
    2, // focus_ring_w
    2, // focus_ring_offset
    1, // border_w
    13, // font_size
    11, // font_size_sm
    16, // font_size_lg
};

/// The default dark theme.
pub const zigguro_dark = build("zigguro-dark", .dark, &.{
    .{ .bg_base, 0x1e1f22ff },           .{ .bg_elevated, 0x2b2d31ff },    .{ .bg_sunken, 0x17181aff },
    .{ .bg_overlay, 0x313338ff },        .{ .fg, 0xe6e7e9ff },             .{ .fg_muted, 0xa9adb5ff },
    .{ .fg_disabled, 0x6c7078ff },       .{ .fg_on_accent, 0xffffffff },   .{ .fg_link, 0x7db4ffff },
    .{ .border, 0x3c3f45ff },            .{ .border_strong, 0x80858eff },  .{ .focus_ring, 0x5a9cffff },
    .{ .accent, 0x2f6ad9ff },            .{ .accent_hover, 0x2a62cbff },   .{ .accent_pressed, 0x2455b3ff },
    .{ .danger, 0xf26b6bff },            .{ .warning, 0xe5b454ff },        .{ .success, 0x58c27dff },
    .{ .info, 0x6aa7ffff },              .{ .button_bg, 0x3a3d43ff },      .{ .button_bg_hover, 0x44474eff },
    .{ .button_bg_pressed, 0x34363cff }, .{ .button_fg, 0xe6e7e9ff },      .{ .button_border, 0x4a4d54ff },
    .{ .control_bg, 0x232428ff },        .{ .control_border, 0x80858eff }, .{ .control_checked, 0x5a9cffff },
    .{ .control_thumb, 0xe6e7e9ff },     .{ .track, 0x3c3f45ff },          .{ .selection_bg, 0x264f78ff },
    .{ .hover_bg, 0xffffff12 },          .{ .badge_bg, 0x2f6ad9ff },       .{ .badge_fg, 0xffffffff },
    .{ .scrollbar_thumb, 0xffffff40 },   .{ .shadow, 0x00000080 },
}, default_dims);

/// The default light theme.
pub const zigguro_light = build("zigguro-light", .light, &.{
    .{ .bg_base, 0xffffffff },           .{ .bg_elevated, 0xf6f7f9ff },    .{ .bg_sunken, 0xeef0f3ff },
    .{ .bg_overlay, 0xffffffff },        .{ .fg, 0x1f2328ff },             .{ .fg_muted, 0x57606aff },
    .{ .fg_disabled, 0x9aa1a9ff },       .{ .fg_on_accent, 0xffffffff },   .{ .fg_link, 0x0a58c9ff },
    .{ .border, 0xd0d7deff },            .{ .border_strong, 0x6e7781ff },  .{ .focus_ring, 0x0969daff },
    .{ .accent, 0x0969daff },            .{ .accent_hover, 0x0860c9ff },   .{ .accent_pressed, 0x0550aeff },
    .{ .danger, 0xcf222eff },            .{ .warning, 0x9a6700ff },        .{ .success, 0x1a7f37ff },
    .{ .info, 0x0969daff },              .{ .button_bg, 0xf3f4f6ff },      .{ .button_bg_hover, 0xe9ebefff },
    .{ .button_bg_pressed, 0xdfe2e6ff }, .{ .button_fg, 0x1f2328ff },      .{ .button_border, 0xc4cbd3ff },
    .{ .control_bg, 0xffffffff },        .{ .control_border, 0x6e7781ff }, .{ .control_checked, 0x0969daff },
    .{ .control_thumb, 0xffffffff },     .{ .track, 0xd0d7deff },          .{ .selection_bg, 0xb6d6faff },
    .{ .hover_bg, 0x0000000d },          .{ .badge_bg, 0x0969daff },       .{ .badge_fg, 0xffffffff },
    .{ .scrollbar_thumb, 0x00000040 },   .{ .shadow, 0x00000033 },
}, default_dims);

/// High-contrast dark (AAA text contrast, outlined controls).
pub const zigguro_hc_dark = build("zigguro-hc-dark", .hc_dark, &.{
    .{ .bg_base, 0x000000ff },           .{ .bg_elevated, 0x0a0a0aff },    .{ .bg_sunken, 0x000000ff },
    .{ .bg_overlay, 0x0a0a0aff },        .{ .fg, 0xffffffff },             .{ .fg_muted, 0xe0e0e0ff },
    .{ .fg_disabled, 0xa0a0a0ff },       .{ .fg_on_accent, 0x000000ff },   .{ .fg_link, 0x8cc8ffff },
    .{ .border, 0xffffffff },            .{ .border_strong, 0xffffffff },  .{ .focus_ring, 0xffd400ff },
    .{ .accent, 0x8cc8ffff },            .{ .accent_hover, 0xa8d6ffff },   .{ .accent_pressed, 0x70b8ffff },
    .{ .danger, 0xff8080ff },            .{ .warning, 0xffd400ff },        .{ .success, 0x7cff9cff },
    .{ .info, 0x8cc8ffff },              .{ .button_bg, 0x000000ff },      .{ .button_bg_hover, 0x1a1a1aff },
    .{ .button_bg_pressed, 0x2a2a2aff }, .{ .button_fg, 0xffffffff },      .{ .button_border, 0xffffffff },
    .{ .control_bg, 0x000000ff },        .{ .control_border, 0xffffffff }, .{ .control_checked, 0x8cc8ffff },
    .{ .control_thumb, 0xffffffff },     .{ .track, 0x808080ff },          .{ .selection_bg, 0x0a3a6aff },
    .{ .hover_bg, 0xffffff26 },          .{ .badge_bg, 0x8cc8ffff },       .{ .badge_fg, 0x000000ff },
    .{ .scrollbar_thumb, 0xffffffa0 },   .{ .shadow, 0x00000000 },
}, default_dims);

/// High-contrast light.
pub const zigguro_hc_light = build("zigguro-hc-light", .hc_light, &.{
    .{ .bg_base, 0xffffffff },           .{ .bg_elevated, 0xffffffff },    .{ .bg_sunken, 0xf5f5f5ff },
    .{ .bg_overlay, 0xffffffff },        .{ .fg, 0x000000ff },             .{ .fg_muted, 0x2b2b2bff },
    .{ .fg_disabled, 0x6a6a6aff },       .{ .fg_on_accent, 0xffffffff },   .{ .fg_link, 0x003d99ff },
    .{ .border, 0x000000ff },            .{ .border_strong, 0x000000ff },  .{ .focus_ring, 0x0f4a85ff },
    .{ .accent, 0x003d99ff },            .{ .accent_hover, 0x00337fff },   .{ .accent_pressed, 0x002a66ff },
    .{ .danger, 0xa30000ff },            .{ .warning, 0x6b4a00ff },        .{ .success, 0x0b5e1eff },
    .{ .info, 0x003d99ff },              .{ .button_bg, 0xffffffff },      .{ .button_bg_hover, 0xf0f0f0ff },
    .{ .button_bg_pressed, 0xe0e0e0ff }, .{ .button_fg, 0x000000ff },      .{ .button_border, 0x000000ff },
    .{ .control_bg, 0xffffffff },        .{ .control_border, 0x000000ff }, .{ .control_checked, 0x003d99ff },
    .{ .control_thumb, 0xffffffff },     .{ .track, 0x6a6a6aff },          .{ .selection_bg, 0xc8e1ffff },
    .{ .hover_bg, 0x0000001a },          .{ .badge_bg, 0x003d99ff },       .{ .badge_fg, 0xffffffff },
    .{ .scrollbar_thumb, 0x00000080 },   .{ .shadow, 0x00000000 },
}, default_dims);

/// Every built-in theme.
pub const builtins = [_]*const Theme{ &zigguro_dark, &zigguro_light, &zigguro_hc_dark, &zigguro_hc_light };

/// The built-in theme named `name`.
pub fn builtin(name: []const u8) ?*const Theme {
    for (builtins) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

test "built-in themes pass the contrast lint" {
    for (builtins) |t| {
        var issues: [contrast_pairs.len]LintIssue = undefined;
        const n = lint(t, &issues);
        for (issues[0..@min(n, issues.len)]) |iss| {
            std.debug.print("{s}: {s} on {s} = {d:.2} < {d}\n", .{ t.name, iss.pair.fg.name(), iss.pair.bg.name(), iss.ratio, iss.required });
        }
        try std.testing.expectEqual(@as(usize, 0), n);
    }
}

test "contrast ratio known pairs" {
    try std.testing.expectApproxEqAbs(@as(f64, 21), Color.contrast(Color.hex(0), Color.hex(0xffffff)), 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 4.48), Color.contrast(Color.hex(0x777777), Color.hex(0xffffff)), 0.01);
}

test "builtin lookup" {
    try std.testing.expectEqual(&zigguro_light, builtin("zigguro-light").?);
    try std.testing.expect(builtin("nope") == null);
    try std.testing.expectEqual(@as(f32, 13), zigguro_dark.dim(.font_size));
}
