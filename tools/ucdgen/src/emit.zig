//! Compresses `tables.Ucd` into the `ucd.bin` blob and writes
//! `ucd_tables.zig`, which embeds the blob and names its sections.
//!
//! Property records use a two-stage table: `stage1[cp >> shift]` is a block
//! number, `stage2[block << shift | cp & mask]` a record index, and
//! `records[index]` the packed value: three dependent loads. Identical
//! blocks and records are stored once. The block size (64, 128 or 256) is
//! chosen per table to minimise bytes.
//!
//! Everything is little-endian, every section starts 16-byte aligned, and
//! nothing depends on hash-map iteration order, so output is deterministic.

const std = @import("std");
const tables = @import("tables.zig");
const e = @import("ucd_enums");

/// A two-stage table of `T` records.
pub fn MultiStage(comptime T: type) type {
    return struct {
        shift: u4,
        stage1: []u16,
        stage2: []u16,
        records: []T,
    };
}

/// Builds the smallest two-stage table for `values` (one per code point).
pub fn multiStage(comptime T: type, a: std.mem.Allocator, values: []const T) !MultiStage(T) {
    var best: ?MultiStage(T) = null;
    var best_bytes: usize = std.math.maxInt(usize);
    for ([_]u4{ 6, 7, 8 }) |shift| {
        const ms = try multiStageShift(T, a, values, shift);
        const bytes = ms.stage1.len * 2 + ms.stage2.len * 2 + ms.records.len * @sizeOf(T);
        if (bytes < best_bytes) {
            best = ms;
            best_bytes = bytes;
        }
    }
    return best.?;
}

fn multiStageShift(comptime T: type, a: std.mem.Allocator, values: []const T, shift: u4) !MultiStage(T) {
    const Int = std.meta.Int(.unsigned, @bitSizeOf(T));
    const block: usize = @as(usize, 1) << shift;
    var rec_index: std.AutoHashMapUnmanaged(Int, u16) = .empty;
    var records: std.ArrayList(T) = .empty;
    var block_index: std.StringHashMapUnmanaged(u16) = .empty;
    var stage2: std.ArrayList(u16) = .empty;
    const stage1 = try a.alloc(u16, values.len >> shift);
    const cur = try a.alloc(u16, block);
    for (0..stage1.len) |bi| {
        for (0..block) |j| {
            const v = values[bi * block + j];
            const key: Int = @bitCast(v);
            const gop = try rec_index.getOrPut(a, key);
            if (!gop.found_existing) {
                if (records.items.len > std.math.maxInt(u16)) return error.TooManyRecords;
                gop.value_ptr.* = @intCast(records.items.len);
                try records.append(a, v);
            }
            cur[j] = gop.value_ptr.*;
        }
        const bytes = std.mem.sliceAsBytes(cur);
        const gop = try block_index.getOrPut(a, bytes);
        if (!gop.found_existing) {
            gop.key_ptr.* = try a.dupe(u8, bytes);
            gop.value_ptr.* = @intCast(stage2.items.len >> shift);
            try stage2.appendSlice(a, cur);
        }
        stage1[bi] = gop.value_ptr.*;
    }
    return .{ .shift = shift, .stage1 = stage1, .stage2 = stage2.items, .records = records.items };
}

/// One blob section.
pub const Section = struct { name: []const u8, elem: []const u8, off: usize, len: usize };

/// Accumulates sections into the blob.
pub const Blob = struct {
    a: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    sections: std.ArrayList(Section) = .empty,
    props_shift: u4 = 0,
    aux_shift: u4 = 0,

    /// Appends `items` (little-endian) as section `name` with Zig element type `elem`.
    pub fn add(b: *Blob, name: []const u8, elem: []const u8, comptime T: type, items: []const T) !void {
        while (b.bytes.items.len % 16 != 0) try b.bytes.append(b.a, 0);
        const off = b.bytes.items.len;
        for (items) |it| {
            var buf: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &buf, it, .little);
            try b.bytes.appendSlice(b.a, &buf);
        }
        try b.sections.append(b.a, .{ .name = name, .elem = elem, .off = off, .len = items.len });
    }
};

/// Writes every table into a blob; returns it with its section list.
pub fn buildBlob(a: std.mem.Allocator, u: *const tables.Ucd) !Blob {
    var b: Blob = .{ .a = a };
    var pool: std.ArrayList(u32) = .empty;

    const ps = try multiStage(e.Props, a, u.props);
    try b.add("props_stage1", "u16", u16, ps.stage1);
    try b.add("props_stage2", "u16", u16, ps.stage2);
    const prec = try a.alloc(u64, ps.records.len);
    for (ps.records, prec) |r, *o| o.* = @bitCast(r);
    try b.add("props_records", "u64", u64, prec);
    var ascii: [128]u64 = undefined;
    for (&ascii, 0..) |*x, i| x.* = @bitCast(u.props[i]);
    try b.add("props_ascii", "u64", u64, &ascii);

    const xs = try multiStage(e.Aux, a, u.aux);
    try b.add("aux_stage1", "u16", u16, xs.stage1);
    try b.add("aux_stage2", "u16", u16, xs.stage2);
    const xrec = try a.alloc(u32, xs.records.len);
    for (xs.records, xrec) |r, *o| o.* = @bitCast(r);
    try b.add("aux_records", "u32", u32, xrec);

    // Script_Extensions: (lo, hi, off << 8 | len) over a u8 pool of scripts.
    var scx: std.ArrayList(u32) = .empty;
    var scx_pool: std.ArrayList(u8) = .empty;
    for (u.scx) |r| {
        try scx.appendSlice(a, &.{ r.lo, r.hi, @as(u32, @intCast(scx_pool.items.len)) << 8 | @as(u32, @intCast(r.scripts.len)) });
        for (r.scripts) |s| try scx_pool.append(a, @intFromEnum(s));
    }
    try b.add("scx_ranges", "u32", u32, scx.items);
    try b.add("scx_pool", "u8", u8, scx_pool.items);

    try b.add("mirror", "u32", u32, try pairs(a, u.mirror));
    try b.add("brackets", "u32", u32, try pairs(a, u.brackets));
    try b.add("fold_simple", "u32", u32, try pairs(a, u.fold_simple));
    try b.add("decomp_canon", "u32", u32, try seqs(a, u.decomp_canon, &pool));
    try b.add("decomp_compat", "u32", u32, try seqs(a, u.decomp_compat, &pool));
    try b.add("fold_full", "u32", u32, try seqs(a, u.fold_full, &pool));

    var comp_keys: std.ArrayList(u64) = .empty;
    var comp_vals: std.ArrayList(u32) = .empty;
    for (u.compose) |c| {
        try comp_keys.append(a, @as(u64, c.a) << 21 | c.b);
        try comp_vals.append(a, c.c);
    }
    try b.add("compose_keys", "u64", u64, comp_keys.items);
    try b.add("compose_values", "u32", u32, comp_vals.items);

    var cs: std.ArrayList(u32) = .empty;
    for (u.case_simple) |c| try cs.appendSlice(a, &.{ c[0], c[1], c[2], c[3] });
    try b.add("case_simple", "u32", u32, cs.items);
    // Full case mappings: (cp << 2 | kind, off << 8 | len).
    var cf: std.ArrayList(u32) = .empty;
    for (u.case_full) |c| {
        const off: u32 = @intCast(pool.items.len);
        for (c.cps) |x| try pool.append(a, x);
        try cf.appendSlice(a, &.{ @as(u32, c.cp) << 2 | @intFromEnum(c.kind), off << 8 | @as(u32, @intCast(c.cps.len)) });
    }
    try b.add("case_full", "u32", u32, cf.items);
    try b.add("seq_pool", "u21", u32, pool.items);
    b.props_shift = ps.shift;
    b.aux_shift = xs.shift;
    return b;
}

fn pairs(a: std.mem.Allocator, items: []const [2]u21) ![]u32 {
    const out = try a.alloc(u32, items.len * 2);
    for (items, 0..) |p, i| {
        out[i * 2] = p[0];
        out[i * 2 + 1] = p[1];
    }
    return out;
}

/// (cp, off << 8 | len) per sequence, appending code points to `pool`.
fn seqs(a: std.mem.Allocator, items: []const tables.Seq, pool: *std.ArrayList(u32)) ![]u32 {
    const out = try a.alloc(u32, items.len * 2);
    for (items, 0..) |s, i| {
        out[i * 2] = s.cp;
        out[i * 2 + 1] = @as(u32, @intCast(pool.items.len)) << 8 | @as(u32, @intCast(s.cps.len));
        for (s.cps) |c| try pool.append(a, c);
    }
    return out;
}

/// Writes `ucd_tables.zig` for `blob`.
pub fn writeZig(w: *std.Io.Writer, version: []const u8, blob: *const Blob) !void {
    try w.print(
        \\//! Generated by ucdgen from Unicode {s}. Do not edit.
        \\
        \\/// The Unicode version of the tables.
        \\pub const unicode_version = "{s}";
        \\
        \\/// The table blob (little-endian; every section 16-byte aligned).
        \\pub const blob: [{d}]u8 align(16) = @embedFile("ucd.bin").*;
        \\
        \\/// A section of `blob`: byte offset and element count.
        \\pub const Section = struct {{ off: usize, len: usize }};
        \\
        \\/// Block size (log2) of the `props_*` two-stage table.
        \\pub const props_shift = {d};
        \\/// Block size (log2) of the `aux_*` two-stage table.
        \\pub const aux_shift = {d};
        \\
        \\
    , .{ version, version, blob.bytes.items.len, blob.props_shift, blob.aux_shift });
    for (blob.sections.items) |s| {
        try w.print("/// `{s}`: {d} x {s}.\npub const {s}: Section = .{{ .off = {d}, .len = {d} }};\n", .{ s.name, s.len, s.elem, s.name, s.off, s.len });
    }
}
