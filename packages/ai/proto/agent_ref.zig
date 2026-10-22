//! Agent and session identity: ULID session ids and `AgentRef`.

const std = @import("std");

/// ULID: 48-bit Unix-ms timestamp followed by 80 random bits.
pub const SessionId = u128;

/// Identifies an agent: the session, the agent within it, and optionally
/// the tool call that spawned it.
pub const AgentRef = struct {
    session: SessionId,
    /// 0 = the main agent, >0 = a subagent.
    agent: u32 = 0,
    tool_call: ?[]const u8 = null,
};

const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// Generates ULIDs that are strictly increasing within one generator, even
/// within the same millisecond (the random part is incremented).
pub const UlidGen = struct {
    last: u128 = 0,

    /// Next id for timestamp `ms`, with 80 bits drawn from `random`.
    pub fn nextAt(g: *UlidGen, ms: u64, random: std.Random) SessionId {
        const ts: u128 = @as(u128, ms & 0xFFFF_FFFF_FFFF) << 80;
        var id: u128 = ts | (random.int(u128) & ((@as(u128, 1) << 80) - 1));
        if (id <= g.last) id = g.last + 1;
        g.last = id;
        return id;
    }

    /// Next id using the real clock and `io.random`.
    pub fn next(g: *UlidGen, io: std.Io) SessionId {
        const now = std.Io.Clock.real.now(io);
        const ms: u64 = @intCast(@max(0, @divFloor(now.nanoseconds, std.time.ns_per_ms)));
        var seed: [8]u8 = undefined;
        io.random(&seed);
        var prng: std.Random.DefaultPrng = .init(std.mem.readInt(u64, &seed, .little));
        return g.nextAt(ms, prng.random());
    }
};

/// 26-character Crockford base32 text form.
pub fn format(id: SessionId) [26]u8 {
    var out: [26]u8 = undefined;
    var v = id;
    var i: usize = 26;
    while (i > 0) {
        i -= 1;
        out[i] = crockford[@intCast(v & 31)];
        v >>= 5;
    }
    return out;
}

/// Parses the text form (case-insensitive; I/L read as 1, O as 0).
pub fn parse(s: []const u8) error{InvalidUlid}!SessionId {
    if (s.len != 26) return error.InvalidUlid;
    var v: u128 = 0;
    for (s, 0..) |c0, i| {
        const c = std.ascii.toUpper(c0);
        const d: u8 = switch (c) {
            '0'...'9' => c - '0',
            'O' => 0,
            'I', 'L' => 1,
            else => blk: {
                const idx = std.mem.indexOfScalar(u8, crockford, c) orelse return error.InvalidUlid;
                break :blk @intCast(idx);
            },
        };
        if (i == 0 and d > 7) return error.InvalidUlid;
        v = (v << 5) | d;
    }
    return v;
}

/// Unix milliseconds encoded in a ULID.
pub fn timestampMs(id: SessionId) u64 {
    return @intCast(id >> 80);
}

test "ulid_monotonic" {
    var g: UlidGen = .{};
    var prng: std.Random.DefaultPrng = .init(1);
    var prev: u128 = 0;
    for (0..10_000) |i| {
        const id = g.nextAt(1_700_000_000_000 + i / 100, prng.random());
        try std.testing.expect(id > prev);
        prev = id;
    }
}

test "ulid text round trip" {
    var g: UlidGen = .{};
    const id = g.next(std.testing.io);
    const s = format(id);
    try std.testing.expectEqual(id, try parse(&s));
    try std.testing.expect(timestampMs(id) > 1_600_000_000_000);
    try std.testing.expectError(error.InvalidUlid, parse("8ZZZZZZZZZZZZZZZZZZZZZZZZZ"));
    try std.testing.expectEqual(@as(u128, 0), try parse("0000000000000000000000000O"));
}
