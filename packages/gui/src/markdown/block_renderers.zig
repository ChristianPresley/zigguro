//! Fenced block renderers (E04 extension point for E13.F07.S02.T03): a
//! registry mapping a fence's language (its info string's first word,
//! e.g. `mermaid`) to a builder that draws the block instead of the
//! code view. A renderer can decline (return false), for example while
//! the fence is still streaming, and the code view is shown.

const std = @import("std");
const ui_mod = @import("../core/ui.zig");

const Ui = ui_mod.Ui;

/// What a renderer gets for one fenced block.
pub const BlockInfo = struct {
    /// The info string's first word.
    lang: []const u8,
    /// The whole info string.
    info: []const u8,
    /// The fence's content.
    code: []const u8,
    /// False while the closing fence has not arrived (streaming).
    closed: bool,
    /// The block's source offset: stable across appends.
    key: u32,
    /// The view's content width.
    max_width: f32,
};

pub const BlockRenderer = struct {
    ctx: *anyopaque,
    /// Builds the block's UI; false to fall back to the code view.
    build: *const fn (ctx: *anyopaque, ui: *Ui, b: BlockInfo) bool,
    /// The block's height before layout (virtualized documents); null
    /// estimates it as code.
    estimate: ?*const fn (ctx: *anyopaque, b: BlockInfo) ?f32 = null,
};

pub const MarkdownBlockRenderers = struct {
    pub const capacity = 16;
    const Entry = struct { lang: []const u8, r: BlockRenderer };

    entries: [capacity]Entry = undefined,
    len: usize = 0,

    /// Maps fences of `lang` (compared without case) to `r`, replacing
    /// an earlier renderer of the same language. `lang` must outlive the
    /// registry.
    pub fn register(reg: *MarkdownBlockRenderers, lang: []const u8, r: BlockRenderer) error{RegistryFull}!void {
        for (reg.entries[0..reg.len]) |*e| if (std.ascii.eqlIgnoreCase(e.lang, lang)) {
            e.r = r;
            return;
        };
        if (reg.len == capacity) return error.RegistryFull;
        reg.entries[reg.len] = .{ .lang = lang, .r = r };
        reg.len += 1;
    }

    pub fn find(reg: *const MarkdownBlockRenderers, lang: []const u8) ?BlockRenderer {
        if (lang.len == 0) return null;
        for (reg.entries[0..reg.len]) |e| if (std.ascii.eqlIgnoreCase(e.lang, lang)) return e.r;
        return null;
    }
};

test "register replaces and finds without case" {
    const S = struct {
        fn a(_: *anyopaque, _: *Ui, _: BlockInfo) bool {
            return true;
        }
        fn b(_: *anyopaque, _: *Ui, _: BlockInfo) bool {
            return false;
        }
    };
    var x: u8 = 0;
    var reg: MarkdownBlockRenderers = .{};
    try reg.register("mermaid", .{ .ctx = &x, .build = S.a });
    try reg.register("Mermaid", .{ .ctx = &x, .build = S.b });
    try std.testing.expectEqual(1, reg.len);
    try std.testing.expectEqual(&S.b, reg.find("MERMAID").?.build);
    try std.testing.expectEqual(null, reg.find("dot"));
    try std.testing.expectEqual(null, reg.find(""));
}
