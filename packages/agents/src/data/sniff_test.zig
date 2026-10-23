//! Dialect sniffing on the 30-file corpus (testdata/expected.zon).

const std = @import("std");
const sniff = @import("sniff.zig");
const encoding = @import("encoding.zig");

const testing = std.testing;

const Expected = struct { file: []const u8, delimiter: u8, quote: u8, header: bool };
const expected: []const Expected = @import("testdata/expected.zon");

const corpus = blk: {
    var out: [expected.len][]const u8 = undefined;
    for (expected, 0..) |e, i| out[i] = @embedFile("testdata/" ++ e.file);
    break :blk out;
};

test "sniff_corpus" {
    try testing.expectEqual(@as(usize, 30), expected.len);
    var failed = false;
    for (expected, corpus) |e, raw| {
        const enc = encoding.detect(raw);
        var bytes = raw[encoding.bomLen(enc)..];
        var owned: ?[]u8 = null;
        defer if (owned) |o| testing.allocator.free(o);
        if (enc == .utf16le or enc == .utf16be) {
            owned = try encoding.utf16ToUtf8(testing.allocator, bytes, enc == .utf16be);
            bytes = owned.?;
        }
        const r = sniff.sniff(bytes);
        if (r.dialect.delimiter != e.delimiter or r.dialect.quote != e.quote or r.header != e.header) {
            std.debug.print("{s}: got delimiter 0x{x} quote {?c} header {} (confidence {d:.2}), want 0x{x} {c} {}\n", .{ e.file, r.dialect.delimiter, r.dialect.quote, r.header, r.confidence, e.delimiter, e.quote, e.header });
            failed = true;
        }
    }
    if (failed) return error.TestUnexpectedResult;
}

test "sniff confidence and escapes" {
    const clean = sniff.sniff("a,b,c\n1,2,3\n4,5,6\n7,8,9\n");
    try testing.expect(clean.confidence > 0.99);
    try testing.expectEqual(@as(u32, 3), clean.columns);
    const messy = sniff.sniff("a,b,c\n1,2\n4,5,6,7\n8\n9,9,9\n");
    try testing.expect(messy.confidence < 0.7);
    const bs = sniff.sniff("id,t\n1,\"a \\\"b\\\"\"\n2,\"c\"\n");
    try testing.expectEqual(.backslash, bs.dialect.escape);
    const dq = sniff.sniff("id,t\n1,\"a \"\"b\"\"\"\n2,\"\"\n");
    try testing.expectEqual(.doubled, dq.dialect.escape);
    // One column: no delimiter wins, low confidence.
    const one = sniff.sniff("alpha\nbeta\ngamma\n");
    try testing.expectEqual(@as(u32, 1), one.columns);
    try testing.expect(one.confidence < 0.5);
    try testing.expectEqual(@as(f32, 0), sniff.sniff("").confidence);
}
