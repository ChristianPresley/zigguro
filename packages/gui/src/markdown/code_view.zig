//! Markdown code blocks (E04.F06.S01.T02): a header with the language,
//! a wrap toggle, Copy and the app's actions (Insert, Apply), over the
//! code in a horizontally scrolling box. Syntax colours come from a
//! `Highlighter` (E05 implements it with zg_syntax) and are cached per
//! block by content hash; while a fence is still streaming, the block is
//! highlighted again only after 64 more bytes or a new line.

const std = @import("std");
const ast = @import("ast.zig");
const doc_mod = @import("doc.zig");
const hash = @import("../core/hash.zig");
const ui_mod = @import("../core/ui.zig");
const tokens = @import("../theme/tokens.zig");
const controls = @import("../widgets/controls.zig");
const view_mod = @import("view.zig");

const Allocator = std.mem.Allocator;
const Ui = ui_mod.Ui;
const Token = tokens.Token;
const MdViewState = view_mod.MdViewState;
const none = ast.none;

/// What a highlighted range is.
pub const SyntaxClass = enum(u8) { plain, keyword, string, comment, number, type, function, constant, operator, punctuation };

/// A highlighted byte range of a code block's text.
pub const Span = struct { start: u32, end: u32, class: SyntaxClass };

/// The seam to a syntax highlighter: appends sorted, non-overlapping
/// spans for `code` in `lang` (the fence's first info word) to `out`.
pub const Highlighter = struct {
    ptr: *anyopaque,
    highlight: *const fn (ptr: *anyopaque, gpa: Allocator, lang: []const u8, code: []const u8, out: *std.ArrayList(Span)) Allocator.Error!void,
};

/// A button in every code block header.
pub const CodeAction = struct {
    label: []const u8,
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, lang: []const u8, code: []const u8) void,
};

/// The theme colour of a class.
pub fn classToken(c: SyntaxClass) Token {
    return switch (c) {
        .keyword => .accent,
        .string => .success,
        .comment => .fg_muted,
        .number, .constant => .warning,
        .type => .info,
        .function => .fg_link,
        .plain, .operator, .punctuation => .fg,
    };
}

/// Highlight spans per content hash, and which hash each block shows.
pub const Cache = struct {
    by_hash: std.AutoHashMapUnmanaged(u64, std.ArrayList(Span)) = .empty,
    blocks: std.AutoHashMapUnmanaged(u32, Shown) = .empty,

    const Shown = struct { key: u64, len: u32, lines: u32 };

    /// Frees the spans.
    pub fn deinit(c: *Cache, gpa: Allocator) void {
        var it = c.by_hash.valueIterator();
        while (it.next()) |v| v.deinit(gpa);
        c.by_hash.deinit(gpa);
        c.blocks.deinit(gpa);
    }

    /// The spans block `block` shows (empty if not highlighted).
    pub fn spansOf(c: *const Cache, block: u32) []const Span {
        const shown = c.blocks.get(block) orelse return &.{};
        const v = c.by_hash.getPtr(shown.key) orelse return &.{};
        return v.items;
    }

    /// Highlights block `block` if needed: by content hash, debounced
    /// while `open` (still streaming).
    pub fn update(c: *Cache, gpa: Allocator, h: view_mod.Highlighter, stats: *view_mod.Stats, block: u32, lang: []const u8, code: []const u8, open: bool) void {
        const key = hash.of(.{ lang, code });
        const nl: u32 = @intCast(std.mem.count(u8, code, "\n"));
        if (c.blocks.get(block)) |shown| {
            if (shown.key == key) return;
            if (open and code.len < shown.len + 64 and nl == shown.lines and c.by_hash.contains(shown.key)) return;
        }
        if (!c.by_hash.contains(key)) {
            var spans: std.ArrayList(Span) = .empty;
            h.highlight(h.ptr, gpa, lang, code, &spans) catch {
                spans.deinit(gpa);
                return;
            };
            stats.highlighted += 1;
            c.by_hash.put(gpa, key, spans) catch {
                spans.deinit(gpa);
                return;
            };
        }
        // Drop the spans this block showed before, unless another block
        // shows them too.
        if (c.blocks.get(block)) |old| if (old.key != key and !c.shownElsewhere(old.key, block)) {
            if (c.by_hash.fetchRemove(old.key)) |kv| {
                var v = kv.value;
                v.deinit(gpa);
            }
        };
        c.blocks.put(gpa, block, .{ .key = key, .len = @intCast(code.len), .lines = nl }) catch {};
    }

    fn shownElsewhere(c: *const Cache, key: u64, block: u32) bool {
        var it = c.blocks.iterator();
        while (it.next()) |kv| if (kv.key_ptr.* != block and kv.value_ptr.key == key) return true;
        return false;
    }
};

/// The language of a fenced block: the info string's first word.
pub fn langOf(d: *const doc_mod.Doc, i: u32) []const u8 {
    const b = d.blocks.items[i];
    if (b.kind == .math_block) return "math";
    if (b.kind != .code_fenced) return "";
    const info = d.contentOf(b.info);
    const end = std.mem.indexOfAny(u8, info, " \t") orelse info.len;
    return info[0..end];
}

/// Builds code block `i`.
pub fn build(b: *view_mod.Builder, i: u32) void {
    const ui = b.ui;
    const s = b.s;
    const p = b.p;
    const d = s.doc;
    const blk = d.blocks.items[i];
    const lang = langOf(d, i);
    const e = s.entry(i) orelse return;
    const code = e.flat.text.items;
    if (p.highlighter) |h| if (lang.len > 0 and blk.kind != .math_block) {
        s.code.update(s.gpa, h, &s.stats, i, lang, code, !blk.closed);
    };
    const th = ui.theme();
    const wrapped = s.wrapped.contains(blk.src[0]);
    ui.open(.{ .style = .{ .dir = .column, .bg = .{ .token = .bg_sunken }, .border = .{ .token = .border }, .border_w = th.dim(.border_w), .radius = th.dim(.radius_md), .clip = true }, .role = .group, .label = "Code block", .test_id = "md-code" });
    defer ui.close();

    // Header: language, wrap, copy, actions.
    ui.open(.{ .style = .{ .dir = .row, .align_items = .center, .gap = 4, .padding = .{ .l = 10, .r = 4, .t = 2, .b = 2 } } });
    ui.text(if (lang.len > 0) lang else "text", .{ .color = .fg_muted, .wrap = false, .style = .{ .size = th.dim(.font_size_sm) }, .theme_size = false });
    controls.spacer(ui);
    if (blk.kind != .math_block) {
        if (controls.button(ui, .{ .label = if (wrapped) "No wrap" else "Wrap", .variant = .ghost }).clicked) {
            if (wrapped) _ = s.wrapped.remove(blk.src[0]) else s.wrapped.put(s.gpa, blk.src[0], {}) catch {};
            ui.cx().notify();
        }
    }
    for (p.code_actions, 0..) |a, k| {
        ui.id(@as(u64, k));
        if (controls.button(ui, .{ .label = a.label, .variant = .ghost }).clicked) a.f(a.ctx, lang, code);
    }
    if (controls.button(ui, .{ .label = "Copy", .variant = .ghost }).clicked) {
        ui.window().app.clipboard.set(s.gpa, code);
    }
    ui.close();

    // Body: the code, scrolling sideways unless wrapped.
    ui.open(.{ .style = .{ .dir = .column, .scroll_x = !wrapped, .padding = .{ .l = 10, .r = 10, .t = 2, .b = 8 } } });
    defer ui.close();
    var st = b.base;
    st.font = .mono;
    st.size = @round(b.base.size * 0.92);
    b.leaf(i, st, .fg, wrapped, .start);
}

test "highlight cache by hash and streaming debounce" {
    const gpa = std.testing.allocator;
    const Counter = struct {
        n: u32 = 0,
        fn hl(ptr: *anyopaque, a: Allocator, _: []const u8, code: []const u8, out: *std.ArrayList(Span)) Allocator.Error!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.n += 1;
            try out.append(a, .{ .start = 0, .end = @intCast(@min(code.len, 3)), .class = .keyword });
        }
    };
    var counter: Counter = .{};
    const h: Highlighter = .{ .ptr = &counter, .highlight = Counter.hl };
    var stats: view_mod.Stats = .{};
    var c: Cache = .{};
    defer c.deinit(gpa);
    c.update(gpa, h, &stats, 1, "zig", "const x = 1;", false);
    c.update(gpa, h, &stats, 2, "zig", "const x = 1;", false);
    c.update(gpa, h, &stats, 1, "zig", "const x = 1;", false);
    try std.testing.expectEqual(@as(u32, 1), counter.n);
    try std.testing.expectEqual(@as(usize, 1), c.spansOf(2).len);
    // Streaming: small growth on the same line waits.
    c.update(gpa, h, &stats, 3, "zig", "const", true);
    c.update(gpa, h, &stats, 3, "zig", "const y", true);
    try std.testing.expectEqual(@as(u32, 2), counter.n);
    c.update(gpa, h, &stats, 3, "zig", "const y\n", true);
    try std.testing.expectEqual(@as(u32, 3), counter.n);
}
