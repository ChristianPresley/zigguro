//! `.zigguro/runs/index.bin` (E13.F01.S01.T01): a compact summary of every
//! run, so a cold start lists runs without parsing their journals.
//!
//! Layout (little-endian): header `{magic "ZGRI", version u16, pad u16,
//! count u32}`, `count` fixed 96-byte rows, the title string pool, then a
//! CRC-32 of everything before it. Rows:
//! `{id[16], kind u8, status u8, flags u8 (bit 0 pinned), pad[5], created i64, started i64,
//! ended i64, cost_micros u64, input_tokens u64, output_tokens u64,
//! title_off u32, title_len u16, pad[2], revision u64, pad[8]}`;
//! `started`/`ended` are `minInt(i64)` when unset. Pure.

const std = @import("std");
const run = @import("run.zig");

const Allocator = std.mem.Allocator;

pub const magic = "ZGRI";
pub const version: u16 = 1;
pub const header_len = 12;
pub const row_len = 96;
const none = std.math.minInt(i64);

pub const Row = struct {
    id: run.RunId,
    kind: run.RunKind,
    status: run.RunStatus,
    created_ms: i64,
    started_ms: ?i64,
    ended_ms: ?i64,
    cost: run.Cost,
    title: []const u8,
    revision: u64,
    pinned: bool = false,

    pub fn of(r: *const run.RunRecord) Row {
        return .{
            .id = r.id,
            .kind = r.spec.kind,
            .status = r.status,
            .created_ms = r.created_ms,
            .started_ms = r.started_ms,
            .ended_ms = r.ended_ms,
            .cost = r.cost,
            .title = r.spec.title,
            .revision = r.revision,
            .pinned = r.pinned,
        };
    }
};

/// Encodes `rows` into a fresh buffer.
pub fn encode(gpa: Allocator, rows: []const Row) Allocator.Error![]u8 {
    var pool_len: usize = 0;
    for (rows) |r| pool_len += @min(r.title.len, std.math.maxInt(u16));
    const total = header_len + rows.len * row_len + pool_len + 4;
    const out = try gpa.alloc(u8, total);
    @memset(out, 0);
    @memcpy(out[0..4], magic);
    std.mem.writeInt(u16, out[4..6], version, .little);
    std.mem.writeInt(u32, out[8..12], @intCast(rows.len), .little);
    var pool_off: usize = header_len + rows.len * row_len;
    const pool_base = pool_off;
    for (rows, 0..) |r, i| {
        const row = out[header_len + i * row_len ..][0..row_len];
        @memcpy(row[0..16], &r.id.bytes);
        row[16] = @intFromEnum(r.kind);
        row[17] = @intFromEnum(r.status);
        row[18] = @intFromBool(r.pinned);
        std.mem.writeInt(i64, row[24..32], r.created_ms, .little);
        std.mem.writeInt(i64, row[32..40], r.started_ms orelse none, .little);
        std.mem.writeInt(i64, row[40..48], r.ended_ms orelse none, .little);
        std.mem.writeInt(u64, row[48..56], r.cost.micros, .little);
        std.mem.writeInt(u64, row[56..64], r.cost.input_tokens, .little);
        std.mem.writeInt(u64, row[64..72], r.cost.output_tokens, .little);
        const tl: usize = @min(r.title.len, std.math.maxInt(u16));
        std.mem.writeInt(u32, row[72..76], @intCast(pool_off - pool_base), .little);
        std.mem.writeInt(u16, row[76..78], @intCast(tl), .little);
        std.mem.writeInt(u64, row[80..88], r.revision, .little);
        @memcpy(out[pool_off..][0..tl], r.title[0..tl]);
        pool_off += tl;
    }
    std.mem.writeInt(u32, out[total - 4 ..][0..4], std.hash.Crc32.hash(out[0 .. total - 4]), .little);
    return out;
}

pub const DecodeError = error{ InvalidIndex, OutOfMemory };

/// Decodes `bytes`; titles point into `bytes`.
pub fn decode(gpa: Allocator, bytes: []const u8) DecodeError![]Row {
    if (bytes.len < header_len + 4 or !std.mem.eql(u8, bytes[0..4], magic)) return error.InvalidIndex;
    if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.InvalidIndex;
    const crc = std.mem.readInt(u32, bytes[bytes.len - 4 ..][0..4], .little);
    if (crc != std.hash.Crc32.hash(bytes[0 .. bytes.len - 4])) return error.InvalidIndex;
    const count = std.mem.readInt(u32, bytes[8..12], .little);
    const pool_base = header_len + @as(usize, count) * row_len;
    if (pool_base > bytes.len - 4) return error.InvalidIndex;
    const pool = bytes[pool_base .. bytes.len - 4];
    const rows = try gpa.alloc(Row, count);
    errdefer gpa.free(rows);
    for (rows, 0..) |*r, i| {
        const row = bytes[header_len + i * row_len ..][0..row_len];
        const off = std.mem.readInt(u32, row[72..76], .little);
        const len = std.mem.readInt(u16, row[76..78], .little);
        if (@as(usize, off) + len > pool.len) return error.InvalidIndex;
        const started = std.mem.readInt(i64, row[32..40], .little);
        const ended = std.mem.readInt(i64, row[40..48], .little);
        r.* = .{
            .id = .{ .bytes = row[0..16].* },
            .kind = std.enums.fromInt(run.RunKind, row[16]) orelse return error.InvalidIndex,
            .status = std.enums.fromInt(run.RunStatus, row[17]) orelse return error.InvalidIndex,
            .created_ms = std.mem.readInt(i64, row[24..32], .little),
            .started_ms = if (started == none) null else started,
            .ended_ms = if (ended == none) null else ended,
            .cost = .{
                .micros = std.mem.readInt(u64, row[48..56], .little),
                .input_tokens = std.mem.readInt(u64, row[56..64], .little),
                .output_tokens = std.mem.readInt(u64, row[64..72], .little),
            },
            .title = pool[off..][0..len],
            .revision = std.mem.readInt(u64, row[80..88], .little),
            .pinned = row[18] & 1 != 0,
        };
    }
    return rows;
}

const testing = std.testing;

test "index round trip and corruption" {
    const rows = [_]Row{
        .{ .id = .fromInt(1), .kind = .task, .status = .completed, .created_ms = 5, .started_ms = 6, .ended_ms = null, .cost = .{ .micros = 9 }, .title = "first", .revision = 3, .pinned = true },
        .{ .id = .fromInt(2), .kind = .background, .status = .working, .created_ms = 7, .started_ms = null, .ended_ms = null, .cost = .{}, .title = "", .revision = 1 },
    };
    const bytes = try encode(testing.allocator, &rows);
    defer testing.allocator.free(bytes);
    const got = try decode(testing.allocator, bytes);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("first", got[0].title);
    try testing.expectEqual(@as(?i64, 6), got[0].started_ms);
    try testing.expectEqual(@as(?i64, null), got[0].ended_ms);
    try testing.expect(got[0].pinned and !got[1].pinned);
    try testing.expectEqual(run.RunStatus.working, got[1].status);
    try testing.expectEqual(@as(u64, 3), got[0].revision);

    const bad = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(bad);
    bad[20] ^= 0xff;
    try testing.expectError(error.InvalidIndex, decode(testing.allocator, bad));
    try testing.expectError(error.InvalidIndex, decode(testing.allocator, bytes[0 .. bytes.len - 3]));
}
