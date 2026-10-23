//! App image textures (E04.F06.S02.T02): the images the app wants on the
//! GPU, as slots every window's renderer mirrors. A slot names its pixels
//! (premultiplied RGBA8, borrowed from the owner, usually `ImageCache`)
//! and a generation; the Host uploads a slot to each window whose copy is
//! older and destroys the textures of removed slots. Paint code draws a
//! slot through its `canvas.TextureId` (`canvas.app_image` set), which the
//! window's `DrawListCanvas` maps to its own texture.

const std = @import("std");
const canvas = @import("../paint/canvas.zig");

const Allocator = std.mem.Allocator;
const TextureId = canvas.TextureId;

/// Every app image slot.
pub const ImageTextures = struct {
    slots: std.ArrayList(Slot) = .empty,
    free: std.ArrayList(u32) = .empty,
    /// Slots removed since the last `recycle`: what the current frame
    /// recorded may still name them, so they are not reused yet.
    retired: std.ArrayList(u32) = .empty,
    /// Changes whenever a slot does; a window whose copy has the same
    /// serial has nothing to upload.
    serial: u64 = 0,
    /// The next generation (never reused, so a recycled slot always
    /// differs from what a window saw before).
    next_gen: u32 = 1,
    /// Texel bytes of the live slots.
    bytes: u64 = 0,

    /// One image.
    pub const Slot = struct {
        w: u32 = 0,
        h: u32 = 0,
        /// `w * h * 4` bytes; must stay valid while the slot is live.
        pixels: []const u8 = &.{},
        gen: u32 = 0,
        live: bool = false,
    };

    /// Frees the table (the Host destroys the textures with its renderers).
    pub fn deinit(t: *ImageTextures, gpa: Allocator) void {
        t.slots.deinit(gpa);
        t.free.deinit(gpa);
        t.retired.deinit(gpa);
        t.* = undefined;
    }

    /// Adds an image; `pixels` must outlive the slot (until `remove`).
    pub fn add(t: *ImageTextures, gpa: Allocator, w: u32, h: u32, pixels: []const u8) Allocator.Error!TextureId {
        std.debug.assert(pixels.len == @as(usize, w) * h * 4);
        const i: u32 = if (t.free.pop()) |i| i else blk: {
            if (t.slots.items.len > canvas.app_image_slot) return error.OutOfMemory;
            try t.slots.append(gpa, .{});
            break :blk @intCast(t.slots.items.len - 1);
        };
        t.slots.items[i] = .{ .w = w, .h = h, .pixels = pixels, .gen = t.bump(), .live = true };
        t.bytes += pixels.len;
        return @enumFromInt(canvas.app_image | i);
    }

    /// Replaces a slot's pixels (an animation frame, a full-size image
    /// after its preview); every window uploads it again.
    pub fn update(t: *ImageTextures, id: TextureId, w: u32, h: u32, pixels: []const u8) void {
        const s = t.slotPtr(id) orelse return;
        std.debug.assert(pixels.len == @as(usize, w) * h * 4);
        t.bytes = t.bytes - s.pixels.len + pixels.len;
        s.* = .{ .w = w, .h = h, .pixels = pixels, .gen = t.bump(), .live = true };
    }

    /// Removes a slot; windows destroy their textures for it.
    pub fn remove(t: *ImageTextures, gpa: Allocator, id: TextureId) void {
        const s = t.slotPtr(id) orelse return;
        t.bytes -= s.pixels.len;
        s.* = .{ .gen = t.bump() };
        t.retired.append(gpa, slotOf(id).?) catch {};
    }

    /// Makes the slots removed before now reusable (as a frame starts).
    pub fn recycle(t: *ImageTextures, gpa: Allocator) void {
        if (t.retired.items.len == 0) return;
        t.free.appendSlice(gpa, t.retired.items) catch return;
        t.retired.clearRetainingCapacity();
    }

    /// After a lost device: every live slot uploads again.
    pub fn invalidate(t: *ImageTextures) void {
        for (t.slots.items) |*s| if (s.live) {
            s.gen = t.bump();
        };
    }

    /// The slot of an app image id, or null for a renderer texture.
    pub fn slotOf(id: TextureId) ?u32 {
        const raw = @intFromEnum(id);
        if (raw & canvas.app_image == 0) return null;
        return raw & canvas.app_image_slot;
    }

    /// `id` sampled with nearest filtering.
    pub fn nearest(id: TextureId) TextureId {
        const raw = @intFromEnum(id);
        if (raw & canvas.app_image == 0) return id;
        return @enumFromInt(raw | canvas.app_image_nearest);
    }

    fn slotPtr(t: *ImageTextures, id: TextureId) ?*Slot {
        const i = slotOf(id) orelse return null;
        if (i >= t.slots.items.len or !t.slots.items[i].live) return null;
        return &t.slots.items[i];
    }

    fn bump(t: *ImageTextures) u32 {
        const g = t.next_gen;
        t.next_gen +%= 1;
        if (t.next_gen == 0) t.next_gen = 1;
        t.serial +%= 1;
        return g;
    }
};

/// What one renderer holds for the slots: a texture, its size and the
/// generation it shows. `sync` brings it up to date.
pub const Mirror = struct {
    tex: std.ArrayList(u32) = .empty,
    gens: std.ArrayList(u32) = .empty,
    sizes: std.ArrayList([2]u32) = .empty,
    serial: u64 = std.math.maxInt(u64),

    /// The renderer operations `sync` uses (texture ids as `u32`).
    pub const Ops = struct {
        ctx: *anyopaque,
        create: *const fn (ctx: *anyopaque, w: u32, h: u32) anyerror!u32,
        update: *const fn (ctx: *anyopaque, tex: u32, w: u32, h: u32, pixels: []const u8) anyerror!void,
        destroy: *const fn (ctx: *anyopaque, tex: u32) void,
    };

    /// Frees the lists (not the textures).
    pub fn deinit(m: *Mirror, gpa: Allocator) void {
        m.tex.deinit(gpa);
        m.gens.deinit(gpa);
        m.sizes.deinit(gpa);
        m.* = undefined;
    }

    /// What a `sync` did.
    pub const Change = enum {
        none,
        /// Pixels changed in textures already mapped.
        uploaded,
        /// A slot got a new texture: what was recorded with the old
        /// mapping must be painted again.
        created,
    };

    /// Uploads changed slots, creates textures for new ones and destroys
    /// those of removed ones. Without `destroy` (after recording a frame
    /// that may still name them), slots that would destroy a texture wait
    /// for a later sync.
    pub fn sync(m: *Mirror, gpa: Allocator, t: *const ImageTextures, ops: Ops, destroy: bool) !Change {
        if (m.serial == t.serial) return .none;
        const n = t.slots.items.len;
        while (m.tex.items.len < n) {
            try m.tex.append(gpa, 0);
            try m.gens.append(gpa, 0);
            try m.sizes.append(gpa, .{ 0, 0 });
        }
        var change: Change = .none;
        var skipped = false;
        for (t.slots.items, 0..) |s, i| {
            if (m.gens.items[i] == s.gen) continue;
            const size = [2]u32{ s.w, s.h };
            if (m.tex.items[i] != 0 and (!s.live or !std.mem.eql(u32, &m.sizes.items[i], &size))) {
                if (!destroy) {
                    skipped = true;
                    continue;
                }
                ops.destroy(ops.ctx, m.tex.items[i]);
                m.tex.items[i] = 0;
            }
            if (change == .none) change = .uploaded;
            if (s.live and s.w > 0 and s.h > 0) {
                if (m.tex.items[i] == 0) {
                    m.tex.items[i] = try ops.create(ops.ctx, s.w, s.h);
                    change = .created;
                }
                try ops.update(ops.ctx, m.tex.items[i], s.w, s.h, s.pixels);
            }
            m.gens.items[i] = s.gen;
            m.sizes.items[i] = size;
        }
        if (!skipped) m.serial = t.serial;
        return change;
    }

    /// Destroys every texture (the renderer is going away or was lost).
    pub fn destroyAll(m: *Mirror, ops: Ops) void {
        for (m.tex.items, m.gens.items) |*x, *g| {
            if (x.* != 0) ops.destroy(ops.ctx, x.*);
            x.* = 0;
            g.* = 0;
        }
        m.serial = std.math.maxInt(u64);
    }
};

const testing = std.testing;

const FakeRenderer = struct {
    next: u32 = 1,
    live: u32 = 0,
    uploads: u32 = 0,

    fn ops(f: *FakeRenderer) Mirror.Ops {
        return .{ .ctx = f, .create = create, .update = upd, .destroy = destroy };
    }
    fn create(ctx: *anyopaque, _: u32, _: u32) anyerror!u32 {
        const f: *FakeRenderer = @ptrCast(@alignCast(ctx));
        f.live += 1;
        f.next += 1;
        return f.next - 1;
    }
    fn upd(ctx: *anyopaque, _: u32, _: u32, _: u32, _: []const u8) anyerror!void {
        const f: *FakeRenderer = @ptrCast(@alignCast(ctx));
        f.uploads += 1;
    }
    fn destroy(ctx: *anyopaque, _: u32) void {
        const f: *FakeRenderer = @ptrCast(@alignCast(ctx));
        f.live -= 1;
    }
};

test "slots mirror into a renderer: add, update, remove, device lost" {
    const gpa = testing.allocator;
    var t: ImageTextures = .{};
    defer t.deinit(gpa);
    var m: Mirror = .{};
    defer m.deinit(gpa);
    var r: FakeRenderer = .{};
    const px = [_]u8{0} ** 16;
    const a = try t.add(gpa, 2, 2, &px);
    try testing.expect(ImageTextures.slotOf(a) != null);
    try testing.expectEqual(Mirror.Change.created, try m.sync(gpa, &t, r.ops(), true));
    try testing.expectEqual(@as(u32, 1), r.live);
    try testing.expectEqual(Mirror.Change.none, try m.sync(gpa, &t, r.ops(), true));
    // A new size needs a new texture: not while a recorded frame may
    // name the old one.
    t.update(a, 1, 1, px[0..4]);
    try testing.expectEqual(Mirror.Change.none, try m.sync(gpa, &t, r.ops(), false));
    t.update(a, 2, 2, &px);
    try testing.expectEqual(Mirror.Change.uploaded, try m.sync(gpa, &t, r.ops(), true));
    try testing.expectEqual(@as(u32, 2), r.uploads);
    try testing.expectEqual(@as(u32, 1), r.live);
    // Device lost: the renderer's textures are gone; everything uploads
    // again into new ones.
    m.destroyAll(r.ops());
    t.invalidate();
    _ = try m.sync(gpa, &t, r.ops(), true);
    try testing.expectEqual(@as(u32, 1), r.live);
    try testing.expectEqual(@as(u32, 3), r.uploads);
    t.remove(gpa, a);
    _ = try m.sync(gpa, &t, r.ops(), true);
    try testing.expectEqual(@as(u32, 0), r.live);
    try testing.expectEqual(@as(u64, 0), t.bytes);
    // A removed slot is reused only after `recycle`, with a new
    // generation.
    const c = try t.add(gpa, 2, 2, &px);
    try testing.expect(ImageTextures.slotOf(c) != ImageTextures.slotOf(a));
    t.remove(gpa, c);
    t.recycle(gpa);
    const b = try t.add(gpa, 2, 2, &px);
    try testing.expectEqual(ImageTextures.slotOf(c), ImageTextures.slotOf(b));
    _ = try m.sync(gpa, &t, r.ops(), true);
    try testing.expectEqual(@as(u32, 1), r.live);
    m.destroyAll(r.ops());
    try testing.expect(ImageTextures.nearest(b) != b);
}
