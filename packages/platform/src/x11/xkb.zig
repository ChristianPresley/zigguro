//! The X Keyboard Extension requests and events the X11 backend uses
//! (E01.F05.S02.T02): `UseExtension`, `PerClientFlags` for detectable
//! autorepeat, `SelectEvents` for state and map changes, `GetState`,
//! `GetMap` and `GetNames`. `fetchKeymap` turns the server's compiled
//! keymap into the shared `xkb.Keymap` (see `keymap_from_server.zig`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("proto.zig");
const Conn = @import("conn.zig").Conn;
const FdQueue = @import("../wayland/wire/fdqueue.zig").FdQueue;
const xkb = @import("../xkb/keymap.zig");
const from_server = @import("keymap_from_server.zig");

const DecodeError = proto.DecodeError;
const le = std.builtin.Endian.little;

/// The core keyboard's device spec.
pub const use_core_kbd: u16 = 0x100;

/// Event masks for `SelectEvents`.
pub const EventMask = struct {
    /// NewKeyboardNotify.
    pub const new_keyboard: u16 = 1 << 0;
    /// MapNotify.
    pub const map: u16 = 1 << 1;
    /// StateNotify.
    pub const state: u16 = 1 << 2;
};

/// `xkbType` of XKB events (byte 1).
pub const EventType = struct {
    /// NewKeyboardNotify.
    pub const new_keyboard = 0;
    /// MapNotify.
    pub const map = 1;
    /// StateNotify.
    pub const state = 2;
};

/// GetMap component bits.
pub const MapPart = struct {
    /// Key types.
    pub const key_types: u16 = 1 << 0;
    /// Key symbols.
    pub const key_syms: u16 = 1 << 1;
    /// The modifier map.
    pub const modifier_map: u16 = 1 << 2;
    /// Virtual modifier → real modifier bindings.
    pub const virtual_mods: u16 = 1 << 6;
    /// The virtual modifier map.
    pub const virtual_mod_map: u16 = 1 << 7;
    /// What `fetchKeymap` asks for.
    pub const keymap: u16 = key_types | key_syms | modifier_map | virtual_mods | virtual_mod_map;
};

/// GetNames component bits.
pub const NamePart = struct {
    /// Key names.
    pub const keys: u32 = 1 << 9;
    /// Virtual modifier names.
    pub const virtual_mods: u32 = 1 << 11;
};

/// UseExtension: must precede every other XKB request.
pub const UseExtension = struct {
    /// The extension that owns this request.
    pub const extension = "XKEYBOARD";
    /// The minor opcode.
    pub const minor = 0;
    wanted_major: u16 = 1,
    wanted_minor: u16 = 0,

    /// Whether the server speaks the version.
    pub const Reply = struct {
        supported: bool,
        /// Decodes the reply from its wire bytes.
        pub fn decode(b: []const u8, _: *FdQueue) DecodeError!Reply {
            if (b.len < 32) return error.Malformed;
            return .{ .supported = b[1] != 0 };
        }
    };
};

/// SelectEvents with whole event types (no per-type details).
pub const SelectEvents = struct {
    /// The extension that owns this request.
    pub const extension = "XKEYBOARD";
    /// The minor opcode.
    pub const minor = 1;
    device_spec: u16 = use_core_kbd,
    affect_which: u16,
    clear: u16 = 0,
    select_all: u16,
    affect_map: u16 = 0xffff,
    map: u16 = 0xffff,
};

/// GetState.
pub const GetState = struct {
    /// The extension that owns this request.
    pub const extension = "XKEYBOARD";
    /// The minor opcode.
    pub const minor = 4;
    device_spec: u16 = use_core_kbd,
    _pad: u16 = 0,

    /// The modifier state.
    pub const Reply = struct {
        state: State,
        /// Decodes the reply from its wire bytes.
        pub fn decode(b: []const u8, _: *FdQueue) DecodeError!Reply {
            if (b.len < 32) return error.Malformed;
            return .{ .state = .{ .base = b[9], .latched = b[10], .locked = b[11], .group = b[12] } };
        }
    };
};

/// LatchLockState: locks or latches modifiers and the group (tests
/// use it to toggle Caps Lock and layouts).
pub const LatchLockState = struct {
    /// The extension that owns this request.
    pub const extension = "XKEYBOARD";
    /// The minor opcode.
    pub const minor = 5;
    device_spec: u16 = use_core_kbd,
    affect_mod_locks: u8 = 0,
    mod_locks: u8 = 0,
    lock_group: bool = false,
    group_lock: u8 = 0,
    affect_mod_latches: u8 = 0,
    mod_latches: u8 = 0,
    _pad: u8 = 0,
    latch_group: bool = false,
    group_latch: i16 = 0,
};

/// GetMap with whole components (`full`).
pub const GetMap = struct {
    /// The extension that owns this request.
    pub const extension = "XKEYBOARD";
    /// The minor opcode.
    pub const minor = 8;
    device_spec: u16 = use_core_kbd,
    full: u16 = MapPart.keymap,
    partial: u16 = 0,
    first_type: u8 = 0,
    n_types: u8 = 0,
    first_key_sym: u8 = 0,
    n_key_syms: u8 = 0,
    first_key_act: u8 = 0,
    n_key_acts: u8 = 0,
    first_key_behavior: u8 = 0,
    n_key_behaviors: u8 = 0,
    virtual_mods: u16 = 0,
    first_key_explicit: u8 = 0,
    n_key_explicit: u8 = 0,
    first_mod_map_key: u8 = 0,
    n_mod_map_keys: u8 = 0,
    first_vmod_map_key: u8 = 0,
    n_vmod_map_keys: u8 = 0,
    _pad: u16 = 0,

    /// The raw reply; `keymap_from_server.zig` reads it.
    pub const Reply = RawReply;
};

/// GetNames.
pub const GetNames = struct {
    /// The extension that owns this request.
    pub const extension = "XKEYBOARD";
    /// The minor opcode.
    pub const minor = 17;
    device_spec: u16 = use_core_kbd,
    _pad: u16 = 0,
    which: u32 = NamePart.keys | NamePart.virtual_mods,

    /// The raw reply; `keymap_from_server.zig` reads it.
    pub const Reply = RawReply;
};

/// PerClientFlags bits.
pub const PerClientFlag = struct {
    /// Repeats arrive as presses without releases in between.
    pub const detectable_auto_repeat: u32 = 1 << 0;
};

/// PerClientFlags.
pub const PerClientFlags = struct {
    /// The extension that owns this request.
    pub const extension = "XKEYBOARD";
    /// The minor opcode.
    pub const minor = 21;
    device_spec: u16 = use_core_kbd,
    _pad: u16 = 0,
    change: u32,
    value: u32,
    ctrls_to_change: u32 = 0,
    auto_ctrls: u32 = 0,
    auto_ctrl_values: u32 = 0,

    /// The flags now in effect.
    pub const Reply = struct {
        supported: u32,
        value: u32,
        /// Decodes the reply from its wire bytes.
        pub fn decode(b: []const u8, _: *FdQueue) DecodeError!Reply {
            if (b.len < 32) return error.Malformed;
            return .{ .supported = std.mem.readInt(u32, b[8..12], le), .value = std.mem.readInt(u32, b[12..16], le) };
        }
    };
};

/// A whole reply, valid until the connection's next reply.
pub const RawReply = struct {
    bytes: []const u8,
    /// Checks the length and keeps the bytes.
    pub fn decode(b: []const u8, _: *FdQueue) DecodeError!RawReply {
        if (b.len < 32 + @as(usize, std.mem.readInt(u32, b[4..8], le)) * 4) return error.Malformed;
        return .{ .bytes = b };
    }
};

/// The keyboard state, as GetState and StateNotify report it.
pub const State = struct {
    base: u8 = 0,
    latched: u8 = 0,
    locked: u8 = 0,
    /// The effective group.
    group: u8 = 0,

    /// As `xkb.ModState`.
    pub fn mods(s: State) xkb.ModState {
        return .{ .depressed = s.base, .latched = s.latched, .locked = s.locked };
    }
};

/// A decoded XKB event.
pub const Event = union(enum) {
    /// The keymap changed: fetch it again.
    keymap_changed,
    /// The modifier or group state changed.
    state: State,
    other,
};

/// Decodes an event whose code is the extension's event base.
pub fn decodeEvent(ev: []const u8) Event {
    if (ev.len < 32) return .other;
    return switch (ev[1]) {
        EventType.new_keyboard, EventType.map => .keymap_changed,
        EventType.state => .{ .state = .{ .base = ev[10], .latched = ev[11], .locked = ev[12], .group = ev[13] } },
        else => .other,
    };
}

/// Turns on XKB for this client: the version handshake, detectable
/// autorepeat, and state and map events. Returns the event base, or null
/// when the server has no usable XKB.
pub fn enable(c: *Conn) ?u8 {
    const info = c.extension("XKEYBOARD") orelse return null;
    const v = c.reply(c.request(UseExtension, .{}, &.{}) catch return null) catch return null;
    if (!v.supported) return null;
    const f = c.reply(c.request(PerClientFlags, .{
        .change = PerClientFlag.detectable_auto_repeat,
        .value = PerClientFlag.detectable_auto_repeat,
    }, &.{}) catch return null) catch return null;
    if (f.value & PerClientFlag.detectable_auto_repeat == 0) std.log.scoped(.x11).info("XKB detectable autorepeat unsupported", .{});
    const which = EventMask.new_keyboard | EventMask.map | EventMask.state;
    _ = c.request(SelectEvents, .{ .affect_which = which, .select_all = which }, &.{}) catch return null;
    return info.first_event;
}

/// The server's current keymap.
pub fn fetchKeymap(gpa: Allocator, c: *Conn) !xkb.Keymap {
    const map_ck = try c.request(GetMap, .{}, &.{});
    const names_ck = try c.request(GetNames, .{}, &.{});
    // Each reply lives until the next one: copy.
    const map = try gpa.dupe(u8, (try c.reply(map_ck)).bytes);
    defer gpa.free(map);
    const names = try gpa.dupe(u8, (try c.reply(names_ck)).bytes);
    defer gpa.free(names);

    const atoms = try from_server.vmodNameAtoms(names);
    var cookies: [16]@import("conn.zig").Cookie(proto.GetAtomName) = undefined;
    for (atoms.slice(), 0..) |a, i| cookies[i] = try c.request(proto.GetAtomName, .{ .atom = a }, &.{});
    var store: [16][64]u8 = undefined;
    var vmod_names: [16][]const u8 = undefined;
    for (atoms.slice(), 0..) |a, i| {
        const n = if (a == 0) "" else (try c.reply(cookies[i])).name;
        const len = @min(n.len, store[i].len);
        @memcpy(store[i][0..len], n[0..len]);
        vmod_names[i] = store[i][0..len];
    }
    return from_server.keymapFromXkbGetMap(gpa, map, names, vmod_names[0..atoms.len]);
}

const testing = std.testing;

test "request layouts match the protocol sizes" {
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 28), try proto.writeRequest(&buf, GetMap, .{}, 130, false));
    try testing.expectEqual(@as(u8, 8), buf[1]);
    try testing.expectEqual(MapPart.keymap, std.mem.readInt(u16, buf[6..8], le));
    try testing.expectEqual(@as(usize, 12), try proto.writeRequest(&buf, GetNames, .{}, 130, false));
    try testing.expectEqual(@as(usize, 28), try proto.writeRequest(&buf, PerClientFlags, .{ .change = 1, .value = 1 }, 130, false));
    try testing.expectEqual(@as(usize, 16), try proto.writeRequest(&buf, LatchLockState, .{}, 130, false));
    try testing.expectEqual(@as(usize, 16), try proto.writeRequest(&buf, SelectEvents, .{ .affect_which = 7, .select_all = 7 }, 130, false));
    try testing.expectEqual(@as(usize, 8), try proto.writeRequest(&buf, GetState, .{}, 130, false));
}

test "StateNotify and MapNotify decoding" {
    var ev: [32]u8 = @splat(0);
    ev[1] = EventType.state;
    ev[10] = 1; // Shift held
    ev[12] = 2; // Lock locked
    ev[13] = 1; // second group
    const s = decodeEvent(&ev).state;
    try testing.expectEqual(@as(u32, 1), s.mods().depressed);
    try testing.expectEqual(@as(u32, 2), s.mods().locked);
    try testing.expectEqual(@as(u8, 1), s.group);
    ev[1] = EventType.map;
    try testing.expect(decodeEvent(&ev) == .keymap_changed);
    ev[1] = 9;
    try testing.expect(decodeEvent(&ev) == .other);
}
