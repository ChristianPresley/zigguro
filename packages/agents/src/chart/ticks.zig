//! Axis ticks and labels (E13.F07.S01.T03): "nice numbers" (1, 2, 2.5,
//! 5 × 10^k) for linear axes, decades for log axes, calendar-aligned
//! steps for time axes, label formats (SI suffixes, percent, dates) and
//! the thinning that keeps labels from overlapping.

const std = @import("std");
const infer = @import("../data/infer.zig");
const tz = @import("../sched/tz.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const TickSet = struct {
    /// The first tick.
    start: f64 = 0,
    step: f64 = 1,
    count: u32 = 0,
    /// Decimals that print every tick exactly.
    decimals: u8 = 0,

    pub fn value(t: TickSet, i: usize) f64 {
        const v = t.start + @as(f64, @floatFromInt(i)) * t.step;
        // Snap rounding noise (0.30000000000000004, 1e-17 for zero).
        return if (@abs(v) < @abs(t.step) * 1e-9) 0 else v;
    }
};

/// Ticks inside `[lo, hi]` at a nice step giving at most `max_ticks`
/// intervals. Equal endpoints are widened; reversed ones swapped.
pub fn niceTicks(lo_in: f64, hi_in: f64, max_ticks: u8) TickSet {
    if (!std.math.isFinite(lo_in) or !std.math.isFinite(hi_in)) return .{};
    var lo = @min(lo_in, hi_in);
    var hi = @max(lo_in, hi_in);
    if (lo == hi) {
        const d = if (lo == 0) 1 else @abs(lo) * 0.1;
        lo -= d;
        hi += d;
    }
    const step, const nice = niceStep((hi - lo) / @as(f64, @floatFromInt(@max(1, max_ticks))));
    if (!(step > 0) or !std.math.isFinite(step)) return .{};
    const first = @ceil(lo / step - 1e-9);
    const last = @floor(hi / step + 1e-9);
    if (last < first) return .{ .start = first * step, .step = step };
    const count: u32 = @intFromFloat(@min(last - first + 1, 1e6));
    const exp: i32 = @intFromFloat(@floor(std.math.log10(step) + 1e-9));
    var decimals: i32 = -exp;
    if (nice == 2.5) decimals += 1;
    return .{ .start = first * step, .step = step, .count = count, .decimals = @intCast(std.math.clamp(decimals, 0, 20)) };
}

/// The nice step at or above `rough`, and its mantissa.
pub fn niceStep(rough: f64) struct { f64, f64 } {
    if (!(rough > 0) or !std.math.isFinite(rough)) return .{ 0, 0 };
    const exp = @floor(std.math.log10(rough));
    const base = std.math.pow(f64, 10, exp);
    const f = rough / base;
    const nice: f64 = if (f <= 1 + 1e-9) 1 else if (f <= 2 + 1e-9) 2 else if (f <= 2.5 + 1e-9) 2.5 else if (f <= 5 + 1e-9) 5 else 10;
    return .{ nice * base, if (nice == 10) 1 else nice };
}

/// `[lo, hi]` widened outward to multiples of the nice step.
pub fn niceDomain(lo: f64, hi: f64, max_ticks: u8) [2]f64 {
    const t = niceTicks(lo, hi, max_ticks);
    if (t.step == 0) return .{ lo, hi };
    const a = @min(lo, hi);
    const b = @max(lo, hi);
    if (a == b) return .{ t.value(0), t.value(t.count -| 1) };
    return .{ @floor(a / t.step + 1e-9) * t.step, @ceil(b / t.step - 1e-9) * t.step };
}

/// Log-axis ticks: decades, plus 2 and 5 between them when the range
/// spans few decades. `lo` and `hi` must be positive.
pub fn logTicks(a: Allocator, lo: f64, hi: f64, max_ticks: u8) ![]f64 {
    var out: std.ArrayListUnmanaged(f64) = .empty;
    if (!(lo > 0) or !(hi >= lo) or !std.math.isFinite(hi)) return out.items;
    const e0 = @floor(std.math.log10(lo) + 1e-9);
    const e1 = @ceil(std.math.log10(hi) - 1e-9);
    const decades = e1 - e0;
    const mults: []const f64 = if (decades * 3 <= @as(f64, @floatFromInt(max_ticks))) &.{ 1, 2, 5 } else &.{1};
    // Every k-th decade when there are too many.
    const k = @max(1, @ceil(decades / @as(f64, @floatFromInt(@max(1, max_ticks)))));
    var e = e0;
    while (e <= e1) : (e += k) for (mults) |m| {
        const v = m * std.math.pow(f64, 10, e);
        if (v >= lo * (1 - 1e-9) and v <= hi * (1 + 1e-9)) try out.append(a, v);
    };
    return out.items;
}

// ---- Time ----

pub const ms_second: i64 = 1000;
pub const ms_minute: i64 = 60 * ms_second;
pub const ms_hour: i64 = 60 * ms_minute;
pub const ms_day: i64 = 24 * ms_hour;

/// Time-axis steps, shortest first.
pub const TimeStep = enum {
    s1,
    s5,
    s15,
    s30,
    m1,
    m5,
    m15,
    m30,
    h1,
    h3,
    h6,
    h12,
    d1,
    d2,
    w1,
    mo1,
    mo3,
    y1,
    /// A multiple of years (`TimeTicks.years`).
    years,

    /// The step's approximate length.
    pub fn approxMs(s: TimeStep) i64 {
        return switch (s) {
            .s1 => ms_second,
            .s5 => 5 * ms_second,
            .s15 => 15 * ms_second,
            .s30 => 30 * ms_second,
            .m1 => ms_minute,
            .m5 => 5 * ms_minute,
            .m15 => 15 * ms_minute,
            .m30 => 30 * ms_minute,
            .h1 => ms_hour,
            .h3 => 3 * ms_hour,
            .h6 => 6 * ms_hour,
            .h12 => 12 * ms_hour,
            .d1 => ms_day,
            .d2 => 2 * ms_day,
            .w1 => 7 * ms_day,
            .mo1 => 30 * ms_day,
            .mo3 => 91 * ms_day,
            .y1, .years => 365 * ms_day,
        };
    }

    fn fixedMs(s: TimeStep) ?i64 {
        return switch (s) {
            .s1, .s5, .s15, .s30, .m1, .m5, .m15, .m30, .h1, .h3, .h6, .h12 => s.approxMs(),
            else => null,
        };
    }
};

/// Local time: an offset from UTC (null zone: UTC).
pub const Zone = struct {
    tz: ?*const tz.TimeZone = null,

    pub const utc: Zone = .{};

    /// Milliseconds to add to UTC for local time at `utc_ms`.
    pub fn offset(z: Zone, utc_ms: i64) i64 {
        const t = z.tz orelse return 0;
        return @as(i64, t.offsetAt(@divFloor(utc_ms, 1000)).utoff) * 1000;
    }

    pub fn toLocal(z: Zone, utc_ms: i64) i64 {
        return utc_ms + z.offset(utc_ms);
    }

    /// The UTC time of a local wall time (the earlier one in a fold).
    pub fn toUtc(z: Zone, local_ms: i64) i64 {
        if (z.tz == null) return local_ms;
        const guess = local_ms - z.offset(local_ms);
        return local_ms - z.offset(guess);
    }
};

pub const TimeTicks = struct {
    step: TimeStep,
    /// For `.years`: how many.
    years: u32 = 1,
    values: []const i64,
};

/// Ticks inside `[lo, hi]` (UTC milliseconds) at the shortest
/// calendar step giving at most `max_ticks` intervals, aligned in `zone`.
pub fn timeTicks(a: Allocator, lo_in: i64, hi_in: i64, max_ticks: u8, zone: Zone) !TimeTicks {
    const lo = @min(lo_in, hi_in);
    const hi = @max(lo_in, hi_in);
    const span = @max(hi - lo, 1);
    const max: i64 = @max(1, max_ticks);
    var step: TimeStep = .years;
    for (std.enums.values(TimeStep)) |s| {
        if (s == .years) break;
        if (@divFloor(span, s.approxMs()) <= max) {
            step = s;
            break;
        }
    }
    var years: u32 = 1;
    if (step == .years) {
        const rough = @as(f64, @floatFromInt(span)) / @as(f64, @floatFromInt(365 * ms_day)) / @as(f64, @floatFromInt(max));
        years = @intFromFloat(@max(1, niceStep(rough)[0]));
    }
    var out: std.ArrayListUnmanaged(i64) = .empty;
    var t = floorTo(lo, step, years, zone);
    if (t < lo) t = advance(t, step, years, zone);
    var guard: u32 = 0;
    while (t <= hi and guard < 10_000) : (guard += 1) {
        try out.append(a, t);
        t = advance(t, step, years, zone);
    }
    return .{ .step = step, .years = years, .values = out.items };
}

/// The start of the step containing `t`.
pub fn floorTo(t: i64, step: TimeStep, years: u32, zone: Zone) i64 {
    const local = zone.toLocal(t);
    if (step.fixedMs()) |ms| return zone.toUtc(local - @mod(local, ms));
    const day = @divFloor(local, ms_day);
    const c = infer.civilFromDays(day);
    const d: i64 = switch (step) {
        .d1 => day,
        .d2 => day - @mod(day, 2),
        // 1970-01-01 was a Thursday; weeks start on Monday.
        .w1 => day - @mod(day + 3, 7),
        .mo1 => infer.daysFromCivil(c.y, c.m, 1),
        .mo3 => infer.daysFromCivil(c.y, c.m - (c.m - 1) % 3, 1),
        .y1 => infer.daysFromCivil(c.y, 1, 1),
        .years => infer.daysFromCivil(c.y - @mod(c.y, @as(i64, years)), 1, 1),
        else => unreachable,
    };
    return zone.toUtc(d * ms_day);
}

/// `t` (a step start) moved one step on.
pub fn advance(t: i64, step: TimeStep, years: u32, zone: Zone) i64 {
    if (step.fixedMs()) |ms| return t + ms;
    const local = zone.toLocal(t);
    const day = @divFloor(local, ms_day);
    const c = infer.civilFromDays(day);
    const d: i64 = switch (step) {
        .d1 => day + 1,
        .d2 => day + 2,
        .w1 => day + 7,
        .mo1 => addMonths(c.y, c.m, 1),
        .mo3 => addMonths(c.y, c.m, 3),
        .y1 => infer.daysFromCivil(c.y + 1, 1, 1),
        .years => infer.daysFromCivil(c.y + years, 1, 1),
        else => unreachable,
    };
    return zone.toUtc(d * ms_day);
}

fn addMonths(y: i64, m: u32, n: u32) i64 {
    const total = @as(i64, m - 1) + n;
    return infer.daysFromCivil(y + @divFloor(total, 12), @intCast(@mod(total, 12) + 1), 1);
}

const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// A time tick's label at `step`'s precision.
pub fn formatTime(w: *Writer, t: i64, step: TimeStep, zone: Zone) Writer.Error!void {
    const local = zone.toLocal(t);
    const day = @divFloor(local, ms_day);
    const c = infer.civilFromDays(day);
    const in_day = local - day * ms_day;
    const hh: u64 = @intCast(@divFloor(in_day, ms_hour));
    const mm: u64 = @intCast(@divFloor(@mod(in_day, ms_hour), ms_minute));
    const ss: u64 = @intCast(@divFloor(@mod(in_day, ms_minute), ms_second));
    switch (step) {
        .s1, .s5, .s15, .s30 => try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ hh, mm, ss }),
        .m1, .m5, .m15, .m30, .h1, .h3, .h6, .h12 => if (in_day == 0)
            try w.print("{s} {d}", .{ month_names[c.m - 1], c.d })
        else
            try w.print("{d:0>2}:{d:0>2}", .{ hh, mm }),
        .d1, .d2, .w1 => try w.print("{s} {d}", .{ month_names[c.m - 1], c.d }),
        .mo1, .mo3 => if (c.m == 1) try w.print("{d}", .{c.y}) else try w.writeAll(month_names[c.m - 1]),
        .y1, .years => try w.print("{d}", .{c.y}),
    }
}

/// A full timestamp for tooltips: `2026-03-05`, or with `14:03` (and
/// seconds when present) when not midnight.
pub fn formatTimestamp(w: *Writer, t: i64, zone: Zone) Writer.Error!void {
    const local = zone.toLocal(t);
    const day = @divFloor(local, ms_day);
    const c = infer.civilFromDays(day);
    try w.print("{d}-{d:0>2}-{d:0>2}", .{ c.y, c.m, c.d });
    const in_day = local - day * ms_day;
    if (in_day == 0) return;
    const hh: u64 = @intCast(@divFloor(in_day, ms_hour));
    const mm: u64 = @intCast(@divFloor(@mod(in_day, ms_hour), ms_minute));
    const ss: u64 = @intCast(@divFloor(@mod(in_day, ms_minute), ms_second));
    try w.print(" {d:0>2}:{d:0>2}", .{ hh, mm });
    if (ss != 0) try w.print(":{d:0>2}", .{ss});
}

// ---- Numbers ----

pub const NumFormat = enum { fixed, si, percent };

/// `v` with `decimals` decimals; `si` scales by k, M, G, T (keeping the
/// digits the step needs); `percent` multiplies by 100.
pub fn formatNumber(w: *Writer, v_in: f64, decimals: u8, f: NumFormat) Writer.Error!void {
    if (!std.math.isFinite(v_in)) return w.writeAll(if (std.math.isNan(v_in)) "NaN" else if (v_in > 0) "∞" else "-∞");
    switch (f) {
        .fixed => try fixed(w, v_in, decimals),
        .percent => {
            try fixed(w, v_in * 100, decimals -| 2);
            try w.writeByte('%');
        },
        .si => {
            const units = [_]struct { f64, []const u8 }{ .{ 1e12, "T" }, .{ 1e9, "G" }, .{ 1e6, "M" }, .{ 1e3, "k" } };
            for (units) |u| if (@abs(v_in) >= u[0]) return siScaled(w, v_in / u[0], u[1]);
            try fixed(w, v_in, decimals);
        },
    }
}

/// Up to three significant digits after scaling: 1.25k, 12.5k, 125k.
fn siScaled(w: *Writer, x: f64, suffix: []const u8) Writer.Error!void {
    const a = @abs(x);
    const d: u8 = if (a >= 100) 0 else if (a >= 10) 1 else 2;
    var buf: [64]u8 = undefined;
    var s: []const u8 = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ x, d }) catch return w.writeAll("?");
    if (std.mem.indexOfScalar(u8, s, '.') != null) {
        s = std.mem.trimEnd(u8, s, "0");
        s = std.mem.trimEnd(u8, s, ".");
    }
    try w.writeAll(s);
    try w.writeAll(suffix);
}

fn fixed(w: *Writer, v: f64, decimals: u8) Writer.Error!void {
    const x = if (@abs(v) < 0.5 * std.math.pow(f64, 10, -@as(f64, @floatFromInt(decimals)))) 0 else v;
    try w.print("{d:.[1]}", .{ x, decimals });
}

/// The format `auto` picks for ticks: SI when the largest tick reaches a
/// million, fixed otherwise.
pub fn autoFormat(t: TickSet) NumFormat {
    var m: f64 = 0;
    if (t.count > 0) m = @max(@abs(t.value(0)), @abs(t.value(t.count - 1)));
    return if (m >= 1e6) .si else .fixed;
}

/// Label decimals for a free-standing value (tooltips): enough for four
/// significant digits, at most 6.
pub fn valueDecimals(v: f64) u8 {
    const a = @abs(v);
    if (a == 0 or a >= 1000 or !std.math.isFinite(a)) return 0;
    const e: i32 = @intFromFloat(@floor(std.math.log10(a)));
    return @intCast(std.math.clamp(3 - e, 0, 6));
}

/// Writes a value with trailing fractional zeros dropped.
pub fn formatValue(w: *Writer, v: f64) Writer.Error!void {
    var buf: [64]u8 = undefined;
    var s: []const u8 = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ v, valueDecimals(v) }) catch return w.writeAll("?");
    if (std.mem.indexOfScalar(u8, s, '.') != null) {
        s = std.mem.trimEnd(u8, s, "0");
        s = std.mem.trimEnd(u8, s, ".");
    }
    if (std.mem.eql(u8, s, "-0")) s = "0";
    try w.writeAll(s);
}

// ---- Collisions ----

/// The smallest stride (1, 2, 4, …) at which labels centred at
/// `centers` with `widths` keep `gap` between neighbours.
pub fn labelStride(centers: []const f32, widths: []const f32, gap: f32) usize {
    var stride: usize = 1;
    while (stride < centers.len) : (stride *= 2) {
        var ok = true;
        var i: usize = stride;
        while (i < centers.len) : (i += stride) {
            const prev = i - stride;
            if (@abs(centers[i] - centers[prev]) < (widths[i] + widths[prev]) / 2 + gap) {
                ok = false;
                break;
            }
        }
        if (ok) return stride;
    }
    return @max(1, stride);
}

test {
    std.testing.refAllDecls(@This());
}
