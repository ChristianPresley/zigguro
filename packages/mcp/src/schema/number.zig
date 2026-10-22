//! Exact JSON numbers for JSON Schema: `mant * 10^exp` with a 128-bit
//! mantissa. Every literal (`.integer`, `.float`, `.number_string`) parses
//! into a `Num`, and comparisons and `multipleOf` are exact; `1 == 1.0` and
//! `19.99` is a multiple of `0.01`.
//!
//! Literals with more than 38 significant digits keep the top 38 and are
//! marked `inexact`. `multipleOf` falls back to f64 `@rem` with a relative
//! epsilon of 1e-12 when the aligned operands overflow 256 bits.

const std = @import("std");
const Value = std.json.Value;

/// A decimal number. Normalized: `mant` has no trailing zeros, and zero is
/// `{ .neg = false, .mant = 0, .exp = 0 }`.
pub const Num = struct {
    neg: bool = false,
    mant: u128 = 0,
    exp: i32 = 0,
    /// Digits were dropped while parsing (more than 38 significant ones).
    inexact: bool = false,

    /// Zero.
    pub const zero: Num = .{};

    /// Parses a JSON number literal. Returns null for anything else.
    pub fn parse(s: []const u8) ?Num {
        var i: usize = 0;
        var n: Num = .{};
        if (i < s.len and s[i] == '-') {
            n.neg = true;
            i += 1;
        }
        var digits: u32 = 0;
        var exp: i64 = 0;
        var any = false;
        var seen_dot = false;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c == '.') {
                if (seen_dot) return null;
                seen_dot = true;
                continue;
            }
            if (c < '0' or c > '9') break;
            any = true;
            const d: u128 = c - '0';
            if (digits == 0 and d == 0) {
                if (seen_dot) exp -= 1;
                continue;
            }
            if (digits < 38) {
                n.mant = n.mant * 10 + d;
                digits += 1;
                if (seen_dot) exp -= 1;
            } else {
                if (d != 0) n.inexact = true;
                if (!seen_dot) exp += 1;
            }
        }
        if (!any) return null;
        if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
            i += 1;
            var eneg = false;
            if (i < s.len and (s[i] == '+' or s[i] == '-')) {
                eneg = s[i] == '-';
                i += 1;
            }
            var e: i64 = 0;
            var edigits = false;
            while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
                edigits = true;
                e = @min(e * 10 + (s[i] - '0'), 1_000_000);
            }
            if (!edigits) return null;
            exp += if (eneg) -e else e;
        }
        if (i != s.len) return null;
        n.exp = @intCast(std.math.clamp(exp, -2_000_000, 2_000_000));
        return n.normalized();
    }

    /// The number held by a JSON value, or null for non-numbers.
    pub fn fromValue(v: Value) ?Num {
        return switch (v) {
            .integer => |i| fromInt(i),
            .float => |f| fromFloat(f),
            .number_string => |s| parse(s),
            else => null,
        };
    }

    /// The value of integer `i`.
    pub fn fromInt(i: anytype) Num {
        const n: Num = .{ .neg = i < 0, .mant = @abs(@as(i128, i)) };
        return n.normalized();
    }

    /// The shortest decimal that round-trips `f` (so `19.99` stays exact).
    pub fn fromFloat(f: f64) ?Num {
        if (!std.math.isFinite(f)) return null;
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{e}", .{f}) catch return null;
        return parse(s);
    }

    fn normalized(n: Num) Num {
        var r = n;
        if (r.mant == 0) return .{ .inexact = n.inexact };
        while (r.mant % 10 == 0) {
            r.mant /= 10;
            r.exp += 1;
        }
        return r;
    }

    /// Whether the number is zero.
    pub fn isZero(n: Num) bool {
        return n.mant == 0;
    }

    /// Whether the number has no fractional part (`1.0` is an integer).
    pub fn isInteger(n: Num) bool {
        return n.mant == 0 or n.exp >= 0;
    }

    fn digitCount(m: u128) i32 {
        if (m == 0) return 0;
        return @intCast(std.math.log10_int(m) + 1);
    }

    /// Exact ordering.
    pub fn order(a: Num, b: Num) std.math.Order {
        if (a.mant == 0 and b.mant == 0) return .eq;
        const sa: i2 = if (a.mant == 0) 0 else if (a.neg) -1 else 1;
        const sb: i2 = if (b.mant == 0) 0 else if (b.neg) -1 else 1;
        if (sa != sb) return std.math.order(sa, sb);
        const mag = orderMagnitude(a, b);
        return if (sa < 0) mag.invert() else mag;
    }

    fn orderMagnitude(a: Num, b: Num) std.math.Order {
        // Compare the position of the most significant digit first.
        const ta = digitCount(a.mant) + a.exp;
        const tb = digitCount(b.mant) + b.exp;
        if (ta != tb) return std.math.order(ta, tb);
        // Same magnitude: align exponents (the shift is at most 38 digits).
        const m = @min(a.exp, b.exp);
        const xa = @as(u256, a.mant) * pow10(@intCast(a.exp - m));
        const xb = @as(u256, b.mant) * pow10(@intCast(b.exp - m));
        return std.math.order(xa, xb);
    }

    /// Exact equality.
    pub fn eql(a: Num, b: Num) bool {
        return a.order(b) == .eq;
    }

    /// The nearest f64.
    pub fn toF64(n: Num) f64 {
        var buf: [96]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{s}{d}e{d}", .{ if (n.neg) "-" else "", n.mant, n.exp }) catch return std.math.nan(f64);
        return std.fmt.parseFloat(f64, s) catch std.math.nan(f64);
    }

    /// Whether `x` is an integer multiple of `d` (`d > 0`).
    pub fn multipleOf(x: Num, d: Num) bool {
        if (d.mant == 0) return false;
        if (x.mant == 0) return true;
        const m = @min(x.exp, d.exp);
        const sx = x.exp - m;
        const sd = d.exp - m;
        if (sx <= 38 and sd <= 38) {
            const ax = std.math.mul(u256, x.mant, pow10(@intCast(sx))) catch return floatMultiple(x, d);
            const ad = std.math.mul(u256, d.mant, pow10(@intCast(sd))) catch return floatMultiple(x, d);
            return ax % ad == 0;
        }
        // x's exponent is far above d's: x = xm * 10^sx with sx > 38.
        if (sd == 0 and sx > 38) {
            // d.mant must divide xm * 10^sx; reduce 10^sx modulo d.mant.
            var r: u256 = x.mant % d.mant;
            var k: i32 = 0;
            while (k < sx) : (k += 1) r = (r * 10) % d.mant;
            return r == 0;
        }
        return floatMultiple(x, d);
    }

    fn floatMultiple(x: Num, d: Num) bool {
        const fx = x.toF64();
        const fd = d.toF64();
        if (!std.math.isFinite(fx) or !std.math.isFinite(fd)) return false;
        const q = fx / fd;
        if (!std.math.isFinite(q)) return false;
        return @abs(q - @round(q)) <= 1e-12 * @max(1.0, @abs(q));
    }
};

fn pow10(n: u32) u256 {
    var r: u256 = 1;
    var i: u32 = 0;
    while (i < n) : (i += 1) r *= 10;
    return r;
}

const testing = std.testing;

test "number: parse and normalize" {
    const a = Num.parse("19.990").?;
    try testing.expectEqual(@as(u128, 1999), a.mant);
    try testing.expectEqual(@as(i32, -2), a.exp);
    const b = Num.parse("-1.5e3").?;
    try testing.expect(b.neg and b.mant == 15 and b.exp == 2);
    try testing.expect(Num.parse("0.000").?.isZero());
    try testing.expect(Num.parse("1.").?.eql(Num.fromInt(1)));
    try testing.expect(Num.parse("abc") == null);
    try testing.expect(Num.parse("1e") == null);
}

test "number: exact order and integer" {
    try testing.expect(Num.fromInt(1).eql(Num.fromFloat(1.0).?));
    try testing.expect(Num.fromFloat(1.0).?.isInteger());
    try testing.expect(!Num.fromFloat(1.5).?.isInteger());
    try testing.expectEqual(std.math.Order.lt, Num.parse("0.1").?.order(Num.parse("0.11").?));
    try testing.expectEqual(std.math.Order.gt, Num.parse("-0.1").?.order(Num.parse("-0.11").?));
    try testing.expectEqual(std.math.Order.lt, Num.parse("-1e400").?.order(Num.zero));
    try testing.expectEqual(std.math.Order.gt, Num.parse("18446744073709551616").?.order(Num.parse("18446744073709551615").?));
}

test "number: multipleOf exact decimals" {
    try testing.expect(Num.fromFloat(19.99).?.multipleOf(Num.fromFloat(0.01).?));
    try testing.expect(!Num.parse("0.075").?.multipleOf(Num.parse("0.02").?));
    try testing.expect(Num.parse("12391239123").?.multipleOf(Num.parse("1e-8").?));
    try testing.expect(!Num.parse("1e308").?.multipleOf(Num.parse("0.123456789").?));
    try testing.expect(Num.parse("1e60").?.multipleOf(Num.parse("4").?));
    try testing.expect(!Num.parse("1e60").?.multipleOf(Num.parse("3").?));
}
