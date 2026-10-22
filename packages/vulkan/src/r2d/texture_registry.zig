//! CPU copies of a GPU renderer's textures, kept so they can be uploaded
//! again after a device loss (E02.F02.S02.T01). Indexed by `TextureId`;
//! every `updateTexture` is applied here too. Pure.

const std = @import("std");
const types = @import("types.zig");

const TextureId = types.TextureId;
const TextureDesc = types.TextureDesc;
const PxRect = types.PxRect;

/// One texture's description and texels (tightly packed rows).
pub const Shadow = struct {
    desc: TextureDesc,
    pixels: []u8,

    pub fn rowBytes(self: Shadow) u32 {
        return self.desc.width * self.desc.format.bytesPerTexel();
    }
};

const TextureRegistry = @This();

/// Shadows by id; null when free. Index 0 is "no texture".
entries: std.ArrayList(?Shadow) = .empty,

pub fn deinit(self: *TextureRegistry, gpa: std.mem.Allocator) void {
    for (self.entries.items) |e| if (e) |sh| gpa.free(sh.pixels);
    self.entries.deinit(gpa);
}

/// Records a new zeroed texture under `id` (the backend chose it).
pub fn put(self: *TextureRegistry, gpa: std.mem.Allocator, id: TextureId, desc: TextureDesc) error{OutOfMemory}!void {
    const i = @intFromEnum(id);
    std.debug.assert(i != 0);
    const len = @as(usize, desc.width) * desc.height * desc.format.bytesPerTexel();
    const px = try gpa.alloc(u8, len);
    errdefer gpa.free(px);
    @memset(px, 0);
    while (self.entries.items.len <= i) try self.entries.append(gpa, null);
    if (self.entries.items[i]) |old| gpa.free(old.pixels);
    self.entries.items[i] = .{ .desc = desc, .pixels = px };
}

pub fn get(self: *const TextureRegistry, id: TextureId) ?Shadow {
    const i = @intFromEnum(id);
    if (i == 0 or i >= self.entries.items.len) return null;
    return self.entries.items[i];
}

/// Copies `rect` from `data` (`row_pitch` bytes per row) into the copy.
pub fn update(self: *TextureRegistry, id: TextureId, rect: PxRect, data: []const u8, row_pitch: u32) error{InvalidArgument}!void {
    const sh = self.get(id) orelse return error.InvalidArgument;
    if (rect.x < 0 or rect.y < 0 or rect.w == 0 or rect.h == 0) return error.InvalidArgument;
    const x: u32 = @intCast(rect.x);
    const y: u32 = @intCast(rect.y);
    if (x + rect.w > sh.desc.width or y + rect.h > sh.desc.height) return error.InvalidArgument;
    const bpp = sh.desc.format.bytesPerTexel();
    const row = rect.w * bpp;
    if (row_pitch < row or data.len < @as(usize, row_pitch) * (rect.h - 1) + row) return error.InvalidArgument;
    const stride = sh.rowBytes();
    for (0..rect.h) |r| {
        const dst = (y + r) * stride + x * bpp;
        @memcpy(sh.pixels[dst..][0..row], data[r * row_pitch ..][0..row]);
    }
}

pub fn remove(self: *TextureRegistry, gpa: std.mem.Allocator, id: TextureId) void {
    const sh = self.get(id) orelse return;
    gpa.free(sh.pixels);
    self.entries.items[@intFromEnum(id)] = null;
}

/// The lowest unused id (for textures created while no backend runs).
pub fn freeId(self: *const TextureRegistry) TextureId {
    for (self.entries.items[@min(1, self.entries.items.len)..], 1..) |e, i| {
        if (e == null) return @enumFromInt(i);
    }
    return @enumFromInt(@max(1, self.entries.items.len));
}

/// Bytes of texels held.
pub fn bytes(self: *const TextureRegistry) u64 {
    var n: u64 = 0;
    for (self.entries.items) |e| if (e) |sh| {
        n += sh.pixels.len;
    };
    return n;
}

test "texture registry: updates land in the copy" {
    const gpa = std.testing.allocator;
    var reg: TextureRegistry = .{};
    defer reg.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(reg.freeId()));
    try reg.put(gpa, @enumFromInt(2), .{ .width = 4, .height = 3, .format = .rgba8 });
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(reg.freeId()));
    try reg.put(gpa, @enumFromInt(1), .{ .width = 2, .height = 2, .format = .r8 });
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(reg.freeId()));

    // A 2x2 rect at (1,1) from rows padded to 12 bytes.
    var src: [24]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i + 1);
    try reg.update(@enumFromInt(2), .{ .x = 1, .y = 1, .w = 2, .h = 2 }, &src, 12);
    const sh = reg.get(@enumFromInt(2)).?;
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 16, sh.pixels[0..16]);
    try std.testing.expectEqualSlices(u8, src[0..8], sh.pixels[16 + 4 ..][0..8]);
    try std.testing.expectEqualSlices(u8, src[12..20], sh.pixels[32 + 4 ..][0..8]);
    try std.testing.expectEqual(@as(u64, 48 + 4), reg.bytes());

    try std.testing.expectError(error.InvalidArgument, reg.update(@enumFromInt(2), .{ .x = 3, .y = 0, .w = 2, .h = 1 }, &src, 8));
    try std.testing.expectError(error.InvalidArgument, reg.update(@enumFromInt(2), .{ .x = 0, .y = 0, .w = 2, .h = 2 }, src[0..9], 8));
    try std.testing.expectError(error.InvalidArgument, reg.update(@enumFromInt(5), .{ .x = 0, .y = 0, .w = 1, .h = 1 }, &src, 4));

    reg.remove(gpa, @enumFromInt(1));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(reg.freeId()));
    try std.testing.expectEqual(@as(?Shadow, null), reg.get(@enumFromInt(1)));
}
