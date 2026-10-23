//! The `Link` response header (RFC 8288) as GitHub sends it for pagination:
//! `<https://api.github.com/...&page=2>; rel="next", <...>; rel="last"`.
//! Callers follow the URL verbatim and never build page URLs themselves.

const std = @import("std");

/// The URL of the first link whose `rel` (one of its space-separated
/// relation types, ignoring case) is `rel`, or null.
pub fn parseLinkHeader(value: []const u8, rel: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < value.len) {
        const open = std.mem.indexOfScalarPos(u8, value, i, '<') orelse return null;
        const close = std.mem.indexOfScalarPos(u8, value, open + 1, '>') orelse return null;
        const url = std.mem.trim(u8, value[open + 1 .. close], " \t");
        // The parameters run to the next link (a `,` outside quotes).
        var j = close + 1;
        var quoted = false;
        while (j < value.len) : (j += 1) switch (value[j]) {
            '"' => quoted = !quoted,
            ',' => if (!quoted) break,
            else => {},
        };
        if (hasRel(value[close + 1 .. j], rel) and url.len > 0) return url;
        i = j + 1;
    }
    return null;
}

fn hasRel(params: []const u8, rel: []const u8) bool {
    var it = std.mem.splitScalar(u8, params, ';');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        const eq = std.mem.indexOfScalar(u8, p, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, p[0..eq], " \t"), "rel")) continue;
        var v = std.mem.trim(u8, p[eq + 1 ..], " \t");
        if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
        var types = std.mem.tokenizeAny(u8, v, " \t");
        while (types.next()) |t| if (std.ascii.eqlIgnoreCase(t, rel)) return true;
    }
    return false;
}
