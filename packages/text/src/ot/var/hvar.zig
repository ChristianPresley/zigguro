//! `HVAR`: advance-width (and left side bearing) deltas from an
//! `ItemVariationStore`, indexed by glyph through optional
//! `DeltaSetIndexMap`s (an absent advance map is the identity).

const std = @import("std");
const reader = @import("../reader.zig");
const ivs = @import("ivs.zig");
const GlyphId = reader.GlyphId;

/// A view of `HVAR`.
pub const Hvar = struct {
    store: ivs.ItemVariationStore,
    advance_map: ?ivs.DeltaSetIndexMap,
    lsb_map: ?ivs.DeltaSetIndexMap,

    /// Validates the header, the store and the maps.
    pub fn init(bytes: []const u8) error{Malformed}!Hvar {
        if (try reader.readAt(u16, bytes, 0) != 1) return error.Malformed;
        const store_off = try reader.readAt(u32, bytes, 4);
        const adv_off = try reader.readAt(u32, bytes, 8);
        const lsb_off = try reader.readAt(u32, bytes, 12);
        return .{
            .store = try .init(try reader.sub(bytes, store_off)),
            .advance_map = if (adv_off != 0) try .init(try reader.sub(bytes, adv_off)) else null,
            .lsb_map = if (lsb_off != 0) try .init(try reader.sub(bytes, lsb_off)) else null,
        };
    }

    /// The variation index of `gid`'s advance.
    pub fn advanceIdx(h: *const Hvar, gid: GlyphId) ivs.VarIdx {
        if (h.advance_map) |m| return m.get(gid);
        return .{ .outer = 0, .inner = gid };
    }

    /// Advance delta of `gid` with precomputed region scalars.
    pub fn advanceDelta(h: *const Hvar, gid: GlyphId, scalars: []const f32) f32 {
        const i = h.advanceIdx(gid);
        return h.store.deltaScaled(i.outer, i.inner, scalars);
    }

    /// Left-side-bearing delta of `gid`, or null without an lsb map.
    pub fn lsbDelta(h: *const Hvar, gid: GlyphId, scalars: []const f32) ?f32 {
        const m = h.lsb_map orelse return null;
        const i = m.get(gid);
        return h.store.deltaScaled(i.outer, i.inner, scalars);
    }
};
