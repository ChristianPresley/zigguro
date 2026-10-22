//! The legacy `kern` table: horizontal format 0 pair subtables (OpenType
//! version 0 and Apple version 1 headers), applied the way HarfBuzz's kern
//! machine does when GPOS has no `kern` feature.

const std = @import("std");
const ot = @import("../ot/root.zig");
const GlyphId = ot.GlyphId;
const reader = ot.reader;
const readAt = reader.readAt;
const lc = @import("../ot/layout_common.zig");
const Gdef = @import("../ot/gdef.zig").Gdef;
const skippy = @import("skippy.zig");
const buffer = @import("buffer.zig");
const Buffer = buffer.Buffer;

/// One format 0 subtable: sorted (left, right, value) records.
const Pairs = struct {
    data: []const u8,
    count: u32,

    fn value(p: Pairs, left: GlyphId, right: GlyphId) i16 {
        const key = @as(u32, left) << 16 | right;
        var lo: u32 = 0;
        var hi: u32 = p.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const at = @as(usize, mid) * 6;
            const k = std.mem.readInt(u32, p.data[at..][0..4], .big);
            if (k == key) return std.mem.readInt(i16, p.data[at + 4 ..][0..2], .big);
            if (k < key) lo = mid + 1 else hi = mid;
        }
        return 0;
    }
};

/// Up to this many horizontal format 0 subtables are used.
const max_subtables = 8;

/// A parsed `kern` table.
pub const Kern = struct {
    subtables: [max_subtables]Pairs = undefined,
    count: u8 = 0,
    /// A format 1 (state machine) subtable exists; mark zeroing is skipped.
    has_state_machine: bool = false,
    /// A cross-stream subtable exists (not applied).
    has_cross_stream: bool = false,

    /// Parses `bytes`; null when no usable subtable exists.
    pub fn init(bytes: []const u8) ?Kern {
        var k: Kern = .{};
        const v16 = readAt(u16, bytes, 0) catch return null;
        if (v16 == 0) {
            const n = readAt(u16, bytes, 2) catch return null;
            var off: usize = 4;
            for (0..n) |i| {
                const len = readAt(u16, bytes, off + 2) catch break;
                const format = readAt(u8, bytes, off + 4) catch break;
                const cov = readAt(u8, bytes, off + 5) catch break;
                if (format == 1) k.has_state_machine = true;
                if (cov & 0x04 != 0) k.has_cross_stream = true;
                // The last subtable's length is often wrong (it overflows
                // 16 bits in big fonts); format 0 is bounded by the table.
                if (format == 0 and cov & 0x01 != 0 and cov & 0x04 == 0) k.add(bytes, off + 6);
                if (i + 1 < n and len < 6) break;
                off += len;
            }
        } else if (v16 == 1) {
            const n = readAt(u32, bytes, 4) catch return null;
            var off: usize = 8;
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const len = readAt(u32, bytes, off) catch break;
                const cov = readAt(u8, bytes, off + 4) catch break;
                const format = readAt(u8, bytes, off + 5) catch break;
                if (format == 1) k.has_state_machine = true;
                if (cov & 0x40 != 0) k.has_cross_stream = true;
                if (format == 0 and cov & 0xE0 == 0) k.add(bytes, off + 8);
                if (len < 8) break;
                off += len;
            }
        } else return null;
        if (k.count == 0 and !k.has_state_machine) return null;
        return k;
    }

    fn add(k: *Kern, bytes: []const u8, off: usize) void {
        if (k.count == max_subtables) return;
        const n = readAt(u16, bytes, off) catch return;
        const start = off + 8;
        if (start > bytes.len) return;
        const fit: u32 = @intCast(@min(n, (bytes.len - start) / 6));
        k.subtables[k.count] = .{ .data = bytes[start..], .count = fit };
        k.count += 1;
    }

    /// True when any pair names `gid`.
    pub fn involves(k: *const Kern, gid: GlyphId) bool {
        for (k.subtables[0..k.count]) |p| {
            for (0..p.count) |i| {
                const at = i * 6;
                const l = std.mem.readInt(u16, p.data[at..][0..2], .big);
                const r = std.mem.readInt(u16, p.data[at + 2 ..][0..2], .big);
                const v = std.mem.readInt(i16, p.data[at + 4 ..][0..2], .big);
                if (v != 0 and (l == gid or r == gid)) return true;
            }
        }
        return false;
    }

    /// Applies every subtable to glyphs whose mask has `mask` bits, skipping
    /// marks; each kern value is split between the two glyphs' advances.
    pub fn apply(k: *const Kern, b: *Buffer, gdef: *const Gdef, mask: u32) void {
        if (mask == 0) return;
        for (k.subtables[0..k.count]) |p| applyPairs(p, b, gdef, mask);
    }
};

fn applyPairs(p: Pairs, b: *Buffer, gdef: *const Gdef, mask: u32) void {
    var budget = skippy.OpBudget.init(b.len());
    var c: skippy.Ctx = .{
        .buf = b,
        .table = undefined,
        .kind = .gpos,
        .gdef = gdef,
        .budget = &budget,
        .lookup_mask = mask,
        .lookup_props = lc.LookupFlag.ignore_marks,
    };
    var it = skippy.Skippy.init(&c, false);
    const infos = b.infos.items;
    const pos = b.pos.items;
    var idx: usize = 0;
    while (idx < infos.len) {
        if (infos[idx].mask & mask == 0) {
            idx += 1;
            continue;
        }
        it.reset(idx, 1);
        if (!it.next(null)) {
            idx += 1;
            continue;
        }
        const i = idx;
        const j = it.idx;
        const kern: i32 = p.value(infos[i].gid, infos[j].gid);
        if (kern != 0) {
            const k1 = kern >> 1;
            const k2 = kern - k1;
            pos[i].x_adv += k1;
            pos[j].x_adv += k2;
            pos[j].x_off += k2;
            b.unsafeToBreak(i, j + 1);
        }
        idx = j;
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "kern: format 0 fallback splits the value" {
    var t: lc.TestBytes = .{ .gpa = testing.allocator };
    defer t.deinit();
    // version 0, 1 subtable; subtable v0, len, format 0 / horizontal.
    t.u16s(&.{ 0, 1, 0, 14 + 2 * 6, 0x0001 });
    t.u16s(&.{ 2, 12, 1, 0 });
    t.u16s(&.{ 5, 6 });
    t.i16_(-80);
    t.u16s(&.{ 6, 5 });
    t.i16_(31);
    const k = Kern.init(t.buf.items).?;
    try testing.expect(k.involves(6) and !k.involves(7));
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    for ([_]GlyphId{ 5, 6, 5 }, 0..) |g, n| try b.infos.append(testing.allocator, .{ .gid = g, .cluster = @intCast(n), .cp = 'a', .mask = 1 });
    try b.pos.appendNTimes(testing.allocator, .{ .x_adv = 500 }, 3);
    const gdef: Gdef = .{};
    k.apply(&b, &gdef, 1);
    try testing.expectEqual(@as(i32, 460), b.pos.items[0].x_adv);
    try testing.expectEqual(@as(i32, 460 + 15), b.pos.items[1].x_adv);
    try testing.expectEqual(@as(i32, -40), b.pos.items[1].x_off);
    try testing.expectEqual(@as(i32, 516), b.pos.items[2].x_adv);
    try testing.expectEqual(@as(i32, 16), b.pos.items[2].x_off);
}
