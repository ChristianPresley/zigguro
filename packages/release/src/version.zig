//! Strict Semantic Versioning 2.0.0 (https://semver.org/spec/v2.0.0.html).
//!
//! `Version.parse` follows the SemVer BNF exactly and slices into its input:
//! numeric identifiers have no leading zeros (except "0"), pre-release and
//! build identifiers are non-empty `[0-9A-Za-z-]+` separated by `.`, build
//! identifiers may have leading zeros, and core numbers past `u32` are
//! rejected. `order` implements the §11 precedence and ignores build metadata.

const std = @import("std");

/// A parsed SemVer 2.0.0 version. `pre` and `build` have no leading `-`/`+`
/// and are slices of the parsed text (or of static strings).
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    /// Pre-release identifiers, e.g. "rc.1" or "insiders.20261021.1".
    pre: []const u8 = "",
    /// Build metadata, e.g. "g1a2b3c4d5e6f".
    build: []const u8 = "",

    /// The only error `parse` returns.
    pub const ParseError = error{InvalidVersion};

    /// Parses `text` as a strict SemVer 2.0.0 version. The result slices into
    /// `text`.
    pub fn parse(text: []const u8) ParseError!Version {
        var core_end = text.len;
        var pre: []const u8 = "";
        var build: []const u8 = "";
        if (std.mem.indexOfScalar(u8, text, '+')) |plus| {
            build = text[plus + 1 ..];
            if (!validIdents(build, false)) return error.InvalidVersion;
            core_end = plus;
        }
        if (std.mem.indexOfScalar(u8, text[0..core_end], '-')) |dash| {
            pre = text[dash + 1 .. core_end];
            if (!validIdents(pre, true)) return error.InvalidVersion;
            core_end = dash;
        }
        var it = std.mem.splitScalar(u8, text[0..core_end], '.');
        const major = try parseNumber(it.next() orelse return error.InvalidVersion);
        const minor = try parseNumber(it.next() orelse return error.InvalidVersion);
        const patch = try parseNumber(it.next() orelse return error.InvalidVersion);
        if (it.next() != null) return error.InvalidVersion;
        return .{ .major = major, .minor = minor, .patch = patch, .pre = pre, .build = build };
    }

    /// SemVer §11 precedence. Build metadata is ignored.
    pub fn order(a: Version, b: Version) std.math.Order {
        inline for (.{ "major", "minor", "patch" }) |field| {
            const o = std.math.order(@field(a, field), @field(b, field));
            if (o != .eq) return o;
        }
        // A version without a pre-release ranks above one with.
        if (a.pre.len == 0 or b.pre.len == 0) {
            if (a.pre.len == b.pre.len) return .eq;
            return if (a.pre.len == 0) .gt else .lt;
        }
        var ia = std.mem.splitScalar(u8, a.pre, '.');
        var ib = std.mem.splitScalar(u8, b.pre, '.');
        while (true) {
            const x = ia.next();
            const y = ib.next();
            if (x == null and y == null) return .eq;
            if (x == null) return .lt;
            if (y == null) return .gt;
            const o = orderIdent(x.?, y.?);
            if (o != .eq) return o;
        }
    }

    /// True when `a` and `b` have equal precedence (build metadata ignored).
    pub fn eqlIgnoringBuild(a: Version, b: Version) bool {
        return a.major == b.major and a.minor == b.minor and a.patch == b.patch and
            std.mem.eql(u8, a.pre, b.pre);
    }

    /// Writes `X.Y.Z[-pre][+build]`. `format(parse(x)) == x` for every
    /// accepted `x`.
    pub fn format(v: Version, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
        if (v.pre.len != 0) try w.print("-{s}", .{v.pre});
        if (v.build.len != 0) try w.print("+{s}", .{v.build});
    }

    /// `X.Y.Z[-pre]` without build metadata, written into `buf`. Panics in
    /// safe modes when `buf` is too small; 64 bytes fits every version this
    /// project emits (and `max_core_len` bounds the core numbers).
    pub fn coreString(v: Version, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        w.print("{d}.{d}.{d}", .{ v.major, v.minor, v.patch }) catch unreachable;
        if (v.pre.len != 0) w.print("-{s}", .{v.pre}) catch unreachable;
        return w.buffered();
    }

    /// The four u16 fields of a Windows VERSIONINFO `FILEVERSION`:
    /// - stable `X.Y.Z` -> `{X, Y, Z, 0}`
    /// - `X.Y.Z-rc.N` -> `{X, Y, Z, N}`
    /// - `X.Y.Z-insiders.YYYYMMDD.N` -> `{X, Y, Z, (doy * 100 + N) mod 65536}`,
    ///   where `doy` is the day of the year (1..366). The fourth field only
    ///   orders builds within one calendar year.
    /// - any other pre-release -> 4th field 0.
    /// Core numbers are truncated to 16 bits.
    pub fn winFileVersion(v: Version) [4]u16 {
        const head: [3]u16 = .{ @truncate(v.major), @truncate(v.minor), @truncate(v.patch) };
        return head ++ [1]u16{fourthField(v.pre)};
    }

    /// Longest `coreString` for u32 core numbers: three 10-digit numbers and
    /// two dots, without a pre-release.
    pub const max_core_len = 32;
};

fn fourthField(pre: []const u8) u16 {
    if (pre.len == 0) return 0;
    var it = std.mem.splitScalar(u8, pre, '.');
    const kind = it.next().?;
    if (std.mem.eql(u8, kind, "rc")) {
        const n = it.next() orelse return 0;
        if (it.next() != null) return 0;
        const num = std.fmt.parseInt(u32, n, 10) catch return 0;
        return @truncate(num);
    }
    if (std.mem.eql(u8, kind, "insiders")) {
        const date = it.next() orelse return 0;
        const n = it.next() orelse return 0;
        if (it.next() != null or date.len != 8) return 0;
        const ymd = std.fmt.parseInt(u32, date, 10) catch return 0;
        const num = std.fmt.parseInt(u32, n, 10) catch return 0;
        const doy = dayOfYear(ymd / 10000, (ymd / 100) % 100, ymd % 100) orelse return 0;
        return @truncate((@as(u64, doy) * 100 + num) % 65536);
    }
    return 0;
}

/// Day of the year (1..366) of a Gregorian date, or null when invalid.
fn dayOfYear(year: u32, month: u32, day: u32) ?u32 {
    if (month < 1 or month > 12 or day < 1) return null;
    const leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
    const lengths = [12]u32{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day > lengths[month - 1]) return null;
    var doy: u32 = day;
    for (lengths[0 .. month - 1]) |l| doy += l;
    return doy;
}

fn parseNumber(s: []const u8) Version.ParseError!u32 {
    if (s.len == 0) return error.InvalidVersion;
    if (s.len > 1 and s[0] == '0') return error.InvalidVersion;
    for (s) |c| if (!std.ascii.isDigit(c)) return error.InvalidVersion;
    return std.fmt.parseInt(u32, s, 10) catch error.InvalidVersion;
}

/// Validates a dot-separated identifier list. Numeric pre-release
/// identifiers must not have leading zeros.
fn validIdents(s: []const u8, is_pre: bool) bool {
    if (s.len == 0) return false;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |id| {
        if (id.len == 0) return false;
        var numeric = true;
        for (id) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '-')) return false;
            if (!std.ascii.isDigit(c)) numeric = false;
        }
        if (is_pre and numeric and id.len > 1 and id[0] == '0') return false;
    }
    return true;
}

fn isNumeric(id: []const u8) bool {
    for (id) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// §11.4: numeric < alphanumeric; numerics by value (any length);
/// alphanumerics by ASCII.
fn orderIdent(a: []const u8, b: []const u8) std.math.Order {
    const na = isNumeric(a);
    const nb = isNumeric(b);
    if (na and nb) {
        const ta = std.mem.trimStart(u8, a, "0");
        const tb = std.mem.trimStart(u8, b, "0");
        if (ta.len != tb.len) return std.math.order(ta.len, tb.len);
        return std.mem.order(u8, ta, tb);
    }
    if (na) return .lt;
    if (nb) return .gt;
    return std.mem.order(u8, a, b);
}

const testing = std.testing;

fn expectRoundTrip(text: []const u8) !void {
    const v = try Version.parse(text);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try v.format(&w);
    try testing.expectEqualStrings(text, w.buffered());
}

test "version: parse valid corpus" {
    const valid = [_][]const u8{
        // semver.org §9-§11 examples.
        "1.0.0-alpha",                          "1.0.0-alpha.1",                 "1.0.0-0.3.7",                      "1.0.0-x.7.z.92",
        "1.0.0-x-y-z.--",                       "1.0.0-alpha+001",               "1.0.0+20130313144700",             "1.0.0-beta+exp.sha.5114f85",
        "1.0.0+21AF26D3----117B344092BD",       "1.0.0-alpha.beta",              "1.0.0-beta",                       "1.0.0-beta.2",
        "1.0.0-beta.11",                        "1.0.0-rc.1",                    "1.0.0",                            "2.0.0",
        "2.1.0",                                "2.1.1",
        // Edge cases.
                                "0.0.0",                            "0.0.1",
        "0.1.0",                                "10.20.30",                      "4294967295.4294967295.4294967295", "1.1.2-prerelease+meta",
        "1.1.2+meta",                           "1.1.2+meta-valid",              "1.0.0-alpha.0valid",               "1.0.0-alpha-a.b-c-somethinglong+build.1-aef.1-its-okay",
        "1.0.0-rc.1+build.1",                   "2.0.0-rc.1+build.123",          "1.2.3-beta",                       "10.2.3-DEV-SNAPSHOT",
        "1.2.3-SNAPSHOT-123",                   "2.0.0+build.1848",              "2.0.1-alpha.1227",                 "1.0.0-alpha+beta",
        "1.2.3----RC-SNAPSHOT.12.9.1--.12+788", "1.2.3----R-S.12.9.1--.12+meta", "1.2.3----RC-SNAPSHOT.12.9.1--.12", "1.0.0+0.build.1-rc.10000aaa-kk-0.1",
        "1.0.0-0A.is.legal",                    "1.0.0+000",                     "1.0.0+00.01",                      "0.4.0+g1a2b3c4d5e6f",
        "0.5.0-insiders.20261021.1",            "0.0.0-dev+local",               "1.0.0--",                          "1.0.0-0",
        "1.0.0-a.0",                            "1.0.0-a-0",                     "99999999.0.0",                     "1.0.0-x.0a",
    };
    for (valid) |t| try expectRoundTrip(t);
    const v = try Version.parse("1.0.0-beta+exp.sha.5114f85");
    try testing.expectEqualStrings("beta", v.pre);
    try testing.expectEqualStrings("exp.sha.5114f85", v.build);
}

test "version: reject invalid corpus" {
    const invalid = [_][]const u8{
        "",            "1",              "1.2",            "1.2.3-",         "1.2.3+",
        "1.2.3-+",     "1.2.3++",        "01.2.3",         "1.02.3",         "1.2.03",
        "1.2.3-01",    "1.2.3-alpha.01", "1.2.3-a..b",     "1.2.3-.a",       "1.2.3-a.",
        "1.2.3+a..b",  "1.2.3+.a",       "1.2.3.4",        "a.b.c",          "1.2.c",
        "-1.2.3",      "+1.2.3",         "1.2.3-a_b",      "1.2.3+a_b",      "1.2.3 ",
        " 1.2.3",      "v1.2.3",         "4294967296.0.0", "0.4294967296.0",
        "1.2.3-ä",
        "1.2.3+ä",
        "1.2.3-a+b+c", "1..3",           "1.2.",           ".2.3",           "99999999999999999999.0.0",
    };
    for (invalid) |t| {
        if (Version.parse(t)) |_| {
            std.debug.print("accepted invalid version {s}\n", .{t});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "version: precedence chain" {
    const chain = [_][]const u8{
        "1.0.0-alpha",  "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
        "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1",       "1.0.0",
        "1.0.1",        "1.1.0",         "2.0.0",
    };
    for (chain, 0..) |a, i| {
        for (chain, 0..) |b, j| {
            const o = Version.order(try Version.parse(a), try Version.parse(b));
            try testing.expectEqual(std.math.order(i, j), o);
        }
    }
    const x = try Version.parse("1.0.0+aaa");
    const y = try Version.parse("1.0.0+bbb");
    try testing.expectEqual(std.math.Order.eq, x.order(y));
    try testing.expect(x.eqlIgnoringBuild(y));
    try testing.expect(!x.eqlIgnoringBuild(try Version.parse("1.0.0-rc.1")));
    // Long numeric identifiers compare by value.
    try testing.expectEqual(std.math.Order.lt, Version.order(
        try Version.parse("1.0.0-99999999999999999998"),
        try Version.parse("1.0.0-99999999999999999999"),
    ));
    // Insiders sort above the current stable and below the next one.
    try testing.expectEqual(std.math.Order.gt, Version.order(try Version.parse("0.5.0-insiders.20261021.1"), try Version.parse("0.4.0")));
    try testing.expectEqual(std.math.Order.lt, Version.order(try Version.parse("0.5.0-insiders.20261021.1"), try Version.parse("0.5.0")));
    try testing.expectEqual(std.math.Order.lt, Version.order(try Version.parse("0.5.0-insiders.20261021.1"), try Version.parse("0.5.0-insiders.20261021.2")));
}

test "version: agrees with std.SemanticVersion" {
    var prng: std.Random.DefaultPrng = .init(0x5e3e7);
    const r = prng.random();
    const words = [_][]const u8{ "alpha", "beta", "rc", "x-y", "0", "1", "2", "10", "11", "a1", "A", "-" };
    var bufs: [2][96]u8 = undefined;
    for (0..1000) |_| {
        var texts: [2][]const u8 = undefined;
        for (&texts, &bufs) |*t, *buf| {
            var w: std.Io.Writer = .fixed(buf);
            try w.print("{d}.{d}.{d}", .{ r.uintLessThan(u32, 3), r.uintLessThan(u32, 3), r.uintLessThan(u32, 3) });
            const n = r.uintLessThan(usize, 4);
            for (0..n) |k| try w.print("{s}{s}", .{ if (k == 0) "-" else ".", words[r.uintLessThan(usize, words.len)] });
            if (r.boolean()) try w.print("+b{d}", .{r.int(u8)});
            t.* = w.buffered();
        }
        const ours = Version.order(try Version.parse(texts[0]), try Version.parse(texts[1]));
        const theirs = std.SemanticVersion.order(try std.SemanticVersion.parse(texts[0]), try std.SemanticVersion.parse(texts[1]));
        try testing.expectEqual(theirs, ours);
    }
}

test "version: winFileVersion mapping" {
    const cases = [_]struct { []const u8, [4]u16 }{
        .{ "0.4.0", .{ 0, 4, 0, 0 } },
        .{ "1.2.3+g1a2b3c4d5e6f", .{ 1, 2, 3, 0 } },
        .{ "1.2.3-rc.4", .{ 1, 2, 3, 4 } },
        .{ "0.5.0-insiders.20260101.1", .{ 0, 5, 0, 101 } },
        .{ "0.5.0-insiders.20261021.3", .{ 0, 5, 0, 29403 } },
        .{ "0.5.0-insiders.20241231.9", .{ 0, 5, 0, 36609 } }, // leap year: doy 366
        .{ "0.5.0-insiders.20251231.700", .{ 0, 5, 0, 36500 + 700 } },
        .{ "0.5.0-insiders.20261399.1", .{ 0, 5, 0, 0 } }, // invalid date
        .{ "0.5.0-dev", .{ 0, 5, 0, 0 } },
        .{ "0.5.0-rc", .{ 0, 5, 0, 0 } },
        .{ "70000.1.2", .{ 70000 - 65536, 1, 2, 0 } },
    };
    for (cases) |c| try testing.expectEqual(c[1], (try Version.parse(c[0])).winFileVersion());
}

test "version: coreString drops build metadata" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("1.2.3-rc.1", (try Version.parse("1.2.3-rc.1+g00")).coreString(&buf));
    try testing.expectEqualStrings("4294967295.4294967295.4294967295", (try Version.parse("4294967295.4294967295.4294967295")).coreString(&buf));
}

test "fuzz: version parse" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var input: [128]u8 = undefined;
            const n = s.slice(&input);
            const text = input[0..n];
            const v = Version.parse(text) catch return;
            var buf: [256]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            try v.format(&w);
            try testing.expectEqualStrings(text, w.buffered());
            try testing.expectEqual(std.math.Order.eq, v.order(v));
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "version") });
}
