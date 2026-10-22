//! JSONC (JSON with `//` and `/* */` comments and trailing commas) reader for
//! imports: VS Code settings, keybindings and themes, Claude Code settings
//! and plugin manifests. `stripJsonc` turns comments and trailing commas into
//! spaces without moving any byte, so spans and line numbers of the stripped
//! text match the original. E04's theme importer uses the same stripper.
//!
//! The parser is a small recursive-descent JSON reader that records the span
//! of every value and key (std.json's `parseFromSlice` loses spans).

const std = @import("std");
const diag = @import("diag.zig");
const zon_load = @import("zon_load.zig");

const Allocator = std.mem.Allocator;
const Node = zon_load.Node;
const Field = zon_load.Field;
const Doc = zon_load.Doc;
const Diags = diag.Diags;
const Span = diag.Span;

/// Errors of `stripJsonc`.
pub const StripError = error{ OutOfMemory, UnterminatedComment };

/// Returns a copy of `src` with comments replaced by spaces (newlines kept)
/// and trailing commas before `}`/`]` replaced by a space. Byte offsets are
/// unchanged. `//` inside strings is kept.
pub fn stripJsonc(gpa: Allocator, src: []const u8) StripError![]u8 {
    const out = try gpa.dupe(u8, src);
    errdefer gpa.free(out);
    try stripInPlace(out);
    return out;
}

/// `stripJsonc` on a mutable buffer.
pub fn stripInPlace(buf: []u8) error{UnterminatedComment}!void {
    var i: usize = 0;
    // Index of a comma that is the last significant byte so far, if any.
    var pending_comma: ?usize = null;
    while (i < buf.len) {
        const c = buf[i];
        switch (c) {
            '"' => {
                pending_comma = null;
                i += 1;
                while (i < buf.len and buf[i] != '"') : (i += 1) {
                    if (buf[i] == '\\') i += 1;
                }
                i += 1;
            },
            '/' => {
                if (i + 1 < buf.len and buf[i + 1] == '/') {
                    while (i < buf.len and buf[i] != '\n') : (i += 1) buf[i] = ' ';
                } else if (i + 1 < buf.len and buf[i + 1] == '*') {
                    const start = i;
                    i += 2;
                    while (i + 1 < buf.len and !(buf[i] == '*' and buf[i + 1] == '/')) i += 1;
                    if (i + 1 >= buf.len) return error.UnterminatedComment;
                    i += 2;
                    for (buf[start..i]) |*b| {
                        if (b.* != '\n' and b.* != '\r') b.* = ' ';
                    }
                } else {
                    pending_comma = null;
                    i += 1;
                }
            },
            ',' => {
                pending_comma = i;
                i += 1;
            },
            '}', ']' => {
                if (pending_comma) |p| buf[p] = ' ';
                pending_comma = null;
                i += 1;
            },
            ' ', '\t', '\r', '\n' => i += 1,
            else => {
                pending_comma = null;
                i += 1;
            },
        }
    }
}

/// Parses JSONC `source` into a `Doc` whose spans index `source`. Errors go
/// to `diags` and return `error.Invalid`. Duplicate keys keep the first
/// occurrence with an error diagnostic, like the ZON loader.
pub fn loadJsonc(gpa: Allocator, source: []const u8, diags: *Diags) zon_load.Error!Doc {
    if (source.len > zon_load.max_file_bytes) {
        diags.add(.none, .err, "file is larger than {d} bytes", .{zon_load.max_file_bytes});
        return error.Invalid;
    }
    var doc: Doc = .{ .arena = .init(gpa), .source = undefined, .root = undefined, .line_starts = undefined };
    errdefer doc.arena.deinit();
    const a = doc.arena.allocator();
    const stripped = try a.dupeZ(u8, source);
    stripInPlace(stripped) catch {
        const off: u32 = @intCast(std.mem.lastIndexOf(u8, source, "/*") orelse 0);
        diags.add(.{ .start = off, .end = off + 2 }, .err, "unterminated block comment", .{});
        return error.Invalid;
    };
    doc.source = try a.dupeZ(u8, source);
    doc.line_starts = try zon_load.lineStarts(a, source);
    var p: Parser = .{ .a = a, .src = stripped, .diags = diags };
    p.skipWs();
    doc.root = p.value(0) catch |e| switch (e) {
        error.Syntax => return error.Invalid,
        error.OutOfMemory => return error.OutOfMemory,
    };
    p.skipWs();
    if (p.i < p.src.len) {
        p.fail("unexpected trailing content", .{}) catch {};
        return error.Invalid;
    }
    return doc;
}

const Parser = struct {
    a: Allocator,
    src: []const u8,
    i: u32 = 0,
    diags: *Diags,

    const PErr = error{ Syntax, OutOfMemory };

    fn fail(p: *Parser, comptime fmt: []const u8, args: anytype) PErr {
        p.diags.add(.{ .start = p.i, .end = @min(p.i + 1, @as(u32, @intCast(p.src.len))) }, .err, fmt, args);
        return error.Syntax;
    }

    fn skipWs(p: *Parser) void {
        while (p.i < p.src.len) switch (p.src[p.i]) {
            ' ', '\t', '\r', '\n' => p.i += 1,
            else => return,
        };
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.i < p.src.len) p.src[p.i] else null;
    }

    fn value(p: *Parser, depth: u32) PErr!Node {
        if (depth > zon_load.max_depth) return p.fail("nesting deeper than {d}", .{zon_load.max_depth});
        const start = p.i;
        const c = p.peek() orelse return p.fail("unexpected end of input", .{});
        const kind: zon_load.Kind = switch (c) {
            '{' => try p.object(depth),
            '[' => try p.array(depth),
            '"' => .{ .string = try p.string() },
            't' => try p.word("true", .{ .bool = true }),
            'f' => try p.word("false", .{ .bool = false }),
            'n' => try p.word("null", .null),
            '-', '0'...'9' => try p.number(),
            else => return p.fail("unexpected character '{c}'", .{c}),
        };
        return .{ .v = kind, .span = .{ .start = start, .end = p.i } };
    }

    fn word(p: *Parser, w: []const u8, k: zon_load.Kind) PErr!zon_load.Kind {
        if (!std.mem.startsWith(u8, p.src[p.i..], w)) return p.fail("invalid literal", .{});
        p.i += @intCast(w.len);
        return k;
    }

    fn number(p: *Parser) PErr!zon_load.Kind {
        const start = p.i;
        var is_float = false;
        if (p.peek() == '-') p.i += 1;
        while (p.peek()) |c| switch (c) {
            '0'...'9' => p.i += 1,
            '.', 'e', 'E', '+', '-' => {
                is_float = true;
                p.i += 1;
            },
            else => break,
        };
        const text = p.src[start..p.i];
        if (!is_float) {
            if (std.fmt.parseInt(i64, text, 10)) |v| return .{ .int = v } else |_| {}
        }
        const f = std.fmt.parseFloat(f64, text) catch {
            p.i = start;
            return p.fail("invalid number", .{});
        };
        return .{ .float = f };
    }

    fn string(p: *Parser) PErr![]const u8 {
        p.i += 1; // opening quote
        const start = p.i;
        // Fast path: no escapes.
        while (p.i < p.src.len and p.src[p.i] != '"' and p.src[p.i] != '\\' and p.src[p.i] >= 0x20) p.i += 1;
        if (p.peek() == '"') {
            const s = p.src[start..p.i];
            p.i += 1;
            return p.a.dupe(u8, s);
        }
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(p.a, p.src[start..p.i]);
        while (true) {
            const c = p.peek() orelse return p.fail("unterminated string", .{});
            switch (c) {
                '"' => {
                    p.i += 1;
                    break;
                },
                '\\' => {
                    p.i += 1;
                    const e = p.peek() orelse return p.fail("unterminated string", .{});
                    p.i += 1;
                    switch (e) {
                        '"', '\\', '/' => try out.append(p.a, e),
                        'b' => try out.append(p.a, 8),
                        'f' => try out.append(p.a, 12),
                        'n' => try out.append(p.a, '\n'),
                        'r' => try out.append(p.a, '\r'),
                        't' => try out.append(p.a, '\t'),
                        'u' => {
                            var cp: u21 = try p.hex4();
                            if (cp >= 0xD800 and cp < 0xDC00) {
                                if (!std.mem.startsWith(u8, p.src[p.i..], "\\u")) return p.fail("lone surrogate", .{});
                                p.i += 2;
                                const lo = try p.hex4();
                                if (lo < 0xDC00 or lo > 0xDFFF) return p.fail("invalid surrogate pair", .{});
                                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                            } else if (cp >= 0xDC00 and cp <= 0xDFFF) return p.fail("lone surrogate", .{});
                            var buf: [4]u8 = undefined;
                            const n = std.unicode.utf8Encode(cp, &buf) catch return p.fail("invalid code point", .{});
                            try out.appendSlice(p.a, buf[0..n]);
                        },
                        else => return p.fail("invalid escape", .{}),
                    }
                },
                0...0x1f => return p.fail("control character in string", .{}),
                else => {
                    try out.append(p.a, c);
                    p.i += 1;
                },
            }
            if (out.items.len > zon_load.max_string_bytes) return p.fail("string longer than {d} bytes", .{zon_load.max_string_bytes});
        }
        return out.items;
    }

    fn hex4(p: *Parser) PErr!u21 {
        if (p.i + 4 > p.src.len) return p.fail("truncated \\u escape", .{});
        const v = std.fmt.parseInt(u16, p.src[p.i..][0..4], 16) catch return p.fail("invalid \\u escape", .{});
        p.i += 4;
        return v;
    }

    fn array(p: *Parser, depth: u32) PErr!zon_load.Kind {
        p.i += 1;
        var items: std.ArrayList(Node) = .empty;
        p.skipWs();
        if (p.peek() == ']') {
            p.i += 1;
            return .{ .array = &.{} };
        }
        while (true) {
            p.skipWs();
            try items.append(p.a, try p.value(depth + 1));
            p.skipWs();
            const c = p.peek() orelse return p.fail("unterminated array", .{});
            p.i += 1;
            if (c == ']') break;
            if (c != ',') {
                p.i -= 1;
                return p.fail("expected ',' or ']'", .{});
            }
        }
        return .{ .array = items.items };
    }

    fn object(p: *Parser, depth: u32) PErr!zon_load.Kind {
        p.i += 1;
        var fields: std.ArrayList(Field) = .empty;
        p.skipWs();
        if (p.peek() == '}') {
            p.i += 1;
            return .{ .object = &.{} };
        }
        while (true) {
            p.skipWs();
            if (p.peek() != '"') return p.fail("expected a string key", .{});
            const kstart = p.i;
            const key = try p.string();
            const key_span: Span = .{ .start = kstart, .end = p.i };
            p.skipWs();
            if (p.peek() != ':') return p.fail("expected ':'", .{});
            p.i += 1;
            p.skipWs();
            const v = try p.value(depth + 1);
            const dup = for (fields.items) |f| {
                if (std.mem.eql(u8, f.key, key)) break true;
            } else false;
            if (dup) {
                p.diags.add(key_span, .err, "duplicate key '{s}'; the first occurrence wins", .{key});
            } else try fields.append(p.a, .{ .key = key, .key_span = key_span, .value = v });
            p.skipWs();
            const c = p.peek() orelse return p.fail("unterminated object", .{});
            p.i += 1;
            if (c == '}') break;
            if (c != ',') {
                p.i -= 1;
                return p.fail("expected ',' or '}}'", .{});
            }
        }
        return .{ .object = fields.items };
    }
};

test "jsonc: comments and trailing commas stripped, offsets preserved" {
    const src =
        \\{
        \\  // line comment
        \\  "a": 1, /* block
        \\  comment */ "b": [1, 2,],
        \\}
    ;
    const out = try stripJsonc(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(src.len, out.len);
    try std.testing.expect(std.mem.indexOf(u8, out, "comment") == null);
    try std.testing.expectEqual(std.mem.count(u8, src, "\n"), std.mem.count(u8, out, "\n"));
    var d = Diags.init(std.testing.allocator);
    defer d.deinit();
    var doc = try loadJsonc(std.testing.allocator, src, &d);
    defer doc.deinit();
    try std.testing.expectEqual(@as(i64, 1), doc.root.get("a").?.v.int);
    const b = doc.root.get("b").?;
    try std.testing.expectEqualStrings("[1, 2,]", b.span.slice(src));
    try std.testing.expectEqual(@as(u32, 4), doc.lineCol(b.span.start).line);
}

test "jsonc: // inside strings kept" {
    var d = Diags.init(std.testing.allocator);
    defer d.deinit();
    var doc = try loadJsonc(std.testing.allocator, "{\"url\": \"http://x/*y*/\", \"q\": \"a\\\"//b\"}", &d);
    defer doc.deinit();
    try std.testing.expectEqualStrings("http://x/*y*/", doc.root.get("url").?.v.string);
    try std.testing.expectEqualStrings("a\"//b", doc.root.get("q").?.v.string);
}

test "jsonc: unterminated block comment → diag" {
    var d = Diags.init(std.testing.allocator);
    defer d.deinit();
    try std.testing.expectError(error.Invalid, loadJsonc(std.testing.allocator, "{ /* oops ", &d));
    try std.testing.expect(d.contains("unterminated block comment"));
}

test "jsonc: nested depth limit" {
    var d = Diags.init(std.testing.allocator);
    defer d.deinit();
    const src = "[" ** 80 ++ "]" ** 80;
    try std.testing.expectError(error.Invalid, loadJsonc(std.testing.allocator, src, &d));
    try std.testing.expect(d.contains("nesting"));
}

test "jsonc: escapes, numbers, errors with positions" {
    var d = Diags.init(std.testing.allocator);
    defer d.deinit();
    var doc = try loadJsonc(std.testing.allocator, "{\"s\": \"\\u00e9\\ud83d\\ude00\\n\", \"f\": -1.5e2, \"i\": -7, \"n\": null}", &d);
    defer doc.deinit();
    try std.testing.expectEqualStrings("é😀\n", doc.root.get("s").?.v.string);
    try std.testing.expectEqual(@as(f64, -150), doc.root.get("f").?.v.float);
    try std.testing.expectEqual(@as(i64, -7), doc.root.get("i").?.v.int);
    var d2 = Diags.init(std.testing.allocator);
    defer d2.deinit();
    try std.testing.expectError(error.Invalid, loadJsonc(std.testing.allocator, "{\n  \"a\" 1\n}", &d2));
    try std.testing.expectEqual(@as(u32, 2), diag.lineCol("{\n  \"a\" 1\n}", d2.items()[0].span.start).line);
}

test "fuzz: jsonc" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];
            var d = Diags.init(std.testing.allocator);
            defer d.deinit();
            var doc = loadJsonc(std.testing.allocator, input, &d) catch return;
            doc.deinit();
        }
    }.f, .{});
}
