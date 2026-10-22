//! UCD text-file parsing (UAX #44): `;`-separated fields, `#` comments,
//! `X..Y` ranges, `# @missing:` default lines and UnicodeData First/Last
//! range pairs.

const std = @import("std");

/// Maximum fields per line that callers see.
pub const max_fields = 16;

/// One data line (or `@missing` line) with its code point range.
pub const Line = struct {
    lo: u21,
    hi: u21,
    /// Trimmed fields after the code point field.
    fields: [max_fields][]const u8 = undefined,
    n: usize = 0,
    /// True for a `# @missing:` default line.
    missing: bool = false,
    /// 1-based line number, for errors.
    number: usize = 0,

    /// Field `i` after the code point column, or "" when absent.
    pub fn field(l: *const Line, i: usize) []const u8 {
        return if (i < l.n) l.fields[i] else "";
    }
};

/// Parse errors carry no payload; `Iterator.err_line` holds the location.
pub const Error = error{ BadCodePoint, BadRange, TooManyFields };

/// Iterates the data and `@missing` lines of a UCD file.
pub const Iterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    number: usize = 0,
    /// Line number of the last error.
    err_line: usize = 0,

    /// Iterates `text`.
    pub fn init(text: []const u8) Iterator {
        return .{ .lines = std.mem.splitScalar(u8, text, '\n') };
    }

    /// The next line with data, or null at the end.
    pub fn next(it: *Iterator) Error!?Line {
        while (it.lines.next()) |raw| {
            it.number += 1;
            var s = std.mem.trimEnd(u8, raw, "\r");
            var missing = false;
            if (std.mem.startsWith(u8, s, "# @missing:")) {
                s = s["# @missing:".len..];
                missing = true;
            } else if (std.mem.indexOfScalar(u8, s, '#')) |h| s = s[0..h];
            s = std.mem.trim(u8, s, " \t");
            if (s.len == 0) continue;
            var fields = std.mem.splitScalar(u8, s, ';');
            const cp_field = std.mem.trim(u8, fields.first(), " \t");
            var line: Line = .{ .lo = 0, .hi = 0, .missing = missing, .number = it.number };
            const r = parseRange(cp_field) catch |e| {
                it.err_line = it.number;
                return e;
            };
            line.lo = r[0];
            line.hi = r[1];
            while (fields.next()) |f| {
                if (line.n == max_fields) {
                    it.err_line = it.number;
                    return error.TooManyFields;
                }
                line.fields[line.n] = std.mem.trim(u8, f, " \t");
                line.n += 1;
            }
            // A trailing ';' (SpecialCasing, emoji-variation-sequences) is not a field.
            if (line.n > 0 and line.fields[line.n - 1].len == 0) line.n -= 1;
            return line;
        }
        return null;
    }
};

/// Parses `XXXX` or `XXXX..YYYY`.
pub fn parseRange(s: []const u8) Error![2]u21 {
    if (std.mem.indexOf(u8, s, "..")) |dots| {
        const lo = try parseCp(s[0..dots]);
        const hi = try parseCp(s[dots + 2 ..]);
        if (lo > hi) return error.BadRange;
        return .{ lo, hi };
    }
    const c = try parseCp(s);
    return .{ c, c };
}

/// Parses one hexadecimal code point.
pub fn parseCp(s: []const u8) Error!u21 {
    const v = std.fmt.parseInt(u32, std.mem.trim(u8, s, " \t"), 16) catch return error.BadCodePoint;
    if (v > 0x10FFFF) return error.BadCodePoint;
    return @intCast(v);
}

/// Parses a space-separated code point sequence into `buf`.
pub fn parseCps(s: []const u8, buf: []u21) Error![]u21 {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    while (it.next()) |t| {
        if (n == buf.len) return error.TooManyFields;
        buf[n] = try parseCp(t);
        n += 1;
    }
    return buf[0..n];
}

/// One UnicodeData.txt record, with First/Last pairs merged into a range.
pub const UnicodeDataRecord = struct {
    lo: u21,
    hi: u21,
    /// The 14 fields after the code point (name, gc, ccc, bidi, decomposition, ...).
    fields: [14][]const u8,
};

/// Iterates UnicodeData.txt records, merging `<..., First>`/`<..., Last>`.
pub const UnicodeDataIterator = struct {
    it: Iterator,

    /// Iterates `text`.
    pub fn init(text: []const u8) UnicodeDataIterator {
        return .{ .it = .init(text) };
    }

    /// The next record, or null at the end.
    pub fn next(u: *UnicodeDataIterator) (Error || error{BadFirstLast})!?UnicodeDataRecord {
        const l = (try u.it.next()) orelse return null;
        var rec: UnicodeDataRecord = .{ .lo = l.lo, .hi = l.hi, .fields = @splat("") };
        for (0..@min(l.n, 14)) |i| rec.fields[i] = l.fields[i];
        if (std.mem.endsWith(u8, rec.fields[0], ", First>")) {
            const last = (try u.it.next()) orelse return error.BadFirstLast;
            if (!std.mem.endsWith(u8, last.field(0), ", Last>") or last.lo < l.lo) return error.BadFirstLast;
            rec.hi = last.lo;
        }
        return rec;
    }
};

test "ranges and fields" {
    var it = Iterator.init("# comment\n0041..005A    ; Lu # LATIN\n\n00DF; 00DF; 0053 0073; 0053 0053; # SHARP S\r\n");
    const a = (try it.next()).?;
    try std.testing.expectEqual(@as(u21, 0x41), a.lo);
    try std.testing.expectEqual(@as(u21, 0x5A), a.hi);
    try std.testing.expectEqualStrings("Lu", a.field(0));
    const b = (try it.next()).?;
    try std.testing.expectEqual(@as(usize, 3), b.n);
    try std.testing.expectEqualStrings("0053 0073", b.field(1));
    var buf: [4]u21 = undefined;
    try std.testing.expectEqualSlices(u21, &.{ 0x53, 0x73 }, try parseCps(b.field(1), &buf));
    try std.testing.expect((try it.next()) == null);
    try std.testing.expectError(error.BadRange, parseRange("0042..0041"));
    try std.testing.expectError(error.BadCodePoint, parseRange("110000"));
}

test "missing lines" {
    var it = Iterator.init("# @missing: 0000..10FFFF; Left_To_Right\n# @missing: 0590..05FF; R\n0041; L\n");
    const m = (try it.next()).?;
    try std.testing.expect(m.missing);
    try std.testing.expectEqual(@as(u21, 0x10FFFF), m.hi);
    try std.testing.expect((try it.next()).?.missing);
    try std.testing.expect(!(try it.next()).?.missing);
}

test "First/Last pairs" {
    var u = UnicodeDataIterator.init(
        \\0041;LATIN CAPITAL LETTER A;Lu;0;L;;;;;N;;;;0061;
        \\3400;<CJK Ideograph Extension A, First>;Lo;0;L;;;;;N;;;;;
        \\4DBF;<CJK Ideograph Extension A, Last>;Lo;0;L;;;;;N;;;;;
        \\
    );
    const a = (try u.next()).?;
    try std.testing.expectEqualStrings("Lu", a.fields[1]);
    try std.testing.expectEqualStrings("0061", a.fields[12]);
    const r = (try u.next()).?;
    try std.testing.expectEqual(@as(u21, 0x3400), r.lo);
    try std.testing.expectEqual(@as(u21, 0x4DBF), r.hi);
    try std.testing.expect((try u.next()) == null);
}
