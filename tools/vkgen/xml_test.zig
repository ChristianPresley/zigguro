const std = @import("std");
const testing = std.testing;
const xml = @import("xml.zig");

fn expectStart(p: *xml.Parser, name: []const u8) !xml.Event.Start {
    const e = try p.next();
    try testing.expect(e == .start);
    try testing.expectEqualStrings(name, e.start.name);
    return e.start;
}

fn expectText(p: *xml.Parser, raw: []const u8) !void {
    const e = try p.next();
    try testing.expect(e == .text);
    try testing.expectEqualStrings(raw, e.text.raw);
}

fn expectEnd(p: *xml.Parser, name: []const u8) !void {
    const e = try p.next();
    try testing.expect(e == .end);
    try testing.expectEqualStrings(name, e.end);
}

test "xml: elements, attributes both quote styles, self-closing" {
    var p: xml.Parser = .init("<a x=\"1\" y = 'two'><b/><c z=\"3\" /></a>");
    const a = try expectStart(&p, "a");
    try testing.expect(!a.self_closing);
    try testing.expectEqualStrings("1", a.attrs.get("x").?);
    try testing.expectEqualStrings("two", a.attrs.get("y").?);
    try testing.expect(a.attrs.get("w") == null);
    var it = a.attrs;
    try testing.expectEqualStrings("x", it.next().?.name);
    try testing.expectEqualStrings("y", it.next().?.name);
    try testing.expect(it.next() == null);
    const b = try expectStart(&p, "b");
    try testing.expect(b.self_closing);
    const c = try expectStart(&p, "c");
    try testing.expect(c.self_closing);
    try testing.expectEqualStrings("3", c.attrs.get("z").?);
    try expectEnd(&p, "a");
    try testing.expect(try p.next() == .eof);
}

test "xml: mixed content order preserved" {
    var p: xml.Parser = .init("<member>const <type>void</type>* <name>pNext</name></member>");
    _ = try expectStart(&p, "member");
    try expectText(&p, "const ");
    _ = try expectStart(&p, "type");
    try expectText(&p, "void");
    try expectEnd(&p, "type");
    try expectText(&p, "* ");
    _ = try expectStart(&p, "name");
    try expectText(&p, "pNext");
    try expectEnd(&p, "name");
    try expectEnd(&p, "member");
    try testing.expect(try p.next() == .eof);
}

test "xml: entities and char refs decode" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const t: xml.RawText = .{ .raw = "&lt;&#65;&#x42;&amp;&quot;&apos;&gt; \xc3\xa9" };
    try t.decode(&out, testing.allocator);
    try testing.expectEqualStrings("<AB&\"'> \xc3\xa9", out.items);
    out.clearRetainingCapacity();
    try testing.expectError(error.InvalidEntity, xml.decodeValue("&nope;", &out, testing.allocator));
    try testing.expectError(error.InvalidEntity, xml.decodeValue("a & b", &out, testing.allocator));
    try testing.expectError(error.InvalidCharRef, xml.decodeValue("&#xD800;", &out, testing.allocator));
    try testing.expectError(error.InvalidCharRef, xml.decodeValue("&#0;", &out, testing.allocator));
    try testing.expect((xml.RawText{ .raw = " \n\t" }).isWhitespace());
    try testing.expect(!(xml.RawText{ .raw = " x " }).isWhitespace());
}

test "xml: comment, PI, CDATA, DOCTYPE skipped correctly" {
    var p: xml.Parser = .init("<?xml version=\"1.0\"?><!DOCTYPE r [<!ENTITY x \"]>\">]><!-- a - b --><r><![CDATA[<&>]]></r>");
    try testing.expectEqualStrings("xml version=\"1.0\"", (try p.next()).pi);
    try testing.expectEqualStrings(" a - b ", (try p.next()).comment);
    _ = try expectStart(&p, "r");
    const t = (try p.next()).text;
    try testing.expect(t.cdata);
    try testing.expectEqualStrings("<&>", t.raw);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try t.decode(&out, testing.allocator);
    try testing.expectEqualStrings("<&>", out.items);
    try expectEnd(&p, "r");
    try testing.expect(try p.next() == .eof);
}

test "xml: mismatched end tag reports line:col" {
    var p: xml.Parser = .init("<a>\n  <b>\n  </c>\n</a>");
    _ = try expectStart(&p, "a");
    try expectText(&p, "\n  ");
    _ = try expectStart(&p, "b");
    try expectText(&p, "\n  ");
    try testing.expectError(error.MismatchedEndTag, p.next());
    const loc = p.location();
    try testing.expectEqual(@as(u32, 3), loc.line);
    try testing.expectEqual(@as(u32, 3), loc.col);
}

test "xml: errors" {
    const cases = [_]struct { []const u8, xml.Error }{
        .{ "<a", error.UnexpectedEof },
        .{ "<a>", error.UnexpectedEof },
        .{ "<1a/>", error.InvalidName },
        .{ "<a x=1/>", error.AttributeSyntax },
        .{ "<a x=\"1\"y=\"2\"/>", error.AttributeSyntax },
        .{ "<a x=\"1\" x='2'/>", error.DuplicateAttribute },
        .{ "<a x=\"1/>", error.UnterminatedTag },
        .{ "</a>", error.MismatchedEndTag },
        .{ "<!-- x", error.UnexpectedEof },
        .{ "<a/ >", error.UnterminatedTag },
    };
    for (cases) |c| {
        var p: xml.Parser = .init(c[0]);
        const got = while (true) {
            const e = p.next() catch |err| break err;
            if (e == .eof) break error.NoError;
        };
        try testing.expectEqual(@as(anyerror, c[1]), got);
    }
    // Depth limit.
    var deep: [(xml.max_depth + 1) * 3]u8 = undefined;
    for (0..xml.max_depth + 1) |i| @memcpy(deep[i * 3 ..][0..3], "<a>");
    var p: xml.Parser = .init(&deep);
    const got = while (true) {
        _ = p.next() catch |err| break err;
    };
    try testing.expectEqual(error.TooDeep, got);
}

test "xml: skipElement nested" {
    var p: xml.Parser = .init("<r><a><b><a/></b><c>t</c></a><d/><e/></r>");
    _ = try expectStart(&p, "r");
    _ = try expectStart(&p, "a");
    try p.skipElement();
    _ = try expectStart(&p, "d");
    try p.skipElement(); // self-closing: nothing to skip
    _ = try expectStart(&p, "e");
    try expectEnd(&p, "r");
    try testing.expect(try p.next() == .eof);
}

test "xml: vendored vk.xml parses end to end" {
    const src = @embedFile("data/vk.xml");
    var p: xml.Parser = .init(src);
    var events: usize = 0;
    while (true) {
        const e = try p.next();
        events += 1;
        if (e == .eof) break;
    }
    // About 150k events for v1.4.330.
    try testing.expect(events > 100_000);
}

test "fuzz: xml parser never panics" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [1024]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            var p: xml.Parser = .init(input);
            var n: usize = 0;
            while (n < 4096) : (n += 1) {
                const e = p.next() catch break;
                switch (e) {
                    .eof => break,
                    .start => |st| {
                        var it = st.attrs;
                        while (it.next()) |_| {}
                        if (n % 3 == 0) p.skipElement() catch break;
                    },
                    .text => |t| {
                        var out: std.ArrayList(u8) = .empty;
                        defer out.deinit(testing.allocator);
                        t.decode(&out, testing.allocator) catch {};
                    },
                    else => {},
                }
            }
            _ = p.location();
        }
    }.one, .{ .corpus = &.{
        @embedFile("testdata/xml/header.xml"),
        @embedFile("testdata/xml/handles.xml"),
        @embedFile("testdata/xml/struct.xml"),
        @embedFile("testdata/xml/enums_partial.xml"),
        @embedFile("testdata/xml/command.xml"),
        @embedFile("testdata/xml/extension.xml"),
    } });
}
