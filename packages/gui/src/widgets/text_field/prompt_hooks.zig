//! Agent-prompt hooks for `TextField` (E04.F05.S02.T02): callbacks a
//! prompt or chat input installs (`Props.prompt`) to open completions.
//!
//! A trigger fires when one of `trigger_chars` is typed at a word start
//! (the start of the text or after whitespace or an opening bracket); the
//! callback gets the character, its byte offset and the caret rectangle
//! (window logical) to anchor a completion popover. Pasted or IME
//! committed text never fires a trigger.
//!
//! Files dragged from another app are accepted when `on_drop_files` is
//! set, and handed over as local paths on drop (input/drop.zig).
//!
//!
//! Rich paste: with `on_paste_rich` set, Ctrl+V on a clipboard without
//! text asks the platform for an image (`image/png`) and hands the bytes
//! over when they arrive; text pastes stay instant.

const std = @import("std");
const geom = @import("../../core/geom.zig");

const Rect = geom.Rect;

pub const PromptHooks = struct {
    ctx: *anyopaque,
    /// ASCII characters that open a completion.
    trigger_chars: []const u8 = "@/",
    on_trigger: ?*const fn (ctx: *anyopaque, ch: u8, byte_offset: u32, caret_rect: Rect) void = null,
    /// Local paths dropped on the field (valid during the call only).
    on_drop_files: ?*const fn (ctx: *anyopaque, paths: []const []const u8) void = null,
    /// Pasted non-text data (`mime` such as "image/png"; bytes valid
    /// during the call only). Returns whether it was consumed.
    on_paste_rich: ?*const fn (ctx: *anyopaque, mime: []const u8, bytes: []const u8) bool = null,
};

/// The trigger character `typed` at `offset` in `t` (after insertion),
/// or null when it is not a trigger at a word start.
pub fn trigger(h: *const PromptHooks, t: []const u8, offset: u32, typed: []const u8) ?u8 {
    if (typed.len != 1 or std.mem.indexOfScalar(u8, h.trigger_chars, typed[0]) == null) return null;
    if (offset > 0) switch (t[offset - 1]) {
        ' ', '\t', '\n', '\r', '(', '[', '{', '"', '\'' => {},
        else => return null,
    };
    return typed[0];
}

test "triggers only at a word start" {
    var ctx: u8 = 0;
    const h: PromptHooks = .{ .ctx = &ctx };
    try std.testing.expectEqual(@as(?u8, '@'), trigger(&h, "@", 0, "@"));
    try std.testing.expectEqual(@as(?u8, '/'), trigger(&h, "ask /", 4, "/"));
    try std.testing.expectEqual(@as(?u8, '@'), trigger(&h, "(@", 1, "@"));
    try std.testing.expectEqual(@as(?u8, null), trigger(&h, "me@", 2, "@"));
    try std.testing.expectEqual(@as(?u8, null), trigger(&h, "a/b", 1, "/"));
    try std.testing.expectEqual(@as(?u8, null), trigger(&h, "#", 0, "#"));
    try std.testing.expectEqual(@as(?u8, null), trigger(&h, "@@", 0, "@@"));
}
