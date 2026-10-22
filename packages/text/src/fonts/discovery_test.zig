//! Font discovery tests: the XML tokenizer, fontconfig parsing and the
//! Linux loader over fixture trees in `testdata/fontconfig/` (a fake
//! root and HOME through `Options.sysroot` and an injected environment),
//! and font file listing.

const std = @import("std");
const testing = std.testing;
const options = @import("zg_options");
const xml = @import("xml.zig");
const fc = @import("fontconfig_xml.zig");
const discovery = @import("discovery.zig");
const linux = @import("discovery_linux.zig");

fn collect(gpa: std.mem.Allocator, src: []const u8) ![]xml.Token {
    var out: std.ArrayList(xml.Token) = .empty;
    errdefer out.deinit(gpa);
    var t: xml.Tokenizer = .init(src);
    while (try t.next()) |tok| try out.append(gpa, tok);
    return out.toOwnedSlice(gpa);
}

test "xml tokenizer entities/comments/cdata" {
    const gpa = testing.allocator;
    const src =
        \\<?xml version="1.0"?>
        \\<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd" [ <!ENTITY x "y"> ]>
        \\<a k='v&amp;w' j = "2"><!-- <b>not a tag</b> --><![CDATA[<c>]]>x &lt;&#65;&#x42;&gt; &quot;&apos;<e/></a>
    ;
    const toks = try collect(gpa, src);
    defer gpa.free(toks);
    // "\n" texts after the declarations, then the elements.
    var tags: std.ArrayList(u8) = .empty;
    defer tags.deinit(gpa);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (toks) |t| switch (t) {
        .start => |s| {
            try tags.appendSlice(gpa, "<");
            try tags.appendSlice(gpa, s.name);
            try testing.expectEqualStrings("v&amp;w", s.attrs.get("k").?);
            try testing.expectEqualStrings("2", s.attrs.get("j").?);
            try testing.expect(s.attrs.get("z") == null);
            const v = try xml.unescape(gpa, s.attrs.get("k").?);
            defer gpa.free(v);
            try testing.expectEqualStrings("v&w", v);
        },
        .empty => |e| {
            try tags.appendSlice(gpa, "<");
            try tags.appendSlice(gpa, e.name);
            try tags.appendSlice(gpa, "/");
        },
        .end => |n| {
            try tags.appendSlice(gpa, "</");
            try tags.appendSlice(gpa, n);
        },
        .text => |raw| {
            const u = try xml.unescape(gpa, raw);
            defer gpa.free(u);
            try text.appendSlice(gpa, u);
        },
    };
    try testing.expectEqualStrings("<a<e/</a", tags.items);
    try testing.expectEqualStrings("\n\nx <AB> \"'", text.items);
}

test "xml malformed -> error" {
    const bad = [_][]const u8{
        "<a",
        "<a b>",
        "<a b=c>",
        "<a b='c>",
        "</>",
        "<!-- open",
        "<![CDATA[ open",
        "<>",
        "<a></a",
    };
    for (bad) |src| {
        var t: xml.Tokenizer = .init(src);
        const r = while (true) {
            const tok = t.next() catch |e| break e;
            if (tok == null) break error.NoError;
        };
        try testing.expectEqual(error.Malformed, r);
    }
    for ([_][]const u8{ "&bogus;", "&#xD800;", "&#0;", "&amp", "&#x110000;" }) |raw|
        try testing.expectError(error.Malformed, xml.unescape(testing.allocator, raw));
}

test "fontconfig parse items" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const items = try fc.parse(arena.allocator(),
        \\<fontconfig>
        \\  <dir prefix="xdg"> fonts </dir>
        \\  <include ignore_missing="yes">conf.d</include>
        \\  <alias><family>a</family><family>b</family><prefer><family>P</family></prefer></alias>
        \\  <selectfont><rejectfont><glob>*.pcf</glob></rejectfont></selectfont>
        \\</fontconfig>
    );
    try testing.expectEqual(4, items.len);
    try testing.expectEqualStrings("fonts", items[0].dir.path);
    try testing.expectEqual(fc.Prefix.xdg, items[0].dir.prefix);
    try testing.expect(items[1].include.ignore_missing);
    try testing.expectEqualStrings("a", items[2].alias.family);
    try testing.expectEqualStrings("b", items[3].alias.family);
    try testing.expectEqualStrings("P", items[3].alias.prefer[0]);
    try testing.expectError(error.Malformed, fc.parse(arena.allocator(), "<fontconfig><dir>x</include></fontconfig>"));
}

test "match-prepend pattern" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const items = try fc.parse(arena.allocator(),
        \\<fontconfig>
        \\  <match target="pattern">
        \\    <test qual="any" name="family"><string>monospace</string></test>
        \\    <edit name="family" mode="prepend" binding="strong"><string>X1</string><string>X2</string></edit>
        \\    <edit name="family" mode="append_last"><string>Z</string></edit>
        \\  </match>
        \\  <match><test name="family"><string>serif</string></test><test name="lang"><string>ja</string></test>
        \\    <edit name="family" mode="prepend"><string>No</string></edit></match>
        \\  <match target="font"><test name="family"><string>serif</string></test>
        \\    <edit name="family" mode="prepend"><string>No</string></edit></match>
        \\  <match><test name="family" compare="contains"><string>serif</string></test>
        \\    <edit name="family" mode="prepend"><string>No</string></edit></match>
        \\  <match><test name="family"><string>serif</string></test>
        \\    <edit name="family" mode="assign"><string>No</string></edit></match>
        \\</fontconfig>
    );
    try testing.expectEqual(1, items.len);
    const a = items[0].alias;
    try testing.expectEqualStrings("monospace", a.family);
    try testing.expectEqual(2, a.prefer.len);
    try testing.expectEqualStrings("X2", a.prefer[1]);
    try testing.expectEqualStrings("Z", a.default[0]);
}

const Fixture = struct {
    env: std.process.Environ.Map,
    root: []u8,

    fn init(case: []const u8) !Fixture {
        const gpa = testing.allocator;
        var env: std.process.Environ.Map = .init(gpa);
        errdefer env.deinit();
        try env.put("HOME", "/home/u");
        return .{ .env = env, .root = try std.fs.path.join(gpa, &.{ options.package_root, "testdata", "fontconfig", case }) };
    }

    fn deinit(f: *Fixture) void {
        f.env.deinit();
        testing.allocator.free(f.root);
    }

    fn discover(f: *Fixture) !linux.Discovery {
        return linux.discoverWith(testing.allocator, testing.io, &f.env, .{ .sysroot = f.root });
    }

    /// The dirs without the sysroot.
    fn expectDirs(f: *const Fixture, d: linux.Discovery, want: []const []const u8) !void {
        var got: std.ArrayList([]const u8) = .empty;
        defer got.deinit(testing.allocator);
        for (d.dirs) |p| {
            try testing.expect(std.mem.startsWith(u8, p, f.root));
            try got.append(testing.allocator, p[f.root.len..]);
        }
        try testing.expectEqualDeep(want, got.items);
    }
};

test "dir prefixes" {
    var f: Fixture = try .init("root");
    defer f.deinit();
    var d = try f.discover();
    defer d.deinit(testing.allocator);
    try f.expectDirs(d, &.{
        "/usr/share/fonts",
        "/home/u/.local/share/fonts", // prefix="xdg"
        "/home/u/.fonts", // ~
        "/etc/fonts/local-fonts", // prefix="relative"
        "/opt/f&b", // entity
        "/usr/share/fonts/truetype", // conf.d/10-a.conf
        "/usr/local/share/fonts", // XDG_DATA_DIRS default
    });
}

test "include dir ordering" {
    // 10-a, 2-b, 30-c, 40-match in byte order; notes.conf, README and
    // the malformed 50-bad.conf contribute nothing.
    var f: Fixture = try .init("root");
    defer f.deinit();
    var d = try f.discover();
    defer d.deinit(testing.allocator);
    for (d.aliases) |a| for (a.prefer) |p| {
        try testing.expect(!std.mem.eql(u8, p, "NotRead"));
        try testing.expect(!std.mem.eql(u8, p, "Bad"));
    };
    try testing.expectEqualStrings("A1", d.aliases[0].prefer[0]);
    try testing.expectEqualStrings("B1", d.aliases[1].prefer[0]);
    try testing.expectEqualStrings("C2", d.aliases[2].accept[0]);
    try testing.expectEqualStrings("X1", d.aliases[3].prefer[0]);
}

test "include cycle" {
    // 2-b.conf includes fonts.conf and 30-c.conf includes conf.d: each
    // file is read once, so every alias appears once.
    var f: Fixture = try .init("root");
    defer f.deinit();
    var d = try f.discover();
    defer d.deinit(testing.allocator);
    try testing.expectEqual(6, d.aliases.len);
}

test "alias collection order" {
    var f: Fixture = try .init("root");
    defer f.deinit();
    var d = try f.discover();
    defer d.deinit(testing.allocator);
    const want = [_][]const u8{ "monospace", "monospace", "monospace", "monospace", "serif", "sans-serif" };
    for (want, d.aliases) |w, a| try testing.expectEqualStrings(w, a.family);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // prefer in rule order, accept in reverse rule order, then defaults.
    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "A1", "B1", "X1", "X2", "C2", "C1", "D1" }),
        try d.preferences(arena.allocator(), "Monospace"),
    );
    try testing.expectEqualDeep(@as([]const []const u8, &.{"User Sans"}), try d.preferences(arena.allocator(), "sans-serif"));
    try testing.expectEqual(0, (try d.preferences(arena.allocator(), "cursive")).len);
}

test "FONTCONFIG_FILE and XDG overrides" {
    var f: Fixture = try .init("root");
    defer f.deinit();
    try f.env.put("FONTCONFIG_FILE", "alt.conf"); // relative to /etc/fonts
    try f.env.put("XDG_DATA_HOME", "/nowhere");
    try f.env.put("XDG_CONFIG_HOME", "/nowhere");
    try f.env.put("XDG_DATA_DIRS", "/usr/local/share");
    var d = try f.discover();
    defer d.deinit(testing.allocator);
    try f.expectDirs(d, &.{ "/usr/share/fonts/truetype", "/usr/local/share/fonts", "/home/u/.fonts", "/usr/share/fonts" });
    try testing.expectEqual(0, d.aliases.len);
}

test "default dirs when no config" {
    var f: Fixture = try .init("noconfig");
    defer f.deinit();
    var d = try f.discover();
    defer d.deinit(testing.allocator);
    try f.expectDirs(d, &.{ "/usr/share/fonts", "/home/u/.fonts" });
    try testing.expectEqual(0, d.aliases.len);
}

test "listFontFiles extension filter and symlink loop" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "fonts/sub/deeper");
    for ([_][]const u8{ "fonts/a.ttf", "fonts/B.OTF", "fonts/c.ttc", "fonts/sub/d.otc", "fonts/sub/deeper/e.ttf", "fonts/x.pcf", "fonts/x.woff2", "fonts/x.bdf", "fonts/x.pfb", "fonts/noext" }) |p|
        try tmp.dir.writeFile(io, .{ .sub_path = p, .data = "x" });
    // A loop back to the top and a second way into sub/.
    try tmp.dir.symLink(io, "..", "fonts/sub/deeper/loop", .{ .is_directory = true });
    try tmp.dir.symLink(io, "sub", "fonts/alias", .{ .is_directory = true });
    try tmp.dir.symLink(io, "a.ttf", "fonts/link.ttf", .{});

    const base = try tmp.dir.realPathFileAlloc(io, "fonts", gpa);
    defer gpa.free(base);
    var out: std.ArrayList(discovery.FileEntry) = .empty;
    defer discovery.freeFileEntries(gpa, &out);
    try discovery.listFontFiles(gpa, io, &.{ base, base }, &out);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    for (out.items) |e| {
        try testing.expectEqual(1, e.size);
        try names.append(gpa, e.path[base.len + 1 ..]);
    }
    // Each directory once (through whichever path reaches it first, in
    // byte order); the file symlink is a file of its own.
    const want: []const []const u8 = &.{ "B.OTF", "a.ttf", "c.ttc", "link.ttf", "alias/d.otc", "alias/deeper/e.ttf" };
    try testing.expectEqualDeep(want, names.items);
}

test "fuzz: xml-tokenizer" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [2048]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            var t: xml.Tokenizer = .init(input);
            var n: usize = 0;
            while (t.next() catch return) |tok| : (n += 1) {
                try testing.expect(n <= input.len);
                switch (tok) {
                    .start, .empty => |tag| {
                        var it = tag.attrs;
                        while (try it.next()) |a| {
                            const u = xml.unescape(testing.allocator, a.value) catch continue;
                            testing.allocator.free(u);
                        }
                    },
                    .text => |raw| {
                        const u = xml.unescape(testing.allocator, raw) catch continue;
                        testing.allocator.free(u);
                    },
                    .end => {},
                }
            }
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            _ = fc.parse(arena.allocator(), input) catch {};
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "xml") });
}
