//! UTF-16 and UTF-32 to and from WTF-8. Unpaired surrogates decode to
//! WTF-8 and encode back as the same code units, so any sequence of code
//! units round-trips. ASCII runs of UTF-16 take a 16-units-at-a-time path.

const std = @import("std");
const wtf8 = @import("wtf8.zig");

const Allocator = std.mem.Allocator;

pub const Endian = std.builtin.Endian;

/// Decodes whole code units from `in` (an even length), carrying a high
/// surrogate that ends the chunk in `pending` for the next call.
pub fn decode16(in: []const u8, comptime endian: Endian, pending: *?u16, out: *std.ArrayList(u8), gpa: Allocator) !void {
    std.debug.assert(in.len % 2 == 0);
    try out.ensureUnusedCapacity(gpa, in.len / 2);
    var i: usize = 0;
    while (i < in.len) {
        if (pending.* == null) i += asciiRun(in[i..], endian, out);
        if (i >= in.len) break;
        const u = std.mem.readInt(u16, in[i..][0..2], endian);
        i += 2;
        if (pending.*) |hi| {
            pending.* = null;
            if (isLow(u)) {
                try wtf8.append(out, gpa, 0x10000 + ((@as(u21, hi) - 0xD800) << 10) + (u - 0xDC00));
                continue;
            }
            try wtf8.append(out, gpa, hi);
        }
        if (isHigh(u)) {
            pending.* = u;
            continue;
        }
        try wtf8.append(out, gpa, u);
    }
}

/// Flushes a high surrogate left at the end of the input.
pub fn finish16(pending: *?u16, out: *std.ArrayList(u8), gpa: Allocator) !void {
    if (pending.*) |hi| try wtf8.append(out, gpa, hi);
    pending.* = null;
}

/// Appends the leading ASCII code units of `in` as bytes, 16 at a time,
/// and returns how many input bytes it consumed.
fn asciiRun(in: []const u8, comptime endian: Endian, out: *std.ArrayList(u8)) usize {
    const V = @Vector(32, u8);
    const even = comptime blk: {
        var m: [16]i32 = undefined;
        for (&m, 0..) |*x, k| x.* = @intCast(2 * k);
        break :blk m;
    };
    const odd = comptime blk: {
        var m: [16]i32 = undefined;
        for (&m, 0..) |*x, k| x.* = @intCast(2 * k + 1);
        break :blk m;
    };
    var i: usize = 0;
    while (i + 32 <= in.len and out.unusedCapacitySlice().len >= 16) {
        const v: V = in[i..][0..32].*;
        const lo_idx = if (endian == .little) even else odd;
        const hi_idx = if (endian == .little) odd else even;
        const lo: @Vector(16, u8) = @shuffle(u8, v, undefined, lo_idx);
        const hi: @Vector(16, u8) = @shuffle(u8, v, undefined, hi_idx);
        if (@reduce(.Or, hi) != 0 or @reduce(.Max, lo) >= 0x80) break;
        const arr: [16]u8 = lo;
        out.appendSliceAssumeCapacity(&arr);
        i += 32;
    }
    return i;
}

fn isHigh(u: u16) bool {
    return u >= 0xD800 and u <= 0xDBFF;
}

fn isLow(u: u16) bool {
    return u >= 0xDC00 and u <= 0xDFFF;
}

/// Decodes whole UTF-32 units from `in` (a multiple of 4). Values past
/// U+10FFFF become U+FFFD.
pub fn decode32(in: []const u8, endian: Endian, out: *std.ArrayList(u8), gpa: Allocator) !void {
    std.debug.assert(in.len % 4 == 0);
    try out.ensureUnusedCapacity(gpa, in.len / 4);
    var i: usize = 0;
    while (i < in.len) : (i += 4) {
        const u = std.mem.readInt(u32, in[i..][0..4], endian);
        try wtf8.append(out, gpa, if (u > 0x10FFFF) 0xFFFD else @intCast(u));
    }
}

/// The offset of the first byte of `utf8` that is not valid WTF-8, if
/// any.
pub fn firstInvalid(utf8: []const u8) ?usize {
    var i: usize = 0;
    while (i < utf8.len) {
        const d = wtf8.next(utf8, i) orelse return i;
        i += d.len;
    }
    return null;
}

/// Appends `utf8` (WTF-8) as UTF-16. A surrogate pair written as two
/// WTF-8 sequences is joined back into its units unchanged.
pub fn encode16(utf8: []const u8, endian: Endian, out: *std.ArrayList(u8), gpa: Allocator) error{ Unrepresentable, OutOfMemory }!void {
    try out.ensureUnusedCapacity(gpa, utf8.len * 2);
    var i: usize = 0;
    while (i < utf8.len) {
        const d = wtf8.next(utf8, i) orelse return error.Unrepresentable;
        i += d.len;
        var buf: [2]u8 = undefined;
        if (d.cp >= 0x10000) {
            const v = d.cp - 0x10000;
            std.mem.writeInt(u16, &buf, @intCast(0xD800 + (v >> 10)), endian);
            try out.appendSlice(gpa, &buf);
            std.mem.writeInt(u16, &buf, @intCast(0xDC00 + (v & 0x3FF)), endian);
        } else {
            std.mem.writeInt(u16, &buf, @intCast(d.cp), endian);
        }
        try out.appendSlice(gpa, &buf);
    }
}

/// Appends `utf8` (WTF-8) as UTF-32.
pub fn encode32(utf8: []const u8, endian: Endian, out: *std.ArrayList(u8), gpa: Allocator) error{ Unrepresentable, OutOfMemory }!void {
    try out.ensureUnusedCapacity(gpa, utf8.len * 4);
    var i: usize = 0;
    while (i < utf8.len) {
        const d = wtf8.next(utf8, i) orelse return error.Unrepresentable;
        i += d.len;
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, d.cp, endian);
        try out.appendSlice(gpa, &buf);
    }
}
