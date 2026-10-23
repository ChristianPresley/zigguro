//! TZif reader (E13.F02.S01.T04), RFC 9636 §3: versions 1 to 4. Version
//! 2+ files skip the 32-bit block and read the 64-bit one, then the
//! footer TZ string. Leap-second records are skipped. `parse` only
//! validates and locates the blocks; it allocates nothing. Pure.

const std = @import("std");

pub const Error = error{ InvalidTzif, UnsupportedTzifVersion };

pub const Counts = struct {
    isut: u32,
    isstd: u32,
    leap: u32,
    time: u32,
    type: u32,
    char: u32,
};

pub const TtInfo = struct { utoff: i32, is_dst: bool, desig_idx: u8 };

/// A validated view of one data block.
pub const Parsed = struct {
    /// 0 for version 1, else 2, 3 or 4.
    version: u8,
    counts: Counts,
    /// 4 (version 1) or 8 bytes per transition time.
    time_size: u8,
    times: []const u8,
    indices: []const u8,
    ttinfos: []const u8,
    designations: []const u8,
    /// Without the surrounding newlines; null when absent or empty.
    footer: ?[]const u8,

    pub fn transition(p: *const Parsed, i: usize) i64 {
        return if (p.time_size == 8)
            std.mem.readInt(i64, p.times[i * 8 ..][0..8], .big)
        else
            std.mem.readInt(i32, p.times[i * 4 ..][0..4], .big);
    }

    pub fn ttinfo(p: *const Parsed, i: usize) TtInfo {
        const b = p.ttinfos[i * 6 ..][0..6];
        return .{ .utoff = std.mem.readInt(i32, b[0..4], .big), .is_dst = b[4] != 0, .desig_idx = b[5] };
    }
};

const header_len = 44;

fn readCounts(h: []const u8) Error!Counts {
    if (h.len < header_len) return error.InvalidTzif;
    if (!std.mem.eql(u8, h[0..4], "TZif")) return error.InvalidTzif;
    var c: [6]u32 = undefined;
    for (&c, 0..) |*v, i| v.* = std.mem.readInt(u32, h[20 + i * 4 ..][0..4], .big);
    return .{ .isut = c[0], .isstd = c[1], .leap = c[2], .time = c[3], .type = c[4], .char = c[5] };
}

fn blockLen(c: Counts, time_size: u64) u64 {
    return @as(u64, c.time) * time_size + c.time + @as(u64, c.type) * 6 + c.char +
        @as(u64, c.leap) * (time_size + 4) + c.isstd + c.isut;
}

pub fn parse(bytes: []const u8) Error!Parsed {
    const c1 = try readCounts(bytes);
    const version: u8 = switch (bytes[4]) {
        0 => 0,
        '2', '3', '4' => bytes[4] - '0',
        else => return error.UnsupportedTzifVersion,
    };
    var off: u64 = header_len;
    var c = c1;
    var time_size: u8 = 4;
    if (version >= 2) {
        off += blockLen(c1, 4);
        if (off > bytes.len) return error.InvalidTzif;
        c = try readCounts(bytes[@intCast(off)..]);
        if (bytes[@intCast(off + 4)] != bytes[4]) return error.InvalidTzif;
        off += header_len;
        time_size = 8;
    }
    // RFC 9636 §3.1 limits.
    if (c.type == 0 or c.type > 256 or c.char == 0 or (c.isstd != 0 and c.isstd != c.type) or (c.isut != 0 and c.isut != c.type))
        return error.InvalidTzif;
    const end = off + blockLen(c, time_size);
    if (end > bytes.len) return error.InvalidTzif;
    var p: Parsed = .{
        .version = version,
        .counts = c,
        .time_size = time_size,
        .times = undefined,
        .indices = undefined,
        .ttinfos = undefined,
        .designations = undefined,
        .footer = null,
    };
    var o: usize = @intCast(off);
    p.times = bytes[o..][0 .. c.time * time_size];
    o += p.times.len;
    p.indices = bytes[o..][0..c.time];
    o += c.time;
    p.ttinfos = bytes[o..][0 .. c.type * 6];
    o += p.ttinfos.len;
    p.designations = bytes[o..][0..c.char];
    for (p.indices) |ix| if (ix >= c.type) return error.InvalidTzif;
    var i: usize = 0;
    while (i < c.type) : (i += 1) if (p.ttinfo(i).desig_idx >= c.char) return error.InvalidTzif;
    i = 1;
    while (i < c.time) : (i += 1) if (p.transition(i) <= p.transition(i - 1)) return error.InvalidTzif;
    if (version >= 2) {
        const rest = bytes[@intCast(end)..];
        if (rest.len < 2 or rest[0] != '\n') return error.InvalidTzif;
        const nl = std.mem.indexOfScalarPos(u8, rest, 1, '\n') orelse return error.InvalidTzif;
        if (nl > 1) p.footer = rest[1..nl];
    }
    return p;
}
