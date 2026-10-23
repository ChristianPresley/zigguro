//! Static types of the data query language (E13.F06.S02.T01): value
//! types, schemas, and the signatures of functions and aggregates.

const std = @import("std");
const infer = @import("../infer.zig");

pub const Type = enum {
    null_,
    bool_,
    int,
    float,
    string,
    date,
    datetime,

    pub fn fromCol(t: infer.ColType) Type {
        return switch (t) {
            .null_ => .null_,
            .bool_ => .bool_,
            .int => .int,
            .float, .decimal => .float,
            .date => .date,
            .datetime => .datetime,
            .string => .string,
        };
    }

    pub fn name(t: Type) []const u8 {
        return switch (t) {
            .null_ => "null",
            .bool_ => "bool",
            .int => "int",
            .float => "float",
            .string => "string",
            .date => "date",
            .datetime => "datetime",
        };
    }

    pub fn numeric(t: Type) bool {
        return t == .int or t == .float;
    }

    pub fn temporal(t: Type) bool {
        return t == .date or t == .datetime;
    }

    /// Whether values of `a` and `b` can be compared.
    pub fn comparable(a: Type, b: Type) bool {
        if (a == .null_ or b == .null_ or a == b) return true;
        if (a.numeric() and b.numeric()) return true;
        return a.temporal() and b.temporal();
    }

    /// The common type of two branches (case, coalesce), if any.
    pub fn unify(a: Type, b: Type) ?Type {
        if (a == b) return a;
        if (a == .null_) return b;
        if (b == .null_) return a;
        if (a.numeric() and b.numeric()) return .float;
        if (a.temporal() and b.temporal()) return .datetime;
        return null;
    }
};

pub const SchemaCol = struct { name: []const u8, ty: Type };

pub const Schema = struct {
    columns: []const SchemaCol,

    pub fn find(s: Schema, n: []const u8) ?u32 {
        for (s.columns, 0..) |c, i| if (std.mem.eql(u8, c.name, n)) return @intCast(i);
        return null;
    }

    /// The closest column name (edit distance ≤ 2, ignoring case), for
    /// "did you mean" hints.
    pub fn closest(s: Schema, n: []const u8) ?[]const u8 {
        var best: ?[]const u8 = null;
        var best_d: usize = 3;
        for (s.columns) |c| {
            const d = distance(c.name, n);
            if (d < best_d) {
                best = c.name;
                best_d = d;
            }
        }
        return best;
    }
};

/// Case-insensitive Levenshtein distance, capped at 3 (names up to 64).
fn distance(a: []const u8, b: []const u8) usize {
    if (a.len > 64 or b.len > 64) return 3;
    if (@max(a.len, b.len) - @min(a.len, b.len) >= 3) return 3;
    var prev: [65]usize = undefined;
    var cur: [65]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = @intFromBool(std.ascii.toLower(ca) != std.ascii.toLower(cb));
            cur[j + 1] = @min(@min(prev[j + 1] + 1, cur[j] + 1), prev[j] + cost);
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return @min(prev[b.len], 3);
}

pub const Func = enum {
    lower,
    upper,
    contains,
    starts_with,
    ends_with,
    length,
    substr,
    regex_match,
    year,
    month,
    day,
    trunc,
    date_diff,
    abs,
    round,
    floor,
    ceil,
    log,
    sqrt,
    coalesce,
};

pub const Agg = enum {
    count,
    count_distinct,
    sum,
    avg,
    min,
    max,
    median,
    p,
    stddev,
};

/// Units of `trunc` and `date_diff`.
pub const Unit = enum { year, quarter, month, week, day, hour, minute, second };

pub fn funcOf(n: []const u8) ?Func {
    return std.meta.stringToEnum(Func, n);
}

pub fn aggOf(n: []const u8) ?Agg {
    return std.meta.stringToEnum(Agg, n);
}
