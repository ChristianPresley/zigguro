//! TraceLogging metadata blobs for the ETW bridge (E14.F02.S03.T01), pure
//! and testable on every OS. ETW decodes self-describing ("manifest-free")
//! events from these blobs: the provider traits name the provider, and each
//! event's metadata names the event and its fields with their types.
//!
//! Layouts (TraceLoggingProvider.h; Chromium's minimal TraceLogging
//! writer):
//! - traits: `u16 size` (including itself), the UTF-8 provider name, NUL;
//! - event: `u16 size`, `u8 tags` (0), the UTF-8 event name, NUL, then per
//!   field its name, NUL and `u8 InType` (with bit 7 set when an `u8
//!   OutType` follows).

const std = @import("std");

/// `_TlgIn_t` values used here.
pub const InType = enum(u8) {
    /// NUL-terminated 8-bit string (`TlgInANSISTRING`).
    ansi_string = 2,
    int64 = 9,
    uint64 = 10,
};

/// `TlgOutUTF8`: decode an ANSI string as UTF-8.
pub const out_utf8: u8 = 35;
/// Bit 7 of an InType byte: an OutType byte follows.
pub const chain_flag: u8 = 0x80;

/// A field: its name and type. Strings are always UTF-8.
pub const Field = struct {
    name: []const u8,
    type: enum { string, i64, u64 },
};

/// The provider traits blob for `name`.
pub fn traits(comptime name: []const u8) [2 + name.len + 1]u8 {
    var out: [2 + name.len + 1]u8 = undefined;
    std.mem.writeInt(u16, out[0..2], out.len, .little);
    @memcpy(out[2..][0..name.len], name);
    out[out.len - 1] = 0;
    return out;
}

fn eventLen(comptime name: []const u8, comptime fields: []const Field) usize {
    var n: usize = 2 + 1 + name.len + 1;
    for (fields) |f| n += f.name.len + 1 + @as(usize, if (f.type == .string) 2 else 1);
    return n;
}

/// The metadata blob of event `name` with `fields`, built at comptime.
pub fn event(comptime name: []const u8, comptime fields: []const Field) [eventLen(name, fields)]u8 {
    @setEvalBranchQuota(10_000);
    var out: [eventLen(name, fields)]u8 = undefined;
    std.mem.writeInt(u16, out[0..2], out.len, .little);
    out[2] = 0; // tags
    var i: usize = 3;
    @memcpy(out[i..][0..name.len], name);
    i += name.len;
    out[i] = 0;
    i += 1;
    for (fields) |f| {
        @memcpy(out[i..][0..f.name.len], f.name);
        i += f.name.len;
        out[i] = 0;
        i += 1;
        switch (f.type) {
            .string => {
                out[i] = @intFromEnum(InType.ansi_string) | chain_flag;
                out[i + 1] = out_utf8;
                i += 2;
            },
            .i64 => {
                out[i] = @intFromEnum(InType.int64);
                i += 1;
            },
            .u64 => {
                out[i] = @intFromEnum(InType.uint64);
                i += 1;
            },
        }
    }
    return out;
}

/// The bridge's events.
pub const frame = event("Frame", &.{.{ .name = "seq", .type = .u64 }});
pub const zone_begin = event("ZoneBegin", &.{ .{ .name = "name", .type = .string }, .{ .name = "tid", .type = .u64 } });
pub const zone = event("Zone", &.{ .{ .name = "name", .type = .string }, .{ .name = "dur_ns", .type = .u64 } });
pub const instant = event("Instant", &.{ .{ .name = "name", .type = .string }, .{ .name = "value", .type = .i64 } });

test "etw: traits blob golden" {
    const t = traits("Zigguro");
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 'Z', 'i', 'g', 'g', 'u', 'r', 'o', 0 }, &t);
}

test "etw: metadata blob golden bytes" {
    try std.testing.expectEqualSlices(u8, &.{ 14, 0, 0, 'F', 'r', 'a', 'm', 'e', 0, 's', 'e', 'q', 0, 10 }, &frame);
    // "Zone\0", "name\0" 0x82 0x23, "dur_ns\0" 0x0a.
    try std.testing.expectEqualSlices(u8, &.{
        23,  0,   0,   'Z', 'o', 'n',  'e', 0,
        'n', 'a', 'm', 'e', 0,   0x82, 35,  'd',
        'u', 'r', '_', 'n', 's', 0,    10,
    }, zone[0..23]);
    try std.testing.expectEqual(@as(usize, 23), zone.len);
    try std.testing.expectEqual(@as(u16, instant.len), std.mem.readInt(u16, instant[0..2], .little));
    try std.testing.expectEqual(@as(u8, 9), instant[instant.len - 1]);
}
