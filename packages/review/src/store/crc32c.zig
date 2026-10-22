//! CRC-32C (Castagnoli), the journal's frame check, as
//! `std.hash.crc.Crc32Iscsi` computes it but fast enough for a cold load
//! (E12.F01.S02 budget): the std one takes a byte per table lookup,
//! about 40 ms of a 17 MB journal. This one uses the SSE 4.2 `crc32`
//! instruction when the target has it and slicing-by-8 tables otherwise.

const std = @import("std");
const builtin = @import("builtin");

const poly: u32 = 0x82f63b78;

const tables: [8][256]u32 = blk: {
    @setEvalBranchQuota(20_000);
    var t: [8][256]u32 = undefined;
    for (&t[0], 0..) |*e, i| {
        var c: u32 = i;
        for (0..8) |_| c = (c >> 1) ^ ((c & 1) * poly);
        e.* = c;
    }
    for (1..8) |k| {
        for (&t[k], 0..) |*e, i| e.* = (t[k - 1][i] >> 8) ^ t[0][t[k - 1][i] & 0xff];
    }
    break :blk t;
};

/// LLVM only: the self-hosted x86 backend cannot encode it yet.
const hardware = builtin.cpu.arch == .x86_64 and builtin.zig_backend == .stage2_llvm and
    std.Target.x86.featureSetHas(builtin.cpu.features, .crc32);

/// An incremental CRC-32C.
pub const Crc32c = struct {
    state: u32 = 0xffff_ffff,

    pub fn update(c: *Crc32c, bytes: []const u8) void {
        c.state = if (hardware) updateHw(c.state, bytes) else updateTables(c.state, bytes);
    }

    pub fn final(c: Crc32c) u32 {
        return ~c.state;
    }

    pub fn hash(bytes: []const u8) u32 {
        var c: Crc32c = .{};
        c.update(bytes);
        return c.final();
    }
};

fn updateTables(state: u32, bytes: []const u8) u32 {
    var c = state;
    var i: usize = 0;
    while (i + 8 <= bytes.len) : (i += 8) {
        const v = std.mem.readInt(u64, bytes[i..][0..8], .little) ^ c;
        c = tables[7][@as(u8, @truncate(v))] ^
            tables[6][@as(u8, @truncate(v >> 8))] ^
            tables[5][@as(u8, @truncate(v >> 16))] ^
            tables[4][@as(u8, @truncate(v >> 24))] ^
            tables[3][@as(u8, @truncate(v >> 32))] ^
            tables[2][@as(u8, @truncate(v >> 40))] ^
            tables[1][@as(u8, @truncate(v >> 48))] ^
            tables[0][@as(u8, @truncate(v >> 56))];
    }
    for (bytes[i..]) |b| c = tables[0][@as(u8, @truncate(c)) ^ b] ^ (c >> 8);
    return c;
}

fn updateHw(state: u32, bytes: []const u8) u32 {
    var c: u64 = state;
    var i: usize = 0;
    while (i + 8 <= bytes.len) : (i += 8) {
        c = asm ("crc32q %[v], %[c]"
            : [c] "=r" (-> u64),
            : [v] "r" (std.mem.readInt(u64, bytes[i..][0..8], .little)),
              [in] "0" (c),
        );
    }
    return updateTables(@truncate(c), bytes[i..]);
}

const testing = std.testing;

test "crc32c: matches std's Crc32Iscsi, in one piece and in parts" {
    var buf: [1031]u8 = undefined;
    var rng: std.Random.DefaultPrng = .init(7);
    rng.random().bytes(&buf);
    try testing.expectEqual(@as(u32, 0xe3069283), Crc32c.hash("123456789"));
    for (0..buf.len) |n| {
        const want = std.hash.crc.Crc32Iscsi.hash(buf[0..n]);
        try testing.expectEqual(want, Crc32c.hash(buf[0..n]));
        try testing.expectEqual(want, ~updateTables(0xffff_ffff, buf[0..n]));
        var c: Crc32c = .{};
        c.update(buf[0 .. n / 3]);
        c.update(buf[n / 3 .. n]);
        try testing.expectEqual(want, c.final());
    }
}
