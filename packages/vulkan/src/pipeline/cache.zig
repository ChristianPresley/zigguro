//! The persisted pipeline cache (E02.F05.S02.T01).
//!
//! File: `<dir>/pipelines-<vendorID>-<deviceID>.bin`, our 40-byte header
//! then the driver's blob:
//!
//! | bytes | field |
//! |---|---|
//! | 0..4 | magic "ZGPC" |
//! | 4..8 | version (1), little-endian |
//! | 8..16 | Wyhash of the payload |
//! | 16..24 | payload length |
//! | 24..40 | shader interface hash and shader build id |
//!
//! The file is untrusted: `parse` bounds-checks everything, then checks
//! the Vulkan header (`headerSize` 32, `headerVersion` ONE, vendor and
//! device ids, `pipelineCacheUUID`) before any byte reaches the driver.
//! Saving writes `<name>.tmp`, syncs and renames, so a crash mid-save
//! leaves the previous file intact.

const std = @import("std");
const vk = @import("../vk/vk.zig");
const Gpu = @import("../gpu/Gpu.zig");

const log = std.log.scoped(.zg_vulkan);

pub const magic = "ZGPC";
pub const version: u32 = 1;
pub const header_len = 40;
/// Larger files are ignored.
pub const max_file_bytes = 64 << 20;
const vk_header_len = 32;

/// What a cache file must match.
pub const Expect = struct {
    vendor_id: u32,
    device_id: u32,
    uuid: [vk.uuid_size]u8,
    /// Shader interface hash and build id.
    shaders: [16]u8,
};

pub const Reject = enum {
    too_small,
    too_large,
    bad_magic,
    bad_version,
    length_mismatch,
    checksum,
    shaders_changed,
    vk_header_size,
    vk_header_version,
    vendor,
    device,
    uuid,
};

pub const Parsed = union(enum) {
    /// The driver blob, safe to pass as `pInitialData`.
    ok: []const u8,
    rejected: Reject,
};

fn le32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .little);
}

fn le64(b: []const u8) u64 {
    return std.mem.readInt(u64, b[0..8], .little);
}

/// Validates a cache file. Pure; never reads out of bounds.
pub fn parse(bytes: []const u8, expect: Expect) Parsed {
    if (bytes.len > max_file_bytes) return .{ .rejected = .too_large };
    if (bytes.len < header_len + vk_header_len) return .{ .rejected = .too_small };
    if (!std.mem.eql(u8, bytes[0..4], magic)) return .{ .rejected = .bad_magic };
    if (le32(bytes[4..]) != version) return .{ .rejected = .bad_version };
    const payload = bytes[header_len..];
    if (le64(bytes[16..]) != payload.len) return .{ .rejected = .length_mismatch };
    if (le64(bytes[8..]) != std.hash.Wyhash.hash(0, payload)) return .{ .rejected = .checksum };
    if (!std.mem.eql(u8, bytes[24..40], &expect.shaders)) return .{ .rejected = .shaders_changed };
    // VkPipelineCacheHeaderVersionOne, in host byte order (little-endian
    // on every supported target).
    if (le32(payload[0..]) != vk_header_len) return .{ .rejected = .vk_header_size };
    if (le32(payload[4..]) != @intFromEnum(vk.PipelineCacheHeaderVersion.one)) return .{ .rejected = .vk_header_version };
    if (le32(payload[8..]) != expect.vendor_id) return .{ .rejected = .vendor };
    if (le32(payload[12..]) != expect.device_id) return .{ .rejected = .device };
    if (!std.mem.eql(u8, payload[16..32], &expect.uuid)) return .{ .rejected = .uuid };
    return .{ .ok = payload };
}

/// Our header for `blob`.
pub fn header(blob: []const u8, shaders: [16]u8) [header_len]u8 {
    var h: [header_len]u8 = undefined;
    @memcpy(h[0..4], magic);
    std.mem.writeInt(u32, h[4..8], version, .little);
    std.mem.writeInt(u64, h[8..16], std.hash.Wyhash.hash(0, blob), .little);
    std.mem.writeInt(u64, h[16..24], blob.len, .little);
    @memcpy(h[24..40], &shaders);
    return h;
}

/// `pipelines-<vendor>-<device>.bin` (hex ids).
pub fn fileName(buf: []u8, vendor_id: u32, device_id: u32) []const u8 {
    return std.fmt.bufPrint(buf, "pipelines-{x:0>4}-{x:0>4}.bin", .{ vendor_id, device_id }) catch unreachable;
}

/// A `VkPipelineCache` loaded from disk when a valid file exists.
pub const PipelineCache = struct {
    gpu: *Gpu,
    handle: vk.PipelineCache = .null_handle,
    expect: Expect,
    /// The driver blob size at load (0 for an empty cache).
    initial_size: usize = 0,
    /// True when the file passed validation and was given to the driver.
    loaded: bool = false,
    /// Why a present file was ignored.
    rejected: ?Reject = null,
    /// Pipelines created through this cache since load or save.
    created: u32 = 0,

    /// Loads `<dir>/pipelines-*.bin` (if `dir` is set) for `gpu` and
    /// shader identity `shaders`. Never fails: any problem gives an empty
    /// cache (or none at all, if even that fails).
    pub fn load(io: std.Io, gpu: *Gpu, dir: ?std.Io.Dir, shaders: [16]u8) PipelineCache {
        var self: PipelineCache = .{ .gpu = gpu, .expect = .{
            .vendor_id = gpu.info.vendor_id,
            .device_id = gpu.info.device_id,
            .uuid = gpu.info.pipeline_cache_uuid,
            .shaders = shaders,
        } };
        var initial: []const u8 = &.{};
        var file_buf: ?[]u8 = null;
        defer if (file_buf) |b| gpu.gpa.free(b);
        if (dir) |d| {
            var name_buf: [64]u8 = undefined;
            const name = fileName(&name_buf, self.expect.vendor_id, self.expect.device_id);
            if (d.readFileAlloc(io, name, gpu.gpa, .limited(max_file_bytes + 1))) |bytes| {
                file_buf = bytes;
                switch (parse(bytes, self.expect)) {
                    .ok => |blob| initial = blob,
                    .rejected => |r| {
                        self.rejected = r;
                        log.info("pipeline cache {s} ignored: {t}", .{ name, r });
                    },
                }
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => log.info("pipeline cache {s} unreadable: {t}", .{ name, err }),
            }
        }
        const d = &gpu.ddisp;
        if (vk.check(d.create_pipeline_cache(gpu.dev, &.{ .initial_data_size = initial.len, .p_initial_data = if (initial.len > 0) initial.ptr else null }, null, &self.handle))) |_| {
            self.loaded = initial.len > 0;
            self.initial_size = initial.len;
        } else |_| {
            // A driver that rejects the data: start empty.
            self.handle = .null_handle;
            if (initial.len > 0) _ = vk.check(d.create_pipeline_cache(gpu.dev, &.{ .initial_data_size = 0 }, null, &self.handle)) catch {
                self.handle = .null_handle;
            };
        }
        if (self.handle != .null_handle) gpu.name(self.handle, "pipeline-cache");
        return self;
    }

    pub fn destroy(self: *PipelineCache) void {
        if (self.handle != .null_handle) self.gpu.ddisp.destroy_pipeline_cache(self.gpu.dev, self.handle, null);
        self.* = undefined;
    }

    /// Writes the cache to `dir` atomically when pipelines were created
    /// or its size changed since load or the last save. Errors are logged
    /// and otherwise ignored.
    pub fn saveIfChanged(self: *PipelineCache, io: std.Io, dir: std.Io.Dir) void {
        self.save(io, dir) catch |err| log.info("pipeline cache not saved: {t}", .{err});
    }

    fn save(self: *PipelineCache, io: std.Io, dir: std.Io.Dir) !void {
        if (self.handle == .null_handle) return;
        const gpa = self.gpu.gpa;
        const d = &self.gpu.ddisp;
        var size: usize = 0;
        _ = try vk.check(d.get_pipeline_cache_data(self.gpu.dev, self.handle, &size, null));
        if (self.created == 0 and size == self.initial_size) return;
        if (size > max_file_bytes - header_len) return error.TooLarge;
        const buf = try gpa.alloc(u8, header_len + size);
        defer gpa.free(buf);
        // The cache may grow between the two calls (VK_INCOMPLETE); keep
        // what fits, which is a valid cache.
        _ = try vk.check(d.get_pipeline_cache_data(self.gpu.dev, self.handle, &size, buf[header_len..].ptr));
        const blob = buf[header_len..][0..size];
        buf[0..header_len].* = header(blob, self.expect.shaders);
        const file = buf[0 .. header_len + size];

        var name_buf: [64]u8 = undefined;
        const name = fileName(&name_buf, self.expect.vendor_id, self.expect.device_id);
        var tmp_buf: [72]u8 = undefined;
        const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{name});
        {
            const f = try dir.createFile(io, tmp, .{});
            defer f.close(io);
            try f.writeStreamingAll(io, file);
            try f.sync(io);
        }
        try dir.rename(tmp, dir, name, io);
        self.initial_size = size;
        self.created = 0;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

const fixture_expect: Expect = .{ .vendor_id = 0x10005, .device_id = 0, .uuid = @splat(7), .shaders = @splat(3) };

/// A well-formed file around a fake driver blob.
fn fixture(gpa: std.mem.Allocator, extra: usize) ![]u8 {
    const blob = try gpa.alloc(u8, vk_header_len + extra);
    defer gpa.free(blob);
    std.mem.writeInt(u32, blob[0..4], vk_header_len, .little);
    std.mem.writeInt(u32, blob[4..8], 1, .little);
    std.mem.writeInt(u32, blob[8..12], fixture_expect.vendor_id, .little);
    std.mem.writeInt(u32, blob[12..16], fixture_expect.device_id, .little);
    @memcpy(blob[16..32], &fixture_expect.uuid);
    for (blob[32..], 0..) |*b, i| b.* = @truncate(i);
    const out = try gpa.alloc(u8, header_len + blob.len);
    out[0..header_len].* = header(blob, fixture_expect.shaders);
    @memcpy(out[header_len..], blob);
    return out;
}

test "cache: a well-formed file is accepted" {
    const f = try fixture(testing.allocator, 100);
    defer testing.allocator.free(f);
    try testing.expectEqual(@as(usize, 132), parse(f, fixture_expect).ok.len);
}

test "cache: header validation rejects wrong uuid/vendor/size" {
    const gpa = testing.allocator;
    const f = try fixture(gpa, 16);
    defer gpa.free(f);
    var e = fixture_expect;
    e.uuid[3] = 9;
    try testing.expectEqual(Reject.uuid, parse(f, e).rejected);
    e = fixture_expect;
    e.vendor_id = 0x10de;
    try testing.expectEqual(Reject.vendor, parse(f, e).rejected);
    e = fixture_expect;
    e.device_id = 1;
    try testing.expectEqual(Reject.device, parse(f, e).rejected);
    e = fixture_expect;
    e.shaders[0] = 0;
    try testing.expectEqual(Reject.shaders_changed, parse(f, e).rejected);
    // A wrong Vulkan headerSize, with a checksum that matches.
    std.mem.writeInt(u32, f[header_len..][0..4], 16, .little);
    f[0..header_len].* = header(f[header_len..], fixture_expect.shaders);
    try testing.expectEqual(Reject.vk_header_size, parse(f, fixture_expect).rejected);
    f[0] = 'X';
    try testing.expectEqual(Reject.bad_magic, parse(f, fixture_expect).rejected);
}

test "cache: wrapper checksum detects bit flip" {
    const gpa = testing.allocator;
    const f = try fixture(gpa, 64);
    defer gpa.free(f);
    for ([_]usize{ header_len, header_len + 20, f.len - 1 }) |at| {
        f[at] ^= 0x10;
        try testing.expectEqual(Reject.checksum, parse(f, fixture_expect).rejected);
        f[at] ^= 0x10;
    }
    try testing.expect(parse(f, fixture_expect) == .ok);
}

test "cache: truncated file ignored" {
    const gpa = testing.allocator;
    const f = try fixture(gpa, 64);
    defer gpa.free(f);
    for (0..f.len) |n| {
        const r = parse(f[0..n], fixture_expect);
        try testing.expect(r == .rejected);
    }
}

test "fuzz: cache file parser" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            switch (parse(input, fixture_expect)) {
                // Anything accepted is exactly the bytes after our header.
                .ok => |blob| try std.testing.expectEqual(input.len - header_len, blob.len),
                .rejected => {},
            }
        }
    }.one, .{});
}
