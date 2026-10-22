//! The XML subset Wayland protocol files use: elements, single- or
//! double-quoted attributes, self-closing tags, comments, the `<?xml?>`
//! declaration, CDATA (skipped), character data, the five predefined
//! entities and numeric character references. No DTDs. Errors carry a
//! line and column.

const std = @import("std");

/// One attribute; `value` has entities decoded.
pub const Attr = struct { name: []const u8, value: []const u8 };

/// What `Tokenizer.next` returns.
pub const Token = union(enum) {
    /// `<name a="1">`, or the start of `<name/>` (followed by `end`).
    start: struct { name: []const u8, attrs: []const Attr },
    /// `</name>` or the end of a self-closing tag.
    end: []const u8,
    /// Character data between tags, entities decoded.
    text: []const u8,
    eof,
};

/// Errors; the position is in `Tokenizer.line` and `Tokenizer.col`.
pub const Error = error{ Syntax, OutOfMemory };

/// A pull tokenizer. Decoded strings are allocated in `arena`.
pub const Tokenizer = struct {
    src: []const u8,
    arena: std.mem.Allocator,
    pos: usize = 0,
    /// The line and column of the last error (1-based).
    line: u32 = 1,
    col: u32 = 1,
    pending_end: ?[]const u8 = null,
    /// Open element names, to check nesting.
    stack: std.ArrayList([]const u8) = .empty,

    /// A tokenizer over `src`.
    pub fn init(arena: std.mem.Allocator, src: []const u8) Tokenizer {
        return .{ .src = src, .arena = arena };
    }

    fn fail(t: *Tokenizer, at: usize) Error {
        t.line = 1;
        var line_start: usize = 0;
        for (t.src[0..@min(at, t.src.len)], 0..) |c, i| if (c == '\n') {
            t.line += 1;
            line_start = i + 1;
        };
        t.col = @intCast(at - line_start + 1);
        return error.Syntax;
    }

    /// The next token.
    pub fn next(t: *Tokenizer) Error!Token {
        if (t.pending_end) |n| {
            t.pending_end = null;
            return .{ .end = n };
        }
        while (true) {
            if (t.pos >= t.src.len) {
                if (t.stack.items.len != 0) return t.fail(t.pos);
                return .eof;
            }
            if (t.src[t.pos] != '<') {
                const start = t.pos;
                const end = std.mem.indexOfScalarPos(u8, t.src, start, '<') orelse t.src.len;
                t.pos = end;
                const raw = t.src[start..end];
                if (t.stack.items.len == 0) {
                    if (std.mem.trim(u8, raw, " \t\r\n").len != 0) return t.fail(start);
                    continue;
                }
                return .{ .text = try t.decode(raw, start) };
            }
            const rest = t.src[t.pos..];
            if (std.mem.startsWith(u8, rest, "<!--")) {
                const e = std.mem.indexOfPos(u8, t.src, t.pos + 4, "-->") orelse return t.fail(t.pos);
                t.pos = e + 3;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
                const e = std.mem.indexOfPos(u8, t.src, t.pos + 9, "]]>") orelse return t.fail(t.pos);
                t.pos = e + 3;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "<?")) {
                const e = std.mem.indexOfPos(u8, t.src, t.pos + 2, "?>") orelse return t.fail(t.pos);
                t.pos = e + 2;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "<!")) return t.fail(t.pos); // DTDs are not supported
            if (std.mem.startsWith(u8, rest, "</")) {
                const at = t.pos;
                t.pos += 2;
                const name = t.readName() orelse return t.fail(t.pos);
                _ = t.skipSpace();
                if (t.pos >= t.src.len or t.src[t.pos] != '>') return t.fail(t.pos);
                t.pos += 1;
                const open = t.stack.pop() orelse return t.fail(at);
                if (!std.mem.eql(u8, open, name)) return t.fail(at);
                return .{ .end = name };
            }
            return t.startTag();
        }
    }

    fn startTag(t: *Tokenizer) Error!Token {
        t.pos += 1;
        const name = t.readName() orelse return t.fail(t.pos);
        var attrs: std.ArrayList(Attr) = .empty;
        while (true) {
            const had_space = t.skipSpace();
            if (t.pos >= t.src.len) return t.fail(t.pos);
            const c = t.src[t.pos];
            if (c == '>') {
                t.pos += 1;
                try t.stack.append(t.arena, name);
                break;
            }
            if (c == '/') {
                if (t.pos + 1 >= t.src.len or t.src[t.pos + 1] != '>') return t.fail(t.pos);
                t.pos += 2;
                t.pending_end = name;
                break;
            }
            if (!had_space) return t.fail(t.pos);
            const an = t.readName() orelse return t.fail(t.pos);
            _ = t.skipSpace();
            if (t.pos >= t.src.len or t.src[t.pos] != '=') return t.fail(t.pos);
            t.pos += 1;
            _ = t.skipSpace();
            if (t.pos >= t.src.len) return t.fail(t.pos);
            const q = t.src[t.pos];
            if (q != '"' and q != '\'') return t.fail(t.pos);
            const vstart = t.pos + 1;
            const vend = std.mem.indexOfScalarPos(u8, t.src, vstart, q) orelse return t.fail(t.pos);
            if (std.mem.indexOfScalar(u8, t.src[vstart..vend], '<') != null) return t.fail(vstart);
            t.pos = vend + 1;
            try attrs.append(t.arena, .{ .name = an, .value = try t.decode(t.src[vstart..vend], vstart) });
        }
        return .{ .start = .{ .name = name, .attrs = attrs.items } };
    }

    fn skipSpace(t: *Tokenizer) bool {
        const start = t.pos;
        while (t.pos < t.src.len and std.ascii.isWhitespace(t.src[t.pos])) t.pos += 1;
        return t.pos > start;
    }

    fn readName(t: *Tokenizer) ?[]const u8 {
        const start = t.pos;
        while (t.pos < t.src.len) : (t.pos += 1) {
            const c = t.src[t.pos];
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == ':' or c == '.' or c >= 0x80)) break;
        }
        if (t.pos == start or std.ascii.isDigit(t.src[start])) return null;
        return t.src[start..t.pos];
    }

    /// Decodes entities in `raw` (which starts at offset `at`).
    fn decode(t: *Tokenizer, raw: []const u8, at: usize) Error![]const u8 {
        if (std.mem.indexOfScalar(u8, raw, '&') == null) return raw;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] != '&') {
                try out.append(t.arena, raw[i]);
                i += 1;
                continue;
            }
            const semi = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse return t.fail(at + i);
            const ent = raw[i + 1 .. semi];
            if (ent.len > 1 and ent[0] == '#') {
                const cp = (if (ent[1] == 'x') std.fmt.parseInt(u21, ent[2..], 16) else std.fmt.parseInt(u21, ent[1..], 10)) catch return t.fail(at + i);
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch return t.fail(at + i);
                try out.appendSlice(t.arena, buf[0..n]);
            } else {
                const map = [_]struct { []const u8, u8 }{ .{ "lt", '<' }, .{ "gt", '>' }, .{ "amp", '&' }, .{ "quot", '"' }, .{ "apos", '\'' } };
                const ch = for (map) |m| {
                    if (std.mem.eql(u8, m[0], ent)) break m[1];
                } else return t.fail(at + i);
                try out.append(t.arena, ch);
            }
            i = semi + 1;
        }
        return out.items;
    }
};

const testing = std.testing;

test "xml tokenizer: entities, comments, self-closing, errors with line numbers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var t: Tokenizer = .init(arena.allocator(),
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!-- a comment -->
        \\<protocol name='p'>
        \\  <description summary="a &amp; b">x &lt; y &#65;&#x42;<![CDATA[skip]]></description>
        \\  <arg name="a" type="int"/>
        \\</protocol>
    );
    const p = (try t.next()).start;
    try testing.expectEqualStrings("protocol", p.name);
    try testing.expectEqualStrings("p", p.attrs[0].value);
    try testing.expectEqualStrings("\n  ", (try t.next()).text);
    const d = (try t.next()).start;
    try testing.expectEqualStrings("a & b", d.attrs[0].value);
    try testing.expectEqualStrings("x < y AB", (try t.next()).text);
    try testing.expectEqualStrings("description", (try t.next()).end);
    _ = try t.next(); // whitespace
    const a = (try t.next()).start;
    try testing.expectEqualStrings("arg", a.name);
    try testing.expectEqual(2, a.attrs.len);
    try testing.expectEqualStrings("arg", (try t.next()).end);
    _ = try t.next();
    try testing.expectEqualStrings("protocol", (try t.next()).end);
    try testing.expect(try t.next() == .eof);

    var bad: Tokenizer = .init(arena.allocator(), "<a>\n  <b></a>");
    _ = try bad.next();
    _ = try bad.next();
    _ = try bad.next();
    try testing.expectError(error.Syntax, bad.next());
    try testing.expectEqual(2, bad.line);
    try testing.expectEqual(6, bad.col);

    var ent: Tokenizer = .init(arena.allocator(), "<a x=\"&bogus;\"/>");
    try testing.expectError(error.Syntax, ent.next());
    var dtd: Tokenizer = .init(arena.allocator(), "<!DOCTYPE x>");
    try testing.expectError(error.Syntax, dtd.next());
    var unclosed: Tokenizer = .init(arena.allocator(), "<a>");
    _ = try unclosed.next();
    try testing.expectError(error.Syntax, unclosed.next());
}
