//! VS Code theme import (E04.F08.S02.T01) against the fixtures in
//! testdata/themes and a `.vsix` zipped here.

const std = @import("std");
const geom = @import("../core/geom.zig");
const tokens = @import("tokens.zig");
const theme_mod = @import("theme.zig");
const vscode = @import("vscode.zig");
const vsix = @import("vsix.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Color = geom.Color;

fn fixture(buf: []u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/testdata/themes/{s}", .{ @import("zg_options").package_root, name });
}

fn hasWarning(r: *const vscode.ImportResult, needle: []const u8) bool {
    for (r.warnings) |w| if (std.mem.indexOf(u8, w, needle) != null) return true;
    return false;
}

test "rgba parsing" {
    try testing.expectEqual(Color{ .r = 0x11, .g = 0x22, .b = 0x33, .a = 0xff }, vscode.parseColor("#123").?);
    try testing.expectEqual(Color{ .r = 0x11, .g = 0x22, .b = 0x33, .a = 0x44 }, vscode.parseColor("#1234").?);
    try testing.expectEqual(Color{ .r = 0xab, .g = 0xcd, .b = 0xef, .a = 0xff }, vscode.parseColor("#ABCDEF").?);
    try testing.expectEqual(Color{ .r = 0xab, .g = 0xcd, .b = 0xef, .a = 0x80 }, vscode.parseColor("#abcdef80").?);
    for ([_][]const u8{ "", "#", "#12", "#12345", "#1234567", "123456", "#gggggg", "red" }) |s| {
        try testing.expectEqual(@as(?Color, null), vscode.parseColor(s));
    }
}

test "include chain merge and colors mapping" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var r = try vscode.importJson(gpa, testing.io, std.Io.Dir.cwd(), try fixture(&buf, "child.json"));
    defer r.deinit();
    const th = &r.source;
    try testing.expectEqualStrings("Fixture Child", th.name);
    // The parent's type.
    try testing.expectEqual(theme_mod.Theme.Kind.light, th.kind);
    // The child overrides; the parent's other colours stay.
    try testing.expectEqual(Color.hex(0xfafafa), th.color(.bg_base));
    try testing.expectEqual(Color.hex(0x202020), th.color(.fg));
    try testing.expectEqual(Color.hex(0xeeeeee), th.color(.bg_sunken));
    try testing.expectEqual(Color.hex(0x0078d4), th.color(.focus_ring));
    try testing.expectEqual(Color.hex(0x0055aa), th.color(.accent));
    // Derived from the closest mapped token.
    try testing.expectEqual(Color.hex(0x0055aa), th.color(.accent_hover));
    try testing.expectEqual(Color.hex(0x0055aa), th.color(.accent_pressed));
    // Not set and not derived: the built-in light theme's.
    try testing.expectEqual(theme_mod.zigguro_light.color(.danger), th.color(.danger));
    // Unknown ids are counted once; invalid colours are named.
    try testing.expect(hasWarning(&r, "2 colour ids have no zigguro token"));
    try testing.expect(hasWarning(&r, "badge.background: invalid colour"));
    // Token rules: parent first, then the child.
    try testing.expectEqual(@as(usize, 4), r.syntax.rules.len);
    const s = r.syntax.styleFor(&.{ "source.zig", "string.quoted.double.zig" });
    try testing.expectEqual(Color.hex(0x0000ff), s.fg.?);
    try testing.expect(s.font_style.?.bold);
    const json = r.syntax.styleFor(&.{ "source.json", "string.quoted.double.json" });
    try testing.expectEqual(@as(?@import("syntax_theme.zig").FontStyleSet, null), json.font_style);
    const cm = r.syntax.styleFor(&.{ "source.zig", "comment.line.double-slash.zig" });
    try testing.expectEqual(Color.hex(0x008000), cm.fg.?);
    try testing.expect(cm.font_style.?.italic);
    try testing.expectEqual(Color.hex(0xa31515), r.syntax.styleFor(&.{ "source.ruby", "constant.other.symbol.ruby" }).fg.?);
}

test "include cycle error" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectError(error.IncludeCycle, vscode.importJson(gpa, testing.io, std.Io.Dir.cwd(), try fixture(&buf, "cycle_a.json")));
}

test "semantic keys parse" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var r = try vscode.importJson(gpa, testing.io, std.Io.Dir.cwd(), try fixture(&buf, "child.json"));
    defer r.deinit();
    try testing.expect(r.syntax.semantic_highlighting);
    try testing.expectEqual(@as(usize, 3), r.syntax.semantic.len);
    try testing.expectEqual(Color.hex(0x795e26), r.syntax.semanticStyle("variable", &.{"readonly"}, "zig").?.fg.?);
    try testing.expect(r.syntax.semanticStyle("class", &.{"declaration"}, null).?.font_style.?.bold);
    const f = r.syntax.semanticStyle("function", &.{}, "c").?;
    try testing.expect(f.font_style.?.underline);
    try testing.expectEqual(@as(?@import("syntax_theme.zig").ResolvedStyle, null), r.syntax.semanticStyle("variable", &.{"readonly"}, "c"));
}

test "kind mapping" {
    try testing.expectEqual(theme_mod.Theme.Kind.dark, vscode.kindOf("vs-dark"));
    try testing.expectEqual(theme_mod.Theme.Kind.light, vscode.kindOf("vs"));
    try testing.expectEqual(theme_mod.Theme.Kind.hc_dark, vscode.kindOf("hc-black"));
    try testing.expectEqual(theme_mod.Theme.Kind.hc_light, vscode.kindOf("hc-light"));
    try testing.expectEqual(theme_mod.Theme.Kind.dark, vscode.kindOf("something"));
}

/// A zip of `files`, deflating those whose name ends in `.json` except
/// `package.json` (stored).
fn buildZip(files: []const [2][]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var central: std.ArrayList(u8) = .empty;
    defer central.deinit(gpa);
    for (files) |f| {
        const name = f[0];
        const raw = f[1];
        const deflate = !std.mem.endsWith(u8, name, "package.json");
        var data: []const u8 = raw;
        var owned: ?[]u8 = null;
        defer if (owned) |o| gpa.free(o);
        if (deflate) {
            var w: std.Io.Writer.Allocating = try .initCapacity(gpa, raw.len + 64);
            defer w.deinit();
            const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
            defer gpa.free(window);
            const c = try gpa.create(std.compress.flate.Compress);
            defer gpa.destroy(c);
            c.* = try .init(&w.writer, window, .raw, .fastest);
            try c.writer.writeAll(raw);
            try c.finish();
            owned = try w.toOwnedSlice();
            data = owned.?;
        }
        const offset: u32 = @intCast(out.items.len);
        const method: u16 = if (deflate) 8 else 0;
        const crc = std.hash.Crc32.hash(raw);
        var lh: [30]u8 = @splat(0);
        lh[0..4].* = "PK\x03\x04".*;
        std.mem.writeInt(u16, lh[8..10], method, .little);
        std.mem.writeInt(u32, lh[14..18], crc, .little);
        std.mem.writeInt(u32, lh[18..22], @intCast(data.len), .little);
        std.mem.writeInt(u32, lh[22..26], @intCast(raw.len), .little);
        std.mem.writeInt(u16, lh[26..28], @intCast(name.len), .little);
        try out.appendSlice(gpa, &lh);
        try out.appendSlice(gpa, name);
        try out.appendSlice(gpa, data);
        var ch: [46]u8 = @splat(0);
        ch[0..4].* = "PK\x01\x02".*;
        std.mem.writeInt(u16, ch[10..12], method, .little);
        std.mem.writeInt(u32, ch[16..20], crc, .little);
        std.mem.writeInt(u32, ch[20..24], @intCast(data.len), .little);
        std.mem.writeInt(u32, ch[24..28], @intCast(raw.len), .little);
        std.mem.writeInt(u16, ch[28..30], @intCast(name.len), .little);
        std.mem.writeInt(u32, ch[42..46], offset, .little);
        try central.appendSlice(gpa, &ch);
        try central.appendSlice(gpa, name);
    }
    const cd_off: u32 = @intCast(out.items.len);
    try out.appendSlice(gpa, central.items);
    var eocd: [22]u8 = @splat(0);
    eocd[0..4].* = "PK\x05\x06".*;
    std.mem.writeInt(u16, eocd[8..10], @intCast(files.len), .little);
    std.mem.writeInt(u16, eocd[10..12], @intCast(files.len), .little);
    std.mem.writeInt(u32, eocd[12..16], @intCast(central.items.len), .little);
    std.mem.writeInt(u32, eocd[16..20], cd_off, .little);
    try out.appendSlice(gpa, &eocd);
    return out.toOwnedSlice(gpa);
}

test "vsix list and import" {
    const pkg =
        \\{ "name": "fixture-themes", "contributes": { "themes": [
        \\  { "label": "Fixture Dark", "uiTheme": "vs-dark", "path": "./themes/dark.json" },
        \\  { "label": "Fixture HC", "uiTheme": "hc-black", "path": "./themes/hc.json" },
        \\] } }
    ;
    const dark =
        \\{ "include": "../shared/common.json", "colors": { "editor.background": "#1e1e1e" } }
    ;
    const common =
        \\{ "name": "Common", "colors": { "editor.foreground": "#d4d4d4", "editor.background": "#000000" },
        \\  "tokenColors": [ { "scope": "keyword", "settings": { "foreground": "#569cd6" } } ] }
    ;
    const hc =
        \\{ "name": "HC", "colors": { "editor.background": "#000000", "editor.foreground": "#ffffff" } }
    ;
    const zip = try buildZip(&.{
        .{ "extension/package.json", pkg },
        .{ "extension/themes/dark.json", dark },
        .{ "extension/shared/common.json", common },
        .{ "extension/themes/hc.json", hc },
    });
    defer gpa.free(zip);

    var ar: std.heap.ArenaAllocator = .init(gpa);
    defer ar.deinit();
    const z = try vsix.Zip.parse(ar.allocator(), zip);
    const list = try vsix.listInZip(ar.allocator(), z);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("Fixture Dark", list[0].label);
    try testing.expectEqualStrings("extension/themes/dark.json", list[0].path);

    var r = try vsix.importZipBytes(gpa, zip, "Fixture Dark");
    defer r.deinit();
    try testing.expectEqualStrings("Common", r.source.name);
    try testing.expectEqual(theme_mod.Theme.Kind.dark, r.source.kind);
    try testing.expectEqual(Color.hex(0x1e1e1e), r.source.color(.bg_base));
    try testing.expectEqual(Color.hex(0xd4d4d4), r.source.color(.fg));
    try testing.expectEqual(Color.hex(0x569cd6), r.syntax.styleFor(&.{ "source.zig", "keyword.control.zig" }).fg.?);

    var h = try vsix.importZipBytes(gpa, zip, "Fixture HC");
    defer h.deinit();
    try testing.expectEqual(theme_mod.Theme.Kind.hc_dark, h.source.kind);
    try testing.expectError(error.ThemeNotFound, vsix.importZipBytes(gpa, zip, "Missing"));
    try testing.expectError(error.InvalidVsix, vsix.importZipBytes(gpa, "not a zip", "x"));
}

test "a theme with poor contrast gets lint warnings" {
    const Mem = struct {
        fn load(_: *anyopaque, a: std.mem.Allocator, _: []const u8) anyerror![]const u8 {
            return a.dupe(u8, "{ \"colors\": { \"editor.background\": \"#777777\", \"editor.foreground\": \"#808080\" } }");
        }
        fn resolve(_: *anyopaque, a: std.mem.Allocator, _: []const u8, rel: []const u8) std.mem.Allocator.Error![]const u8 {
            return a.dupe(u8, rel);
        }
    };
    var dummy: u8 = 0;
    var r = try vscode.importWith(gpa, .{ .ctx = &dummy, .load = Mem.load, .resolve = Mem.resolve }, "mem.json", null);
    defer r.deinit();
    try testing.expect(hasWarning(&r, "contrast: fg on bg.base"));
    try testing.expectEqualStrings("imported", r.source.name);
}
