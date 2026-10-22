//! A pull reader over one JSON document, for the journal's hot decoder
//! (`records.readChangeset`): a cold load decodes every changeset
//! snapshot, and `std.json.Scanner` alone spends more than the load's
//! budget on them. Tokens come straight off the bytes. It checks what a
//! decoder relies on (nesting, strings and their escapes, literals,
//! number syntax) and takes `,` and `:` as plain separators: frames are
//! CRC-checked, so a record is either what the store wrote or refused.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = error{ InvalidRecord, OutOfMemory };

pub const Kind = enum { object_begin, object_end, array_begin, array_end, string, number, true, false, null, end };

pub const Token = union(Kind) {
    object_begin,
    object_end,
    array_begin,
    array_end,
    string: []const u8,
    number: []const u8,
    true,
    false,
    null,
    end,
};

/// Containers nest at most this deep.
pub const max_depth = 64;

pub const Pull = struct {
    src: []const u8,
    pos: usize = 0,
    /// Unescaped strings; callers keep their scratch here too.
    a: Allocator,
    /// Bit `i` set: the container at depth `i + 1` is an object.
    objects: u64 = 0,
    depth: u8 = 0,

    pub fn init(a: Allocator, src: []const u8) Pull {
        return .{ .src = src, .a = a };
    }

    /// The kind of the next token, not consumed.
    pub fn peek(p: *Pull) Error!Kind {
        while (p.pos < p.src.len) : (p.pos += 1) switch (p.src[p.pos]) {
            ' ', '\t', '\n', '\r', ',', ':' => {},
            else => break,
        };
        if (p.pos == p.src.len) return .end;
        return switch (p.src[p.pos]) {
            '{' => .object_begin,
            '}' => .object_end,
            '[' => .array_begin,
            ']' => .array_end,
            '"' => .string,
            '-', '0'...'9' => .number,
            't' => .true,
            'f' => .false,
            'n' => .null,
            else => error.InvalidRecord,
        };
    }

    pub fn next(p: *Pull) Error!Token {
        switch (try p.peek()) {
            .object_begin => return p.open(true, .object_begin),
            .array_begin => return p.open(false, .array_begin),
            .object_end => return p.close(true, .object_end),
            .array_end => return p.close(false, .array_end),
            .string => return .{ .string = try p.string() },
            .number => return .{ .number = try p.number() },
            .true => return p.literal("true", .true),
            .false => return p.literal("false", .false),
            .null => return p.literal("null", .null),
            .end => return if (p.depth == 0) .end else error.InvalidRecord,
        }
    }

    pub fn expect(p: *Pull, comptime kind: Kind) Error!void {
        if (std.meta.activeTag(try p.next()) != kind) return error.InvalidRecord;
    }

    /// The next key of the current object, or null at its end.
    pub fn key(p: *Pull) Error!?[]const u8 {
        return switch (try p.next()) {
            .string => |s| s,
            .object_end => null,
            else => error.InvalidRecord,
        };
    }

    /// Consumes a `null` value; decoders take it as an absent field.
    pub fn isNull(p: *Pull) Error!bool {
        if (try p.peek() != .null) return false;
        _ = try p.next();
        return true;
    }

    /// Whether the current array holds another element; consumes its end.
    pub fn more(p: *Pull) Error!bool {
        if (try p.peek() != .array_end) return true;
        _ = try p.next();
        return false;
    }

    pub fn str(p: *Pull) Error![]const u8 {
        return switch (try p.next()) {
            .string => |s| s,
            else => error.InvalidRecord,
        };
    }

    pub fn int(p: *Pull, comptime T: type) Error!T {
        return switch (try p.next()) {
            .number => |s| std.fmt.parseInt(T, s, 10) catch error.InvalidRecord,
            else => error.InvalidRecord,
        };
    }

    pub fn boolean(p: *Pull) Error!bool {
        return switch (try p.next()) {
            .true => true,
            .false => false,
            else => error.InvalidRecord,
        };
    }

    pub fn enumOf(p: *Pull, comptime E: type) Error!E {
        return std.meta.stringToEnum(E, try p.str()) orelse error.InvalidRecord;
    }

    /// Skips the next value, containers whole.
    pub fn skip(p: *Pull) Error!void {
        const at = p.depth;
        switch (try p.next()) {
            .object_begin, .array_begin => while (p.depth > at) {
                if (try p.next() == .end) return error.InvalidRecord;
            },
            .object_end, .array_end, .end => return error.InvalidRecord,
            else => {},
        }
    }

    /// The text of the next value, for a decoder that wants it whole.
    pub fn raw(p: *Pull) Error![]const u8 {
        _ = try p.peek();
        const start = p.pos;
        try p.skip();
        return p.src[start..p.pos];
    }

    fn open(p: *Pull, object: bool, t: Token) Error!Token {
        if (p.depth == max_depth) return error.InvalidRecord;
        const bit = @as(u64, 1) << @intCast(p.depth);
        if (object) p.objects |= bit else p.objects &= ~bit;
        p.depth += 1;
        p.pos += 1;
        return t;
    }

    fn close(p: *Pull, object: bool, t: Token) Error!Token {
        if (p.depth == 0) return error.InvalidRecord;
        p.depth -= 1;
        const was_object = p.objects & (@as(u64, 1) << @intCast(p.depth)) != 0;
        if (was_object != object) return error.InvalidRecord;
        p.pos += 1;
        return t;
    }

    fn literal(p: *Pull, comptime word: []const u8, t: Token) Error!Token {
        if (!std.mem.startsWith(u8, p.src[p.pos..], word)) return error.InvalidRecord;
        p.pos += word.len;
        return t;
    }

    fn number(p: *Pull) Error![]const u8 {
        const s = p.src;
        const start = p.pos;
        var i = start;
        if (s[i] == '-') i += 1;
        const int_start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == int_start or (s[int_start] == '0' and i - int_start > 1)) return error.InvalidRecord;
        if (i < s.len and s[i] == '.') {
            i += 1;
            const f = i;
            while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
            if (i == f) return error.InvalidRecord;
        }
        if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
            i += 1;
            if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
            const e = i;
            while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
            if (i == e) return error.InvalidRecord;
        }
        p.pos = i;
        return s[start..i];
    }

    /// A string's contents; escaped ones are decoded into `a`.
    fn string(p: *Pull) Error![]const u8 {
        const s = p.src;
        const start = p.pos + 1;
        const end = std.mem.indexOfScalarPos(u8, s, start, '"') orelse return error.InvalidRecord;
        if (std.mem.indexOfScalarPos(u8, s[0..end], start, '\\') == null) {
            p.pos = end + 1;
            return s[start..end];
        }
        var out: std.ArrayList(u8) = .empty;
        var i = start;
        while (true) {
            if (i >= s.len) return error.InvalidRecord;
            const c = s[i];
            i += 1;
            switch (c) {
                '"' => break,
                '\\' => {
                    if (i >= s.len) return error.InvalidRecord;
                    const e = s[i];
                    i += 1;
                    try out.append(p.a, switch (e) {
                        '"', '\\', '/' => e,
                        'b' => 0x08,
                        'f' => 0x0c,
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        'u' => {
                            var cp: u21 = try hex4(s, &i);
                            if (cp >= 0xd800 and cp < 0xdc00) {
                                if (i + 2 > s.len or s[i] != '\\' or s[i + 1] != 'u') return error.InvalidRecord;
                                i += 2;
                                const lo = try hex4(s, &i);
                                if (lo < 0xdc00 or lo >= 0xe000) return error.InvalidRecord;
                                cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                            } else if (cp >= 0xdc00 and cp < 0xe000) return error.InvalidRecord;
                            var buf: [4]u8 = undefined;
                            const n = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidRecord;
                            try out.appendSlice(p.a, buf[0..n]);
                            continue;
                        },
                        else => return error.InvalidRecord,
                    });
                },
                else => try out.append(p.a, c),
            }
        }
        p.pos = i;
        return out.items;
    }
};

fn hex4(s: []const u8, i: *usize) Error!u21 {
    if (i.* + 4 > s.len) return error.InvalidRecord;
    const v = std.fmt.parseInt(u16, s[i.*..][0..4], 16) catch return error.InvalidRecord;
    i.* += 4;
    return v;
}

const testing = std.testing;

test "pull: tokens, escapes, nesting and refusals" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var p: Pull = .init(arena.allocator(), " {\"a\\n\\u00e9\\ud83d\\ude00\": [1, -2.5e3, true, false, null, {\"x\": []}], \"b\": \"plain\"} ");
    try p.expect(.object_begin);
    try testing.expectEqualStrings("a\n\u{e9}\u{1f600}", (try p.key()).?);
    try p.expect(.array_begin);
    try testing.expectEqual(@as(u8, 1), try p.int(u8));
    try testing.expectEqualStrings("-2.5e3", (try p.next()).number);
    try testing.expect(try p.boolean());
    try testing.expect(!try p.boolean());
    try testing.expect(try p.isNull());
    try testing.expectEqualStrings("{\"x\": []}", try p.raw());
    try testing.expect(!try p.more());
    try testing.expectEqualStrings("b", (try p.key()).?);
    try testing.expectEqualStrings("plain", try p.str());
    try testing.expectEqual(@as(?[]const u8, null), try p.key());
    try p.expect(.end);

    for ([_][]const u8{ "{]", "[1", "]", "\"open", "01", "-", "1.", "tru", "\"\\x\"", "\"\\ud800\"", "\"\\udc00\"", "@" }) |bad| {
        var q: Pull = .init(arena.allocator(), bad);
        const r: Error!void = while (true) {
            const t = q.next() catch |e| break e;
            if (t == .end) break;
        };
        try testing.expectError(error.InvalidRecord, r);
    }
    var deep: Pull = .init(arena.allocator(), "[" ** (max_depth + 1));
    try testing.expectError(error.InvalidRecord, deep.skip());
}
