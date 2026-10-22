//! Journal frames (E12.F01.S02.T01):
//! `[len: u32 LE][crc32c: u32 LE over kind+payload][kind: u8][payload]`,
//! where `len` counts the kind byte and the payload. Pure.
//!
//! A reader stops at the first frame it cannot trust: `torn` when the
//! bytes end inside a frame (a crash during an append), `corrupt` when a
//! complete frame fails its CRC or has an impossible length.

const std = @import("std");

const Crc = std.hash.crc.Crc32Iscsi;

pub const header_len = 9;
/// Larger frames are corruption (content goes to blobs).
pub const max_frame = 64 << 20;

pub const Kind = enum(u8) {
    /// A full changeset snapshot; a later one with the same id wins.
    changeset = 1,
    /// A changeset left the queue.
    remove = 2,
    /// A checkpoint (F04).
    checkpoint = 3,
    /// A `History` record: what an apply, undo or restore wrote.
    apply = 4,
    /// The next changeset, apply and checkpoint ids, written by a
    /// compaction so that ids of dropped records are not handed out again.
    ids = 5,
    /// An approval request and its outcome (F05.S02); a later one with the
    /// same id wins.
    approval = 6,
    _,
};

/// Appends one frame to `out`.
pub fn encode(gpa: std.mem.Allocator, out: *std.ArrayList(u8), kind: Kind, payload: []const u8) std.mem.Allocator.Error!void {
    std.debug.assert(payload.len + 1 <= max_frame);
    var crc: Crc = .init();
    const k = [1]u8{@intFromEnum(kind)};
    crc.update(&k);
    crc.update(payload);
    var hdr: [header_len]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(payload.len + 1), .little);
    std.mem.writeInt(u32, hdr[4..8], crc.final(), .little);
    hdr[8] = k[0];
    try out.ensureUnusedCapacity(gpa, header_len + payload.len);
    out.appendSliceAssumeCapacity(&hdr);
    out.appendSliceAssumeCapacity(payload);
}

pub const Frame = struct { kind: Kind, payload: []const u8 };

pub const Next = union(enum) {
    frame: Frame,
    /// No more bytes.
    end,
    /// The bytes end inside a frame.
    torn,
    /// A complete frame with a bad CRC or length.
    corrupt,
};

/// Reads frames from a byte slice.
pub const Reader = struct {
    bytes: []const u8,
    /// Offset of the next frame (after the last good one).
    pos: usize = 0,

    pub fn next(r: *Reader) Next {
        const rest = r.bytes[r.pos..];
        if (rest.len == 0) return .end;
        if (rest.len < 4) return .torn;
        const len = std.mem.readInt(u32, rest[0..4], .little);
        if (len == 0 or len > max_frame) return .corrupt;
        if (rest.len < 8 + @as(usize, len)) return .torn;
        const want = std.mem.readInt(u32, rest[4..8], .little);
        const body = rest[8..][0..len];
        if (Crc.hash(body) != want) return .corrupt;
        r.pos += 8 + len;
        return .{ .frame = .{ .kind = @enumFromInt(body[0]), .payload = body[1..] } };
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "journal: frames round trip; torn and corrupt tails detected" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try encode(testing.allocator, &buf, .changeset, "{\"a\":1}");
    try encode(testing.allocator, &buf, .remove, "");
    const good = buf.items.len;
    try encode(testing.allocator, &buf, .checkpoint, "xyz");

    var r: Reader = .{ .bytes = buf.items };
    try testing.expectEqualStrings("{\"a\":1}", r.next().frame.payload);
    try testing.expectEqual(Kind.remove, r.next().frame.kind);
    try testing.expectEqualStrings("xyz", r.next().frame.payload);
    try testing.expect(r.next() == .end);

    // Every proper prefix of the last frame is torn.
    for (good + 1..buf.items.len) |n| {
        var t: Reader = .{ .bytes = buf.items[0..n] };
        _ = t.next();
        _ = t.next();
        try testing.expect(t.next() == .torn);
        try testing.expectEqual(good, t.pos);
    }
    // A flipped payload bit is corrupt.
    buf.items[buf.items.len - 1] ^= 1;
    var c: Reader = .{ .bytes = buf.items };
    _ = c.next();
    _ = c.next();
    try testing.expect(c.next() == .corrupt);
}

test "fuzz: review journal" {
    try testing.fuzz({}, struct {
        fn one(_: void, sm: *testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const bytes = buf[0..sm.slice(&buf)];
            var r: Reader = .{ .bytes = bytes };
            while (true) switch (r.next()) {
                .frame => |f| {
                    // Every frame returned has a valid CRC.
                    const start = @intFromPtr(f.payload.ptr) - @intFromPtr(bytes.ptr) - 1;
                    const want = std.mem.readInt(u32, bytes[start - 4 ..][0..4], .little);
                    try testing.expectEqual(want, Crc.hash(bytes[start..][0 .. f.payload.len + 1]));
                },
                else => break,
            };
        }
    }.one, .{});
}
