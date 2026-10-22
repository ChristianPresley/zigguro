//! XInput2 for the X11 backend (E01.F05.S02.T02): the requests we send
//! (`XIQueryVersion`, `XISelectEvents`, `XIQueryDevice`), device and
//! enter/leave event decoding, and smooth scrolling from scroll
//! valuators. Pointer positions arrive in FP16.16 (subpixel), scrolling
//! as valuator values whose change divided by the valuator's increment
//! is one wheel notch. Keyboard input stays on core events (with XKB).

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("proto.zig");
const FdQueue = @import("../wayland/wire/fdqueue.zig").FdQueue;

const DecodeError = proto.DecodeError;
const le = std.builtin.Endian.little;

fn u16At(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], le);
}
fn u32At(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], le);
}

/// XI2 event types (`evtype`).
pub const EventType = struct {
    /// A device's classes changed (e.g. the master switched slaves).
    pub const device_changed = 1;
    /// A button went down.
    pub const button_press = 4;
    /// A button went up.
    pub const button_release = 5;
    /// The pointer moved or a valuator changed.
    pub const motion = 6;
    /// The pointer entered a window.
    pub const enter = 7;
    /// The pointer left a window.
    pub const leave = 8;
    /// Devices were added, removed or reattached.
    pub const hierarchy_changed = 11;
    /// A touch began (XI 2.2).
    pub const touch_begin = 18;
    /// A touch moved.
    pub const touch_update = 19;
    /// A touch ended.
    pub const touch_end = 20;
};

/// Device ids for selections and queries.
pub const Device = struct {
    /// Every device.
    pub const all: u16 = 0;
    /// The master devices.
    pub const all_master: u16 = 1;
};

/// Device event flag: a pointer event emulated from scrolling or touch.
pub const pointer_emulated: u32 = 1 << 16;

/// The event mask for windows: pointer, scroll, touch (XI 2.2+).
pub fn windowMask(touch: bool) u32 {
    const E = EventType;
    var m: u32 = (1 << E.device_changed) | (1 << E.button_press) | (1 << E.button_release) | (1 << E.motion) | (1 << E.enter) | (1 << E.leave);
    if (touch) m |= (1 << E.touch_begin) | (1 << E.touch_update) | (1 << E.touch_end);
    return m;
}

/// XIQueryVersion.
pub const QueryVersion = struct {
    /// The extension that owns this request.
    pub const extension = "XInputExtension";
    /// The minor opcode.
    pub const minor = 47;
    major: u16 = 2,
    minor_version: u16 = 4,

    /// The version both sides speak.
    pub const Reply = struct {
        major: u16,
        minor: u16,
        /// Decodes the reply from its wire bytes.
        pub fn decode(b: []const u8, _: *FdQueue) DecodeError!Reply {
            if (b.len < 32) return error.Malformed;
            return .{ .major = u16At(b, 8), .minor = u16At(b, 10) };
        }

        /// Whether this is at least `maj.min`.
        pub fn atLeast(v: Reply, maj: u16, min: u16) bool {
            return v.major > maj or (v.major == maj and v.minor >= min);
        }
    };
};

/// XISelectEvents with one 32-bit mask for one device (or device set).
pub const SelectEvents = struct {
    /// The extension that owns this request.
    pub const extension = "XInputExtension";
    /// The minor opcode.
    pub const minor = 46;
    window: u32,
    num_masks: u16 = 1,
    _pad: u16 = 0,
    device_id: u16,
    mask_len: u16 = 1,
    mask: u32,
};

/// XIGrabDevice: an active grab of one device (a drag's pointer grab).
pub const GrabDevice = struct {
    /// The extension that owns this request.
    pub const extension = "XInputExtension";
    /// The minor opcode.
    pub const minor = 51;
    grab_window: u32,
    time: u32 = 0,
    cursor: u32 = 0,
    device_id: u16,
    /// 0 Sync, 1 Async.
    grab_mode: u8 = 1,
    paired_device_mode: u8 = 1,
    owner_events: u8 = 0,
    _pad: u8 = 0,
    mask_len: u16 = 1,
    mask: u32,

    /// 0 Success; otherwise AlreadyGrabbed, InvalidTime, NotViewable or
    /// Frozen.
    pub const Reply = struct {
        status: u8,
        /// Decodes the reply from its wire bytes.
        pub fn decode(b: []const u8, _: *FdQueue) DecodeError!Reply {
            if (b.len < 32) return error.Malformed;
            return .{ .status = b[8] };
        }
    };
};

/// XIUngrabDevice.
pub const UngrabDevice = struct {
    /// The extension that owns this request.
    pub const extension = "XInputExtension";
    /// The minor opcode.
    pub const minor = 52;
    time: u32 = 0,
    device_id: u16,
    _pad: u16 = 0,
};

/// XIQueryDevice.
pub const QueryDevice = struct {
    /// The extension that owns this request.
    pub const extension = "XInputExtension";
    /// The minor opcode.
    pub const minor = 48;
    device_id: u16 = Device.all,
    _pad: u16 = 0,

    /// The raw reply, valid until the connection's next reply; parse it
    /// with `Scrolling.load`.
    pub const Reply = struct {
        bytes: []const u8,
        /// Checks the length and keeps the bytes.
        pub fn decode(b: []const u8, _: *FdQueue) DecodeError!Reply {
            if (b.len < 32 + @as(usize, u32At(b, 4)) * 4) return error.Malformed;
            return .{ .bytes = b };
        }
    };
};

/// FP16.16 → float.
pub fn fp1616(v: u32) f32 {
    return @as(f32, @floatFromInt(@as(i32, @bitCast(v)))) / 65536.0;
}

/// FP32.32 (integral, fraction) → float.
pub fn fp3232(b: []const u8) f64 {
    const int: i32 = @bitCast(u32At(b, 0));
    const frac: u32 = u32At(b, 4);
    return @as(f64, @floatFromInt(int)) + @as(f64, @floatFromInt(frac)) / 4294967296.0;
}

/// A decoded device event (button, motion, touch).
pub const DeviceEvent = struct {
    evtype: u16,
    device_id: u16,
    source_id: u16,
    /// Button number or touch id.
    detail: u32,
    /// Server time in ms.
    time: u32,
    window: u32,
    /// Root and event-window positions.
    root: [2]f32,
    pos: [2]f32,
    flags: u32,
    /// Effective modifiers (core state bits).
    mods: u16,
    /// The valuator mask and the FP32.32 values of its set bits.
    valuator_mask: []const u8,
    values: []const u8,

    /// The value of valuator `n`, if the event carries it.
    pub fn valuator(e: *const DeviceEvent, n: u16) ?f64 {
        const byte = n / 8;
        if (byte >= e.valuator_mask.len) return null;
        if (e.valuator_mask[byte] & (@as(u8, 1) << @intCast(n % 8)) == 0) return null;
        var idx: usize = 0;
        for (0..n) |i| {
            if (e.valuator_mask[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0) idx += 1;
        }
        if ((idx + 1) * 8 > e.values.len) return null;
        return fp3232(e.values[idx * 8 ..][0..8]);
    }
};

/// Decodes a device event; null for other types or short events.
pub fn decodeDeviceEvent(ev: []const u8) ?DeviceEvent {
    if (ev.len < 80) return null;
    const evtype = u16At(ev, 8);
    switch (evtype) {
        EventType.button_press, EventType.button_release, EventType.motion, EventType.touch_begin, EventType.touch_update, EventType.touch_end => {},
        else => return null,
    }
    const buttons_len = @as(usize, u16At(ev, 48)) * 4;
    const valuators_len = @as(usize, u16At(ev, 50)) * 4;
    if (ev.len < 80 + buttons_len + valuators_len) return null;
    const mask = ev[80 + buttons_len ..][0..valuators_len];
    var n_values: usize = 0;
    for (mask) |m| n_values += @popCount(m);
    const values_at = 80 + buttons_len + valuators_len;
    const values = ev[values_at..@min(ev.len, values_at + n_values * 8)];
    return .{
        .evtype = evtype,
        .device_id = u16At(ev, 10),
        .source_id = u16At(ev, 52),
        .detail = u32At(ev, 16),
        .time = u32At(ev, 12),
        .window = u32At(ev, 24),
        .root = .{ fp1616(u32At(ev, 32)), fp1616(u32At(ev, 36)) },
        .pos = .{ fp1616(u32At(ev, 40)), fp1616(u32At(ev, 44)) },
        .flags = u32At(ev, 56),
        .mods = @truncate(u32At(ev, 72)),
        .valuator_mask = mask,
        .values = values,
    };
}

/// A decoded XI_Enter / XI_Leave.
pub const Crossing = struct {
    entered: bool,
    device_id: u16,
    source_id: u16,
    window: u32,
    pos: [2]f32,
};

/// Decodes an enter or leave event.
pub fn decodeCrossing(ev: []const u8) ?Crossing {
    if (ev.len < 72) return null;
    const evtype = u16At(ev, 8);
    if (evtype != EventType.enter and evtype != EventType.leave) return null;
    return .{
        .entered = evtype == EventType.enter,
        .device_id = u16At(ev, 10),
        .source_id = u16At(ev, 16),
        .window = u32At(ev, 24),
        .pos = .{ fp1616(u32At(ev, 40)), fp1616(u32At(ev, 44)) },
    };
}

/// Scroll valuators by device, and their last values.
pub const Scrolling = struct {
    /// One scroll valuator.
    pub const Valuator = struct {
        device: u16,
        number: u16,
        horizontal: bool,
        increment: f64,
        /// The last value seen; null after a reset, so the next event
        /// only sets the baseline.
        last: ?f64 = null,
    };

    list: std.ArrayList(Valuator) = .empty,

    /// Frees the list.
    pub fn deinit(s: *Scrolling, gpa: Allocator) void {
        s.list.deinit(gpa);
    }

    /// Replaces the list from an XIQueryDevice reply.
    pub fn load(s: *Scrolling, gpa: Allocator, reply: []const u8) !void {
        if (reply.len < 32) return error.Malformed;
        s.list.clearRetainingCapacity();
        var pos: usize = 32;
        for (0..u16At(reply, 8)) |_| {
            if (pos + 12 > reply.len) return error.Malformed;
            const dev = u16At(reply, pos);
            const n_classes = u16At(reply, pos + 6);
            const name_len = u16At(reply, pos + 8);
            pos += 12 + std.mem.alignForward(usize, name_len, 4);
            for (0..n_classes) |_| {
                if (pos + 8 > reply.len) return error.Malformed;
                const kind = u16At(reply, pos);
                const len = @as(usize, u16At(reply, pos + 2)) * 4;
                if (len < 8 or pos + len > reply.len) return error.Malformed;
                if (kind == 3 and len >= 24) {
                    const inc = fp3232(reply[pos + 16 ..][0..8]);
                    if (inc != 0) try s.list.append(gpa, .{
                        .device = dev,
                        .number = u16At(reply, pos + 6),
                        .horizontal = u16At(reply, pos + 8) == 2,
                        .increment = inc,
                    });
                }
                pos += len;
            }
        }
    }

    /// Whether `device` has scroll valuators (then its wheel buttons are
    /// emulated and ignored).
    pub fn has(s: *const Scrolling, device: u16) bool {
        for (s.list.items) |v| if (v.device == device) return true;
        return false;
    }

    /// Forgets the last values (on enter and device changes).
    pub fn reset(s: *Scrolling) void {
        for (s.list.items) |*v| v.last = null;
    }

    /// The scroll in notches (dx, dy) a motion event carries; positive
    /// is right and down.
    pub fn delta(s: *Scrolling, e: *const DeviceEvent) [2]f64 {
        var d: [2]f64 = .{ 0, 0 };
        for (s.list.items) |*v| {
            if (v.device != e.source_id) continue;
            const now = e.valuator(v.number) orelse continue;
            if (v.last) |prev| d[if (v.horizontal) 0 else 1] += (now - prev) / v.increment;
            v.last = now;
        }
        return d;
    }
};

const testing = std.testing;

/// Builds a device event for tests: valuators as (number, value) pairs.
fn testEvent(buf: []u8, evtype: u16, source: u16, detail: u32, flags: u32, vals: []const struct { u16, f64 }) []u8 {
    @memset(buf, 0);
    buf[0] = 35;
    std.mem.writeInt(u16, buf[8..10], evtype, le);
    std.mem.writeInt(u16, buf[10..12], 2, le);
    std.mem.writeInt(u32, buf[16..20], detail, le);
    std.mem.writeInt(u32, buf[24..28], 0x400001, le);
    std.mem.writeInt(u32, buf[40..44], @bitCast(@as(i32, 10 * 65536 + 32768)), le); // 10.5
    std.mem.writeInt(u32, buf[44..48], @bitCast(@as(i32, -3 * 65536)), le);
    std.mem.writeInt(u16, buf[50..52], 1, le); // valuators_len
    std.mem.writeInt(u16, buf[52..54], source, le);
    std.mem.writeInt(u32, buf[56..60], flags, le);
    std.mem.writeInt(u32, buf[72..76], 1, le); // effective: Shift
    var at: usize = 84;
    var sorted: [8]struct { u16, f64 } = undefined;
    @memcpy(sorted[0..vals.len], vals);
    std.mem.sort(struct { u16, f64 }, sorted[0..vals.len], {}, struct {
        fn lt(_: void, a: struct { u16, f64 }, b: struct { u16, f64 }) bool {
            return a[0] < b[0];
        }
    }.lt);
    for (sorted[0..vals.len]) |v| {
        buf[80 + v[0] / 8] |= @as(u8, 1) << @intCast(v[0] % 8);
        const int: i32 = @intFromFloat(@floor(v[1]));
        const frac: u32 = @intFromFloat((v[1] - @floor(v[1])) * 4294967296.0);
        std.mem.writeInt(u32, buf[at..][0..4], @bitCast(int), le);
        std.mem.writeInt(u32, buf[at + 4 ..][0..4], frac, le);
        at += 8;
    }
    std.mem.writeInt(u32, buf[4..8], @intCast((at - 32) / 4), le);
    return buf[0..at];
}

test "FP16.16 and FP32.32 conversion" {
    try testing.expectEqual(@as(f32, 10.5), fp1616(10 * 65536 + 32768));
    try testing.expectEqual(@as(f32, -3), fp1616(@bitCast(@as(i32, -3 * 65536))));
    var b: [8]u8 = undefined;
    std.mem.writeInt(u32, b[0..4], @bitCast(@as(i32, -2)), le);
    std.mem.writeInt(u32, b[4..8], 0x8000_0000, le);
    try testing.expectEqual(@as(f64, -1.5), fp3232(&b));
}

test "device events decode position, flags, mods and valuators" {
    var buf: [160]u8 = undefined;
    const ev = testEvent(&buf, EventType.motion, 9, 0, pointer_emulated, &.{ .{ 0, 10.5 }, .{ 3, 240 } });
    const e = decodeDeviceEvent(ev).?;
    try testing.expectEqual(@as(u16, 9), e.source_id);
    try testing.expectEqual(@as(u32, 0x400001), e.window);
    try testing.expectEqual([2]f32{ 10.5, -3 }, e.pos);
    try testing.expect(e.flags & pointer_emulated != 0);
    try testing.expectEqual(@as(u16, 1), e.mods);
    try testing.expectEqual(@as(?f64, 10.5), e.valuator(0));
    try testing.expectEqual(@as(?f64, 240), e.valuator(3));
    try testing.expectEqual(@as(?f64, null), e.valuator(2));
    try testing.expectEqual(@as(?f64, null), e.valuator(40));
    try testing.expect(decodeDeviceEvent(ev[0..60]) == null);
}

test "scroll valuator delta to notches with increment 120, 15 and 1.0" {
    var s: Scrolling = .{};
    defer s.deinit(testing.allocator);
    try s.list.append(testing.allocator, .{ .device = 9, .number = 3, .horizontal = false, .increment = 120 });
    try s.list.append(testing.allocator, .{ .device = 9, .number = 2, .horizontal = true, .increment = 15 });
    try s.list.append(testing.allocator, .{ .device = 11, .number = 2, .horizontal = false, .increment = 1.0 });
    var buf: [160]u8 = undefined;
    // The first event only sets the baseline.
    var e = decodeDeviceEvent(testEvent(&buf, EventType.motion, 9, 0, 0, &.{ .{ 2, 30 }, .{ 3, 1200 } })).?;
    try testing.expectEqual([2]f64{ 0, 0 }, s.delta(&e));
    e = decodeDeviceEvent(testEvent(&buf, EventType.motion, 9, 0, 0, &.{ .{ 2, 22.5 }, .{ 3, 1260 } })).?;
    try testing.expectEqual([2]f64{ -0.5, 0.5 }, s.delta(&e));
    // Another device's valuator 2 has its own increment and baseline.
    e = decodeDeviceEvent(testEvent(&buf, EventType.motion, 11, 0, 0, &.{.{ 2, 5 }})).?;
    try testing.expectEqual([2]f64{ 0, 0 }, s.delta(&e));
    e = decodeDeviceEvent(testEvent(&buf, EventType.motion, 11, 0, 0, &.{.{ 2, 8 }})).?;
    try testing.expectEqual([2]f64{ 0, 3 }, s.delta(&e));
    // After a reset (enter), the baseline starts over.
    s.reset();
    e = decodeDeviceEvent(testEvent(&buf, EventType.motion, 9, 0, 0, &.{.{ 3, 0 }})).?;
    try testing.expectEqual([2]f64{ 0, 0 }, s.delta(&e));
    try testing.expect(s.has(9) and !s.has(3));
}

test "XIQueryDevice reply: scroll classes per device" {
    var r: [32 + 12 + 8 + 8 + 24 + 12 + 24]u8 = @splat(0);
    r[0] = 1;
    std.mem.writeInt(u32, r[4..8], (r.len - 32) / 4, le);
    std.mem.writeInt(u16, r[8..10], 2, le);
    // Device 9 "mouse" with a button class and a vertical scroll class.
    var p: usize = 32;
    std.mem.writeInt(u16, r[p..][0..2], 9, le);
    std.mem.writeInt(u16, r[p + 6 ..][0..2], 2, le);
    std.mem.writeInt(u16, r[p + 8 ..][0..2], 5, le);
    p += 12 + 8;
    std.mem.writeInt(u16, r[p..][0..2], 1, le); // ButtonClass, 8 bytes
    std.mem.writeInt(u16, r[p + 2 ..][0..2], 2, le);
    p += 8;
    std.mem.writeInt(u16, r[p..][0..2], 3, le); // ScrollClass
    std.mem.writeInt(u16, r[p + 2 ..][0..2], 6, le);
    std.mem.writeInt(u16, r[p + 6 ..][0..2], 3, le); // valuator 3
    std.mem.writeInt(u16, r[p + 8 ..][0..2], 1, le); // vertical
    std.mem.writeInt(u32, r[p + 16 ..][0..4], 120, le);
    p += 24;
    // Device 4 with no classes and no name.
    std.mem.writeInt(u16, r[p..][0..2], 4, le);
    p += 12;
    try testing.expectEqual(r.len - 24, p);
    var s: Scrolling = .{};
    defer s.deinit(testing.allocator);
    try s.load(testing.allocator, r[0 .. r.len - 24]);
    try testing.expectEqual(@as(usize, 1), s.list.items.len);
    try testing.expectEqual(Scrolling.Valuator{ .device = 9, .number = 3, .horizontal = false, .increment = 120 }, s.list.items[0]);
    try testing.expectError(error.Malformed, s.load(testing.allocator, r[0..50]));
}

test "request sizes" {
    var buf: [32]u8 = undefined;
    try testing.expectEqual(@as(usize, 20), try proto.writeRequest(&buf, SelectEvents, .{ .window = 1, .device_id = Device.all_master, .mask = windowMask(true) }, 131, false));
    try testing.expectEqual(@as(usize, 8), try proto.writeRequest(&buf, QueryDevice, .{}, 131, false));
    try testing.expectEqual(@as(usize, 8), try proto.writeRequest(&buf, QueryVersion, .{}, 131, false));
    try testing.expectEqual(@as(usize, 28), try proto.writeRequest(&buf, GrabDevice, .{ .grab_window = 1, .device_id = 2, .mask = 1 << EventType.motion }, 131, false));
    try testing.expectEqual(@as(usize, 12), try proto.writeRequest(&buf, UngrabDevice, .{ .device_id = 2 }, 131, false));
}
