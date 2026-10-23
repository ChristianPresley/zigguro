const std = @import("std");
const parseLinkHeader = @import("link_header.zig").parseLinkHeader;

test "link_header_parse_table" {
    const Case = struct { value: []const u8, rel: []const u8, want: ?[]const u8 };
    const cases = [_]Case{
        // GitHub's own shape.
        .{ .value = "<https://api.github.com/repositories/1/issues?page=2>; rel=\"next\", <https://api.github.com/repositories/1/issues?page=5>; rel=\"last\"", .rel = "next", .want = "https://api.github.com/repositories/1/issues?page=2" },
        .{ .value = "<https://api.github.com/repositories/1/issues?page=2>; rel=\"next\", <https://api.github.com/repositories/1/issues?page=5>; rel=\"last\"", .rel = "last", .want = "https://api.github.com/repositories/1/issues?page=5" },
        // The last page has no next.
        .{ .value = "<https://a/x?page=1>; rel=\"prev\", <https://a/x?page=1>; rel=\"first\"", .rel = "next", .want = null },
        .{ .value = "", .rel = "next", .want = null },
        .{ .value = "garbage", .rel = "next", .want = null },
        .{ .value = "<https://a/x?page=2", .rel = "next", .want = null },
        // Extra parameters, unquoted values, odd spacing and case.
        .{ .value = "<https://a/x?page=3>; title=\"Page, three\"; REL = next", .rel = "next", .want = "https://a/x?page=3" },
        .{ .value = "  < https://a/x?page=4 >  ;rel=\"next\"  ", .rel = "next", .want = "https://a/x?page=4" },
        .{ .value = "<https://a/x?page=1>;rel=\"prev first\",<https://a/x?page=3>;rel=\"next\"", .rel = "first", .want = "https://a/x?page=1" },
        .{ .value = "<https://a/x?page=1>;rel=\"prev first\",<https://a/x?page=3>;rel=\"next\"", .rel = "next", .want = "https://a/x?page=3" },
        // A comma inside the URL is part of it.
        .{ .value = "<https://a/x?labels=a,b&page=2>; rel=\"next\"", .rel = "next", .want = "https://a/x?labels=a,b&page=2" },
        // A rel that only contains the word is not it.
        .{ .value = "<https://a/x?page=2>; rel=\"nextish\"", .rel = "next", .want = null },
        .{ .value = "<https://a/x?page=2>; anchor=\"next\"", .rel = "next", .want = null },
        .{ .value = "<>; rel=\"next\", <https://a/y>; rel=\"next\"", .rel = "next", .want = "https://a/y" },
    };
    for (cases, 0..) |c, i| {
        const got = parseLinkHeader(c.value, c.rel);
        errdefer std.debug.print("case {d}: {?s}\n", .{ i, got });
        if (c.want) |w| try std.testing.expectEqualStrings(w, got orelse return error.TestExpectedEqual) else try std.testing.expect(got == null);
    }
}
