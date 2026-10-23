//! POSIX TZ rule strings (E13.F02.S01.T04): `std offset [dst [offset]
//! [,rule,rule]]`, as found in a TZif footer or in `$TZ`. Rules are
//! `Mm.w.d`, `Jn` or `n`, each with an optional `/time`; names may be
//! quoted (`<+0330>`). RFC 9636 §3.3.2 extensions are accepted: rule
//! times from -167 to 167 hours and all-year daylight saving time. Pure.

const std = @import("std");
const zone = @import("zone.zig");

pub const Error = error{InvalidTzString};

pub const RuleDate = struct {
    kind: Kind,
    /// Local time of day of the change, in seconds (may be negative or
    /// past 24 h).
    time_s: i32 = 7200,

    pub const Kind = union(enum) {
        /// `Jn`: day 1..365, February 29 never counted.
        julian_no_leap: u16,
        /// `n`: day 0..365, February 29 counted.
        julian: u16,
        /// `Mm.w.d`: weekday `day` (0 = Sunday) of week `week` (5 = last).
        mwd: struct { month: u4, week: u3, day: u3 },
    };

    /// Days since 1970-01-01 of this date in `year`.
    pub fn dayIn(r: RuleDate, year: u16) i64 {
        const jan1 = zone.daysFromCivil(year, 1, 1);
        return switch (r.kind) {
            .julian_no_leap => |n| jan1 + n - 1 + @intFromBool(zone.isLeap(year) and n >= 60),
            .julian => |n| jan1 + n,
            .mwd => |m| blk: {
                const first = zone.weekday(year, m.month, 1);
                var d: u32 = 1 + (@as(u32, m.day) + 7 - first) % 7 + (@as(u32, m.week) - 1) * 7;
                while (d > zone.daysInMonth(year, m.month)) d -= 7;
                break :blk zone.daysFromCivil(year, m.month, @intCast(d));
            },
        };
    }
};

/// Offsets are seconds east of UTC (the opposite sign of the string).
pub const PosixRule = struct {
    std_off: i32,
    dst_off: ?i32 = null,
    start: ?RuleDate = null,
    end: ?RuleDate = null,
    /// NUL-padded.
    std_abbr: [8]u8 = @splat(0),
    dst_abbr: [8]u8 = @splat(0),

    pub const Info = struct { utoff: i32, is_dst: bool };

    pub fn parse(s: []const u8) Error!PosixRule {
        var p: Parser = .{ .s = s };
        var r: PosixRule = .{ .std_off = 0 };
        try p.name(&r.std_abbr);
        r.std_off = -try p.offset(24);
        if (p.done()) return r;
        try p.name(&r.dst_abbr);
        r.dst_off = r.std_off + 3600;
        if (!p.done() and p.peek() != ',') r.dst_off = -try p.offset(24);
        if (p.done()) {
            // No rule: the US rule, as glibc and zic assume.
            r.start = .{ .kind = .{ .mwd = .{ .month = 3, .week = 2, .day = 0 } } };
            r.end = .{ .kind = .{ .mwd = .{ .month = 11, .week = 1, .day = 0 } } };
            return r;
        }
        try p.expect(',');
        r.start = try p.rule();
        try p.expect(',');
        r.end = try p.rule();
        if (!p.done()) return error.InvalidTzString;
        return r;
    }

    pub fn stdAbbr(r: *const PosixRule) []const u8 {
        return std.mem.sliceTo(&r.std_abbr, 0);
    }

    pub fn dstAbbr(r: *const PosixRule) []const u8 {
        return std.mem.sliceTo(&r.dst_abbr, 0);
    }

    pub fn offsetAt(r: *const PosixRule, unix_s: i64) i32 {
        return r.at(unix_s).utoff;
    }

    pub fn at(r: *const PosixRule, unix_s: i64) Info {
        const dst = r.dst_off orelse return .{ .utoff = r.std_off, .is_dst = false };
        const t = r.changes(yearOf(unix_s + r.std_off));
        const in_dst = if (t.start < t.end) unix_s >= t.start and unix_s < t.end else !(unix_s >= t.end and unix_s < t.start);
        return if (in_dst) .{ .utoff = dst, .is_dst = true } else .{ .utoff = r.std_off, .is_dst = false };
    }

    /// The instants daylight saving time starts and ends in `year`
    /// (only for rules with daylight saving time).
    pub fn changes(r: *const PosixRule, year: u16) struct { start: i64, end: i64 } {
        const s = r.start.?;
        const e = r.end.?;
        return .{
            .start = s.dayIn(year) * 86_400 + s.time_s - r.std_off,
            .end = e.dayIn(year) * 86_400 + e.time_s - r.dst_off.?,
        };
    }

    /// The first change strictly after `unix_s`, if the rule has any.
    pub fn nextChange(r: *const PosixRule, unix_s: i64) ?i64 {
        if (r.dst_off == null) return null;
        const y = yearOf(unix_s + r.std_off);
        var best: ?i64 = null;
        for ([_]u16{ y -| 1, y, y +| 1 }) |yy| {
            const c = r.changes(yy);
            for ([_]i64{ c.start, c.end }) |t| {
                if (t > unix_s and (best == null or t < best.?)) best = t;
            }
        }
        // All-year daylight saving time: the "changes" are not changes.
        if (best) |b| if (r.at(b - 1).utoff == r.at(b).utoff) return null;
        return best;
    }
};

/// Clamped to the years `LocalDateTime` covers.
fn yearOf(unix_s: i64) u16 {
    const lo = zone.daysFromCivil(1, 1, 1) * 86_400;
    const hi = zone.daysFromCivil(9999, 12, 31) * 86_400;
    return zone.civilFromDays(@divFloor(std.math.clamp(unix_s, lo, hi), 86_400)).year;
}

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn done(p: *const Parser) bool {
        return p.i >= p.s.len;
    }

    fn peek(p: *const Parser) u8 {
        return if (p.done()) 0 else p.s[p.i];
    }

    fn expect(p: *Parser, c: u8) Error!void {
        if (p.peek() != c) return error.InvalidTzString;
        p.i += 1;
    }

    fn name(p: *Parser, out: *[8]u8) Error!void {
        const start = p.i;
        var text: []const u8 = undefined;
        if (p.peek() == '<') {
            p.i += 1;
            while (!p.done() and p.s[p.i] != '>') : (p.i += 1) {
                const c = p.s[p.i];
                if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-') return error.InvalidTzString;
            }
            if (p.done()) return error.InvalidTzString;
            text = p.s[start + 1 .. p.i];
            p.i += 1;
        } else {
            while (!p.done() and std.ascii.isAlphabetic(p.s[p.i])) p.i += 1;
            text = p.s[start..p.i];
        }
        if (text.len < 3 or text.len > out.len) return error.InvalidTzString;
        @memcpy(out[0..text.len], text);
    }

    fn num(p: *Parser, max: u32) Error!u32 {
        const start = p.i;
        var v: u32 = 0;
        while (!p.done() and std.ascii.isDigit(p.s[p.i])) : (p.i += 1) {
            v = v * 10 + (p.s[p.i] - '0');
            if (v > max) return error.InvalidTzString;
        }
        if (p.i == start) return error.InvalidTzString;
        return v;
    }

    /// `[+-]hh[:mm[:ss]]` in seconds, sign as written.
    fn offset(p: *Parser, max_h: u32) Error!i32 {
        var neg = false;
        if (p.peek() == '+' or p.peek() == '-') {
            neg = p.peek() == '-';
            p.i += 1;
        }
        var v: i32 = @intCast(try p.num(max_h) * 3600);
        if (p.peek() == ':') {
            p.i += 1;
            v += @intCast(try p.num(59) * 60);
            if (p.peek() == ':') {
                p.i += 1;
                v += @intCast(try p.num(59));
            }
        }
        return if (neg) -v else v;
    }

    fn rule(p: *Parser) Error!RuleDate {
        var r: RuleDate = .{ .kind = undefined };
        switch (p.peek()) {
            'M' => {
                p.i += 1;
                const m = try p.num(12);
                try p.expect('.');
                const w = try p.num(5);
                try p.expect('.');
                const d = try p.num(6);
                if (m < 1 or w < 1) return error.InvalidTzString;
                r.kind = .{ .mwd = .{ .month = @intCast(m), .week = @intCast(w), .day = @intCast(d) } };
            },
            'J' => {
                p.i += 1;
                const n = try p.num(365);
                if (n < 1) return error.InvalidTzString;
                r.kind = .{ .julian_no_leap = @intCast(n) };
            },
            else => r.kind = .{ .julian = @intCast(try p.num(365)) },
        }
        if (p.peek() == '/') {
            p.i += 1;
            r.time_s = try p.offset(167);
        }
        return r;
    }
};
