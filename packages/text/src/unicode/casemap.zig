//! Default case conversion (Unicode Standard ch. 3): full upper, lower
//! (with Final_Sigma) and title case, plus the case-shape classifier used
//! by preserve-case replace. Language-specific mappings (Turkish, Azeri,
//! Lithuanian) are not applied.

const std = @import("std");
const Allocator = std.mem.Allocator;
const p = @import("props.zig");
const decode = @import("decode.zig");
const word = @import("word.zig");
const appendCp = @import("casefold.zig").appendCp;

inline fn cpAt(bytes: []const u8, i: usize) struct { cp: u21, len: usize } {
    const u = decode.at(bytes, i);
    return .{ .cp = if (u.valid) u.cp else 0xFFFD, .len = u.len };
}

fn appendMapped(out: *std.ArrayList(u8), gpa: Allocator, cp: u21, k: p.CaseKind) !void {
    if (cp < 0x80) {
        const c: u8 = @intCast(cp);
        try out.append(gpa, switch (k) {
            .lower => if (c >= 'A' and c <= 'Z') c | 0x20 else c,
            .upper, .title => if (c >= 'a' and c <= 'z') c & ~@as(u8, 0x20) else c,
        });
        return;
    }
    const m = p.caseMapFull(cp, k);
    for (m.slice()) |x| try appendCp(out, gpa, x);
}

/// Appends the full uppercase mapping of `bytes`.
pub fn toUpper(out: *std.ArrayList(u8), gpa: Allocator, bytes: []const u8) !void {
    try out.ensureUnusedCapacity(gpa, bytes.len);
    var i: usize = 0;
    while (i < bytes.len) {
        const c = cpAt(bytes, i);
        try appendMapped(out, gpa, c.cp, .upper);
        i += c.len;
    }
}

/// Appends the full lowercase mapping of `bytes`, with Final_Sigma.
pub fn toLower(out: *std.ArrayList(u8), gpa: Allocator, bytes: []const u8) !void {
    try lowerRange(out, gpa, bytes, 0, bytes.len);
}

fn lowerRange(out: *std.ArrayList(u8), gpa: Allocator, bytes: []const u8, from: usize, to: usize) !void {
    try out.ensureUnusedCapacity(gpa, to - from);
    var i = from;
    while (i < to) {
        const c = cpAt(bytes, i);
        if (c.cp == 0x03A3) {
            try appendCp(out, gpa, if (finalSigma(bytes, i, i + c.len)) 0x03C2 else 0x03C3);
        } else {
            try appendMapped(out, gpa, c.cp, .lower);
        }
        i += c.len;
    }
}

/// Final_Sigma: a cased letter precedes (skipping Case_Ignorable) and none
/// follows (skipping Case_Ignorable).
fn finalSigma(bytes: []const u8, start: usize, end: usize) bool {
    var before = false;
    var j = start;
    while (j > 0) {
        j = decode.prevStart(bytes, j);
        const cp = cpAt(bytes, j).cp;
        if (p.isCaseIgnorable(cp)) continue;
        before = p.isCased(cp);
        break;
    }
    if (!before) return false;
    var k = end;
    while (k < bytes.len) {
        const c = cpAt(bytes, k);
        k += c.len;
        if (p.isCaseIgnorable(c.cp)) continue;
        return !p.isCased(c.cp);
    }
    return true;
}

/// Appends `bytes` in title case: in each UAX #29 word the first cased
/// letter is titlecased and the rest lowercased.
pub fn toTitle(out: *std.ArrayList(u8), gpa: Allocator, bytes: []const u8) !void {
    var it = word.WordIterator.init(bytes);
    while (it.next()) |w| try titleRange(out, gpa, bytes, w.start, w.start + w.len);
}

fn titleRange(out: *std.ArrayList(u8), gpa: Allocator, bytes: []const u8, from: usize, to: usize) !void {
    var i = from;
    while (i < to) {
        const c = cpAt(bytes, i);
        if (p.isCased(c.cp)) {
            try appendMapped(out, gpa, c.cp, .title);
            return lowerRange(out, gpa, bytes, i + c.len, to);
        }
        try appendCp(out, gpa, c.cp);
        i += c.len;
    }
}

/// The case pattern of a string.
pub const CaseShape = enum { lower, upper, title, mixed, uncased };

const Letter = enum { upper, lower, none };

fn letterCase(cp: u21) Letter {
    if (!p.isCased(cp)) return .none;
    return switch (p.props(cp).gc) {
        .Lu, .Lt => .upper,
        else => .lower,
    };
}

/// `uncased` without cased letters; `upper`/`lower` when every cased
/// letter is; `title` when the first is upper/title case and the rest
/// lower; `mixed` otherwise.
pub fn caseShape(bytes: []const u8) CaseShape {
    var first: Letter = .none;
    var rest_upper = false;
    var rest_lower = false;
    var i: usize = 0;
    while (i < bytes.len) {
        const c = cpAt(bytes, i);
        i += c.len;
        const l = letterCase(c.cp);
        if (l == .none) continue;
        if (first == .none) {
            first = l;
            continue;
        }
        if (l == .upper) rest_upper = true else rest_lower = true;
    }
    return switch (first) {
        .none => .uncased,
        .lower => if (rest_upper) .mixed else .lower,
        .upper => if (!rest_lower) .upper else if (!rest_upper) .title else .mixed,
    };
}

/// Appends `bytes` converted to `shape` (`title` titlecases the first
/// cased letter and lowercases the rest; `mixed` and `uncased` copy).
pub fn applyShape(out: *std.ArrayList(u8), gpa: Allocator, bytes: []const u8, shape: CaseShape) !void {
    switch (shape) {
        .lower => try toLower(out, gpa, bytes),
        .upper => try toUpper(out, gpa, bytes),
        .title => try titleRange(out, gpa, bytes, 0, bytes.len),
        .mixed, .uncased => try out.appendSlice(gpa, bytes),
    }
}
