//! The user feature syntax shared with settings (E15): CSS
//! `font-feature-settings` and HarfBuzz forms, comma or space separated.
//!
//!     liga=0, calt, 'ss01', "cv05" 2, -kern, +zero, aalt[3:5]=2, smcp on
//!
//! A tag is 1-4 printable ASCII characters (padded with spaces), optionally
//! quoted. `-tag` sets 0, `+tag` or a bare tag sets 1, `=N`, ` N`, `on`
//! and `off` give the value, and `[start:end]` limits it to a byte range of
//! the run text (either bound may be omitted).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ot = @import("../ot/root.zig");
const Feature = @import("buffer.zig").Feature;

/// Where parsing failed.
pub const Diagnostic = struct {
    /// Byte offset of the offending character.
    pos: usize = 0,
    msg: []const u8 = "",
};

pub const Error = error{InvalidFeature} || Allocator.Error;

/// Appends the features of `spec` to `out`.
pub fn parseFeatures(spec: []const u8, out: *std.ArrayList(Feature), gpa: Allocator) Error!void {
    var d: Diagnostic = .{};
    return parseFeaturesDiag(spec, out, gpa, &d);
}

/// `parseFeatures` that reports the failing position in `diag`.
pub fn parseFeaturesDiag(spec: []const u8, out: *std.ArrayList(Feature), gpa: Allocator, diag: *Diagnostic) Error!void {
    var p: Parser = .{ .s = spec, .diag = diag };
    while (true) {
        p.skipSeparators();
        if (p.i >= spec.len) return;
        const f = try p.feature();
        try out.append(gpa, f);
    }
}

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    diag: *Diagnostic,

    fn fail(p: *Parser, msg: []const u8) error{InvalidFeature} {
        p.diag.* = .{ .pos = p.i, .msg = msg };
        return error.InvalidFeature;
    }

    fn peek(p: *const Parser) ?u8 {
        return if (p.i < p.s.len) p.s[p.i] else null;
    }

    fn skipSpaces(p: *Parser) void {
        while (p.peek()) |c| {
            if (c != ' ' and c != '\t') break;
            p.i += 1;
        }
    }

    fn skipSeparators(p: *Parser) void {
        while (p.peek()) |c| {
            if (c != ' ' and c != '\t' and c != ',') break;
            p.i += 1;
        }
    }

    fn number(p: *Parser) ?u32 {
        const start = p.i;
        var v: u32 = 0;
        while (p.peek()) |c| {
            if (c < '0' or c > '9') break;
            v = v *| 10 +| (c - '0');
            p.i += 1;
        }
        return if (p.i == start) null else v;
    }

    fn word(p: *Parser, w: []const u8) bool {
        if (!std.ascii.startsWithIgnoreCase(p.s[p.i..], w)) return false;
        const end = p.i + w.len;
        if (end < p.s.len and std.ascii.isAlphanumeric(p.s[end])) return false;
        p.i = end;
        return true;
    }

    fn feature(p: *Parser) Error!Feature {
        var f: Feature = .{ .tag = 0 };
        var explicit: ?u32 = null;
        switch (p.peek().?) {
            '-' => {
                explicit = 0;
                p.i += 1;
            },
            '+' => {
                explicit = 1;
                p.i += 1;
            },
            else => {},
        }
        f.tag = try p.tagName();
        if (p.peek() == '[') {
            p.i += 1;
            p.skipSpaces();
            if (p.number()) |n| f.start = n;
            p.skipSpaces();
            if (p.peek() == ':' or p.peek() == ';') {
                p.i += 1;
                p.skipSpaces();
                if (p.number()) |n| f.end = n;
            } else {
                // `[n]` is the single position n.
                f.end = f.start +| 1;
            }
            p.skipSpaces();
            if (p.peek() != ']') return p.fail("expected ']'");
            p.i += 1;
            if (f.start >= f.end and f.end != std.math.maxInt(u32)) return p.fail("empty feature range");
        }
        const before_value = p.i;
        p.skipSpaces();
        if (p.peek() == '=') {
            p.i += 1;
            p.skipSpaces();
            explicit = try p.value() orelse return p.fail("expected a value after '='");
        } else if (try p.value()) |v| {
            explicit = v;
        } else p.i = before_value;
        f.value = @intCast(@min(explicit orelse 1, std.math.maxInt(u16)));
        if (p.peek()) |c| if (c != ',' and c != ' ' and c != '\t') return p.fail("expected ',' or a space");
        return f;
    }

    fn value(p: *Parser) error{InvalidFeature}!?u32 {
        if (p.number()) |n| return n;
        if (p.word("on") or p.word("true")) return 1;
        if (p.word("off") or p.word("false")) return 0;
        return null;
    }

    fn tagName(p: *Parser) error{InvalidFeature}!ot.Tag {
        var quote: ?u8 = null;
        if (p.peek()) |c| if (c == '\'' or c == '"') {
            quote = c;
            p.i += 1;
        };
        var b: [4]u8 = .{ ' ', ' ', ' ', ' ' };
        var n: usize = 0;
        while (p.peek()) |c| {
            if (quote) |q| {
                if (c == q) break;
                if (c < 0x20 or c > 0x7E) return p.fail("tag characters must be printable ASCII");
            } else if (!std.ascii.isAlphanumeric(c) and c != '_') break;
            if (n == 4) return p.fail("tags are at most 4 characters");
            b[n] = c;
            n += 1;
            p.i += 1;
        }
        if (n == 0) return p.fail("expected a feature tag");
        if (quote) |q| {
            if (p.peek() != q) return p.fail("unterminated quote");
            p.i += 1;
        }
        return std.mem.readInt(u32, &b, .big);
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;
const tag = ot.tag;

fn expectParse(spec: []const u8, want: []const Feature) !void {
    var out: std.ArrayList(Feature) = .empty;
    defer out.deinit(testing.allocator);
    try parseFeatures(spec, &out, testing.allocator);
    try testing.expectEqualSlices(Feature, want, out.items);
}

fn expectFail(spec: []const u8, pos: usize) !void {
    var out: std.ArrayList(Feature) = .empty;
    defer out.deinit(testing.allocator);
    var d: Diagnostic = .{};
    try testing.expectError(error.InvalidFeature, parseFeaturesDiag(spec, &out, testing.allocator, &d));
    try testing.expectEqual(pos, d.pos);
}

test "features: parser cases" {
    try expectParse("", &.{});
    try expectParse("liga=0, calt", &.{ .{ .tag = tag("liga"), .value = 0 }, .{ .tag = tag("calt") } });
    try expectParse("'ss01', 'cv05', 'zero'", &.{ .{ .tag = tag("ss01") }, .{ .tag = tag("cv05") }, .{ .tag = tag("zero") } });
    try expectParse("-kern +zero cv05=2", &.{ .{ .tag = tag("kern"), .value = 0 }, .{ .tag = tag("zero") }, .{ .tag = tag("cv05"), .value = 2 } });
    try expectParse("\"liga\" off, \"smcp\" on, \"salt\" 3", &.{ .{ .tag = tag("liga"), .value = 0 }, .{ .tag = tag("smcp") }, .{ .tag = tag("salt"), .value = 3 } });
    try expectParse("aalt[3:5]=2", &.{.{ .tag = tag("aalt"), .value = 2, .start = 3, .end = 5 }});
    try expectParse("kern[:4], liga[2:]", &.{ .{ .tag = tag("kern"), .start = 0, .end = 4 }, .{ .tag = tag("liga"), .start = 2 } });
    try expectParse("kern[7]", &.{.{ .tag = tag("kern"), .start = 7, .end = 8 }});
    try expectParse("cv1", &.{.{ .tag = std.mem.readInt(u32, "cv1 ", .big) }});
    try expectFail("liga=", 5);
    try expectFail("ligature", 4);
    try expectFail("'liga", 5);
    try expectFail("kern[3:2]", 9);
    try expectFail("liga;", 4);
    try expectFail("=1", 0);
}
