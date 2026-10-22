//! The shared variation formats: region scalars, `ItemVariationStore` and
//! `DeltaSetIndexMap` (OpenType "variations common table formats"). Used by
//! HVAR, MVAR, CFF2 `blend` and, for the scalar rule, gvar.

const std = @import("std");
const reader = @import("../reader.zig");

/// Normalized coordinates, one F2Dot14 per fvar axis; empty means the
/// default instance (every axis at 0).
pub const VarCoords = []const i16;

/// The scalar of one axis of a region (start, peak, end) at `coord`, all
/// F2Dot14, following the spec's pseudo-code exactly.
pub inline fn axisScalar(start: i16, peak: i16, end: i16, coord: i16) f32 {
    if (start > peak or peak > end) return 1; // invalid: axis ignored
    if (start < 0 and end > 0 and peak != 0) return 1; // invalid: axis ignored
    if (peak == 0) return 1;
    if (coord < start or coord > end) return 0;
    if (coord == peak) return 1;
    if (coord < peak) return @as(f32, @floatFromInt(@as(i32, coord) - start)) / @as(f32, @floatFromInt(@as(i32, peak) - start));
    return @as(f32, @floatFromInt(@as(i32, end) - coord)) / @as(f32, @floatFromInt(@as(i32, end) - peak));
}

/// The coordinate of `axis`, 0 past the end of `coords`.
pub inline fn coordAt(coords: VarCoords, axis: usize) i16 {
    return if (axis < coords.len) coords[axis] else 0;
}

/// An `ItemVariationStore` (format 1) over borrowed bytes.
pub const ItemVariationStore = struct {
    data: []const u8,
    /// Offset of the region list's first region record.
    regions_off: u32,
    axis_count: u16,
    region_count: u16,
    data_count: u16,

    /// Validates the header and the region list.
    pub fn init(bytes: []const u8) error{Malformed}!ItemVariationStore {
        var r = try reader.Reader.at(bytes, 0);
        if (try r.u16_() != 1) return error.Malformed;
        const rl = try r.u32_();
        const n = try r.u16_();
        _ = try reader.subLen(bytes, 8, @as(usize, n) * 4);
        const axis_count = try reader.readAt(u16, bytes, rl);
        const region_count = try reader.readAt(u16, bytes, @as(usize, rl) + 2);
        _ = try reader.subLen(bytes, @as(usize, rl) + 4, @as(usize, region_count) * axis_count * 6);
        return .{ .data = bytes, .regions_off = rl + 4, .axis_count = axis_count, .region_count = region_count, .data_count = n };
    }

    /// The scalar of region `ri` at `coords` (0 for an out-of-range index).
    pub fn regionScalar(s: *const ItemVariationStore, ri: u16, coords: VarCoords) f32 {
        if (ri >= s.region_count) return 0;
        const rec = s.data[s.regions_off + @as(usize, ri) * s.axis_count * 6 ..];
        var v: f32 = 1;
        for (0..s.axis_count) |a| {
            const t = rec[a * 6 ..][0..6];
            const start = std.mem.readInt(i16, t[0..2], .big);
            const peak = std.mem.readInt(i16, t[2..4], .big);
            const end = std.mem.readInt(i16, t[4..6], .big);
            v *= axisScalar(start, peak, end, coordAt(coords, a));
            if (v == 0) return 0;
        }
        return v;
    }

    /// Fills `out[0..region_count]` with every region's scalar; instances
    /// cache this so later deltas are only multiply-adds.
    pub fn regionScalars(s: *const ItemVariationStore, coords: VarCoords, out: []f32) void {
        for (out[0..s.region_count], 0..) |*o, i| o.* = s.regionScalar(@intCast(i), coords);
    }

    /// One `ItemVariationData` subtable.
    pub const Data = struct {
        item_count: u16,
        word_count: u16,
        long_words: bool,
        /// `regionIndexCount` big-endian u16 region indices.
        regions: []const u8,
        rows: []const u8,

        /// Number of regions (columns) in each row.
        pub fn regionCount(d: Data) u16 {
            return @intCast(d.regions.len / 2);
        }

        /// Region index of column `j`.
        pub fn region(d: Data, j: usize) u16 {
            return std.mem.readInt(u16, d.regions[j * 2 ..][0..2], .big);
        }

        fn rowSize(d: Data) usize {
            const n = d.regionCount();
            return if (d.long_words) 4 * @as(usize, d.word_count) + 2 * (n - d.word_count) else 2 * @as(usize, d.word_count) + (n - d.word_count);
        }

        /// Row `inner` weighted by precomputed region scalars (0 for a row
        /// past the end).
        pub fn deltaScaled(d: Data, inner: u16, scalars: []const f32) f32 {
            if (inner >= d.item_count) return 0;
            var sum: f32 = 0;
            for (0..d.regionCount()) |j| {
                const ri = d.region(j);
                if (ri < scalars.len) sum += scalars[ri] * @as(f32, @floatFromInt(d.delta(inner, j)));
            }
            return sum;
        }

        /// The delta in column `j` of row `inner` (which must be < item_count).
        pub fn delta(d: Data, inner: u16, j: usize) i32 {
            const row = d.rows[@as(usize, inner) * d.rowSize() ..];
            if (d.long_words) {
                if (j < d.word_count) return std.mem.readInt(i32, row[j * 4 ..][0..4], .big);
                return std.mem.readInt(i16, row[4 * @as(usize, d.word_count) + (j - d.word_count) * 2 ..][0..2], .big);
            }
            if (j < d.word_count) return std.mem.readInt(i16, row[j * 2 ..][0..2], .big);
            return @as(i8, @bitCast(row[2 * @as(usize, d.word_count) + (j - d.word_count)]));
        }
    };

    /// The `outer`th data subtable, validated.
    pub fn itemData(s: *const ItemVariationStore, outer: u16) error{Malformed}!Data {
        if (outer >= s.data_count) return error.Malformed;
        const off = try reader.readAt(u32, s.data, 8 + @as(usize, outer) * 4);
        var r = try reader.Reader.at(s.data, off);
        const items = try r.u16_();
        const wdc = try r.u16_();
        const nreg = try r.u16_();
        const word_count = wdc & 0x7FFF;
        if (word_count > nreg) return error.Malformed;
        const regions = try r.slice(@as(usize, nreg) * 2);
        var d: Data = .{ .item_count = items, .word_count = word_count, .long_words = wdc & 0x8000 != 0, .regions = regions, .rows = &.{} };
        d.rows = try r.slice(d.rowSize() * items);
        return d;
    }

    /// The delta of item (outer, inner) at `coords`. 0xFFFF/0xFFFF and
    /// out-of-range items mean no variation.
    pub fn delta(s: *const ItemVariationStore, outer: u16, inner: u16, coords: VarCoords) f32 {
        if (outer == 0xFFFF and inner == 0xFFFF) return 0;
        const d = s.itemData(outer) catch return 0;
        if (inner >= d.item_count) return 0;
        var sum: f32 = 0;
        for (0..d.regionCount()) |j| {
            const sc = s.regionScalar(d.region(j), coords);
            if (sc != 0) sum += sc * @as(f32, @floatFromInt(d.delta(inner, j)));
        }
        return sum;
    }

    /// `delta` with region scalars precomputed by `regionScalars`.
    pub fn deltaScaled(s: *const ItemVariationStore, outer: u16, inner: u16, scalars: []const f32) f32 {
        if (outer == 0xFFFF and inner == 0xFFFF) return 0;
        const d = s.itemData(outer) catch return 0;
        return d.deltaScaled(inner, scalars);
    }
};

/// A variation index: outer (data subtable) and inner (row).
pub const VarIdx = struct { outer: u16, inner: u16 };

/// A `DeltaSetIndexMap` (formats 0 and 1).
pub const DeltaSetIndexMap = struct {
    entries: []const u8,
    count: u32,
    entry_size: u8,
    inner_bits: u5,

    /// Validates the header and that all entries fit.
    pub fn init(bytes: []const u8) error{Malformed}!DeltaSetIndexMap {
        var r = try reader.Reader.at(bytes, 0);
        const format = try r.u8_();
        const ef = try r.u8_();
        const count: u32 = switch (format) {
            0 => try r.u16_(),
            1 => try r.u32_(),
            else => return error.Malformed,
        };
        const size: u8 = ((ef & 0x30) >> 4) + 1;
        const entries = try r.slice(@as(usize, count) * size);
        return .{ .entries = entries, .count = count, .entry_size = size, .inner_bits = @intCast((ef & 0x0F) + 1) };
    }

    /// The mapping of `i`; indices past the end use the last entry, and an
    /// empty map is the identity.
    pub fn get(m: *const DeltaSetIndexMap, i: u32) VarIdx {
        if (m.count == 0) return .{ .outer = @truncate(i >> 16), .inner = @truncate(i) };
        const k = @min(i, m.count - 1);
        const e = m.entries[@as(usize, k) * m.entry_size ..][0..m.entry_size];
        var v: u32 = 0;
        for (e) |b| v = (v << 8) | b;
        return .{ .outer = @truncate(v >> m.inner_bits), .inner = @truncate(v & ((@as(u32, 1) << m.inner_bits) - 1)) };
    }
};
