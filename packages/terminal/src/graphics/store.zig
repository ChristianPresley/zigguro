//! The terminal's images and their placements (E06.F08.S01.T01).
//!
//! An image is premultiplied RGBA8 pixels, shared by reference count with
//! whoever draws them (the view keeps a texture of it alive). A placement
//! puts an image on a screen: anchored at a tracked pin, so it moves with
//! its row through scrolling and reflow, `cols` x `rows` cells big, with a
//! source rectangle, a pixel offset inside its first cell and a z-index.
//!
//! The store keeps at most `quota` bytes of pixels: past it, the least
//! recently used images without placements are dropped first, then any.

const std = @import("std");
const Allocator = std.mem.Allocator;
const PageList = @import("../screen/PageList.zig");
const TrackedPin = PageList.TrackedPin;

/// Decoded pixels, shared by reference count.
pub const Pixels = struct {
    gpa: Allocator,
    refs: u32 = 1,
    w: u32,
    h: u32,
    /// `w * h * 4` bytes, premultiplied RGBA.
    rgba: []u8,

    /// Takes ownership of `rgba`.
    pub fn create(gpa: Allocator, w: u32, h: u32, rgba: []u8) !*Pixels {
        const p = try gpa.create(Pixels);
        p.* = .{ .gpa = gpa, .w = w, .h = h, .rgba = rgba };
        return p;
    }

    pub fn retain(p: *Pixels) *Pixels {
        p.refs += 1;
        return p;
    }

    pub fn release(p: *Pixels) void {
        p.refs -= 1;
        if (p.refs > 0) return;
        p.gpa.free(p.rgba);
        p.gpa.destroy(p);
    }
};

pub const Image = struct {
    id: u32,
    /// The client's image number (`I`), 0 when none.
    number: u32 = 0,
    pixels: *Pixels,
    /// The store's use clock when it was last placed or transmitted.
    last_use: u64 = 0,
    /// Freed with its last placement (sixel images, which have no id a
    /// client could place again).
    transient: bool = false,
};

pub const ScreenId = enum(u1) { primary, alternate };

pub const Placement = struct {
    image_id: u32,
    /// The client's placement id (`p`), 0 when none.
    id: u32 = 0,
    screen: ScreenId,
    /// The anchor: the image's top-left cell.
    pin: *TrackedPin,
    cols: u16,
    rows: u16,
    /// Source rectangle in image pixels (`w`/`h` 0: to the edge).
    src_x: u32 = 0,
    src_y: u32 = 0,
    src_w: u32 = 0,
    src_h: u32 = 0,
    /// The drawn size, in the terminal's cell pixels (`Terminal.cell_px`).
    px_w: u32 = 0,
    px_h: u32 = 0,
    /// Offset inside the anchor cell, in pixels.
    off_x: u32 = 0,
    off_y: u32 = 0,
    z: i32 = 0,
    /// A Unicode-placeholder (virtual) placement: kept, not drawn.
    virtual: bool = false,
};

pub const Store = struct {
    gpa: Allocator,
    images: std.AutoArrayHashMapUnmanaged(u32, Image) = .empty,
    placements: std.ArrayList(Placement) = .empty,
    /// Pixel bytes held.
    bytes: usize = 0,
    quota: usize = 256 << 20,
    clock: u64 = 0,
    /// Changes whenever an image or placement does (the view redraws).
    serial: u64 = 0,
    /// The next id handed to an image transmitted with only a number.
    next_auto_id: u32 = 0x8000_0000,

    pub fn init(gpa: Allocator) Store {
        return .{ .gpa = gpa };
    }

    /// Frees everything; `pls` are the lists the pins live in (null when
    /// they are already freed).
    pub fn deinit(s: *Store, pls: ?[2]*PageList) void {
        if (pls) |l| for (s.placements.items) |p| l[@intFromEnum(p.screen)].untrack(p.pin);
        s.placements.deinit(s.gpa);
        for (s.images.values()) |img| img.pixels.release();
        s.images.deinit(s.gpa);
        s.* = undefined;
    }

    pub fn get(s: *Store, id: u32) ?*Image {
        return s.images.getPtr(id);
    }

    /// The newest image with client number `n`.
    pub fn byNumber(s: *Store, n: u32) ?*Image {
        var best: ?*Image = null;
        for (s.images.values()) |*img| if (img.number == n and (best == null or img.last_use >= best.?.last_use)) {
            best = img;
        };
        return best;
    }

    pub fn autoId(s: *Store) u32 {
        while (s.images.contains(s.next_auto_id)) s.next_auto_id +%= 1;
        defer s.next_auto_id +%= 1;
        return s.next_auto_id;
    }

    /// Adds `pixels` as image `id` (taking the reference), replacing an
    /// image with that id and its placements, then enforces the quota.
    pub fn put(s: *Store, pls: [2]*PageList, id: u32, number: u32, pixels: *Pixels) !void {
        if (s.images.contains(id)) s.removeImage(pls, id);
        s.clock += 1;
        try s.images.put(s.gpa, id, .{ .id = id, .number = number, .pixels = pixels, .last_use = s.clock });
        s.bytes += pixels.rgba.len;
        s.serial +%= 1;
        s.enforceQuota(pls, id);
    }

    /// Removes image `id` and its placements.
    pub fn removeImage(s: *Store, pls: [2]*PageList, id: u32) void {
        var i: usize = 0;
        while (i < s.placements.items.len) {
            if (s.placements.items[i].image_id == id) s.removePlacement(pls, i) else i += 1;
        }
        const kv = s.images.fetchSwapRemove(id) orelse return;
        s.bytes -= kv.value.pixels.rgba.len;
        kv.value.pixels.release();
        s.serial +%= 1;
    }

    /// Adds a placement (replacing one with the same image and non-zero
    /// placement id); the store takes the pin.
    pub fn place(s: *Store, pls: [2]*PageList, p: Placement) !void {
        if (p.id != 0) for (s.placements.items, 0..) |q, i| if (q.image_id == p.image_id and q.id == p.id) {
            s.removePlacement(pls, i);
            break;
        };
        errdefer pls[@intFromEnum(p.screen)].untrack(p.pin);
        try s.placements.append(s.gpa, p);
        s.clock += 1;
        if (s.images.getPtr(p.image_id)) |img| img.last_use = s.clock;
        s.serial +%= 1;
    }

    pub fn removePlacement(s: *Store, pls: [2]*PageList, i: usize) void {
        const p = s.placements.orderedRemove(i);
        pls[@intFromEnum(p.screen)].untrack(p.pin);
        s.serial +%= 1;
        if (s.images.get(p.image_id)) |img| if (img.transient and !s.hasPlacements(p.image_id)) s.removeImage(pls, p.image_id);
    }

    pub fn hasPlacements(s: *const Store, id: u32) bool {
        for (s.placements.items) |p| if (p.image_id == id) return true;
        return false;
    }

    /// Drops placements whose rows are gone for good (evicted, erased);
    /// rows that are only cold come back.
    pub fn prune(s: *Store, pls: [2]*PageList) void {
        var i: usize = 0;
        while (i < s.placements.items.len) {
            const t = s.placements.items[i].pin;
            if (t.garbage and t.cold == null) s.removePlacement(pls, i) else i += 1;
        }
    }

    /// Removes every placement on `screen` (and, with `free`, the images
    /// left without one).
    pub fn clearScreen(s: *Store, pls: [2]*PageList, screen: ScreenId, free: bool) void {
        var i: usize = 0;
        while (i < s.placements.items.len) {
            if (s.placements.items[i].screen == screen) s.removePlacement(pls, i) else i += 1;
        }
        if (free) s.freeUnplaced(pls);
    }

    /// Frees images that no placement shows.
    pub fn freeUnplaced(s: *Store, pls: [2]*PageList) void {
        var i: usize = 0;
        while (i < s.images.count()) {
            const id = s.images.keys()[i];
            if (!s.hasPlacements(id)) s.removeImage(pls, id) else i += 1;
        }
    }

    /// Drops least recently used images until under the quota, those
    /// without placements first; `keep` (just added) goes last.
    fn enforceQuota(s: *Store, pls: [2]*PageList, keep: u32) void {
        inline for (.{ true, false }) |unplaced_only| {
            while (s.bytes > s.quota) {
                var victim: ?u32 = null;
                var oldest: u64 = std.math.maxInt(u64);
                for (s.images.values()) |img| {
                    if (img.id == keep) continue;
                    if (unplaced_only and s.hasPlacements(img.id)) continue;
                    if (img.last_use < oldest) {
                        oldest = img.last_use;
                        victim = img.id;
                    }
                }
                s.removeImage(pls, victim orelse break);
            }
        }
    }
};
