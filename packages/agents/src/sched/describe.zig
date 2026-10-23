//! English descriptions of cron expressions (E13.F02.S01.T01) for the
//! automation editor and `zg automation show`: the common shapes ("every
//! 15 minutes", "at 09:30 on weekdays", "every hour from 09:00 to 17:00")
//! read naturally; anything else lists its fields. Deterministic and
//! allocation-free.

const std = @import("std");
const cron = @import("cron.zig");

const CronExpr = cron.CronExpr;
const Writer = std.Io.Writer;

const all_minutes: u64 = (1 << 60) - 1;
const all_hours: u32 = (1 << 24) - 1;
const all_months: u16 = 0x1FFE;
const all_dow: u8 = 0x7F;
const weekdays: u8 = 0b0111110;
const weekends: u8 = 0b1000001;

const month_names = [_][]const u8{ "", "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const dow_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

pub fn describe(c: *const CronExpr, w: *Writer) Writer.Error!void {
    const starts_every = try writeTime(c, w);
    try writeDays(c, w, starts_every);
}

/// The time of day. True when the phrase already repeats ("every ..."),
/// so "every day" would be redundant.
fn writeTime(c: *const CronExpr, w: *Writer) Writer.Error!bool {
    const m = c.minutes;
    const h = c.hours;
    if (m == all_minutes) {
        try w.writeAll("every minute");
        try writeHourWindow(h, w);
        return true;
    }
    if (stepOf(u64, m, 0, 59)) |n| {
        try w.print("every {d} minutes", .{n});
        try writeHourWindow(h, w);
        return true;
    }
    if (single(u64, m)) |mi| {
        if (h == all_hours) {
            try w.print("every hour at :{d:0>2}", .{mi});
            return true;
        }
        if (single(u32, h)) |hr| {
            try w.print("at {d:0>2}:{d:0>2}", .{ hr, mi });
            return false;
        }
        if (stepOf(u32, h, 0, 23)) |n| {
            try w.print("every {d} hours at :{d:0>2}", .{ n, mi });
            return true;
        }
        if (run(u32, h)) |r| {
            try w.print("every hour from {d:0>2}:{d:0>2} to {d:0>2}:{d:0>2}", .{ r[0], mi, r[1], mi });
            return true;
        }
        if (@popCount(h) <= 6) {
            try w.writeAll("at ");
            var it = bits(u32, h);
            var i: usize = 0;
            const n = @popCount(h);
            while (it.next()) |hr| : (i += 1) {
                try sep(w, i, n);
                try w.print("{d:0>2}:{d:0>2}", .{ hr, mi });
            }
            return false;
        }
    }
    if (@popCount(m) <= 4 and h == all_hours) {
        try w.writeAll("every hour at ");
        var it = bits(u64, m);
        var i: usize = 0;
        while (it.next()) |mi| : (i += 1) {
            try sep(w, i, @popCount(m));
            try w.print(":{d:0>2}", .{mi});
        }
        return true;
    }
    if (@popCount(m) <= 4 and single(u32, h) != null) {
        const hr = single(u32, h).?;
        try w.writeAll("at ");
        var it = bits(u64, m);
        var i: usize = 0;
        while (it.next()) |mi| : (i += 1) {
            try sep(w, i, @popCount(m));
            try w.print("{d:0>2}:{d:0>2}", .{ hr, mi });
        }
        return false;
    }
    try w.writeAll(if (@popCount(m) == 1) "at minute " else "at minutes ");
    try writeList(u64, m, w, .number);
    if (h == all_hours) {
        try w.writeAll(" of every hour");
        return true;
    }
    try w.writeAll(if (@popCount(h) == 1) " past hour " else " past hours ");
    try writeList(u32, h, w, .number);
    return false;
}

/// " from 09:00 to 17:59" or " during hours ..." (nothing for all hours).
fn writeHourWindow(h: u32, w: *Writer) Writer.Error!void {
    if (h == all_hours) return;
    if (single(u32, h)) |hr| return w.print(" from {d:0>2}:00 to {d:0>2}:59", .{ hr, hr });
    if (run(u32, h)) |r| return w.print(" from {d:0>2}:00 to {d:0>2}:59", .{ r[0], r[1] });
    try w.writeAll(" during hours ");
    try writeList(u32, h, w, .number);
}

fn writeDays(c: *const CronExpr, w: *Writer, starts_every: bool) Writer.Error!void {
    const dom_any = c.dom_star;
    const dow_any = c.dow_star;
    if (dom_any and dow_any) {
        if (!starts_every) try w.writeAll(" every day");
        return writeMonths(c.months, w);
    }
    if (!dom_any) {
        try w.writeAll(if (@popCount(c.dom) == 1) " on day " else " on days ");
        try writeList(u32, c.dom, w, .number);
        if (c.months == all_months) try w.writeAll(" of the month");
        if (!dow_any) {
            try w.writeAll(" or");
            try writeDow(c.dow, w);
        }
    } else try writeDow(c.dow, w);
    try writeMonths(c.months, w);
}

fn writeDow(dow: u8, w: *Writer) Writer.Error!void {
    switch (dow) {
        weekdays => try w.writeAll(" on weekdays"),
        weekends => try w.writeAll(" on weekends"),
        all_dow => try w.writeAll(" on every day of the week"),
        else => {
            try w.writeAll(" on ");
            try writeList(u8, dow, w, .weekday);
        },
    }
}

fn writeMonths(months: u16, w: *Writer) Writer.Error!void {
    if (months == all_months) return;
    try w.writeAll(" in ");
    try writeList(u16, months, w, .month);
}

const Names = enum { number, month, weekday };

fn writeName(w: *Writer, v: usize, names: Names) Writer.Error!void {
    switch (names) {
        .number => try w.print("{d}", .{v}),
        .month => try w.writeAll(month_names[v]),
        .weekday => try w.writeAll(dow_names[v]),
    }
}

/// The set bits as English: runs of three or more as "A to B", items
/// joined with ", " and a final " and ".
fn writeList(comptime T: type, mask: T, w: *Writer, names: Names) Writer.Error!void {
    // Collect runs first so the final " and " lands right.
    var lo: [64]u8 = undefined;
    var hi: [64]u8 = undefined;
    var n: usize = 0;
    var it = bits(T, mask);
    while (it.next()) |v| {
        if (n > 0 and hi[n - 1] + 1 == v) {
            hi[n - 1] = v;
        } else {
            lo[n] = v;
            hi[n] = v;
            n += 1;
        }
    }
    // Split runs of two into separate items.
    var items: usize = 0;
    for (0..n) |i| items += if (hi[i] - lo[i] == 1) 2 else 1;
    var k: usize = 0;
    for (0..n) |i| {
        if (hi[i] - lo[i] == 1) {
            try sep(w, k, items);
            try writeName(w, lo[i], names);
            k += 1;
            try sep(w, k, items);
            try writeName(w, hi[i], names);
            k += 1;
            continue;
        }
        try sep(w, k, items);
        try writeName(w, lo[i], names);
        if (hi[i] != lo[i]) {
            try w.writeAll(" to ");
            try writeName(w, hi[i], names);
        }
        k += 1;
    }
}

fn sep(w: *Writer, i: usize, n: usize) Writer.Error!void {
    if (i == 0) return;
    try w.writeAll(if (i + 1 == n) " and " else ", ");
}

fn single(comptime T: type, mask: T) ?u8 {
    if (@popCount(mask) != 1) return null;
    return @ctz(mask);
}

/// One contiguous run of two or more values.
fn run(comptime T: type, mask: T) ?[2]u8 {
    if (@popCount(mask) < 2) return null;
    const lo: u8 = @ctz(mask);
    const hi: u8 = @bitSizeOf(T) - 1 - @clz(mask);
    if (hi - lo + 1 != @popCount(mask)) return null;
    return .{ lo, hi };
}

/// `*/n` with n > 1: every n-th value from `lo` through `max`.
fn stepOf(comptime T: type, mask: T, lo: u8, max: u8) ?u8 {
    if (@popCount(mask) < 2 or @ctz(mask) != lo) return null;
    const rest = mask >> @intCast(lo + 1);
    const n: u8 = @as(u8, @ctz(rest)) + 1;
    if (n < 2) return null;
    var expect: T = 0;
    var v: u16 = lo;
    while (v <= max) : (v += n) expect |= @as(T, 1) << @intCast(v);
    return if (expect == mask) n else null;
}

fn BitIter(comptime T: type) type {
    return struct {
        mask: T,
        fn next(it: *@This()) ?u8 {
            if (it.mask == 0) return null;
            const v: u8 = @ctz(it.mask);
            it.mask &= it.mask - 1;
            return v;
        }
    };
}

fn bits(comptime T: type, mask: T) BitIter(T) {
    return .{ .mask = mask };
}
