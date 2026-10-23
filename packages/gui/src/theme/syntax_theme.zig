//! Syntax colouring rules (E04.F08.S02.T01): TextMate `tokenColors` rules
//! resolved against a token's scope stack, and VS Code semantic token
//! rules. Each property (foreground, background, font style) comes from
//! the best-ranked rule that sets it; ties go to the later rule, as in
//! VS Code. `styleFor` results are cached by the stack's hash (at most
//! `cache_cap` entries; the cache empties when full).

const std = @import("std");
const geom = @import("../core/geom.zig");
const scope_selector = @import("scope_selector.zig");

const Allocator = std.mem.Allocator;
const Color = geom.Color;
pub const ScopeSelector = scope_selector.ScopeSelector;
const Score = scope_selector.Score;

/// Font style flags.
pub const FontStyleSet = packed struct(u8) {
    italic: bool = false,
    bold: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
    _pad: u4 = 0,

    /// From a `fontStyle` string ("italic bold", "" for none).
    pub fn parse(s: []const u8) FontStyleSet {
        var f: FontStyleSet = .{};
        var it = std.mem.tokenizeAny(u8, s, " \t");
        while (it.next()) |w| {
            if (std.mem.eql(u8, w, "italic")) f.italic = true;
            if (std.mem.eql(u8, w, "bold")) f.bold = true;
            if (std.mem.eql(u8, w, "underline")) f.underline = true;
            if (std.mem.eql(u8, w, "strikethrough")) f.strikethrough = true;
        }
        return f;
    }
};

/// What a token looks like; null properties fall back to the editor's.
pub const ResolvedStyle = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    font_style: ?FontStyleSet = null,
};

/// The theme's syntax rules (slices owned by the import's arena).
pub const SyntaxTheme = struct {
    rules: []const Rule = &.{},
    semantic: []const SemanticRule = &.{},
    /// The theme's `semanticHighlighting`: when false, semantic tokens
    /// must not recolour (E05/E07 check it).
    semantic_highlighting: bool = true,
    cache: *Cache,

    /// One `tokenColors` entry.
    pub const Rule = struct {
        selector: ScopeSelector,
        fg: ?Color = null,
        bg: ?Color = null,
        font_style: ?FontStyleSet = null,
    };

    /// One `semanticTokenColors` entry: `type.mod1.mod2:lang`; `*` is
    /// any type.
    pub const SemanticRule = struct {
        token_type: []const u8,
        modifiers: []const []const u8 = &.{},
        lang: ?[]const u8 = null,
        style: ResolvedStyle,
    };

    pub const cache_cap = 4096;

    /// The memoised `styleFor` results.
    pub const Cache = struct {
        gpa: Allocator,
        map: std.AutoHashMapUnmanaged(u64, ResolvedStyle) = .empty,

        pub fn deinit(c: *Cache) void {
            c.map.deinit(c.gpa);
        }
    };

    /// The style of a token with scope stack `stack` (outermost first).
    pub fn styleFor(t: *const SyntaxTheme, stack: []const []const u8) ResolvedStyle {
        var h: std.hash.Wyhash = .init(0);
        for (stack) |s| {
            h.update(s);
            h.update("\x00");
        }
        const key = h.final();
        if (t.cache.map.get(key)) |s| return s;
        const s = t.resolve(stack);
        if (t.cache.map.count() >= cache_cap) t.cache.map.clearRetainingCapacity();
        t.cache.map.put(t.cache.gpa, key, s) catch {};
        return s;
    }

    /// `styleFor` without the cache.
    pub fn resolve(t: *const SyntaxTheme, stack: []const []const u8) ResolvedStyle {
        var out: ResolvedStyle = .{};
        var best: [3]Score = .{ .none, .none, .none };
        for (t.rules) |r| {
            const s = r.selector.match(stack);
            if (!s.matched()) continue;
            // `>=`: the later of equal rules wins.
            if (r.fg) |c| if (s.order(best[0]) != .lt) {
                best[0] = s;
                out.fg = c;
            };
            if (r.bg) |c| if (s.order(best[1]) != .lt) {
                best[1] = s;
                out.bg = c;
            };
            if (r.font_style) |f| if (s.order(best[2]) != .lt) {
                best[2] = s;
                out.font_style = f;
            };
        }
        return out;
    }

    /// The semantic token style for `token_type` with `modifiers` in
    /// language `lang`, or null when no rule applies (or semantic
    /// highlighting is off). The most specific rule wins: a named type
    /// over `*`, more modifiers, a language over none; ties go to the
    /// later rule.
    pub fn semanticStyle(t: *const SyntaxTheme, token_type: []const u8, modifiers: []const []const u8, lang: ?[]const u8) ?ResolvedStyle {
        if (!t.semantic_highlighting) return null;
        var best: ?ResolvedStyle = null;
        var best_score: u32 = 0;
        for (t.semantic) |r| {
            const wild = std.mem.eql(u8, r.token_type, "*");
            if (!wild and !std.mem.eql(u8, r.token_type, token_type)) continue;
            if (r.lang) |l| if (lang == null or !std.mem.eql(u8, l, lang.?)) continue;
            var all = true;
            for (r.modifiers) |m| {
                var has = false;
                for (modifiers) |x| if (std.mem.eql(u8, x, m)) {
                    has = true;
                    break;
                };
                if (!has) {
                    all = false;
                    break;
                }
            }
            if (!all) continue;
            const score: u32 = 1 + @as(u32, if (wild) 0 else 100) + @as(u32, @intCast(r.modifiers.len)) * 10 + @as(u32, if (r.lang != null) 1 else 0);
            if (score >= best_score) {
                best_score = score;
                best = r.style;
            }
        }
        return best;
    }

    /// Parses a `semanticTokenColors` key (`type.mod1.mod2:lang`).
    pub fn parseSemanticKey(arena: Allocator, key: []const u8) Allocator.Error!SemanticRule {
        var sel = key;
        var lang: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, key, ':')) |c| {
            sel = key[0..c];
            lang = key[c + 1 ..];
        }
        var it = std.mem.splitScalar(u8, sel, '.');
        const ty = it.next() orelse "";
        var mods: std.ArrayList([]const u8) = .empty;
        while (it.next()) |m| if (m.len > 0) try mods.append(arena, m);
        return .{ .token_type = ty, .modifiers = mods.items, .lang = lang, .style = .{} };
    }
};

const testing = std.testing;

fn rule(a: Allocator, sel: []const u8, fg: u24) !SyntaxTheme.Rule {
    return .{ .selector = try ScopeSelector.parse(a, sel), .fg = Color.hex(fg) };
}

test "tie goes to the later rule; properties resolve separately" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var cache: SyntaxTheme.Cache = .{ .gpa = testing.allocator };
    defer cache.deinit();
    var italic = try rule(a, "string", 0);
    italic.fg = null;
    italic.font_style = .{ .italic = true };
    const rules = [_]SyntaxTheme.Rule{
        try rule(a, "string", 0x111111),
        try rule(a, "string", 0x222222),
        try rule(a, "source", 0x333333),
        italic,
    };
    const t: SyntaxTheme = .{ .rules = &rules, .cache = &cache };
    const stack = [_][]const u8{ "source.zig", "string.quoted.double.zig" };
    const s = t.styleFor(&stack);
    try testing.expectEqual(Color.hex(0x222222), s.fg.?);
    try testing.expect(s.font_style.?.italic);
    try testing.expectEqual(@as(?Color, null), s.bg);
    // Cached.
    try testing.expectEqual(@as(u32, 1), cache.map.count());
    _ = t.styleFor(&stack);
    try testing.expectEqual(@as(u32, 1), cache.map.count());
    // Only `source` applies to a plain identifier.
    try testing.expectEqual(Color.hex(0x333333), t.styleFor(&.{ "source.zig", "variable.other" }).fg.?);
}

test "semantic keys parse and match by specificity" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var cache: SyntaxTheme.Cache = .{ .gpa = testing.allocator };
    defer cache.deinit();
    var r0 = try SyntaxTheme.parseSemanticKey(a, "*.declaration");
    r0.style = .{ .font_style = .{ .bold = true } };
    var r1 = try SyntaxTheme.parseSemanticKey(a, "variable.readonly:zig");
    r1.style = .{ .fg = Color.hex(0xabcdef) };
    try testing.expectEqualStrings("variable", r1.token_type);
    try testing.expectEqualStrings("readonly", r1.modifiers[0]);
    try testing.expectEqualStrings("zig", r1.lang.?);
    var r2 = try SyntaxTheme.parseSemanticKey(a, "variable");
    r2.style = .{ .fg = Color.hex(0x010101) };
    var t: SyntaxTheme = .{ .semantic = &.{ r0, r1, r2 }, .cache = &cache };
    try testing.expectEqual(Color.hex(0xabcdef), t.semanticStyle("variable", &.{ "readonly", "declaration" }, "zig").?.fg.?);
    try testing.expectEqual(Color.hex(0x010101), t.semanticStyle("variable", &.{"readonly"}, "c").?.fg.?);
    try testing.expect(t.semanticStyle("function", &.{"declaration"}, null).?.font_style.?.bold);
    try testing.expectEqual(@as(?ResolvedStyle, null), t.semanticStyle("function", &.{}, null));
    t.semantic_highlighting = false;
    try testing.expectEqual(@as(?ResolvedStyle, null), t.semanticStyle("variable", &.{}, null));
}
