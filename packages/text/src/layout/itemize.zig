//! Splits a line into shaping items: bidi level runs, script runs, font
//! fallback per grapheme cluster and the caller's style runs. Items are in
//! logical order; line layout orders them visually after shaping.

const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = @import("../unicode/root.zig");
const Script = unicode.Script;
const bidi = unicode.bidi;
const grapheme = unicode.grapheme;
const ScriptRunIterator = unicode.script.ScriptRunIterator;
const fonts = @import("../fonts/root.zig");
const Fallback = fonts.Fallback;
const style_mod = @import("style.zig");
const StyleRun = style_mod.StyleRun;
const Direction = style_mod.Direction;

const log = std.log.scoped(.zg_text);

/// A run of text shaped in one call.
pub const Item = struct {
    start: u32,
    end: u32,
    level: u8,
    script: Script,
    instance: fonts.InstanceId,
    style_index: u16,
    /// The clusters ask for emoji presentation.
    emoji: bool,
};

/// What `itemize` resolved besides the items.
pub const ItemizeInfo = struct {
    /// The resolved paragraph (arena-owned); null on the LTR fast path.
    paragraph: ?bidi.Paragraph,
    has_rtl: bool,
    /// The paragraph embedding level.
    base: u8,
};

/// Itemizes `text` as one line (UAX #9 L1 applied to the whole text).
pub fn itemize(arena: Allocator, text: []const u8, styles: []const StyleRun, base_dir: Direction, fb: *const Fallback, out: *std.ArrayList(Item)) !ItemizeInfo {
    const lv = try resolveLevels(arena, text, base_dir);
    const levels = if (lv.paragraph) |*para| try lineByteLevels(arena, para, 0, @intCast(text.len)) else null;
    try itemizeLevels(arena, text, styles, levels, lv.base, fb, out);
    return lv;
}

/// Resolves the paragraph's levels, skipping UAX #9 when nothing in it
/// can be right-to-left.
pub fn resolveLevels(arena: Allocator, text: []const u8, base_dir: Direction) !ItemizeInfo {
    if (base_dir != .rtl and !bidi.hasRtl(text)) return .{ .paragraph = null, .has_rtl = false, .base = 0 };
    const para = try bidi.resolve(arena, text, base_dir);
    return .{ .paragraph = para, .has_rtl = true, .base = para.base };
}

/// Per-byte levels (after L1) for the line of bytes `[start, end)` of a
/// resolved paragraph; `start` and `end` must be code point boundaries.
pub fn lineByteLevels(arena: Allocator, para: *const bidi.Paragraph, start: u32, end: u32) ![]u8 {
    const offs = para.cp_offsets;
    const cs = std.sort.lowerBound(u32, offs, start, orderU32);
    const ce = std.sort.lowerBound(u32, offs, end, orderU32);
    const cp_levels = try arena.alloc(u8, ce - cs);
    bidi.lineLevels(para.classes[cs..ce], para.levels[cs..ce], para.base, cp_levels);
    const out = try arena.alloc(u8, end - start);
    for (cs..ce, cp_levels) |k, l| {
        const b0 = offs[k] - start;
        const b1 = if (k + 1 < offs.len) @min(offs[k + 1], end) - start else end - start;
        @memset(out[b0..b1], l);
    }
    return out;
}

fn orderU32(a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

/// Itemizes with per-byte `levels` (null: every byte at `base`).
pub fn itemizeLevels(arena: Allocator, text: []const u8, styles: []const StyleRun, levels: ?[]const u8, base: u8, fb: *const Fallback, out: *std.ArrayList(Item)) !void {
    if (text.len == 0) return;
    std.debug.assert(styles.len > 0);
    if (levels == null and styles.len == 1 and isAscii(text)) return asciiItem(arena, text, styles, base, fb, out);
    var sri = ScriptRunIterator.init(text);
    var srun = sri.next().?;
    var si: u16 = 0;
    var cur: ?Item = null;
    var next: usize = 0;
    while (next < text.len) {
        const s: u32 = @intCast(next);
        const e: u32 = @intCast(grapheme.nextBoundary(text, next));
        next = e;
        while (srun.end <= s) srun = sri.next().?;
        while (si + 1 < styles.len and styles[si].end <= s) si += 1;
        if (std.debug.runtime_safety and styles[si].end > s and styles[si].end < e and si + 1 < styles.len)
            log.debug("style run end {d} splits the grapheme at {d}; moved to {d}", .{ styles[si].end, s, e });
        const cluster = text[s..e];
        const level = if (levels) |l| l[s] else base;
        const emoji = (cluster.len > 1 or cluster[0] >= 0x80) and fonts.fallback.emojiPresentation(cluster);
        const inst = fb.resolve(styles[si].style.chain, cluster, if (emoji) .emoji else .default);
        if (cur) |*c| {
            if (c.level == level and c.script == srun.script and c.style_index == si and c.instance == inst and c.emoji == emoji) {
                c.end = e;
                continue;
            }
            try out.append(arena, c.*);
        }
        cur = .{ .start = s, .end = e, .level = level, .script = srun.script, .instance = inst, .style_index = si, .emoji = emoji };
    }
    if (cur) |c| try out.append(arena, c);
}

fn isAscii(text: []const u8) bool {
    for (text) |c| if (c >= 0x80) return false;
    return true;
}

/// One style, no bidi, ASCII: one script, and one item per change of
/// covering instance (only when the primary lacks a character).
fn asciiItem(arena: Allocator, text: []const u8, styles: []const StyleRun, base: u8, fb: *const Fallback, out: *std.ArrayList(Item)) !void {
    var script: Script = .Zyyy;
    for (text) |c| if (std.ascii.isAlphabetic(c)) {
        script = .Latn;
        break;
    };
    const chain = styles[0].style.chain;
    const reg = fb.reg.get(fb.primary(chain));
    if (reg.coversAscii()) {
        try out.append(arena, .{ .start = 0, .end = @intCast(text.len), .level = base, .script = script, .instance = fb.primary(chain), .style_index = 0, .emoji = false });
        return;
    }
    var i: usize = 0;
    while (i < text.len) {
        const n: usize = if (text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n') 2 else 1;
        const inst = fb.resolve(chain, text[i..][0..1], .default);
        const last = if (out.items.len > 0) &out.items[out.items.len - 1] else null;
        if (last != null and last.?.instance == inst and last.?.end == i) {
            last.?.end = @intCast(i + n);
        } else {
            try out.append(arena, .{ .start = @intCast(i), .end = @intCast(i + n), .level = base, .script = script, .instance = inst, .style_index = 0, .emoji = false });
        }
        i += n;
    }
}
