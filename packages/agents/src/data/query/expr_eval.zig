//! Expression evaluation for query execution (E13.F06.S02.T03), one row
//! at a time over typed values.
//!
//! Nulls follow SQL: operators and functions of a null give null (except
//! `is null`, `coalesce`, and `and`/`or`, which are three-valued); `where`
//! keeps a row only when its condition is true. Division or modulo by
//! zero, integer overflow and the square root or log of a negative number
//! give null rather than failing the query.

const std = @import("std");
const zg_regex = @import("zg_regex");
const plan = @import("plan.zig");
const types = @import("types.zig");
const infer = @import("../infer.zig");

const Allocator = std.mem.Allocator;
const TypedExpr = plan.TypedExpr;

pub const Value = plan.Lit;

pub const ms_per_day: i64 = 86_400_000;

/// Per-thread evaluation state: an arena for strings made by functions
/// and compiled regexes.
pub const Eval = struct {
    gpa: Allocator,
    /// Strings built by expressions; reset by the caller between rows or
    /// morsels.
    arena: Allocator,
    regexes: std.StringHashMapUnmanaged(*Compiled) = .empty,

    const Compiled = struct { re: ?zg_regex.Regex, cache: ?zg_regex.Cache };

    pub fn init(gpa: Allocator, arena: Allocator) Eval {
        return .{ .gpa = gpa, .arena = arena };
    }

    pub fn deinit(ev: *Eval) void {
        var it = ev.regexes.iterator();
        while (it.next()) |e| {
            const c = e.value_ptr.*;
            if (c.cache) |*k| k.deinit();
            if (c.re) |*r| r.deinit(ev.gpa);
            ev.gpa.free(e.key_ptr.*);
            ev.gpa.destroy(c);
        }
        ev.regexes.deinit(ev.gpa);
    }

    /// A compiled pattern (null when it doesn't compile: the match is
    /// then null).
    fn regex(ev: *Eval, pattern: []const u8) !*Compiled {
        if (ev.regexes.get(pattern)) |c| return c;
        const c = try ev.gpa.create(Compiled);
        errdefer ev.gpa.destroy(c);
        c.* = .{ .re = zg_regex.Regex.compile(ev.gpa, pattern, .{}) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        }, .cache = null };
        if (c.re) |*r| c.cache = try r.newCache(ev.gpa);
        const key = try ev.gpa.dupe(u8, pattern);
        errdefer ev.gpa.free(key);
        try ev.regexes.put(ev.gpa, key, c);
        return c;
    }

    pub fn eval(ev: *Eval, e: *const TypedExpr, row: []const Value) Allocator.Error!Value {
        return switch (e.node) {
            .lit => |l| l,
            .col => |c| row[c],
            .unary => |u| unary(u.op, try ev.eval(u.e, row)),
            .binary => |b| try ev.binary(b.op, try ev.eval(b.l, row), try ev.eval(b.r, row)),
            .in_list => |x| blk: {
                const v = try ev.eval(x.e, row);
                if (v == .null_) break :blk .null_;
                var saw_null = false;
                for (x.list) |item| {
                    const w = try ev.eval(item, row);
                    if (w == .null_) {
                        saw_null = true;
                        continue;
                    }
                    if (order(v, w) == .eq) break :blk .{ .bool_ = !x.negated };
                }
                break :blk if (saw_null) .null_ else .{ .bool_ = x.negated };
            },
            .between => |x| blk: {
                const v = try ev.eval(x.e, row);
                const lo = try ev.eval(x.lo, row);
                const hi = try ev.eval(x.hi, row);
                const a = order(lo, v) orelse break :blk .null_;
                const b = order(v, hi) orelse break :blk .null_;
                const in = a != .gt and b != .gt;
                break :blk .{ .bool_ = in != x.negated };
            },
            .is_null => |x| .{ .bool_ = ((try ev.eval(x.e, row)) == .null_) != x.negated },
            .case => |c| blk: {
                for (c.whens) |w| if (truthy(try ev.eval(w.cond, row))) break :blk coerce(try ev.eval(w.then, row), e.ty);
                break :blk if (c.else_) |x| coerce(try ev.eval(x, row), e.ty) else .null_;
            },
            .call => |c| try ev.call(c.func, c.args, c.unit, e.ty, row),
        };
    }

    fn binary(ev: *Eval, op: @import("ast.zig").BinOp, l: Value, r: Value) !Value {
        switch (op) {
            .@"and" => {
                if (isFalse(l) or isFalse(r)) return .{ .bool_ = false };
                if (l == .null_ or r == .null_) return .null_;
                return .{ .bool_ = true };
            },
            .@"or" => {
                if (truthy(l) or truthy(r)) return .{ .bool_ = true };
                if (l == .null_ or r == .null_) return .null_;
                return .{ .bool_ = false };
            },
            .eq, .ne, .lt, .le, .gt, .ge => {
                const o = order(l, r) orelse return .null_;
                return .{ .bool_ = switch (op) {
                    .eq => o == .eq,
                    .ne => o != .eq,
                    .lt => o == .lt,
                    .le => o != .gt,
                    .gt => o == .gt,
                    .ge => o != .lt,
                    else => unreachable,
                } };
            },
            else => {},
        }
        if (l == .null_ or r == .null_) return .null_;
        // Temporal arithmetic (int operands are days).
        if (op == .add or op == .sub) {
            switch (l) {
                .date => |d| switch (r) {
                    .int => |n| return dateAdd(d, if (op == .add) n else -%n),
                    .date => |e| if (op == .sub) return .{ .int = @as(i64, d) - e },
                    .datetime => |t| if (op == .sub) return .{ .int = @divFloor(@as(i64, d) * ms_per_day - t, ms_per_day) },
                    else => {},
                },
                .datetime => |t| switch (r) {
                    .int => |n| {
                        const delta = std.math.mul(i64, n, ms_per_day) catch return .null_;
                        return .{ .datetime = (if (op == .add) std.math.add(i64, t, delta) else std.math.sub(i64, t, delta)) catch return .null_ };
                    },
                    .datetime => |u| if (op == .sub) return .{ .int = @divFloor(t - u, ms_per_day) },
                    .date => |d| if (op == .sub) return .{ .int = @divFloor(t - @as(i64, d) * ms_per_day, ms_per_day) },
                    else => {},
                },
                .int => |n| if (op == .add) switch (r) {
                    .date => |d| return dateAdd(d, n),
                    .datetime => |t| return .{ .datetime = std.math.add(i64, t, std.math.mul(i64, n, ms_per_day) catch return .null_) catch return .null_ },
                    else => {},
                },
                .string => |a| if (op == .add and r == .string) return .{ .string = try std.mem.concat(ev.arena, u8, &.{ a, r.string }) },
                else => {},
            }
        }
        if (l == .int and r == .int and op != .div) {
            const x = l.int;
            const y = r.int;
            return .{ .int = switch (op) {
                .add => std.math.add(i64, x, y) catch return .null_,
                .sub => std.math.sub(i64, x, y) catch return .null_,
                .mul => std.math.mul(i64, x, y) catch return .null_,
                .mod => if (y == 0 or (x == std.math.minInt(i64) and y == -1)) return .null_ else @rem(x, y),
                else => unreachable,
            } };
        }
        const x = num(l) orelse return .null_;
        const y = num(r) orelse return .null_;
        const v: f64 = switch (op) {
            .add => x + y,
            .sub => x - y,
            .mul => x * y,
            .div => if (y == 0) return .null_ else x / y,
            .mod => if (y == 0) return .null_ else @rem(x, y),
            else => unreachable,
        };
        return if (std.math.isFinite(v)) .{ .float = v } else .null_;
    }

    fn call(ev: *Eval, f: types.Func, args: []const *const TypedExpr, unit: ?types.Unit, ty: types.Type, row: []const Value) !Value {
        if (f == .coalesce) {
            for (args) |a| {
                const v = try ev.eval(a, row);
                if (v != .null_) return coerce(v, ty);
            }
            return .null_;
        }
        var vs: [3]Value = undefined;
        for (args, 0..) |a, i| {
            vs[i] = try ev.eval(a, row);
            if (vs[i] == .null_) return .null_;
        }
        const a = vs[0];
        switch (f) {
            .lower, .upper => {
                const s = a.string;
                const out = try ev.arena.alloc(u8, s.len);
                for (s, out) |c, *o| o.* = if (f == .lower) std.ascii.toLower(c) else std.ascii.toUpper(c);
                return .{ .string = out };
            },
            .contains => return .{ .bool_ = std.mem.indexOf(u8, a.string, vs[1].string) != null },
            .starts_with => return .{ .bool_ = std.mem.startsWith(u8, a.string, vs[1].string) },
            .ends_with => return .{ .bool_ = std.mem.endsWith(u8, a.string, vs[1].string) },
            .length => return .{ .int = @intCast(codepoints(a.string)) },
            .substr => {
                // 1-based start (negative counts from the end), in characters.
                const s = a.string;
                const n: i64 = @intCast(codepoints(s));
                var start = vs[1].int;
                if (start < 0) start = n + start + 1;
                if (start < 1) start = 1;
                const len: i64 = if (args.len == 3) vs[2].int else n;
                if (len <= 0 or start > n) return .{ .string = "" };
                const from = byteOf(s, @intCast(start - 1));
                const to = byteOf(s, @intCast(@min(n, start - 1 + len)));
                return .{ .string = s[from..to] };
            },
            .regex_match => {
                const c = try ev.regex(vs[1].string);
                const re = &(c.re orelse return .null_);
                return .{ .bool_ = re.isMatch(&c.cache.?, .fromSlice(a.string)) };
            },
            .year, .month, .day => {
                const d = daysOf(a) orelse return .null_;
                const c = infer.civilFromDays(d);
                return .{ .int = switch (f) {
                    .year => c.y,
                    .month => c.m,
                    else => c.d,
                } };
            },
            .trunc => return trunc(a, unit.?),
            .date_diff => return dateDiff(a, vs[1], unit orelse .day),
            .abs => return switch (a) {
                .int => |i| if (i == std.math.minInt(i64)) .null_ else .{ .int = @intCast(@abs(i)) },
                .float => |x| .{ .float = @abs(x) },
                else => .null_,
            },
            .floor, .ceil => return switch (a) {
                .int => a,
                .float => |x| .{ .float = if (f == .floor) @floor(x) else @ceil(x) },
                else => .null_,
            },
            .round => {
                if (args.len == 2) {
                    const x = num(a) orelse return .null_;
                    const digits = std.math.clamp(vs[1].int, -15, 15);
                    const p = std.math.pow(f64, 10, @floatFromInt(digits));
                    return .{ .float = @round(x * p) / p };
                }
                return switch (a) {
                    .int => a,
                    .float => |x| .{ .float = @round(x) },
                    else => .null_,
                };
            },
            .log => {
                const x = num(a) orelse return .null_;
                return if (x > 0) .{ .float = @log(x) } else .null_;
            },
            .sqrt => {
                const x = num(a) orelse return .null_;
                return if (x >= 0) .{ .float = @sqrt(x) } else .null_;
            },
            .coalesce => unreachable,
        }
    }
};

pub fn truthy(v: Value) bool {
    return v == .bool_ and v.bool_;
}

fn isFalse(v: Value) bool {
    return v == .bool_ and !v.bool_;
}

fn unary(op: @import("ast.zig").UnOp, v: Value) Value {
    return switch (op) {
        .not => if (v == .bool_) .{ .bool_ = !v.bool_ } else .null_,
        .neg => switch (v) {
            .int => |i| if (i == std.math.minInt(i64)) .null_ else .{ .int = -i },
            .float => |x| .{ .float = -x },
            else => .null_,
        },
    };
}

fn dateAdd(d: i32, n: i64) Value {
    const v = @as(i64, d) + n;
    if (v < std.math.minInt(i32) or v > std.math.maxInt(i32)) return .null_;
    return .{ .date = @intCast(v) };
}

pub fn num(v: Value) ?f64 {
    return switch (v) {
        .int => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn daysOf(v: Value) ?i64 {
    return switch (v) {
        .date => |d| d,
        .datetime => |t| @divFloor(t, ms_per_day),
        else => null,
    };
}

fn msOf(v: Value) ?i64 {
    return switch (v) {
        .date => |d| @as(i64, d) * ms_per_day,
        .datetime => |t| t,
        else => null,
    };
}

/// Orders two non-null values of comparable types (null otherwise):
/// numbers numerically, dates and datetimes on one timeline, strings by
/// bytes, false before true.
pub fn order(l: Value, r: Value) ?std.math.Order {
    if (l == .null_ or r == .null_) return null;
    if (l == .int and r == .int) return std.math.order(l.int, r.int);
    if (num(l)) |x| if (num(r)) |y| return std.math.order(x, y);
    if (l == .date and r == .date) return std.math.order(l.date, r.date);
    if (msOf(l)) |x| if (msOf(r)) |y| return std.math.order(x, y);
    return switch (l) {
        .string => |a| if (r == .string) std.mem.order(u8, a, r.string) else null,
        .bool_ => |a| if (r == .bool_) std.math.order(@intFromBool(a), @intFromBool(r.bool_)) else null,
        else => null,
    };
}

/// `v` in the static type `ty` where they differ only in width: int to
/// float, date to datetime.
pub fn coerce(v: Value, ty: types.Type) Value {
    return switch (ty) {
        .float => if (v == .int) .{ .float = @floatFromInt(v.int) } else v,
        .datetime => if (v == .date) .{ .datetime = @as(i64, v.date) * ms_per_day } else v,
        else => v,
    };
}

fn codepoints(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| n += @intFromBool(c & 0xC0 != 0x80);
    return n;
}

/// The byte offset of character `k` (or the end).
fn byteOf(s: []const u8, k: usize) usize {
    var n: usize = 0;
    for (s, 0..) |c, i| {
        if (c & 0xC0 != 0x80) {
            if (n == k) return i;
            n += 1;
        }
    }
    return s.len;
}

fn trunc(v: Value, unit: types.Unit) Value {
    const ms = msOf(v) orelse return .null_;
    const days = @divFloor(ms, ms_per_day);
    const c = infer.civilFromDays(days);
    const day_out: ?i64 = switch (unit) {
        .year => infer.daysFromCivil(c.y, 1, 1),
        .quarter => infer.daysFromCivil(c.y, (c.m - 1) / 3 * 3 + 1, 1),
        .month => infer.daysFromCivil(c.y, c.m, 1),
        // ISO weeks start on Monday; 1970-01-01 was a Thursday.
        .week => days - @mod(days + 3, 7),
        .day => days,
        else => null,
    };
    if (day_out) |d| return if (v == .date) .{ .date = @intCast(d) } else .{ .datetime = d * ms_per_day };
    if (v == .date) return v;
    const step: i64 = switch (unit) {
        .hour => 3_600_000,
        .minute => 60_000,
        else => 1000,
    };
    return .{ .datetime = ms - @mod(ms, step) };
}

/// Whole `unit`s from `a` to `b` (negative when `b` is earlier).
fn dateDiff(a: Value, b: Value, unit: types.Unit) Value {
    const x = msOf(a) orelse return .null_;
    const y = msOf(b) orelse return .null_;
    switch (unit) {
        .day, .week => {
            const d = @divTrunc(y - x, ms_per_day);
            return .{ .int = if (unit == .week) @divTrunc(d, 7) else d };
        },
        .hour => return .{ .int = @divTrunc(y - x, 3_600_000) },
        .minute => return .{ .int = @divTrunc(y - x, 60_000) },
        .second => return .{ .int = @divTrunc(y - x, 1000) },
        .month, .quarter, .year => {
            const ca = infer.civilFromDays(@divFloor(x, ms_per_day));
            const cb = infer.civilFromDays(@divFloor(y, ms_per_day));
            var months = (cb.y - ca.y) * 12 + @as(i64, cb.m) - ca.m;
            // A month is whole once the day (and time) is reached.
            const ra = @mod(x, ms_per_day) + @as(i64, ca.d) * ms_per_day;
            const rb = @mod(y, ms_per_day) + @as(i64, cb.d) * ms_per_day;
            if (months > 0 and rb < ra) months -= 1;
            if (months < 0 and rb > ra) months += 1;
            return .{ .int = switch (unit) {
                .month => months,
                .quarter => @divTrunc(months, 3),
                else => @divTrunc(months, 12),
            } };
        },
    }
}

/// A source cell as a value of its column's inferred type (null when it's
/// a null token, or doesn't parse as that type).
pub fn parseCell(text: []const u8, is_null: bool, ty: infer.ColType, ctx: infer.InferCtx) Value {
    if (is_null) return .null_;
    const v = infer.parse(text, ty, ctx) orelse return .null_;
    return switch (v) {
        .bool_ => |b| .{ .bool_ = b },
        .int => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .date => |d| .{ .date = d },
        .datetime => |t| .{ .datetime = t },
        .string => |s| .{ .string = s },
    };
}

/// 64-bit hash of a value: equal values (by `order`) hash equally, so an
/// int and the float of the same number collide on purpose.
pub fn hashValue(v: Value, seed: u64) u64 {
    var h: std.hash.Wyhash = .init(seed);
    switch (v) {
        .null_ => h.update("\x00"),
        .bool_ => |b| h.update(if (b) "\x01t" else "\x01f"),
        .int => |i| {
            h.update("\x02");
            h.update(std.mem.asBytes(&@as(f64, @floatFromInt(i))));
        },
        .float => |f| {
            h.update("\x02");
            const z: f64 = if (f == 0) 0 else f;
            h.update(std.mem.asBytes(&z));
        },
        .date => |d| {
            h.update("\x03");
            h.update(std.mem.asBytes(&(@as(i64, d) * ms_per_day)));
        },
        .datetime => |t| {
            h.update("\x03");
            h.update(std.mem.asBytes(&t));
        },
        .string => |s| {
            h.update("\x04");
            h.update(s);
        },
    }
    return h.final();
}

/// Whether two values are the same group or join key (nulls equal each
/// other here, as in SQL GROUP BY).
pub fn sameKey(a: Value, b: Value) bool {
    if (a == .null_ or b == .null_) return a == .null_ and b == .null_;
    return order(a, b) == .eq;
}
