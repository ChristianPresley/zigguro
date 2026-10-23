//! JSON with comments (E04.F08.S02.T01), as VS Code themes are written:
//! `stripJsonc` removes `//` and `/* */` comments and trailing commas so
//! `std.json` (which has no comment support) can parse the rest. One pass
//! over the bytes; strings and their escapes are kept as they are.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// `src` without comments and trailing commas (caller frees).
pub fn stripJsonc(gpa: Allocator, src: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(gpa, src.len);
    errdefer out.deinit(gpa);
    // Where the last comma not yet followed by a significant byte went
    // in `out`: removed when a `}` or `]` comes next.
    var comma: ?usize = null;
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        switch (c) {
            '"' => {
                comma = null;
                const start = i;
                i += 1;
                while (i < src.len and src[i] != '"') : (i += 1) {
                    if (src[i] == '\\') i += 1;
                }
                i = @min(i + 1, src.len);
                out.appendSliceAssumeCapacity(src[start..i]);
                continue;
            },
            '/' => if (i + 1 < src.len and src[i + 1] == '/') {
                while (i < src.len and src[i] != '\n') i += 1;
                continue;
            } else if (i + 1 < src.len and src[i + 1] == '*') {
                i += 2;
                while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
                i = @min(i + 2, src.len);
                // A comment separates tokens like a space.
                out.appendAssumeCapacity(' ');
                continue;
            },
            ',' => {
                comma = out.items.len;
            },
            '}', ']' => if (comma) |at| {
                out.items[at] = ' ';
                comma = null;
            },
            ' ', '\t', '\r', '\n' => {},
            else => comma = null,
        }
        out.appendAssumeCapacity(c);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

test "jsonc strips comments and trailing commas but not inside strings" {
    const src =
        \\{
        \\  // a line comment
        \\  "a": "x // not a comment", /* block */
        \\  "b": [1, 2, /* trailing */ ],
        \\  "c": "quote \" and /* still text */",
        \\  "d": { "e": 1, },
        \\}
    ;
    const out = try stripJsonc(testing.allocator, src);
    defer testing.allocator.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try testing.expectEqualStrings("x // not a comment", o.get("a").?.string);
    try testing.expectEqual(@as(usize, 2), o.get("b").?.array.items.len);
    try testing.expectEqualStrings("quote \" and /* still text */", o.get("c").?.string);
    try testing.expectEqual(@as(i64, 1), o.get("d").?.object.get("e").?.integer);
}

test "jsonc keeps commas between values and tolerates unterminated input" {
    const out = try stripJsonc(testing.allocator, "[1,/*x*/2]");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[1, 2]", out);
    for ([_][]const u8{ "\"abc", "/* open", "// eol", "\"\\" }) |s| {
        const o = try stripJsonc(testing.allocator, s);
        testing.allocator.free(o);
    }
}

test "fuzz: gui-jsonc" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [1024]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            const out = try stripJsonc(testing.allocator, input);
            defer testing.allocator.free(out);
            try testing.expect(out.len <= input.len);
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "gui-jsonc") });
}
