//! Byte spans inside JSON text, for values a server must get back exactly
//! as it sent them (call and type hierarchy items with their `data`):
//! the elements of an array and the value of an object's field, without
//! decoding them. The input is assumed to be valid JSON (the client
//! already parsed it).

const std = @import("std");
const Allocator = std.mem.Allocator;

fn skipWs(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and (s[j] == ' ' or s[j] == '\t' or s[j] == '\n' or s[j] == '\r')) j += 1;
    return j;
}

/// The end of the string starting at `s[i] == '"'`.
fn stringEnd(s: []const u8, i: usize) usize {
    var j = i + 1;
    while (j < s.len) : (j += 1) switch (s[j]) {
        '\\' => j += 1,
        '"' => return j + 1,
        else => {},
    };
    return s.len;
}

/// The end of the value starting at `i`.
pub fn valueEnd(s: []const u8, i: usize) usize {
    if (i >= s.len) return s.len;
    switch (s[i]) {
        '"' => return stringEnd(s, i),
        '{', '[' => {
            var depth: usize = 0;
            var j = i;
            while (j < s.len) {
                switch (s[j]) {
                    '"' => {
                        j = stringEnd(s, j);
                        continue;
                    },
                    '{', '[' => depth += 1,
                    '}', ']' => {
                        depth -= 1;
                        if (depth == 0) return j + 1;
                    },
                    else => {},
                }
                j += 1;
            }
            return s.len;
        },
        else => {
            var j = i;
            while (j < s.len and s[j] != ',' and s[j] != '}' and s[j] != ']' and s[j] != ' ' and s[j] != '\n' and s[j] != '\r' and s[j] != '\t') j += 1;
            return j;
        },
    }
}

/// The elements of the array `s` (null or not an array: none), as slices
/// of `s`.
pub fn elements(gpa: Allocator, s: []const u8, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    out.clearRetainingCapacity();
    var i = skipWs(s, 0);
    if (i >= s.len or s[i] != '[') return;
    i = skipWs(s, i + 1);
    while (i < s.len and s[i] != ']') {
        const e = valueEnd(s, i);
        try out.append(gpa, s[i..e]);
        i = skipWs(s, e);
        if (i < s.len and s[i] == ',') i = skipWs(s, i + 1);
    }
}

/// The value of field `key` of the object `s`, as a slice of `s`.
pub fn field(s: []const u8, key: []const u8) ?[]const u8 {
    var i = skipWs(s, 0);
    if (i >= s.len or s[i] != '{') return null;
    i = skipWs(s, i + 1);
    while (i < s.len and s[i] == '"') {
        const ke = stringEnd(s, i);
        // Keys with escapes never match (protocol keys have none).
        const name = s[i + 1 .. ke - 1];
        i = skipWs(s, ke);
        if (i >= s.len or s[i] != ':') return null;
        i = skipWs(s, i + 1);
        const ve = valueEnd(s, i);
        if (std.mem.eql(u8, name, key)) return s[i..ve];
        i = skipWs(s, ve);
        if (i < s.len and s[i] == ',') i = skipWs(s, i + 1);
    }
    return null;
}

test "raw_json: elements and fields keep the bytes" {
    const gpa = std.testing.allocator;
    const s = " [ {\"from\": {\"name\":\"a\", \"data\": {\"k\": [1, \"]\"]}}, \"fromRanges\": []}, {\"x\":\"\\\"}\"} , 3 ] ";
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(gpa);
    try elements(gpa, s, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("{\"name\":\"a\", \"data\": {\"k\": [1, \"]\"]}}", field(out.items[0], "from").?);
    try std.testing.expectEqualStrings("[]", field(out.items[0], "fromRanges").?);
    try std.testing.expectEqualStrings("\"\\\"}\"", field(out.items[1], "x").?);
    try std.testing.expectEqualStrings("3", out.items[2]);
    try std.testing.expect(field(out.items[1], "y") == null);
    try elements(gpa, "null", &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}
