//! `format` checks (JSON Schema validation §7). Formats are annotations
//! unless the caller asks for assertion: `.elicitation_only` asserts the
//! four formats MCP elicitation supports (`email`, `uri`, `date`,
//! `date-time`), `.all_supported` adds `uuid`, `ipv4`, `ipv6`, `hostname`,
//! `json-pointer`, `uri-reference`, `duration` and `time`. Unknown formats
//! always pass.

const std = @import("std");

/// Which formats are asserted.
pub const FormatAssertion = enum { none, elicitation_only, all_supported };

/// Whether `s` satisfies `format` under `mode`.
pub fn check(mode: FormatAssertion, format: []const u8, s: []const u8) bool {
    if (mode == .none) return true;
    const elicitation = std.StaticStringMap(*const fn ([]const u8) bool).initComptime(.{
        .{ "email", isEmail },
        .{ "uri", isUri },
        .{ "date", isDate },
        .{ "date-time", isDateTime },
    });
    if (elicitation.get(format)) |f| return f(s);
    if (mode != .all_supported) return true;
    const more = std.StaticStringMap(*const fn ([]const u8) bool).initComptime(.{
        .{ "uuid", isUuid },
        .{ "ipv4", isIpv4 },
        .{ "ipv6", isIpv6 },
        .{ "hostname", isHostname },
        .{ "json-pointer", isJsonPointer },
        .{ "uri-reference", isUriReference },
        .{ "duration", isDuration },
        .{ "time", isTime },
    });
    if (more.get(format)) |f| return f(s);
    return true;
}

/// A simplified RFC 5321 Mailbox: dot-atom or quoted local part, then a
/// hostname or an address literal.
pub fn isEmail(s: []const u8) bool {
    const at = std.mem.lastIndexOfScalar(u8, s, '@') orelse return false;
    const local = s[0..at];
    const domain = s[at + 1 ..];
    if (local.len == 0 or local.len > 64 or domain.len == 0) return false;
    if (local[0] == '"') {
        if (local.len < 2 or local[local.len - 1] != '"') return false;
        var i: usize = 1;
        while (i < local.len - 1) : (i += 1) {
            const c = local[i];
            if (c == '\\') {
                i += 1;
                if (i >= local.len - 1) return false;
                continue;
            }
            if (c == '"' or c < 0x20 or c >= 0x7f) return false;
        }
    } else {
        if (local[0] == '.' or local[local.len - 1] == '.') return false;
        var prev_dot = false;
        for (local) |c| {
            if (c == '.') {
                if (prev_dot) return false;
                prev_dot = true;
                continue;
            }
            prev_dot = false;
            if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "!#$%&'*+-/=?^_`{|}~", c) != null)) return false;
        }
    }
    if (domain[0] == '[') {
        if (domain[domain.len - 1] != ']') return false;
        const lit = domain[1 .. domain.len - 1];
        if (std.ascii.startsWithIgnoreCase(lit, "IPv6:")) return isIpv6(lit[5..]);
        return isIpv4(lit);
    }
    if (domain[domain.len - 1] == '.') return false;
    return isHostname(domain);
}

/// An absolute URI (RFC 3986 §3).
pub fn isUri(s: []const u8) bool {
    return uriReference(s, true);
}

/// A URI or a relative reference (RFC 3986 §4.1).
pub fn isUriReference(s: []const u8) bool {
    return uriReference(s, false);
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

fn isSubDelim(c: u8) bool {
    return std.mem.indexOfScalar(u8, "!$&'()*+,;=", c) != null;
}

/// Whether `s` is made of unreserved, sub-delims, pct-encoded and `extra`.
fn uriPart(s: []const u8, extra: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '%') {
            if (i + 2 >= s.len or !std.ascii.isHex(s[i + 1]) or !std.ascii.isHex(s[i + 2])) return false;
            i += 2;
        } else if (!(isUnreserved(c) or isSubDelim(c) or std.mem.indexOfScalar(u8, extra, c) != null)) return false;
    }
    return true;
}

fn uriReference(s: []const u8, absolute: bool) bool {
    var rest = s;
    // Fragment and query.
    if (std.mem.indexOfScalar(u8, rest, '#')) |i| {
        if (!uriPart(rest[i + 1 ..], ":@/?")) return false;
        rest = rest[0..i];
    }
    if (std.mem.indexOfScalar(u8, rest, '?')) |i| {
        if (!uriPart(rest[i + 1 ..], ":@/?")) return false;
        rest = rest[0..i];
    }
    // Scheme: the part before the first ':' when it precedes any '/'.
    const colon = std.mem.indexOfScalar(u8, rest, ':');
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    var has_scheme = false;
    if (colon) |c| if (c < slash) {
        const scheme = rest[0..c];
        if (scheme.len == 0 or !std.ascii.isAlphabetic(scheme[0])) return false;
        for (scheme) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '+' or ch == '-' or ch == '.')) return false;
        has_scheme = true;
        rest = rest[c + 1 ..];
    };
    if (absolute and !has_scheme) return false;
    var path = rest;
    if (std.mem.startsWith(u8, rest, "//")) {
        const auth_end = std.mem.indexOfScalarPos(u8, rest, 2, '/') orelse rest.len;
        if (!authority(rest[2..auth_end])) return false;
        path = rest[auth_end..];
    } else if (!has_scheme) {
        // path-noscheme: no ':' in the first segment.
        const first_end = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
        if (std.mem.indexOfScalar(u8, path[0..first_end], ':') != null) return false;
    }
    return uriPart(path, ":@/");
}

fn authority(a: []const u8) bool {
    var hostport = a;
    if (std.mem.lastIndexOfScalar(u8, a, '@')) |at| {
        if (!uriPart(a[0..at], ":")) return false;
        hostport = a[at + 1 ..];
    }
    var host = hostport;
    if (hostport.len > 0 and hostport[0] == '[') {
        const close = std.mem.indexOfScalar(u8, hostport, ']') orelse return false;
        const lit = hostport[1..close];
        if (lit.len > 0 and (lit[0] == 'v' or lit[0] == 'V')) {
            const dot = std.mem.indexOfScalar(u8, lit, '.') orelse return false;
            if (dot < 2) return false;
            for (lit[1..dot]) |ch| if (!std.ascii.isHex(ch)) return false;
            if (dot + 1 >= lit.len or !uriPart(lit[dot + 1 ..], ":")) return false;
        } else if (!isIpv6(lit)) return false;
        const after = hostport[close + 1 ..];
        if (after.len == 0) return true;
        if (after[0] != ':') return false;
        for (after[1..]) |ch| if (!std.ascii.isDigit(ch)) return false;
        return true;
    }
    if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |c| {
        for (hostport[c + 1 ..]) |ch| if (!std.ascii.isDigit(ch)) return false;
        host = hostport[0..c];
    }
    return uriPart(host, "");
}

fn digits(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var v: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

/// RFC 3339 full-date.
pub fn isDate(s: []const u8) bool {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return false;
    const y = digits(s[0..4]) orelse return false;
    const m = digits(s[5..7]) orelse return false;
    const d = digits(s[8..10]) orelse return false;
    if (m < 1 or m > 12 or d < 1) return false;
    const leap = (y % 4 == 0 and y % 100 != 0) or y % 400 == 0;
    const days = [_]u32{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return d <= days[m - 1];
}

/// RFC 3339 full-time (a leap second is allowed at 23:59:60 UTC).
pub fn isTime(s: []const u8) bool {
    if (s.len < 9 or s[2] != ':' or s[5] != ':') return false;
    const h = digits(s[0..2]) orelse return false;
    const mi = digits(s[3..5]) orelse return false;
    const se = digits(s[6..8]) orelse return false;
    var rest = s[8..];
    if (rest.len > 0 and rest[0] == '.') {
        var n: usize = 1;
        while (n < rest.len and std.ascii.isDigit(rest[n])) n += 1;
        if (n == 1) return false;
        rest = rest[n..];
    }
    if (h > 23 or mi > 59 or se > 60) return false;
    var off_minutes: i32 = 0;
    if (rest.len == 1 and (rest[0] == 'Z' or rest[0] == 'z')) {
        off_minutes = 0;
    } else if (rest.len == 6 and (rest[0] == '+' or rest[0] == '-') and rest[3] == ':') {
        const oh = digits(rest[1..3]) orelse return false;
        const om = digits(rest[4..6]) orelse return false;
        if (oh > 23 or om > 59) return false;
        const off: i32 = @intCast(oh * 60 + om);
        off_minutes = if (rest[0] == '+') off else -off;
    } else return false;
    if (se == 60) {
        // A leap second only exists at 23:59:60 UTC.
        const utc = @mod(@as(i32, @intCast(h * 60 + mi)) - off_minutes, 24 * 60);
        if (utc != 23 * 60 + 59) return false;
    }
    return true;
}

/// RFC 3339 date-time.
pub fn isDateTime(s: []const u8) bool {
    if (s.len < 20) return false;
    if (s[10] != 'T' and s[10] != 't') return false;
    return isDate(s[0..10]) and isTime(s[11..]);
}

/// RFC 4122 string form.
pub fn isUuid(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// Dotted-quad IPv4 without leading zeros.
pub fn isIpv4(s: []const u8) bool {
    var it = std.mem.splitScalar(u8, s, '.');
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (part.len == 0 or part.len > 3) return false;
        if (part.len > 1 and part[0] == '0') return false;
        const v = digits(part) orelse return false;
        if (v > 255) return false;
    }
    return n == 4;
}

/// RFC 4291 text form (with optional embedded IPv4).
pub fn isIpv6(s: []const u8) bool {
    if (s.len < 2 or s.len > 45) return false;
    if (std.mem.indexOf(u8, s, "::")) |p| {
        if (std.mem.indexOfPos(u8, s, p + 1, "::") != null) return false;
        const head = ipv6Groups(s[0..p], false) orelse return false;
        const tail = ipv6Groups(s[p + 2 ..], true) orelse return false;
        return head + tail < 8;
    }
    return (ipv6Groups(s, true) orelse return false) == 8;
}

/// Counts the groups of a `:`-separated run (empty run: 0). The last part
/// may be an IPv4 address (two groups) when `ipv4_tail`.
fn ipv6Groups(s: []const u8, ipv4_tail: bool) ?usize {
    if (s.len == 0) return 0;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, ':');
    while (it.next()) |part| {
        if (part.len == 0) return null;
        if (std.mem.indexOfScalar(u8, part, '.') != null) {
            if (!ipv4_tail or it.peek() != null or !isIpv4(part)) return null;
            n += 2;
            continue;
        }
        if (part.len > 4) return null;
        for (part) |c| if (!std.ascii.isHex(c)) return null;
        n += 1;
    }
    return n;
}

/// RFC 1123 hostname: dot-separated labels of letters, digits and inner
/// hyphens, each 1..63, total <= 253 (a trailing dot is allowed).
pub fn isHostname(s0: []const u8) bool {
    const s = if (s0.len > 0 and s0[s0.len - 1] == '.') s0[0 .. s0.len - 1] else s0;
    if (s.len == 0 or s.len > 253) return false;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |label| {
        if (label.len == 0 or label.len > 63) return false;
        if (label[0] == '-' or label[label.len - 1] == '-') return false;
        // "xn--" A-labels must at least have content after the prefix.
        if (label.len >= 4 and label[2] == '-' and label[3] == '-' and !std.ascii.startsWithIgnoreCase(label, "xn--")) return false;
        for (label) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-')) return false;
    }
    return true;
}

/// RFC 6901 JSON Pointer.
pub fn isJsonPointer(s: []const u8) bool {
    if (s.len == 0) return true;
    if (s[0] != '/') return false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '~') {
            if (i + 1 >= s.len or (s[i + 1] != '0' and s[i + 1] != '1')) return false;
        }
    }
    return true;
}

/// ISO 8601 duration as constrained by RFC 3339 Appendix A.
pub fn isDuration(s: []const u8) bool {
    if (s.len < 2 or s[0] != 'P') return false;
    var i: usize = 1;
    if (s[i] == 'T' and s.len == 2) return false;
    // Weeks stand alone.
    if (s[s.len - 1] == 'W') return digits(s[1 .. s.len - 1]) != null;
    const date_units = "YMD";
    const time_units = "HMS";
    var in_time = false;
    var last: usize = 0; // index into units, to keep order
    var any = false;
    var any_time = false;
    while (i < s.len) {
        if (s[i] == 'T') {
            if (in_time) return false;
            in_time = true;
            last = 0;
            i += 1;
            continue;
        }
        const start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == start or i >= s.len) return false;
        const units = if (in_time) time_units else date_units;
        const u = std.mem.indexOfScalar(u8, units, s[i]) orelse return false;
        if (u + 1 <= last) return false;
        last = u + 1;
        any = true;
        if (in_time) any_time = true;
        i += 1;
    }
    if (in_time and !any_time) return false;
    return any;
}

const testing = std.testing;

test "formats: elicitation set" {
    try testing.expect(isEmail("joe.bloggs@example.com"));
    try testing.expect(!isEmail("2962"));
    try testing.expect(!isEmail(".test@example.com"));
    try testing.expect(isEmail("\"joe bloggs\"@example.com"));
    try testing.expect(isUri("http://foo.bar/?baz=qux#quux"));
    try testing.expect(!isUri("//foo.bar/?baz=qux#quux"));
    try testing.expect(!isUri("http:// shouldfail.com"));
    try testing.expect(isDate("2020-02-29"));
    try testing.expect(!isDate("2021-02-29"));
    try testing.expect(isDateTime("1963-06-19T08:30:06.283185Z"));
    try testing.expect(isDateTime("1998-12-31T23:59:60Z"));
    try testing.expect(!isDateTime("1998-12-31T22:59:60Z"));
    try testing.expect(isDateTime("1998-12-31T15:59:60.123-08:00"));
    try testing.expect(check(.none, "email", "nope"));
    try testing.expect(!check(.elicitation_only, "email", "nope"));
    try testing.expect(check(.elicitation_only, "uuid", "nope"));
}

test "formats: all supported" {
    try testing.expect(isIpv4("192.168.0.1"));
    try testing.expect(!isIpv4("087.10.0.1"));
    try testing.expect(isIpv6("::1"));
    try testing.expect(isIpv6("1:d6::42"));
    try testing.expect(isIpv6("::ffff:192.168.0.1"));
    try testing.expect(!isIpv6("12345::"));
    try testing.expect(!isIpv6("1:1:1:1:1:1:1:1:1"));
    try testing.expect(isUuid("2EB8AA08-AA98-11EA-B4AA-73B441D16380"));
    try testing.expect(isDuration("P4DT12H30M5S"));
    try testing.expect(!isDuration("PT"));
    try testing.expect(isJsonPointer("/foo/bar~0/baz~1/%a"));
    try testing.expect(!isJsonPointer("/foo/bar~"));
}
