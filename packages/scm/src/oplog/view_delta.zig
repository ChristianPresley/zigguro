//! Delta-encoded views (E09.F03.S02.T01). A view larger than 4 KiB is
//! stored as a patch against the full view its parent operation's view
//! derives from, so 100k operations over a large view stay cheap. The
//! stored object is still a `View`: an empty one whose `extra` holds
//!
//! - `delta`: the patch, over the canonical encodings of the two views;
//! - `delta_base`: the full view's ID;
//! - `delta_depth`: how many patched views since that full one (one byte).
//!
//! Patches always apply to a full view, so reading one costs two reads.
//! After `max_depth` patched views, or once a patch is no longer much
//! smaller than the view, a full view is stored again.
//! The patch is a list of operations, each a tag byte and LEB128 numbers:
//! `0 offset len` copies from the base, `1 len bytes` inserts. It starts
//! with the target length, which is checked.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const enc = @import("../store/encode.zig");
const store_mod = @import("../store/store.zig");
const view_mod = @import("view.zig");
const ObjectId = id_mod.ObjectId;
const Store = store_mod.Store;
const WriteBatch = store_mod.WriteBatch;
const View = view_mod.View;
const Allocator = std.mem.Allocator;

/// Views encoding to at most this many bytes are stored whole.
pub const min_delta_size = 4096;
/// Patched views per full view.
pub const max_depth = 16;

const key_delta = "delta";
const key_base = "delta_base";
const key_depth = "delta_depth";

pub const Error = error{ CorruptObject, WrongKind, DeltaTooDeep } || store_mod.ReadError || Allocator.Error;

/// The patch fields of a stored view, when it is a delta.
pub const DeltaRef = struct { patch: []const u8, base: ObjectId, depth: u8 };

/// A view's full canonical encoding and how many patches deep it was.
pub const Resolved = struct { bytes: []const u8, depth: u8 };

pub fn deltaOf(v: View) ?DeltaRef {
    if (v.extra.len != 3) return null;
    if (!std.mem.eql(u8, v.extra[0].key, key_delta) or !std.mem.eql(u8, v.extra[1].key, key_base) or
        !std.mem.eql(u8, v.extra[2].key, key_depth)) return null;
    if (v.extra[1].value.len != 32 or v.extra[2].value.len != 1) return null;
    var base: ObjectId = undefined;
    @memcpy(&base.bytes, v.extra[1].value);
    return .{ .patch = v.extra[0].value, .base = base, .depth = v.extra[2].value[0] };
}

/// The canonical encoding of view `id`, patches applied, and its depth.
pub fn readBytes(s: *Store, arena: Allocator, id: ObjectId) Error!Resolved {
    const r = try s.read(id);
    defer r.release();
    if (r.kind != .view) return error.WrongKind;
    const raw = try arena.dupe(u8, r.bytes);
    return resolve(s, arena, raw, 0);
}

/// `raw` (a stored view) as full canonical bytes.
pub fn resolve(s: *Store, arena: Allocator, raw: []const u8, hops: u32) Error!Resolved {
    const v = enc.decode(View, arena, raw) catch return error.CorruptObject;
    const d = deltaOf(v) orelse return .{ .bytes = raw, .depth = 0 };
    if (hops >= max_depth) return error.DeltaTooDeep;
    const r = try s.read(d.base);
    defer r.release();
    if (r.kind != .view) return error.CorruptObject;
    const base_raw = try arena.dupe(u8, r.bytes);
    const base = try resolve(s, arena, base_raw, hops + 1);
    return .{ .bytes = try apply(arena, base.bytes, d.patch), .depth = d.depth };
}

/// Reads view `id`, applying patches.
pub fn read(s: *Store, arena: Allocator, id: ObjectId) Error!View {
    const full = try readBytes(s, arena, id);
    return enc.decode(View, arena, full.bytes) catch error.CorruptObject;
}

/// Writes `v` into `b`, as a patch when that pays. `parent` is the view
/// of the operation `v` follows.
pub fn write(gpa: Allocator, s: *Store, b: *WriteBatch, v: View, parent: ?ObjectId) !ObjectId {
    const full = try enc.encodeAlloc(gpa, View, v);
    defer gpa.free(full);
    if (full.len > min_delta_size) {
        if (parent) |parent_id| {
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            // Patch against the full view the parent is (or patches).
            const pr = try s.read(parent_id);
            const parent_raw = arena.dupe(u8, pr.bytes) catch |e| {
                pr.release();
                return e;
            };
            pr.release();
            const pv = enc.decode(View, arena, parent_raw) catch return error.CorruptObject;
            const pd = deltaOf(pv);
            const base_id = if (pd) |d| d.base else parent_id;
            const seq: u8 = if (pd) |d| d.depth else 0;
            if (seq < max_depth) {
                const base = if (pd == null) parent_raw else (try readBytes(s, arena, base_id)).bytes;
                const patch = try diff(arena, base, full);
                if (patch.len < full.len / 2) {
                    var dv = View.empty;
                    var depth = [1]u8{seq + 1};
                    const extra = [_]object.Extra{
                        .{ .key = key_delta, .value = patch },
                        .{ .key = key_base, .value = &base_id.bytes },
                        .{ .key = key_depth, .value = &depth },
                    };
                    dv.extra = &extra;
                    const bytes = try enc.encodeAlloc(arena, View, dv);
                    return b.put(.view, bytes);
                }
            }
        }
    }
    return b.put(.view, full);
}

fn writeUleb(out: *std.ArrayList(u8), gpa: Allocator, x: usize) Allocator.Error!void {
    var v = x;
    while (true) {
        const byte: u8 = @truncate(v & 0x7f);
        v >>= 7;
        if (v == 0) return out.append(gpa, byte);
        try out.append(gpa, byte | 0x80);
    }
}

fn readUleb(p: []const u8, pos: *usize) error{CorruptObject}!usize {
    var x: usize = 0;
    var shift: u6 = 0;
    while (pos.* < p.len) {
        const byte = p[pos.*];
        pos.* += 1;
        x |= @as(usize, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return x;
        if (shift >= 56) return error.CorruptObject;
        shift += 7;
    }
    return error.CorruptObject;
}

const block = 16;

fn blockHash(b: []const u8) u32 {
    const x = std.mem.readInt(u64, b[0..8], .little) *% 0x9e3779b97f4a7c15;
    const y = std.mem.readInt(u64, b[8..16], .little) *% 0xc2b2ae3d27d4eb4f;
    return @truncate((x ^ std.math.rotl(u64, y, 31)) >> 32);
}

/// A patch turning `base` into `target`: copies of 16-byte-aligned base
/// blocks found in `target` (extended both ways), inserts for the rest.
pub fn diff(gpa: Allocator, base: []const u8, target: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try writeUleb(&out, gpa, target.len);
    var table: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer table.deinit(gpa);
    var k: usize = 0;
    while (k + block <= base.len) : (k += block) {
        const gop = try table.getOrPut(gpa, blockHash(base[k..]));
        if (!gop.found_existing) gop.value_ptr.* = @intCast(k);
    }
    var lit_start: usize = 0;
    var i: usize = 0;
    while (i + block <= target.len) {
        const at = table.get(blockHash(target[i..])) orelse {
            i += 1;
            continue;
        };
        if (!std.mem.eql(u8, base[at..][0..block], target[i..][0..block])) {
            i += 1;
            continue;
        }
        // Extend backwards into the pending literal, then forwards.
        var start_t = i;
        var start_b: usize = at;
        while (start_t > lit_start and start_b > 0 and base[start_b - 1] == target[start_t - 1]) {
            start_t -= 1;
            start_b -= 1;
        }
        var end_t = i + block;
        var end_b: usize = at + block;
        while (end_t < target.len and end_b < base.len and base[end_b] == target[end_t]) {
            end_t += 1;
            end_b += 1;
        }
        if (start_t > lit_start) {
            try out.append(gpa, 1);
            try writeUleb(&out, gpa, start_t - lit_start);
            try out.appendSlice(gpa, target[lit_start..start_t]);
        }
        try out.append(gpa, 0);
        try writeUleb(&out, gpa, start_b);
        try writeUleb(&out, gpa, end_b - start_b);
        i = end_t;
        lit_start = end_t;
    }
    if (lit_start < target.len) {
        try out.append(gpa, 1);
        try writeUleb(&out, gpa, target.len - lit_start);
        try out.appendSlice(gpa, target[lit_start..]);
    }
    return out.toOwnedSlice(gpa);
}

/// Applies `patch` to `base`.
pub fn apply(gpa: Allocator, base: []const u8, patch: []const u8) error{ CorruptObject, OutOfMemory }![]u8 {
    var pos: usize = 0;
    const len = try readUleb(patch, &pos);
    // Copies may repeat base bytes, but every operation takes at least
    // two patch bytes.
    if (len > 64 << 20 or len > (patch.len / 2) * base.len + patch.len) return error.CorruptObject;
    const out = try gpa.alloc(u8, len);
    errdefer gpa.free(out);
    var n: usize = 0;
    while (pos < patch.len) {
        const tag = patch[pos];
        pos += 1;
        switch (tag) {
            0 => {
                const off = try readUleb(patch, &pos);
                const l = try readUleb(patch, &pos);
                if (off > base.len or l > base.len - off or l > len - n) return error.CorruptObject;
                @memcpy(out[n..][0..l], base[off..][0..l]);
                n += l;
            },
            1 => {
                const l = try readUleb(patch, &pos);
                if (l > patch.len - pos or l > len - n) return error.CorruptObject;
                @memcpy(out[n..][0..l], patch[pos..][0..l]);
                pos += l;
                n += l;
            },
            else => return error.CorruptObject,
        }
    }
    if (n != len) return error.CorruptObject;
    return out;
}

const testing = std.testing;

test "view delta: diff and apply round-trip" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(3);
    const r = prng.random();
    for (0..200) |_| {
        const base = try gpa.alloc(u8, r.uintLessThan(usize, 20_000));
        defer gpa.free(base);
        r.bytes(base);
        // Edit: a few insertions, deletions and overwrites.
        var target: std.ArrayList(u8) = .empty;
        defer target.deinit(gpa);
        try target.appendSlice(gpa, base);
        for (0..r.uintLessThan(usize, 6)) |_| {
            const at = r.uintAtMost(usize, target.items.len);
            switch (r.uintLessThan(u8, 3)) {
                0 => {
                    var ins: [40]u8 = undefined;
                    r.bytes(&ins);
                    try target.insertSlice(gpa, at, ins[0..r.uintAtMost(usize, 40)]);
                },
                1 => {
                    const l = @min(target.items.len - at, r.uintAtMost(usize, 64));
                    target.replaceRangeAssumeCapacity(at, l, &.{});
                },
                else => if (at < target.items.len) {
                    target.items[at] ^= 0x5a;
                },
            }
        }
        const patch = try diff(gpa, base, target.items);
        defer gpa.free(patch);
        const got = try apply(gpa, base, patch);
        defer gpa.free(got);
        try testing.expectEqualSlices(u8, target.items, got);
        if (base.len > 4096) try testing.expect(patch.len < base.len / 4);
    }
}

test "fuzz: view delta apply" {
    try testing.fuzz({}, struct {
        fn one(_: void, sm: *testing.Smith) anyerror!void {
            var base: [256]u8 = undefined;
            var patch: [256]u8 = undefined;
            const b = base[0..sm.slice(&base)];
            const p = patch[0..sm.slice(&patch)];
            const out = apply(testing.allocator, b, p) catch return;
            testing.allocator.free(out);
        }
    }.one, .{});
}
