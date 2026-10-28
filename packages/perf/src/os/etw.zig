//! Windows ETW bridge (E14.F02.S03.T01): a TraceLogging-compatible
//! (self-describing, manifest-free) provider registered through Advapi32,
//! so WPR/WPA record zigguro frames, zones and instants next to CPU
//! samples. `std.os.windows` declares none of the ETW functions, so they
//! are declared here.
//!
//! Provider "Zigguro", GUID {625b5a21-8f0d-4b3e-8d0e-893db16cf3d4}
//! (generated once for zigguro; `tools/perf/zigguro.wprp` names it).
//! Keywords: bit 0 frames, bit 1 zones, bit 2 instants. Writes are skipped
//! unless a session enabled the provider (tracked by the enable callback).

const std = @import("std");
const builtin = @import("builtin");
const meta = @import("etw_metadata.zig");

/// A Windows GUID.
pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

/// The zigguro provider's GUID.
pub const provider_guid: GUID = .{ .Data1 = 0x625b5a21, .Data2 = 0x8f0d, .Data3 = 0x4b3e, .Data4 = .{ 0x8d, 0x0e, 0x89, 0x3d, 0xb1, 0x6c, 0xf3, 0xd4 } };
/// The provider name.
pub const provider_name = "Zigguro";

/// `EVENT_DESCRIPTOR`.
pub const EVENT_DESCRIPTOR = extern struct {
    Id: u16 = 0,
    Version: u8 = 0,
    Channel: u8 = 11, // the TraceLogging channel
    Level: u8,
    Opcode: u8 = 0,
    Task: u16 = 0,
    Keyword: u64,
};

/// `EVENT_DATA_DESCRIPTOR`: `Type` is the low byte of the reserved word.
pub const EVENT_DATA_DESCRIPTOR = extern struct {
    Ptr: u64,
    Size: u32,
    Type: u8 = 0,
    Reserved1: u8 = 0,
    Reserved2: u16 = 0,
};

/// `EVENT_DATA_DESCRIPTOR_TYPE_*`.
pub const DescriptorType = struct {
    pub const user_data: u8 = 0;
    pub const event_metadata: u8 = 1;
    pub const provider_metadata: u8 = 2;
};

/// `EVENT_INFO_CLASS.EventProviderSetTraits` (evntprov.h).
pub const EventProviderSetTraits: u32 = 2;

/// Keyword bits.
pub const keyword_frames: u64 = 1 << 0;
pub const keyword_zones: u64 = 1 << 1;
pub const keyword_instants: u64 = 1 << 2;

const EnableCallback = *const fn (source: *const GUID, is_enabled: u32, level: u8, match_any: u64, match_all: u64, filter: ?*anyopaque, ctx: ?*anyopaque) callconv(.winapi) void;

const api = if (builtin.os.tag == .windows) struct {
    extern "advapi32" fn EventRegister(ProviderId: *const GUID, EnableCallback: ?EnableCallback, CallbackContext: ?*anyopaque, RegHandle: *u64) callconv(.winapi) u32;
    extern "advapi32" fn EventSetInformation(RegHandle: u64, InformationClass: u32, EventInformation: *const anyopaque, InformationLength: u32) callconv(.winapi) u32;
    extern "advapi32" fn EventWriteTransfer(RegHandle: u64, EventDescriptor: *const EVENT_DESCRIPTOR, ActivityId: ?*const GUID, RelatedActivityId: ?*const GUID, UserDataCount: u32, UserData: [*]const EVENT_DATA_DESCRIPTOR) callconv(.winapi) u32;
    extern "advapi32" fn EventUnregister(RegHandle: u64) callconv(.winapi) u32;
} else struct {};

const traits_blob = meta.traits(provider_name);

/// Names longer than this are cut.
pub const max_name = 256;

/// A registered provider.
pub const Provider = struct {
    handle: u64 = 0,
    /// Enabled level (0 = off) and keywords, from the enable callback.
    level: std.atomic.Value(u8) = .init(0),
    keywords: std.atomic.Value(u64) = .init(0),

    /// Registers the provider into `p` (which must not move). False when
    /// registration fails or off Windows.
    pub fn register(p: *Provider) bool {
        if (builtin.os.tag != .windows) return false;
        if (api.EventRegister(&provider_guid, onEnable, p, &p.handle) != 0) return false;
        _ = api.EventSetInformation(p.handle, EventProviderSetTraits, &traits_blob, traits_blob.len);
        return true;
    }

    /// Unregisters.
    pub fn unregister(p: *Provider) void {
        if (builtin.os.tag != .windows or p.handle == 0) return;
        _ = api.EventUnregister(p.handle);
        p.handle = 0;
    }

    fn onEnable(_: *const GUID, is_enabled: u32, level: u8, match_any: u64, _: u64, _: ?*anyopaque, ctx: ?*anyopaque) callconv(.winapi) void {
        setEnable(@ptrCast(@alignCast(ctx.?)), is_enabled, level, match_any);
    }

    fn setEnable(p: *Provider, is_enabled: u32, level: u8, match_any: u64) void {
        // 0 disable, 1 enable, 2 capture state.
        switch (is_enabled) {
            0 => p.level.store(0, .release),
            1 => {
                p.keywords.store(if (match_any == 0) std.math.maxInt(u64) else match_any, .release);
                p.level.store(if (level == 0) 255 else level, .release);
            },
            else => {},
        }
    }

    /// Whether a session listens at `level` for `keyword` (two loads).
    pub fn enabled(p: *const Provider, level: u8, keyword: u64) bool {
        const l = p.level.load(.acquire);
        return l != 0 and level <= l and p.keywords.load(.acquire) & keyword != 0;
    }

    fn write(p: *Provider, level: u8, keyword: u64, metadata: []const u8, payload: []const EVENT_DATA_DESCRIPTOR) void {
        if (builtin.os.tag != .windows) return;
        var d: [6]EVENT_DATA_DESCRIPTOR = undefined;
        d[0] = .{ .Ptr = @intFromPtr(&traits_blob), .Size = traits_blob.len, .Type = DescriptorType.provider_metadata };
        d[1] = .{ .Ptr = @intFromPtr(metadata.ptr), .Size = @intCast(metadata.len), .Type = DescriptorType.event_metadata };
        @memcpy(d[2..][0..payload.len], payload);
        const desc: EVENT_DESCRIPTOR = .{ .Level = level, .Keyword = keyword };
        _ = api.EventWriteTransfer(p.handle, &desc, null, null, @intCast(2 + payload.len), &d);
    }

    fn data(ptr: *const anyopaque, size: usize) EVENT_DATA_DESCRIPTOR {
        return .{ .Ptr = @intFromPtr(ptr), .Size = @intCast(size) };
    }

    const nul: u8 = 0;

    /// `Frame{seq}` at level 4.
    pub fn frame(p: *Provider, seq: u64) void {
        if (!p.enabled(4, keyword_frames)) return;
        p.write(4, keyword_frames, &meta.frame, &.{data(&seq, 8)});
    }

    /// `ZoneBegin{name, tid}` at level 5.
    pub fn zoneBegin(p: *Provider, name: []const u8, tid: u64) void {
        if (!p.enabled(5, keyword_zones)) return;
        const n = name[0..@min(name.len, max_name)];
        p.write(5, keyword_zones, &meta.zone_begin, &.{ data(n.ptr, n.len), data(&nul, 1), data(&tid, 8) });
    }

    /// `Zone{name, dur_ns}` at level 5, at the zone's end.
    pub fn zone(p: *Provider, name: []const u8, dur_ns: u64) void {
        if (!p.enabled(5, keyword_zones)) return;
        const n = name[0..@min(name.len, max_name)];
        p.write(5, keyword_zones, &meta.zone, &.{ data(n.ptr, n.len), data(&nul, 1), data(&dur_ns, 8) });
    }

    /// `Instant{name, value}` at level 5.
    pub fn instant(p: *Provider, name: []const u8, value: i64) void {
        if (!p.enabled(5, keyword_instants)) return;
        const n = name[0..@min(name.len, max_name)];
        p.write(5, keyword_instants, &meta.instant, &.{ data(n.ptr, n.len), data(&nul, 1), data(&value, 8) });
    }
};

test "etw: descriptor layouts match the C structs" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(EVENT_DESCRIPTOR));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(EVENT_DATA_DESCRIPTOR));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(EVENT_DATA_DESCRIPTOR, "Type"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(EVENT_DESCRIPTOR, "Keyword"));
}

test "etw: register/write/unregister succeeds without listener" {
    var p: Provider = .{};
    if (!p.register()) {
        if (builtin.os.tag == .windows) return error.TestUnexpectedResult;
        return error.SkipZigTest;
    }
    defer p.unregister();
    // No session: nothing is written, and nothing fails.
    p.frame(1);
    p.zoneBegin("gui.frame", 1);
    p.zone("gui.frame", 100);
    p.instant("perf.stall", 3);
}

test "etw: enable callback gates writes" {
    var p: Provider = .{};
    try std.testing.expect(!p.enabled(5, keyword_zones));
    p.setEnable(1, 5, keyword_zones);
    try std.testing.expect(p.enabled(5, keyword_zones));
    try std.testing.expect(!p.enabled(5, keyword_frames));
    p.setEnable(0, 0, 0);
    try std.testing.expect(!p.enabled(4, keyword_frames));
}
