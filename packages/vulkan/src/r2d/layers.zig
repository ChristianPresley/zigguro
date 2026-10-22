//! Offscreen layer bookkeeping shared by the backends (E02.F06.S03.T01).
//!
//! A layer is a render-target texture whose content persists across
//! frames. Plain layers map content pixel (x, y) to texel (x, y). Scroll
//! layers are toroidal: content pixel (x, y) lives at texel
//! `((x + origin.x) mod w, (y + origin.y) mod h)`. When E04 scrolls the
//! content by d, it adds d to the origin (`scrolledOrigin`) and reports the
//! exposed strip (`scrollDamage`) as content damage, so the rest of the
//! texture is reused without being redrawn. Backends render each damaged
//! content rect as up to four wrapped pieces (`wrapRects`); a piece whose
//! offset is not zero is drawn from translated copies of the layer's
//! prims (`appendTranslated`). The composite samples with wraparound, so
//! no seam shows at integer or fractional offsets.
//!
//! `LayerTable` keeps the layers a backend holds, with least-recently
//! composited eviction under a byte budget.

const std = @import("std");
const types = @import("types.zig");
const prim_mod = @import("prim.zig");

const Size = types.Size;
const PxRect = types.PxRect;
const LayerId = types.LayerId;
const ClipRect = types.ClipRect;
const Prim = prim_mod.Prim;

/// How a layer maps content to texels.
pub const LayerKind = enum(u8) {
    /// Content pixel = texel.
    plain,
    /// Wraparound (ring-buffer) addressing in both axes.
    scroll,
};

/// Default layer memory budget (E15 `render.layer_budget_mb`).
pub const default_budget_bytes: u64 = 64 << 20;

/// Bytes a layer of `size` occupies (4 bytes per texel).
pub fn layerBytes(size: Size) u64 {
    return @as(u64, size.w) * size.h * 4;
}

/// A part of a content rect in texture space.
pub const Piece = struct {
    /// The texels to repaint.
    rect: PxRect,
    /// Texel minus content position for this piece.
    offset: [2]i32,

    /// The content rect this piece shows.
    pub fn content(p: Piece) PxRect {
        return .{ .x = p.rect.x - p.offset[0], .y = p.rect.y - p.offset[1], .w = p.rect.w, .h = p.rect.h };
    }
};

/// Maps content rect `r` (cut to the layer) to 1–4 rects in wrapped
/// texture space; returns how many were written to `out` (0 when `r` is
/// outside the layer). Pure.
pub fn wrapRects(r: PxRect, origin: [2]i32, tex_size: Size, out: *[4]Piece) u8 {
    const c = cut(r, tex_size) orelse return 0;
    var xs: [2]Span = undefined;
    var ys: [2]Span = undefined;
    const nx = split(c.x, c.w, origin[0], tex_size.w, &xs);
    const ny = split(c.y, c.h, origin[1], tex_size.h, &ys);
    var n: u8 = 0;
    for (ys[0..ny]) |y| for (xs[0..nx]) |x| {
        out[n] = .{ .rect = .{ .x = x.tex, .y = y.tex, .w = x.len, .h = y.len }, .offset = .{ x.tex - x.content, y.tex - y.content } };
        n += 1;
    };
    return n;
}

const Span = struct { content: i32, tex: i32, len: u32 };

fn split(start: i32, len: u32, origin: i32, period: u32, out: *[2]Span) u8 {
    const p: i32 = @intCast(period);
    const t0 = @mod(start + origin, p);
    const first: u32 = @min(len, @as(u32, @intCast(p - t0)));
    out[0] = .{ .content = start, .tex = t0, .len = first };
    if (first == len) return 1;
    out[1] = .{ .content = start + @as(i32, @intCast(first)), .tex = 0, .len = len - first };
    return 2;
}

fn cut(r: PxRect, size: Size) ?PxRect {
    const x0 = @max(r.x, 0);
    const y0 = @max(r.y, 0);
    const x1 = @min(@as(i64, r.x) + r.w, size.w);
    const y1 = @min(@as(i64, r.y) + r.h, size.h);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
}

/// The origin after the content scrolled by `delta` pixels (content that
/// was at y is now at y - delta.y).
pub fn scrolledOrigin(origin: [2]i32, delta: [2]i32, size: Size) [2]i32 {
    return .{ @mod(origin[0] + delta[0], @as(i32, @intCast(size.w))), @mod(origin[1] + delta[1], @as(i32, @intCast(size.h))) };
}

/// The content rects exposed by scrolling a layer of `size` by `delta`
/// (at most one strip per axis; the whole layer when a step is as large
/// as the layer). Returns how many were written to `out`.
pub fn scrollDamage(delta: [2]i32, size: Size, out: *[2]PxRect) u8 {
    const w: i64 = size.w;
    const h: i64 = size.h;
    if (@abs(@as(i64, delta[0])) >= w or @abs(@as(i64, delta[1])) >= h) {
        out[0] = .{ .x = 0, .y = 0, .w = size.w, .h = size.h };
        return 1;
    }
    var n: u8 = 0;
    if (delta[1] != 0) {
        const d: u32 = @intCast(@abs(delta[1]));
        out[n] = .{ .x = 0, .y = if (delta[1] > 0) @intCast(h - d) else 0, .w = size.w, .h = d };
        n += 1;
    }
    if (delta[0] != 0) {
        const d: u32 = @intCast(@abs(delta[0]));
        out[n] = .{ .x = if (delta[0] > 0) @intCast(w - d) else 0, .y = 0, .w = d, .h = size.h };
        n += 1;
    }
    return n;
}

/// `p` moved by (dx, dy) pixels. Positions in `uv` (gradient end points)
/// move with it; texture coordinates and widths do not.
pub fn translatePrim(p: Prim, dx: f32, dy: f32) Prim {
    var q = p;
    q.bounds[0] += dx;
    q.bounds[1] += dy;
    if (q.kind == .linear_gradient) {
        q.uv[0] += dx;
        q.uv[1] += dy;
        q.uv[2] += dx;
        q.uv[3] += dy;
    }
    return q;
}

/// Whether `p` (with the clip table `clips`) can touch a pixel centre
/// inside `r`. Conservative.
pub fn mayTouch(p: *const Prim, clips: []const ClipRect, r: PxRect) bool {
    var c = p.coverRect();
    if (p.clip != 0 and p.clip < clips.len) {
        const b = clips[p.clip].bounds;
        c = .{ @max(c[0], b[0] - 1), @max(c[1], b[1] - 1), @min(c[2], b[0] + b[2] + 1), @min(c[3], b[1] + b[3] + 1) };
    }
    const rx0: f32 = @floatFromInt(r.x);
    const ry0: f32 = @floatFromInt(r.y);
    return c[0] < rx0 + @as(f32, @floatFromInt(r.w)) and c[2] > rx0 and c[1] < ry0 + @as(f32, @floatFromInt(r.h)) and c[3] > ry0;
}

/// Appends, translated by `piece.offset`, the prims of `prims` drawn into
/// layer `z` that may touch the piece's content, to `out_prims`. Their
/// clip indices refer to `clips` translated by the same offset
/// (`appendTranslatedClips`).
pub fn appendTranslated(gpa: std.mem.Allocator, prims: []const Prim, z: u16, clips: []const ClipRect, piece: Piece, out_prims: *std.ArrayList(Prim)) !void {
    const src = piece.content();
    const dx: f32 = @floatFromInt(piece.offset[0]);
    const dy: f32 = @floatFromInt(piece.offset[1]);
    for (prims) |*p| {
        if (p.layer_z != z or !mayTouch(p, clips, src)) continue;
        try out_prims.append(gpa, translatePrim(p.*, dx, dy));
    }
}

/// Appends `clips` translated by `offset` to `out`.
pub fn appendTranslatedClips(gpa: std.mem.Allocator, clips: []const ClipRect, offset: [2]i32, out: *std.ArrayList(ClipRect)) !void {
    const dx: f32 = @floatFromInt(offset[0]);
    const dy: f32 = @floatFromInt(offset[1]);
    try out.ensureUnusedCapacity(gpa, clips.len);
    for (clips) |c| {
        var t = c;
        t.bounds[0] += dx;
        t.bounds[1] += dy;
        out.appendAssumeCapacity(t);
    }
}

/// The layers a backend holds. `Res` is the backend's texture handle.
pub fn LayerTable(comptime Res: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            id: LayerId,
            size: Size,
            kind: LayerKind,
            /// The texture holds complete content.
            valid: bool = false,
            /// Frame number of the last use.
            last_used: u64 = 0,
            res: Res,
        };

        entries: std.ArrayList(Entry) = .empty,

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.entries.deinit(gpa);
        }

        /// The layer `id`, if held. The pointer is valid until the next
        /// `put` or `remove`.
        pub fn find(self: *Self, id: LayerId) ?*Entry {
            for (self.entries.items) |*e| if (e.id == id) return e;
            return null;
        }

        /// Adds a layer (its id must not be held).
        pub fn put(self: *Self, gpa: std.mem.Allocator, e: Entry) !*Entry {
            std.debug.assert(self.find(e.id) == null);
            try self.entries.append(gpa, e);
            return &self.entries.items[self.entries.items.len - 1];
        }

        /// Removes and returns layer `id`.
        pub fn remove(self: *Self, id: LayerId) ?Entry {
            for (self.entries.items, 0..) |e, i| if (e.id == id) return self.entries.swapRemove(i);
            return null;
        }

        /// Marks layer `id` used in `frame`.
        pub fn markUsed(self: *Self, id: LayerId, frame: u64) void {
            if (self.find(id)) |e| e.last_used = frame;
        }

        /// Bytes held by all layers.
        pub fn bytes(self: *const Self) u64 {
            var total: u64 = 0;
            for (self.entries.items) |e| total += layerBytes(e.size);
            return total;
        }

        /// While the layers exceed `budget_bytes`, removes and returns the
        /// least recently used layer not used in `frame` (null when within
        /// budget or only this frame's layers are left). The caller
        /// destroys its texture once no frame in flight uses it.
        pub fn evictOne(self: *Self, budget_bytes: u64, frame: u64) ?Entry {
            if (self.bytes() <= budget_bytes) return null;
            var best: ?usize = null;
            for (self.entries.items, 0..) |e, i| {
                if (e.last_used >= frame) continue;
                if (best == null or e.last_used < self.entries.items[best.?].last_used) best = i;
            }
            return self.entries.swapRemove(best orelse return null);
        }
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "layers: wrapRects 1/2/4 pieces" {
    // Exhaustive over small sizes: every content pixel of the rect lands
    // on exactly one texel, at (x + ox) mod w, (y + oy) mod h.
    var hits: [8 * 8]u8 = undefined;
    var w: u32 = 1;
    while (w <= 5) : (w += 1) {
        var h: u32 = 1;
        while (h <= 4) : (h += 1) {
            const size: Size = .{ .w = w, .h = h };
            var ox: i32 = -6;
            while (ox <= 6) : (ox += 1) {
                var oy: i32 = -5;
                while (oy <= 5) : (oy += 1) {
                    var rx: i32 = -1;
                    while (rx <= @as(i32, @intCast(w))) : (rx += 1) {
                        var ry: i32 = -1;
                        while (ry <= @as(i32, @intCast(h))) : (ry += 1) {
                            var rw: u32 = 1;
                            while (rw <= w + 1) : (rw += 1) {
                                var rh: u32 = 1;
                                while (rh <= h + 1) : (rh += 1) {
                                    const r: PxRect = .{ .x = rx, .y = ry, .w = rw, .h = rh };
                                    var out: [4]Piece = undefined;
                                    const n = wrapRects(r, .{ ox, oy }, size, &out);
                                    @memset(&hits, 0);
                                    for (out[0..n]) |p| {
                                        try testing.expect(p.rect.x >= 0 and p.rect.y >= 0 and p.rect.w > 0 and p.rect.h > 0);
                                        try testing.expect(p.rect.x + @as(i64, p.rect.w) <= w and p.rect.y + @as(i64, p.rect.h) <= h);
                                        var yy: i32 = 0;
                                        while (yy < p.rect.h) : (yy += 1) {
                                            var xx: i32 = 0;
                                            while (xx < p.rect.w) : (xx += 1) {
                                                const tx = p.rect.x + xx;
                                                const ty = p.rect.y + yy;
                                                const cx = tx - p.offset[0];
                                                const cy = ty - p.offset[1];
                                                try testing.expectEqual(@mod(cx + ox, @as(i32, @intCast(w))), tx);
                                                try testing.expectEqual(@mod(cy + oy, @as(i32, @intCast(h))), ty);
                                                hits[@intCast(ty * 8 + tx)] += 1;
                                            }
                                        }
                                    }
                                    // Exactly the part of r inside the layer.
                                    var expect: u32 = 0;
                                    if (cut(r, size)) |c| expect = c.w * c.h;
                                    var got: u32 = 0;
                                    for (hits) |c| {
                                        try testing.expect(c <= 1);
                                        got += c;
                                    }
                                    try testing.expectEqual(expect, got);
                                    const wraps_x = if (cut(r, size)) |c| @mod(c.x + ox, @as(i32, @intCast(w))) + @as(i32, @intCast(c.w)) > w else false;
                                    const wraps_y = if (cut(r, size)) |c| @mod(c.y + oy, @as(i32, @intCast(h))) + @as(i32, @intCast(c.h)) > h else false;
                                    const want: u8 = if (expect == 0) 0 else @as(u8, if (wraps_x) 2 else 1) * @as(u8, if (wraps_y) 2 else 1);
                                    try testing.expectEqual(want, n);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

test "layers: LRU eviction order" {
    const gpa = testing.allocator;
    var t: LayerTable(u32) = .{};
    defer t.deinit(gpa);
    const sz: Size = .{ .w = 16, .h = 16 }; // 1 KiB each
    for (0..5) |i| _ = try t.put(gpa, .{ .id = @enumFromInt(i), .size = sz, .kind = .plain, .last_used = 10 + i, .res = @intCast(i) });
    t.markUsed(@enumFromInt(0), 20); // 0 is now the most recent
    try testing.expectEqual(@as(u64, 5 << 10), t.bytes());
    try testing.expectEqual(@as(?Entry32, null), t.evictOne(5 << 10, 20));
    var order: [3]u32 = undefined;
    for (&order) |*o| o.* = t.evictOne(2 << 10, 20).?.res;
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, &order);
    try testing.expectEqual(@as(?Entry32, null), t.evictOne(2 << 10, 20));
    try testing.expectEqual(@as(u32, 4), t.evictOne(1 << 10, 20).?.res);
    // Layers used this frame are never evicted, even over budget.
    try testing.expectEqual(@as(?Entry32, null), t.evictOne(0, 20));
    try testing.expectEqual(@as(u32, 0), t.evictOne(0, 21).?.res);
    try testing.expectEqual(@as(usize, 0), t.entries.items.len);
}

const Entry32 = LayerTable(u32).Entry;

test "layers: scroll sequence repaint area equals sum of |d|" {
    // Simulates E04 scrolling a 64×100 scroll layer: each step repaints
    // only the exposed strip, and the wrapped pieces cover exactly it.
    const size: Size = .{ .w = 64, .h = 100 };
    const steps = [_]i32{ 3, 3, 3, -7, 40, 99, -99, 1, -1, 57, 57, -12 };
    var origin: [2]i32 = .{ 0, 0 };
    var area: u64 = 0;
    var expect: u64 = 0;
    for (steps) |d| {
        origin = scrolledOrigin(origin, .{ 0, d }, size);
        var strips: [2]PxRect = undefined;
        const n = scrollDamage(.{ 0, d }, size, &strips);
        for (strips[0..n]) |s| {
            var pieces: [4]Piece = undefined;
            const np = wrapRects(s, origin, size, &pieces);
            for (pieces[0..np]) |p| area += @as(u64, p.rect.w) * p.rect.h;
        }
        expect += @as(u64, @abs(d)) * size.w;
    }
    try testing.expectEqual(expect, area);
    // A step of the whole layer or more repaints everything once.
    var strips: [2]PxRect = undefined;
    try testing.expectEqual(@as(u8, 1), scrollDamage(.{ 0, 100 }, size, &strips));
    try testing.expectEqual(@as(u32, 100), strips[0].h);
}

test "layers: translated prims and clips" {
    const gpa = testing.allocator;
    const clips = [_]ClipRect{ .{ .bounds = .{ 0, 0, 0, 0 } }, .{ .bounds = .{ 0, 90, 64, 20 } } };
    const prims = [_]Prim{
        .{ .bounds = .{ 0, 95, 10, 4 }, .kind = .rect, .layer_z = 1, .clip = 1 },
        .{ .bounds = .{ 0, 10, 10, 4 }, .kind = .rect, .layer_z = 1 }, // outside the piece
        .{ .bounds = .{ 0, 95, 10, 4 }, .kind = .linear_gradient, .uv = .{ 0, 95, 10, 99 }, .layer_z = 1 },
        .{ .bounds = .{ 0, 95, 10, 4 }, .kind = .rect, .layer_z = 2 }, // other layer
    };
    var out: std.ArrayList(Prim) = .empty;
    defer out.deinit(gpa);
    const piece: Piece = .{ .rect = .{ .x = 0, .y = 0, .w = 64, .h = 10 }, .offset = .{ 0, -90 } };
    try appendTranslated(gpa, &prims, 1, &clips, piece, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(f32, 5), out.items[0].bounds[1]);
    try testing.expectEqual([4]f32{ 0, 5, 10, 9 }, out.items[1].uv);
    var tc: std.ArrayList(ClipRect) = .empty;
    defer tc.deinit(gpa);
    try appendTranslatedClips(gpa, &clips, piece.offset, &tc);
    try testing.expectEqual(@as(f32, 0), tc.items[1].bounds[1]);
}
