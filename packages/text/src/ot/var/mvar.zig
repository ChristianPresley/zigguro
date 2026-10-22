//! `MVAR`: deltas for font-wide metrics, keyed by value tag.

const std = @import("std");
const reader = @import("../reader.zig");
const ivs = @import("ivs.zig");
const Tag = reader.Tag;

/// A view of `MVAR`.
pub const Mvar = struct {
    store: ?ivs.ItemVariationStore,
    /// Value records sorted by tag: Tag, outer u16, inner u16 (plus padding
    /// up to `record_size`).
    records: []const u8,
    record_size: u16,

    /// Validates the header, the records and the store.
    pub fn init(bytes: []const u8) error{Malformed}!Mvar {
        if (try reader.readAt(u16, bytes, 0) != 1) return error.Malformed;
        const size = try reader.readAt(u16, bytes, 6);
        const count = try reader.readAt(u16, bytes, 8);
        const store_off = try reader.readAt(u16, bytes, 10);
        if (size < 8) return error.Malformed;
        return .{
            .store = if (store_off != 0) try .init(try reader.sub(bytes, store_off)) else null,
            .records = try reader.subLen(bytes, 12, @as(usize, count) * size),
            .record_size = size,
        };
    }

    /// The delta for `t` with precomputed scalars (0 when absent).
    pub fn delta(m: *const Mvar, t: Tag, scalars: []const f32) f32 {
        const s = &(m.store orelse return 0);
        var lo: usize = 0;
        var hi: usize = m.records.len / m.record_size;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const r = m.records[mid * m.record_size ..][0..8];
            const rt = std.mem.readInt(u32, r[0..4], .big);
            if (rt == t) return s.deltaScaled(std.mem.readInt(u16, r[4..6], .big), std.mem.readInt(u16, r[6..8], .big), scalars);
            if (rt < t) lo = mid + 1 else hi = mid;
        }
        return 0;
    }
};
