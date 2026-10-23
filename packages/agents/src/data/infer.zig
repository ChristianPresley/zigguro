//! Column types (E13.F06.S01.T03) inferred from sampled cells.
//!
//! Null cells (empty, `\N`, `null`, `NA`, `N/A`) are left out; the rest
//! are tried in order: bool (`true/false/yes/no/0/1`), int (i64, an
//! optional sign, no separators), decimal (a `,` decimal point, when the
//! file allows it), float, date (`YYYY-MM-DD`, or `DD/MM/YYYY` vs
//! `MM/DD/YYYY` told apart by a part above 12), datetime (RFC 3339), else
//! string. A column has the first type at least 98% of its non-null
//! samples parse as.

const std = @import("std");

pub const ColType = enum {
    null_,
    bool_,
    int,
    float,
    decimal,
    date,
    datetime,
    string,

    pub fn numeric(t: ColType) bool {
        return switch (t) {
            .int, .float, .decimal, .date, .datetime => true,
            else => false,
        };
    }
};

pub const DateOrder = enum { dmy, mdy };

pub const InferCtx = struct {
    /// `,` may be the decimal point (the CSV delimiter is `;`).
    decimal_comma: bool = false,
    /// How to read `a/b/YYYY` when no part is above 12.
    date_order: ?DateOrder = null,
};

/// A parsed cell. Dates are days since 1970-01-01, datetimes
/// milliseconds since the Unix epoch (UTC).
pub const Value = union(enum) {
    bool_: bool,
    int: i64,
    float: f64,
    date: i32,
    datetime: i64,
    string: []const u8,

    /// The value on a number line (strings have none).
    pub fn toF64(v: Value) ?f64 {
        return switch (v) {
            .bool_ => |b| @floatFromInt(@intFromBool(b)),
            .int => |i| @floatFromInt(i),
            .float => |f| f,
            .date => |d| @floatFromInt(d),
            .datetime => |t| @floatFromInt(t),
            .string => null,
        };
    }

    pub fn order(a: Value, b: Value) std.math.Order {
        if (a == .string and b == .string) return std.mem.order(u8, a.string, b.string);
        const x = a.toF64() orelse return .lt;
        const y = b.toF64() orelse return .gt;
        return std.math.order(x, y);
    }
};

const null_tokens = [_][]const u8{ "", "\\N", "null", "NULL", "Null", "NA", "N/A", "n/a", "NaN" };

pub fn isNullText(s: []const u8) bool {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len > 4) return false;
    for (null_tokens) |n| if (std.mem.eql(u8, t, n)) return true;
    return false;
}

const bool_tokens = [_]struct { []const u8, bool }{
    .{ "true", true }, .{ "false", false }, .{ "yes", true }, .{ "no", false }, .{ "1", true }, .{ "0", false },
};

pub fn parseBool(s: []const u8) ?bool {
    for (bool_tokens) |b| if (std.ascii.eqlIgnoreCase(s, b[0])) return b[1];
    return null;
}

pub fn parseInt(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    const digits = if (s[0] == '+' or s[0] == '-') s[1..] else s;
    if (digits.len == 0) return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(i64, if (s[0] == '+') s[1..] else s, 10) catch null;
}

pub fn parseFloat(s: []const u8) ?f64 {
    if (s.len == 0) return null;
    // Only plain decimal and exponent forms (no hex, inf, nan).
    for (s) |c| if (!(std.ascii.isDigit(c) or c == '.' or c == '-' or c == '+' or c == 'e' or c == 'E')) return null;
    return std.fmt.parseFloat(f64, s) catch null;
}

/// `^\d+,\d+$` (and a sign) read with `,` as the decimal point.
pub fn parseDecimalComma(s: []const u8) ?f64 {
    const comma = std.mem.indexOfScalar(u8, s, ',') orelse return null;
    const int_part = if (s.len > 0 and (s[0] == '-' or s[0] == '+')) s[1..comma] else s[0..comma];
    const frac = s[comma + 1 ..];
    if (int_part.len == 0 or frac.len == 0) return null;
    for (int_part) |c| if (!std.ascii.isDigit(c)) return null;
    for (frac) |c| if (!std.ascii.isDigit(c)) return null;
    var buf: [64]u8 = undefined;
    if (s.len > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    buf[comma] = '.';
    return std.fmt.parseFloat(f64, buf[0..s.len]) catch null;
}

pub fn daysFromCivil(y: i64, m: u32, d: u32) i32 {
    // Howard Hinnant's algorithm.
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe: i64 = yy - era * 400;
    const mp: i64 = @intCast((m + 9) % 12);
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, d) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return @intCast(era * 146097 + doe - 719468);
}

/// Year, month and day of `days` since 1970-01-01 (Howard Hinnant's
/// `civil_from_days`).
pub fn civilFromDays(days: i64) struct { y: i64, m: u32, d: u32 } {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe: i64 = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .y = yoe + era * 400 + @intFromBool(m <= 2), .m = m, .d = d };
}

fn validDate(y: i64, m: u32, d: u32) bool {
    if (m < 1 or m > 12 or d < 1) return false;
    const leap = (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
    const days = [_]u32{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return d <= days[m - 1];
}

fn num(s: []const u8) ?u32 {
    if (s.len == 0 or s.len > 4) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}

/// `YYYY-MM-DD` as days since the epoch.
pub fn parseIsoDate(s: []const u8) ?i32 {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return null;
    const y = num(s[0..4]) orelse return null;
    const m = num(s[5..7]) orelse return null;
    const d = num(s[8..10]) orelse return null;
    if (!validDate(y, m, d)) return null;
    return daysFromCivil(y, m, d);
}

/// The two leading parts of `a/b/YYYY` (or with `.` or `-`), if `s` has
/// that shape.
pub fn slashParts(s: []const u8) ?struct { a: u32, b: u32, y: u32 } {
    var it = std.mem.tokenizeAny(u8, s, "/.-");
    const a = num(it.next() orelse return null) orelse return null;
    const b = num(it.next() orelse return null) orelse return null;
    const ys = it.next() orelse return null;
    if (it.next() != null or ys.len != 4) return null;
    const y = num(ys) orelse return null;
    if (std.mem.indexOfScalar(u8, s, '/') == null and std.mem.indexOfScalar(u8, s, '.') == null) return null;
    return .{ .a = a, .b = b, .y = y };
}

pub fn parseSlashDate(s: []const u8, order: DateOrder) ?i32 {
    const p = slashParts(s) orelse return null;
    const m, const d = if (order == .dmy) .{ p.b, p.a } else .{ p.a, p.b };
    if (!validDate(p.y, m, d)) return null;
    return daysFromCivil(p.y, m, d);
}

/// RFC 3339 (`YYYY-MM-DDTHH:MM:SS[.frac](Z|±HH:MM)`; a space for `T`
/// and a missing zone, read as UTC, are accepted) as Unix milliseconds.
pub fn parseDatetime(s: []const u8) ?i64 {
    if (s.len < 19 or (s[10] != 'T' and s[10] != 't' and s[10] != ' ')) return null;
    const days = parseIsoDate(s[0..10]) orelse return null;
    if (s[13] != ':' or s[16] != ':') return null;
    const hh = num(s[11..13]) orelse return null;
    const mm = num(s[14..16]) orelse return null;
    const ss = num(s[17..19]) orelse return null;
    if (hh > 23 or mm > 59 or ss > 60) return null;
    var i: usize = 19;
    var ms: i64 = 0;
    if (i < s.len and s[i] == '.') {
        i += 1;
        var scale: i64 = 100;
        const start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
            ms += @as(i64, s[i] - '0') * scale;
            scale = @divTrunc(scale, 10);
        }
        if (i == start) return null;
    }
    var offset_min: i64 = 0;
    if (i < s.len) {
        if (s[i] == 'Z' or s[i] == 'z') {
            i += 1;
        } else if ((s[i] == '+' or s[i] == '-') and i + 6 == s.len and s[i + 3] == ':') {
            const oh = num(s[i + 1 .. i + 3]) orelse return null;
            const om = num(s[i + 4 .. i + 6]) orelse return null;
            offset_min = @as(i64, oh) * 60 + om;
            if (s[i] == '-') offset_min = -offset_min;
            i += 6;
        } else return null;
    }
    if (i != s.len) return null;
    const secs = @as(i64, days) * 86400 + @as(i64, hh) * 3600 + @as(i64, mm) * 60 + ss - offset_min * 60;
    return secs * 1000 + ms;
}

/// The date order the samples imply: a first part above 12 means day
/// first, a second part above 12 month first.
pub fn dateOrderOf(samples: []const []const u8) ?DateOrder {
    for (samples) |s| {
        const p = slashParts(std.mem.trim(u8, s, " ")) orelse continue;
        if (p.a > 12 and p.b <= 12) return .dmy;
        if (p.b > 12 and p.a <= 12) return .mdy;
    }
    return null;
}

/// The column's type from its samples.
pub fn inferColumn(samples: []const []const u8, ctx: InferCtx) ColType {
    var n: usize = 0;
    var ok = std.EnumArray(ColType, usize).initFill(0);
    const order = ctx.date_order orelse dateOrderOf(samples) orelse .mdy;
    for (samples) |raw| {
        if (isNullText(raw)) continue;
        const s = std.mem.trim(u8, raw, " \t");
        n += 1;
        if (parseBool(s) != null) ok.getPtr(.bool_).* += 1;
        if (parseInt(s) != null) ok.getPtr(.int).* += 1;
        if (parseFloat(s) != null) ok.getPtr(.float).* += 1;
        if (ctx.decimal_comma and (parseDecimalComma(s) != null or parseInt(s) != null)) ok.getPtr(.decimal).* += 1;
        if (parseIsoDate(s) != null or parseSlashDate(s, order) != null) ok.getPtr(.date).* += 1;
        if (parseDatetime(s) != null) ok.getPtr(.datetime).* += 1;
    }
    if (n == 0) return .null_;
    const need = (n * 98 + 99) / 100;
    for ([_]ColType{ .bool_, .int, .decimal, .float, .date, .datetime }) |t| {
        if (ok.get(t) >= need) return t;
    }
    return .string;
}

/// Parses a cell as `ty` (null for null cells or when it doesn't parse).
pub fn parse(raw: []const u8, ty: ColType, ctx: InferCtx) ?Value {
    if (isNullText(raw)) return null;
    return parseNonNull(std.mem.trim(u8, raw, " \t"), ty, ctx);
}

/// `parse` for trimmed text already known not to be null.
pub fn parseNonNull(s: []const u8, ty: ColType, ctx: InferCtx) ?Value {
    return switch (ty) {
        .null_ => null,
        .bool_ => if (parseBool(s)) |b| .{ .bool_ = b } else null,
        .int => if (parseInt(s)) |i| .{ .int = i } else if (parseFloat(s)) |f| .{ .float = f } else null,
        .float => if (parseFloat(s)) |f| .{ .float = f } else null,
        .decimal => if (parseDecimalComma(s)) |f| .{ .float = f } else if (parseInt(s)) |i| .{ .int = i } else null,
        .date => if (parseIsoDate(s)) |d| .{ .date = d } else if (parseSlashDate(s, ctx.date_order orelse .mdy)) |d| .{ .date = d } else null,
        .datetime => if (parseDatetime(s)) |t| .{ .datetime = t } else null,
        .string => .{ .string = s },
    };
}
