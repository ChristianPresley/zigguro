//! VS Code colour theme import (E04.F08.S02.T01): reads a theme JSON
//! (with comments and trailing commas) and its `include` chain into a
//! zigguro `Theme` and a `SyntaxTheme`.
//!
//! - `include` loads the parent first, relative to the including file,
//!   at most 8 deep; a cycle is an error. The child's `colors` and
//!   `semanticTokenColors` override the parent's; `tokenColors` are
//!   concatenated parent first.
//! - `colors` map to tokens through `vscode_map.zon`; tokens a theme does
//!   not set come from the closest mapped token (`derived`) or else from
//!   the built-in theme of the same kind. Ids without a mapping are
//!   counted in one warning.
//! - Colours are `#RGB`, `#RGBA`, `#RRGGBB` or `#RRGGBBAA`; anything else
//!   is a warning and skipped.
//! - A string `tokenColors` (a `.tmTheme` path) is a warning and skipped.
//! - `type` (or a `.vsix`'s `uiTheme`) picks the kind: `vs` light,
//!   `hc-black` high-contrast dark, `hc-light` high-contrast light,
//!   anything else dark.
//! - The imported theme goes through the contrast lint; failures are
//!   warnings.

const std = @import("std");
const geom = @import("../core/geom.zig");
const tokens = @import("tokens.zig");
const theme_mod = @import("theme.zig");
const jsonc = @import("jsonc.zig");
const syntax = @import("syntax_theme.zig");

const Allocator = std.mem.Allocator;
const Color = geom.Color;
const Token = tokens.Token;
const Theme = theme_mod.Theme;
const SyntaxTheme = syntax.SyntaxTheme;
const Value = std.json.Value;

/// One VS Code colour id and the token it sets.
const Pair = struct { id: []const u8, token: []const u8 };
const vscode_map: []const Pair = @import("vscode_map.zon");

/// Tokens no VS Code id sets directly, and the token they follow.
const derived = [_][2]Token{
    .{ .accent_pressed, .accent_hover },
    .{ .accent_hover, .accent },
    .{ .control_checked, .accent },
    .{ .focus_ring, .accent },
    .{ .quick_input_highlight, .accent },
    .{ .fg_link, .accent },
    .{ .button_bg_pressed, .button_bg_hover },
    .{ .button_bg_hover, .button_bg },
    .{ .button_fg, .fg },
    .{ .control_bg, .bg_sunken },
    .{ .bg_overlay, .bg_elevated },
    .{ .bg_elevated, .bg_base },
    .{ .bg_sunken, .bg_base },
    .{ .hover_bg, .selection_bg },
    .{ .track, .border },
    .{ .control_thumb, .scrollbar_thumb },
};

/// The result of an import. `deinit` frees it all.
pub const ImportResult = struct {
    arena: *std.heap.ArenaAllocator,
    gpa: Allocator,
    /// The workbench colours over the built-in theme of the same kind.
    source: Theme,
    syntax: SyntaxTheme,
    warnings: []const []const u8,

    pub fn deinit(r: *ImportResult) void {
        r.syntax.cache.deinit();
        r.gpa.destroy(r.syntax.cache);
        r.arena.deinit();
        r.gpa.destroy(r.arena);
        r.* = undefined;
    }
};

/// Import failures (beyond loading files).
pub const ImportError = error{ InvalidTheme, IncludeCycle, IncludeTooDeep } || Allocator.Error;

/// Reads the files of a theme: `load` returns a file's bytes (allocated
/// in `arena`), `resolve` an include path relative to the including file.
pub const Loader = struct {
    ctx: *anyopaque,
    load: *const fn (ctx: *anyopaque, arena: Allocator, path: []const u8) anyerror![]const u8,
    resolve: *const fn (ctx: *anyopaque, arena: Allocator, from: []const u8, rel: []const u8) Allocator.Error![]const u8,
};

pub const max_include_depth = 8;

/// Imports the theme at `path` (relative to `dir`).
pub fn importJson(gpa: Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !ImportResult {
    const Files = struct {
        io: std.Io,
        dir: std.Io.Dir,
        fn load(ctx: *anyopaque, arena: Allocator, p: []const u8) anyerror![]const u8 {
            const f: *@This() = @ptrCast(@alignCast(ctx));
            return f.dir.readFileAlloc(f.io, p, arena, .limited(16 << 20));
        }
        fn resolve(_: *anyopaque, arena: Allocator, from: []const u8, rel: []const u8) Allocator.Error![]const u8 {
            const base = std.fs.path.dirname(from) orelse return arena.dupe(u8, rel);
            return std.fs.path.join(arena, &.{ base, rel });
        }
    };
    var files: Files = .{ .io = io, .dir = dir };
    return importWith(gpa, .{ .ctx = &files, .load = Files.load, .resolve = Files.resolve }, path, null);
}

/// Imports the theme at `path` through `loader`; `kind_hint` (a `.vsix`
/// `uiTheme`) applies when the theme has no `type`.
pub fn importWith(gpa: Allocator, loader: Loader, path: []const u8, kind_hint: ?[]const u8) !ImportResult {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }
    const cache = try gpa.create(SyntaxTheme.Cache);
    errdefer gpa.destroy(cache);
    cache.* = .{ .gpa = gpa };
    var im: Importer = .{ .a = arena.allocator(), .loader = loader };
    try im.loadFile(path, 0);
    var r: ImportResult = .{ .arena = arena, .gpa = gpa, .source = undefined, .syntax = .{ .cache = cache }, .warnings = &.{} };
    try im.finish(&r, kind_hint);
    return r;
}

/// The kind of a VS Code `type`/`uiTheme` value.
pub fn kindOf(s: []const u8) Theme.Kind {
    if (std.mem.eql(u8, s, "vs") or std.mem.eql(u8, s, "light")) return .light;
    if (std.mem.eql(u8, s, "hc-black") or std.mem.eql(u8, s, "hcDark")) return .hc_dark;
    if (std.mem.eql(u8, s, "hc-light") or std.mem.eql(u8, s, "hcLight")) return .hc_light;
    return .dark;
}

/// `#RGB`, `#RGBA`, `#RRGGBB` or `#RRGGBBAA`.
pub fn parseColor(s: []const u8) ?Color {
    if (s.len < 4 or s[0] != '#') return null;
    const h = s[1..];
    var v: [8]u8 = undefined;
    switch (h.len) {
        3, 4 => for (h, 0..) |c, i| {
            v[i * 2] = c;
            v[i * 2 + 1] = c;
        },
        6, 8 => @memcpy(v[0..h.len], h),
        else => return null,
    }
    const n: usize = if (h.len <= 4) h.len * 2 else h.len;
    var b: [4]u8 = .{ 0, 0, 0, 255 };
    for (0..n / 2) |i| b[i] = std.fmt.parseInt(u8, v[i * 2 ..][0..2], 16) catch return null;
    return .{ .r = b[0], .g = b[1], .b = b[2], .a = b[3] };
}

const Importer = struct {
    a: Allocator,
    loader: Loader,
    /// The include chain being loaded (cycle check).
    chain: std.ArrayList([]const u8) = .empty,
    name: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    colors: std.StringArrayHashMapUnmanaged(Value) = .empty,
    token_colors: std.ArrayList(Value) = .empty,
    semantic: std.StringArrayHashMapUnmanaged(Value) = .empty,
    semantic_on: bool = true,
    warnings: std.ArrayList([]const u8) = .empty,

    fn warn(im: *Importer, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try im.warnings.append(im.a, try std.fmt.allocPrint(im.a, fmt, args));
    }

    fn loadFile(im: *Importer, path: []const u8, depth: u32) !void {
        if (depth > max_include_depth) return error.IncludeTooDeep;
        for (im.chain.items) |p| if (std.mem.eql(u8, p, path)) return error.IncludeCycle;
        try im.chain.append(im.a, path);
        defer _ = im.chain.pop();
        const bytes = try im.loader.load(im.loader.ctx, im.a, path);
        const clean = try jsonc.stripJsonc(im.a, bytes);
        const v = std.json.parseFromSliceLeaky(Value, im.a, clean, .{}) catch return error.InvalidTheme;
        if (v != .object) return error.InvalidTheme;
        const o = v.object;
        if (o.get("include")) |inc| if (inc == .string) {
            try im.loadFile(try im.loader.resolve(im.loader.ctx, im.a, path, inc.string), depth + 1);
        };
        if (o.get("name")) |n| if (n == .string) {
            im.name = n.string;
        };
        if (o.get("type")) |t| if (t == .string) {
            im.kind = t.string;
        };
        if (o.get("colors")) |c| if (c == .object) {
            var it = c.object.iterator();
            while (it.next()) |e| try im.colors.put(im.a, e.key_ptr.*, e.value_ptr.*);
        };
        if (o.get("tokenColors")) |tc| switch (tc) {
            .array => |arr| try im.token_colors.appendSlice(im.a, arr.items),
            .string => |s| try im.warn("tokenColors \"{s}\": .tmTheme files are not supported", .{s}),
            else => {},
        };
        if (o.get("semanticHighlighting")) |s| if (s == .bool) {
            im.semantic_on = s.bool;
        };
        if (o.get("semanticTokenColors")) |c| if (c == .object) {
            var it = c.object.iterator();
            while (it.next()) |e| try im.semantic.put(im.a, e.key_ptr.*, e.value_ptr.*);
        };
    }

    fn color(im: *Importer, what: []const u8, v: Value) Allocator.Error!?Color {
        if (v == .string) if (parseColor(v.string)) |c| return c;
        try im.warn("{s}: invalid colour", .{what});
        return null;
    }

    fn finish(im: *Importer, r: *ImportResult, kind_hint: ?[]const u8) !void {
        const kind = kindOf(im.kind orelse kind_hint orelse "vs-dark");
        const base: *const Theme = switch (kind) {
            .dark => &theme_mod.zigguro_dark,
            .light => &theme_mod.zigguro_light,
            .hc_dark => &theme_mod.zigguro_hc_dark,
            .hc_light => &theme_mod.zigguro_hc_light,
        };
        var th = base.*;
        th.kind = kind;
        th.name = im.name orelse "imported";
        // Workbench colours.
        var set: [Token.count]bool = @splat(false);
        var unmapped: usize = 0;
        var it = im.colors.iterator();
        while (it.next()) |e| {
            const id = e.key_ptr.*;
            var mapped = false;
            for (vscode_map) |p| if (std.mem.eql(u8, p.id, id)) {
                mapped = true;
                break;
            };
            if (!mapped) unmapped += 1;
        }
        for (vscode_map) |p| {
            const t = Token.fromName(p.token) orelse unreachable;
            if (set[@intFromEnum(t)]) continue;
            const v = im.colors.get(p.id) orelse continue;
            const c = try im.color(p.id, v) orelse continue;
            th.colors[@intFromEnum(t)] = c;
            set[@intFromEnum(t)] = true;
        }
        // Later entries feed earlier ones (`accent_hover` from `accent`,
        // then `accent_pressed` from it): resolve until nothing changes.
        var again = true;
        while (again) {
            again = false;
            for (derived) |d| {
                if (set[@intFromEnum(d[0])] or !set[@intFromEnum(d[1])]) continue;
                th.colors[@intFromEnum(d[0])] = th.colors[@intFromEnum(d[1])];
                set[@intFromEnum(d[0])] = true;
                again = true;
            }
        }
        if (unmapped > 0) try im.warn("{d} colour ids have no zigguro token", .{unmapped});

        // Token colours.
        var rules: std.ArrayList(SyntaxTheme.Rule) = .empty;
        for (im.token_colors.items, 0..) |tc, i| {
            if (tc != .object) continue;
            const settings = tc.object.get("settings") orelse continue;
            if (settings != .object) continue;
            var rule: SyntaxTheme.Rule = .{ .selector = .{ .alts = &.{} } };
            var what_buf: [32]u8 = undefined;
            const what = std.fmt.bufPrint(&what_buf, "tokenColors[{d}]", .{i}) catch "tokenColors";
            if (settings.object.get("foreground")) |f| rule.fg = try im.color(what, f);
            if (settings.object.get("background")) |b| rule.bg = try im.color(what, b);
            if (settings.object.get("fontStyle")) |f| if (f == .string) {
                rule.font_style = syntax.FontStyleSet.parse(f.string);
            };
            const scope = tc.object.get("scope") orelse {
                // A rule without a scope sets the editor defaults.
                if (rule.fg) |c| th.colors[@intFromEnum(Token.fg)] = c;
                if (rule.bg) |c| th.colors[@intFromEnum(Token.bg_base)] = c;
                continue;
            };
            switch (scope) {
                .string => |s| rule.selector = try syntax.ScopeSelector.parse(im.a, s),
                .array => |arr| {
                    var joined: std.ArrayList(u8) = .empty;
                    for (arr.items) |x| if (x == .string) {
                        if (joined.items.len > 0) try joined.append(im.a, ',');
                        try joined.appendSlice(im.a, x.string);
                    };
                    rule.selector = try syntax.ScopeSelector.parse(im.a, joined.items);
                },
                else => continue,
            }
            if (rule.selector.alts.len == 0) continue;
            try rules.append(im.a, rule);
        }

        // Semantic token colours.
        var sem: std.ArrayList(SyntaxTheme.SemanticRule) = .empty;
        var sit = im.semantic.iterator();
        while (sit.next()) |e| {
            var rule = try SyntaxTheme.parseSemanticKey(im.a, e.key_ptr.*);
            switch (e.value_ptr.*) {
                .string => rule.style.fg = try im.color(e.key_ptr.*, e.value_ptr.*),
                .object => |o| {
                    if (o.get("foreground")) |f| rule.style.fg = try im.color(e.key_ptr.*, f);
                    var fs: syntax.FontStyleSet = .{};
                    var any = false;
                    if (o.get("fontStyle")) |f| if (f == .string) {
                        fs = syntax.FontStyleSet.parse(f.string);
                        any = true;
                    };
                    inline for (.{ "bold", "italic", "underline", "strikethrough" }) |k| {
                        if (o.get(k)) |b| if (b == .bool) {
                            @field(fs, k) = b.bool;
                            any = true;
                        };
                    }
                    if (any) rule.style.font_style = fs;
                },
                else => continue,
            }
            try sem.append(im.a, rule);
        }

        // The contrast lint.
        var issues: [theme_mod.contrast_pairs.len]theme_mod.LintIssue = undefined;
        const n = theme_mod.lint(&th, &issues);
        for (issues[0..@min(n, issues.len)]) |x| {
            try im.warn("contrast: {s} on {s} is {d:.2}, needs {d:.1}", .{ x.pair.fg.name(), x.pair.bg.name(), x.ratio, x.required });
        }

        r.source = th;
        r.syntax.rules = rules.items;
        r.syntax.semantic = sem.items;
        r.syntax.semantic_highlighting = im.semantic_on;
        r.warnings = im.warnings.items;
    }
};
