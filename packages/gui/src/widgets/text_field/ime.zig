//! `TextField` IME support (E04.F05.S02.T02): what the field reports to the
//! platform input method and how it takes composition events.
//!
//! - Focus enables the IME (`EventCx.setIme`) with the field's purpose
//!   (`password` for password fields, else `normal`), the caret rectangle
//!   and up to `max_surrounding` bytes of text around the caret; blur
//!   disables it. Every caret move or edit re-reports, and the window only
//!   tells the platform when something changed, so the candidate window
//!   follows the caret without a command per frame.
//! - Password fields never send their text.
//! - `ime_preedit` keeps a copy of the composition in the field's state;
//!   it is drawn in place of the selection, underlined, with the target
//!   clause underlined twice as thick. An empty preedit ends it.
//! - Committed text arrives as an ordinary `text` event (one undo step);
//!   `ime_delete_surrounding` deletes around the selection, widened to
//!   whole graphemes.
//! - While a composition is open the IME owns the keyboard: key events
//!   are consumed so arrows and Backspace do not edit under it.

const std = @import("std");
const zg_platform = @import("zg_platform");
const geom = @import("../../core/geom.zig");
const event_mod = @import("../../input/event.zig");
const model = @import("model.zig");

const EventCx = event_mod.EventCx;
const Rect = geom.Rect;

/// The text-input-v3 limit on surrounding text.
pub const max_surrounding: u32 = 4000;

/// The composition a field shows, with the bytes it owns.
pub const PreeditStore = struct {
    gpa: ?std.mem.Allocator = null,
    buf: std.ArrayList(u8) = .empty,

    pub fn deinit(p: *PreeditStore) void {
        if (p.gpa) |gpa| p.buf.deinit(gpa);
        p.* = .{};
    }

    /// Copies `pe` (an empty text clears it) and returns what the field
    /// shows at `sel`.
    pub fn set(p: *PreeditStore, gpa: std.mem.Allocator, pe: event_mod.ImePreedit, sel: [2]u32) !?model.Preedit {
        if (pe.text.len == 0) {
            p.buf.clearRetainingCapacity();
            return null;
        }
        if (p.gpa == null) p.gpa = gpa;
        p.buf.clearRetainingCapacity();
        try p.buf.appendSlice(p.gpa.?, pe.text);
        const n: i32 = @intCast(pe.text.len);
        const b = if (pe.cursor_begin < 0) -1 else @min(pe.cursor_begin, n);
        const e = std.math.clamp(pe.cursor_end, 0, n);
        return .{ .text = p.buf.items, .cursor = .{ b, @max(e, b) }, .range_in_buffer = sel };
    }
};

/// The IME purpose of a field.
pub fn purpose(password: bool) zg_platform.ime.ImePurpose {
    return if (password) .password else .normal;
}

/// The byte range of `t` sent as surrounding text: at most
/// `max_surrounding` bytes around `head`, cut at UTF-8 boundaries (also
/// when `t` itself starts or ends inside a character).
pub fn window(t: []const u8, head: u32) [2]u32 {
    const len: u32 = @intCast(t.len);
    var lo: u32 = 0;
    var hi: u32 = len;
    if (len > max_surrounding) {
        lo = head -| max_surrounding / 2;
        hi = @min(len, lo + max_surrounding);
        if (hi - lo < max_surrounding) lo = hi - max_surrounding;
    }
    while (lo < len and lo < head and isCont(t[lo])) lo += 1;
    while (hi > head and hi < len and isCont(t[hi])) hi -= 1;
    // A character cut off at the end of `t`.
    if (hi == len and hi > head) {
        var k = hi - 1;
        while (k > head and hi - k < 4 and isCont(t[k])) k -= 1;
        const need = std.unicode.utf8ByteSequenceLength(t[k]) catch 1;
        if (need > hi - k) hi = k;
    }
    return .{ lo, hi };
}

fn isCont(c: u8) bool {
    return c & 0xC0 == 0x80;
}

/// Reports the field to the IME: purpose, `caret` (window logical) and
/// the text around the caret (none for passwords).
pub fn report(ec: *EventCx, t: []const u8, sel: model.Selection, password: bool, caret: Rect) void {
    var sr: ?zg_platform.ime.Surrounding = null;
    if (!password) {
        const w = window(t, sel.head);
        sr = .{
            .text = t[w[0]..w[1]],
            .cursor_byte = sel.head - w[0],
            .anchor_byte = std.math.clamp(sel.anchor, w[0], w[1]) - w[0],
        };
    }
    ec.setIme(.{ .purpose = purpose(password), .caret = caret, .surrounding = sr });
}

test {
    std.testing.refAllDecls(@This());
}
