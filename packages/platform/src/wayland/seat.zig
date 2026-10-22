//! wl_seat input as plain state machines: the keyboard (keymap, modifiers,
//! text, compose, client-side repeat), the pointer (events grouped until
//! `frame`, click counting, scroll by source) and touch. The backend
//! decodes the protocol, converts surface coordinates to physical pixels
//! and calls these with its mutex held; events go to a sink with
//! `stage(Event)` and `text([]const u8) PayloadSlice`, so the logic is
//! tested without a compositor.

const std = @import("std");
const types = @import("../api/types.zig");
const keys = @import("../api/keys.zig");
const event_api = @import("../api/event.zig");
const xkb = @import("../xkb/keymap.zig");
const compose_mod = @import("../xkb/compose.zig");
const keysyms = @import("../xkb/keysyms.zig");
const evdevToKey = @import("../xkb/evdev.zig").evdevToKey;

const Event = event_api.Event;
const WindowId = types.WindowId;
const Keymap = xkb.Keymap;

/// Linux button codes (`BTN_*`).
pub const BTN = struct {
    /// BTN_LEFT.
    pub const left: u32 = 0x110;
    /// BTN_RIGHT.
    pub const right: u32 = 0x111;
    /// BTN_MIDDLE.
    pub const middle: u32 = 0x112;
    /// BTN_SIDE.
    pub const side: u32 = 0x113;
    /// BTN_EXTRA.
    pub const extra: u32 = 0x114;
    /// BTN_FORWARD.
    pub const forward: u32 = 0x115;
    /// BTN_BACK.
    pub const back: u32 = 0x116;
};

/// The `Button` for a `BTN_*` code; unknown codes are numbered after
/// the named ones.
pub fn buttonOf(code: u32) types.Button {
    return switch (code) {
        BTN.left => .left,
        BTN.right => .right,
        BTN.middle => .middle,
        BTN.side, BTN.back => .back,
        BTN.extra, BTN.forward => .forward,
        else => @enumFromInt(@as(u8, @truncate(5 + (code -% BTN.left)))),
    };
}

/// What the backend should do with the repeat timer after a key event.
pub const Repeat = union(enum) {
    /// Leave it as it is.
    keep,
    /// Fire first after `delay_ms`, then every `interval_ms`.
    arm: struct { delay_ms: u32, interval_ms: u32 },
    /// Stop it.
    disarm,
};

/// Real-modifier masks of the api modifiers, from the keymap's virtual
/// modifiers (with the usual real modifiers when a name is missing).
pub const Masks = struct {
    shift: u32 = 1 << 0,
    lock: u32 = 1 << 1,
    ctrl: u32 = 1 << 2,
    alt: u32 = 1 << 3,
    num: u32 = 1 << 4,
    super: u32 = 1 << 6,
    level3: u32 = 1 << 7,

    /// The masks `km` defines.
    pub fn of(km: *const Keymap) Masks {
        const d: Masks = .{};
        return .{
            .alt = orDefault(km.vmodMask("Alt"), d.alt),
            .num = orDefault(km.vmodMask("NumLock"), d.num),
            .super = orDefault(km.vmodMask("Super"), d.super),
            .level3 = orDefault(km.vmodMask("LevelThree"), d.level3),
        };
    }

    fn orDefault(v: u32, d: u32) u32 {
        return if (v == 0) d else v;
    }

    /// The api modifiers for a modifier state.
    pub fn mods(m: Masks, s: xkb.ModState) keys.Mods {
        const eff = s.depressed | s.latched | s.locked;
        return .{
            .shift = eff & m.shift != 0,
            .ctrl = eff & m.ctrl != 0,
            .alt = eff & m.alt != 0,
            .super = eff & m.super != 0,
            .alt_gr = eff & m.level3 != 0,
            .caps_lock = s.locked & m.lock != 0,
            .num_lock = s.locked & m.num != 0,
        };
    }
};

/// Click-count limits, as on Win32.
const double_click_ns: u64 = 500 * std.time.ns_per_ms;
const double_click_px: f32 = 4;

/// A wl_pointer axis.
pub const Axis = enum(u1) { vertical, horizontal };

/// A wl_pointer axis source.
pub const AxisSource = enum(u32) { wheel = 0, finger = 1, continuous = 2, wheel_tilt = 3, _ };

const Frame = struct {
    moved: bool = false,
    buttons: [8]struct { code: u32, pressed: bool } = undefined,
    n_buttons: u8 = 0,
    value: [2]f64 = .{ 0, 0 },
    has_value: [2]bool = .{ false, false },
    v120: [2]i32 = .{ 0, 0 },
    has_v120: [2]bool = .{ false, false },
    discrete: [2]i32 = .{ 0, 0 },
    stop: [2]bool = .{ false, false },
    source: ?AxisSource = null,
};

const TouchPoint = struct { id: i32, win: WindowId, pos: [2]f32, scale120: u32, phase: ?types.Phase = null };

/// One seat's input state.
pub const Seat = struct {
    // ---- keyboard ----
    keymap: ?Keymap = null,
    masks: Masks = .{},
    compose: ?compose_mod.ComposeState = null,
    state: xkb.ModState = .{},
    group: u32 = 0,
    kb_focus: ?WindowId = null,
    /// evdev codes held, for releases on leave.
    held: [32]u32 = undefined,
    n_held: u8 = 0,
    /// Repeat rate (per second; 0 disables) and delay (ms).
    rate: i32 = 25,
    delay: i32 = 600,
    repeat_key: ?u32 = null,
    /// Serials for activation, move/resize and selections.
    last_serial: u32 = 0,
    last_button_serial: u32 = 0,
    last_enter_serial: u32 = 0,

    // ---- pointer ----
    ptr_focus: ?WindowId = null,
    ptr_pos: [2]f32 = .{ 0, 0 },
    frame: Frame = .{},
    finger_scrolling: bool = false,
    last_click_ns: u64 = 0,
    last_click_pos: [2]f32 = .{ -100, -100 },
    last_click_button: types.Button = .left,
    clicks: u8 = 0,

    // ---- touch ----
    touches: [16]TouchPoint = undefined,
    n_touches: u8 = 0,

    /// Frees the keymap.
    pub fn deinit(s: *Seat, gpa: std.mem.Allocator) void {
        if (s.keymap) |*k| k.deinit(gpa);
        s.keymap = null;
    }

    /// Installs a freshly parsed keymap, freeing the old one.
    pub fn setKeymap(s: *Seat, gpa: std.mem.Allocator, km: Keymap) void {
        if (s.keymap) |*k| k.deinit(gpa);
        s.keymap = km;
        s.masks = Masks.of(&s.keymap.?);
        if (s.compose) |*c| c.reset();
    }

    /// The current api modifiers.
    pub fn mods(s: *const Seat) keys.Mods {
        return s.masks.mods(s.state);
    }

    // ---- keyboard ----

    /// `wl_keyboard.enter`: focus moves to `win`; the keys already held
    /// are remembered without press events.
    pub fn kbEnter(s: *Seat, out: anytype, win: WindowId, serial: u32, held_keys: []const u32) !void {
        s.kb_focus = win;
        s.last_serial = serial;
        s.n_held = 0;
        for (held_keys) |k| s.hold(k);
        try out.stage(.{ .window_focus = .{ .win = win, .focused = true } });
    }

    /// `wl_keyboard.leave`: held keys are released and repeat stops.
    pub fn kbLeave(s: *Seat, out: anytype, now_ns: u64) !Repeat {
        const win = s.kb_focus orelse return .disarm;
        for (s.held[0..s.n_held]) |k| try s.emitKey(out, win, k, .release, now_ns);
        s.n_held = 0;
        s.kb_focus = null;
        s.repeat_key = null;
        if (s.compose) |*c| c.reset();
        try out.stage(.{ .window_focus = .{ .win = win, .focused = false } });
        return .disarm;
    }

    /// `wl_keyboard.key`.
    pub fn key(s: *Seat, out: anytype, serial: u32, evdev: u32, pressed: bool, now_ns: u64) !Repeat {
        s.last_serial = serial;
        const win = s.kb_focus orelse return .keep;
        if (pressed) s.hold(evdev) else s.unhold(evdev);
        try s.emitKey(out, win, evdev, if (pressed) .press else .release, now_ns);
        if (pressed) {
            const repeats = if (s.keymap) |*km| km.repeats(evdev + 8) else true;
            if (repeats and s.rate > 0) {
                s.repeat_key = evdev;
                return .{ .arm = .{ .delay_ms = @intCast(@max(1, s.delay)), .interval_ms = @intCast(@max(1, @divTrunc(1000, s.rate))) } };
            }
            if (s.repeat_key != null) {
                s.repeat_key = null;
                return .disarm;
            }
            return .keep;
        }
        if (s.repeat_key == evdev) {
            s.repeat_key = null;
            return .disarm;
        }
        return .keep;
    }

    /// The repeat timer fired `n` times.
    pub fn repeatFired(s: *Seat, out: anytype, n: u64, now_ns: u64) !void {
        const k = s.repeat_key orelse return;
        const win = s.kb_focus orelse return;
        for (0..@min(n, 32)) |_| try s.emitKey(out, win, k, .repeat, now_ns);
    }

    /// A press from a server that repeats keys itself (X11 detectable
    /// autorepeat): if `evdev` is already held, emits a repeat and returns
    /// true; otherwise the caller handles it as a press with `key`.
    pub fn serverRepeat(s: *Seat, out: anytype, evdev: u32, now_ns: u64) !bool {
        const win = s.kb_focus orelse return false;
        for (s.held[0..s.n_held]) |h| if (h == evdev) {
            try s.emitKey(out, win, evdev, .repeat, now_ns);
            return true;
        };
        return false;
    }

    /// `wl_keyboard.modifiers`.
    pub fn modifiers(s: *Seat, serial: u32, depressed: u32, latched: u32, locked: u32, group: u32) void {
        s.last_serial = serial;
        s.state = .{ .depressed = depressed, .latched = latched, .locked = locked };
        s.group = group;
    }

    /// `wl_keyboard.repeat_info`.
    pub fn repeatInfo(s: *Seat, rate: i32, delay: i32) Repeat {
        s.rate = @max(0, rate);
        s.delay = @max(0, delay);
        if (s.rate == 0 and s.repeat_key != null) {
            s.repeat_key = null;
            return .disarm;
        }
        return .keep;
    }

    fn hold(s: *Seat, k: u32) void {
        for (s.held[0..s.n_held]) |h| if (h == k) return;
        if (s.n_held < s.held.len) {
            s.held[s.n_held] = k;
            s.n_held += 1;
        }
    }

    fn unhold(s: *Seat, k: u32) void {
        for (s.held[0..s.n_held], 0..) |h, i| if (h == k) {
            s.held[i] = s.held[s.n_held - 1];
            s.n_held -= 1;
            return;
        };
    }

    fn emitKey(s: *Seat, out: anytype, win: WindowId, evdev: u32, action: keys.KeyAction, now_ns: u64) !void {
        const m = s.mods();
        const code = evdev + 8;
        const sym = if (s.keymap) |*km| km.resolve(code, s.state, s.group).keysym else 0;
        const chord = (m.ctrl or m.alt) and !m.alt_gr;
        // Shortcuts report the key's first-level keysym, as on Win32.
        const keysym = if (chord) (if (s.keymap) |*km| km.resolve(code, .{}, s.group).keysym else sym) else sym;
        const cp: u21 = keysyms.keysymToCodepoint(sym) orelse 0;
        var text: types.PayloadSlice = .empty;
        var composed: ?[]const u8 = null;
        if (action != .release and !chord) {
            const st: compose_mod.Status = if (action == .press) (if (s.compose) |*c| c.feed(sym) else .nothing) else .nothing;
            switch (st) {
                .nothing => if (cp >= 0x20 and cp != 0x7f) {
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                    text = out.text(buf[0..n]);
                },
                .composing, .cancelled => {},
                .composed => composed = s.compose.?.result().utf8,
            }
        }
        try out.stage(.{ .key = .{ .win = win, .ev = .{
            .key = evdevToKey(@truncate(evdev)),
            .keysym = keysym,
            .codepoint = if (chord) 0 else cp,
            .mods = m,
            .action = action,
            .text = text,
            .native_scancode = @truncate(evdev),
            .time_ns = now_ns,
        } } });
        if (composed) |c| if (c.len > 0) try out.stage(.{ .text_input = .{ .win = win, .text = out.text(c) } });
    }

    // ---- pointer ----

    /// `wl_pointer.enter` at `pos` (physical pixels).
    pub fn ptrEnter(s: *Seat, out: anytype, win: WindowId, serial: u32, pos: [2]f32) !void {
        s.ptr_focus = win;
        s.last_enter_serial = serial;
        s.ptr_pos = pos;
        s.frame.moved = true;
        try out.stage(.{ .pointer_enter_leave = .{ .win = win, .entered = true } });
    }

    /// `wl_pointer.leave`.
    pub fn ptrLeave(s: *Seat, out: anytype) !void {
        const win = s.ptr_focus orelse return;
        s.ptr_focus = null;
        s.frame = .{};
        try out.stage(.{ .pointer_enter_leave = .{ .win = win, .entered = false } });
    }

    /// `wl_pointer.motion` to `pos` (physical pixels).
    pub fn ptrMotion(s: *Seat, pos: [2]f32) void {
        s.ptr_pos = pos;
        s.frame.moved = true;
    }

    /// `wl_pointer.button`.
    pub fn ptrButton(s: *Seat, serial: u32, code: u32, pressed: bool) void {
        s.last_serial = serial;
        if (pressed) s.last_button_serial = serial;
        const f = &s.frame;
        if (f.n_buttons < f.buttons.len) {
            f.buttons[f.n_buttons] = .{ .code = code, .pressed = pressed };
            f.n_buttons += 1;
        }
    }

    /// `wl_pointer.axis` (surface units).
    pub fn ptrAxis(s: *Seat, axis: Axis, value: f64) void {
        s.frame.value[@intFromEnum(axis)] += value;
        s.frame.has_value[@intFromEnum(axis)] = true;
    }

    /// `wl_pointer.axis_value120`.
    pub fn ptrAxis120(s: *Seat, axis: Axis, v120: i32) void {
        s.frame.v120[@intFromEnum(axis)] += v120;
        s.frame.has_v120[@intFromEnum(axis)] = true;
    }

    /// `wl_pointer.axis_discrete` (before v8).
    pub fn ptrAxisDiscrete(s: *Seat, axis: Axis, steps: i32) void {
        s.frame.discrete[@intFromEnum(axis)] += steps;
    }

    /// `wl_pointer.axis_source`.
    pub fn ptrAxisSource(s: *Seat, src: AxisSource) void {
        s.frame.source = src;
    }

    /// `wl_pointer.axis_stop`.
    pub fn ptrAxisStop(s: *Seat, axis: Axis) void {
        s.frame.stop[@intFromEnum(axis)] = true;
    }

    /// `wl_pointer.frame`: emits what the frame gathered. `scale120`
    /// converts finger scrolling to physical pixels.
    pub fn ptrFrame(s: *Seat, out: anytype, now_ns: u64, scale120: u32) !void {
        const f = s.frame;
        s.frame = .{};
        const win = s.ptr_focus orelse return;
        const m = s.mods();
        if (f.moved) try out.stage(.{ .pointer_move = .{ .win = win, .pos_px = s.ptr_pos, .mods = m, .time_ns = now_ns } });
        for (f.buttons[0..f.n_buttons]) |b| {
            const button = buttonOf(b.code);
            if (b.pressed) {
                const near = @abs(s.ptr_pos[0] - s.last_click_pos[0]) <= double_click_px and @abs(s.ptr_pos[1] - s.last_click_pos[1]) <= double_click_px;
                if (button == s.last_click_button and near and now_ns -| s.last_click_ns <= double_click_ns and s.clicks < 3) s.clicks += 1 else s.clicks = 1;
                s.last_click_ns = now_ns;
                s.last_click_pos = s.ptr_pos;
                s.last_click_button = button;
            }
            try out.stage(.{ .pointer_button = .{ .win = win, .button = button, .pressed = b.pressed, .pos_px = s.ptr_pos, .mods = m, .clicks = if (b.pressed) s.clicks else 0, .time_ns = now_ns } });
        }
        try s.scrollOf(out, win, f, scale120);
    }

    fn scrollOf(s: *Seat, out: anytype, win: WindowId, f: Frame, scale120: u32) !void {
        const any_value = f.has_value[0] or f.has_value[1];
        const any_stop = f.stop[0] or f.stop[1];
        if (!any_value and !any_stop) return;
        const src = f.source orelse (if (f.has_v120[0] or f.has_v120[1] or f.discrete[0] != 0 or f.discrete[1] != 0) AxisSource.wheel else AxisSource.continuous);
        switch (src) {
            .wheel, .wheel_tilt => {
                // Lines: value120 when the compositor sends it, else
                // discrete steps, else the conventional 10 units a notch.
                var d: [2]f32 = .{ 0, 0 };
                for (0..2) |i| d[i] = if (f.has_v120[i])
                    @as(f32, @floatFromInt(f.v120[i])) / 120
                else if (f.discrete[i] != 0)
                    @floatFromInt(f.discrete[i])
                else
                    @floatCast(f.value[i] / 10);
                if (d[0] == 0 and d[1] == 0) return;
                try out.stage(.{ .scroll = .{ .win = win, .dx = d[1], .dy = d[0], .unit = .lines, .source = if (src == .wheel_tilt) .wheel_tilt else .wheel, .phase = .none } });
            },
            else => {
                const k: f64 = @as(f64, @floatFromInt(scale120)) / 120;
                const finger = src == .finger;
                const phase: types.Phase = if (!finger) .none else if (any_stop and !any_value) .end else if (!s.finger_scrolling) .begin else .update;
                if (finger) s.finger_scrolling = phase != .end;
                try out.stage(.{ .scroll = .{
                    .win = win,
                    .dx = @floatCast(f.value[1] * k),
                    .dy = @floatCast(f.value[0] * k),
                    .unit = .pixels,
                    .source = if (finger) .finger else .continuous,
                    .phase = phase,
                } });
                if (finger and any_stop and any_value) {
                    s.finger_scrolling = false;
                    try out.stage(.{ .scroll = .{ .win = win, .dx = 0, .dy = 0, .unit = .pixels, .source = .finger, .phase = .end } });
                }
            },
        }
    }

    // ---- touch ----

    /// `wl_touch.down` at `pos` (physical pixels) on `win`.
    pub fn touchDown(s: *Seat, serial: u32, win: WindowId, id: i32, pos: [2]f32, scale120: u32) void {
        s.last_serial = serial;
        if (s.find(id)) |t| {
            t.* = .{ .id = id, .win = win, .pos = pos, .scale120 = scale120, .phase = .begin };
            return;
        }
        if (s.n_touches == s.touches.len) return;
        s.touches[s.n_touches] = .{ .id = id, .win = win, .pos = pos, .scale120 = scale120, .phase = .begin };
        s.n_touches += 1;
    }

    /// `wl_touch.motion` in surface units; the point keeps its surface's
    /// scale from `down`.
    pub fn touchMotion(s: *Seat, id: i32, surface_pos: [2]f64) void {
        const t = s.find(id) orelse return;
        const k: f64 = @as(f64, @floatFromInt(t.scale120)) / 120;
        t.pos = .{ @floatCast(surface_pos[0] * k), @floatCast(surface_pos[1] * k) };
        if (t.phase == null) t.phase = .update;
    }

    /// `wl_touch.up`.
    pub fn touchUp(s: *Seat, serial: u32, id: i32) void {
        s.last_serial = serial;
        const t = s.find(id) orelse return;
        t.phase = .end;
    }

    /// `wl_touch.cancel`: every point is cancelled.
    pub fn touchCancel(s: *Seat, out: anytype) !void {
        for (s.touches[0..s.n_touches]) |t| try out.stage(.{ .touch = .{ .win = t.win, .id = t.id, .phase = .cancel, .pos_px = t.pos } });
        s.n_touches = 0;
    }

    /// `wl_touch.frame`: emits the changed points.
    pub fn touchFrame(s: *Seat, out: anytype) !void {
        var i: usize = 0;
        while (i < s.n_touches) {
            const t = &s.touches[i];
            if (t.phase) |ph| try out.stage(.{ .touch = .{ .win = t.win, .id = t.id, .phase = ph, .pos_px = t.pos } });
            if (t.phase == .end) {
                s.touches[i] = s.touches[s.n_touches - 1];
                s.n_touches -= 1;
                continue;
            }
            t.phase = null;
            i += 1;
        }
    }

    fn find(s: *Seat, id: i32) ?*TouchPoint {
        for (s.touches[0..s.n_touches]) |*t| if (t.id == id) return t;
        return null;
    }

    /// Forgets a destroyed window.
    pub fn forget(s: *Seat, win: WindowId) void {
        if (s.kb_focus == win) {
            s.kb_focus = null;
            s.n_held = 0;
            s.repeat_key = null;
        }
        if (s.ptr_focus == win) s.ptr_focus = null;
        var i: usize = 0;
        while (i < s.n_touches) {
            if (s.touches[i].win == win) {
                s.touches[i] = s.touches[s.n_touches - 1];
                s.n_touches -= 1;
            } else i += 1;
        }
    }
};

// ---- tests ----

const testing = std.testing;

/// Records events; text payloads are kept in a list.
const Rec = struct {
    events: std.ArrayList(Event) = .empty,
    texts: std.ArrayList([]u8) = .empty,

    fn deinit(r: *Rec) void {
        for (r.texts.items) |t| testing.allocator.free(t);
        r.texts.deinit(testing.allocator);
        r.events.deinit(testing.allocator);
    }

    /// Records `ev`.
    pub fn stage(r: *Rec, ev: Event) !void {
        try r.events.append(testing.allocator, ev);
    }

    /// Keeps a copy of `bytes`; `off` is its index.
    pub fn text(r: *Rec, bytes: []const u8) types.PayloadSlice {
        const owned = testing.allocator.dupe(u8, bytes) catch return .empty;
        r.texts.append(testing.allocator, owned) catch {
            testing.allocator.free(owned);
            return .empty;
        };
        return .{ .off = @intCast(r.texts.items.len - 1), .len = @intCast(bytes.len) };
    }

    fn textOf(r: *const Rec, p: types.PayloadSlice) []const u8 {
        if (p.len == 0) return "";
        return r.texts.items[p.off];
    }
};

const us_keymap = @embedFile("../xkb/testdata/us.xkb");

fn seatWithKeymap() !Seat {
    var s: Seat = .{};
    s.setKeymap(testing.allocator, try Keymap.parse(testing.allocator, us_keymap));
    return s;
}

const w1: WindowId = @enumFromInt(1);
const KEY_A = 30;
const KEY_LEFTSHIFT = 42;

test "enter does not emit presses; leave releases held keys" {
    var s = try seatWithKeymap();
    defer s.deinit(testing.allocator);
    var r: Rec = .{};
    defer r.deinit();
    try s.kbEnter(&r, w1, 5, &.{ KEY_A, KEY_LEFTSHIFT });
    try testing.expectEqual(@as(usize, 1), r.events.items.len);
    try testing.expect(r.events.items[0] == .window_focus);
    r.events.clearRetainingCapacity();
    try testing.expectEqual(Repeat.disarm, try s.kbLeave(&r, 0));
    var releases: usize = 0;
    for (r.events.items) |e| if (e == .key) {
        try testing.expectEqual(keys.KeyAction.release, e.key.ev.action);
        releases += 1;
    };
    try testing.expectEqual(@as(usize, 2), releases);
    try testing.expect(r.events.items[r.events.items.len - 1].window_focus.focused == false);
}

test "keys resolve through the keymap; shift and ctrl" {
    var s = try seatWithKeymap();
    defer s.deinit(testing.allocator);
    var r: Rec = .{};
    defer r.deinit();
    try s.kbEnter(&r, w1, 1, &.{});
    const rep = try s.key(&r, 2, KEY_A, true, 0);
    try testing.expect(rep == .arm);
    const a = r.events.items[1].key.ev;
    try testing.expectEqual(keys.Key.key_a, a.key);
    try testing.expectEqual(@as(u32, 'a'), a.keysym);
    try testing.expectEqualStrings("a", r.textOf(a.text));
    s.modifiers(3, 1, 0, 0, 0); // Shift
    _ = try s.key(&r, 4, KEY_A, true, 0);
    const big = r.events.items[2].key.ev;
    try testing.expectEqualStrings("A", r.textOf(big.text));
    try testing.expect(big.mods.shift);
    s.modifiers(5, 4, 0, 0, 0); // Control
    _ = try s.key(&r, 6, KEY_A, true, 0);
    const ctl = r.events.items[3].key.ev;
    try testing.expect(ctl.mods.ctrl);
    try testing.expectEqual(@as(usize, 0), ctl.text.len);
    try testing.expectEqual(@as(u32, 'a'), ctl.keysym);
    try testing.expectEqual(Repeat.disarm, try s.key(&r, 7, KEY_A, false, 0));
}

test "repeat fires for the held key; rate 0 disables" {
    var s = try seatWithKeymap();
    defer s.deinit(testing.allocator);
    var r: Rec = .{};
    defer r.deinit();
    try s.kbEnter(&r, w1, 1, &.{});
    _ = s.repeatInfo(40, 300);
    const rep = try s.key(&r, 2, KEY_A, true, 0);
    try testing.expectEqual(@as(u32, 300), rep.arm.delay_ms);
    try testing.expectEqual(@as(u32, 25), rep.arm.interval_ms);
    r.events.clearRetainingCapacity();
    try s.repeatFired(&r, 3, 0);
    try testing.expectEqual(@as(usize, 3), r.events.items.len);
    for (r.events.items) |e| try testing.expectEqual(keys.KeyAction.repeat, e.key.ev.action);
    try testing.expectEqual(Repeat.disarm, s.repeatInfo(0, 300));
    try testing.expectEqual(Repeat.keep, try s.key(&r, 4, KEY_A, true, 0));
}

test "detectable autorepeat: a second press of a held key repeats" {
    var s = try seatWithKeymap();
    defer s.deinit(testing.allocator);
    var r: Rec = .{};
    defer r.deinit();
    try s.kbEnter(&r, w1, 1, &.{});
    try testing.expect(!try s.serverRepeat(&r, KEY_A, 0));
    _ = try s.key(&r, 0, KEY_A, true, 0);
    try testing.expect(try s.serverRepeat(&r, KEY_A, 0));
    try testing.expect(try s.serverRepeat(&r, KEY_A, 0));
    _ = try s.key(&r, 0, KEY_A, false, 0);
    try testing.expect(!try s.serverRepeat(&r, KEY_A, 0));
    const ev = r.events.items[1..];
    try testing.expectEqual(@as(usize, 4), ev.len);
    try testing.expectEqual(keys.KeyAction.press, ev[0].key.ev.action);
    try testing.expectEqual(keys.KeyAction.repeat, ev[1].key.ev.action);
    try testing.expectEqualStrings("a", r.textOf(ev[2].key.ev.text));
    try testing.expectEqual(keys.KeyAction.release, ev[3].key.ev.action);
}

test "dead key + letter → one composed text_input" {
    var table = try compose_mod.ComposeTable.parse(testing.allocator, testing.io, "<dead_acute> <e> : \"é\" eacute\n", .{});
    defer table.deinit(testing.allocator);
    var s = try seatWithKeymap();
    defer s.deinit(testing.allocator);
    s.compose = .init(&table);
    var r: Rec = .{};
    defer r.deinit();
    try s.kbEnter(&r, w1, 1, &.{});
    // Feed the keysyms directly: the us keymap has no dead keys.
    try testing.expectEqual(compose_mod.Status.composing, s.compose.?.feed(0xfe51)); // dead_acute
    _ = try s.key(&r, 2, 18, true, 0); // KEY_E
    var composed: ?[]const u8 = null;
    for (r.events.items) |e| switch (e) {
        .key => |k| try testing.expectEqual(@as(usize, 0), k.ev.text.len),
        .text_input => |t| composed = r.textOf(t.text),
        else => {},
    };
    try testing.expectEqualStrings("é", composed.?);
}

test "frame groups motion, buttons and scroll; click counting" {
    var s: Seat = .{};
    var r: Rec = .{};
    defer r.deinit();
    try s.ptrEnter(&r, w1, 9, .{ 10, 10 });
    s.ptrMotion(.{ 20, 30 });
    s.ptrButton(10, BTN.left, true);
    s.ptrAxisSource(.wheel);
    s.ptrAxis120(.vertical, 60);
    s.ptrAxis(.vertical, 7.5);
    try s.ptrFrame(&r, 1000, 120);
    try testing.expect(r.events.items[0] == .pointer_enter_leave);
    try testing.expectEqual([2]f32{ 20, 30 }, r.events.items[1].pointer_move.pos_px);
    try testing.expectEqual(@as(u8, 1), r.events.items[2].pointer_button.clicks);
    const sc = r.events.items[3].scroll;
    try testing.expectEqual(@as(f32, 0.5), sc.dy);
    try testing.expectEqual(event_api.ScrollUnit.lines, sc.unit);
    try testing.expectEqual(@as(u32, 10), s.last_button_serial);
    s.ptrButton(11, BTN.left, false);
    s.ptrButton(12, BTN.left, true);
    try s.ptrFrame(&r, 2000, 120);
    try testing.expectEqual(@as(u8, 2), r.events.items[5].pointer_button.clicks);
    try testing.expectEqual(types.Button.back, buttonOf(BTN.side));
}

test "finger scrolling: pixels by scale, begin/update/end" {
    var s: Seat = .{};
    var r: Rec = .{};
    defer r.deinit();
    try s.ptrEnter(&r, w1, 1, .{ 0, 0 });
    try s.ptrFrame(&r, 0, 240);
    r.events.clearRetainingCapacity();
    s.ptrAxisSource(.finger);
    s.ptrAxis(.vertical, 3);
    try s.ptrFrame(&r, 0, 240);
    s.ptrAxisSource(.finger);
    s.ptrAxis(.horizontal, -1);
    try s.ptrFrame(&r, 0, 240);
    s.ptrAxisSource(.finger);
    s.ptrAxisStop(.vertical);
    try s.ptrFrame(&r, 0, 240);
    const e = r.events.items;
    try testing.expectEqual(types.Phase.begin, e[0].scroll.phase);
    try testing.expectEqual(@as(f32, 6), e[0].scroll.dy);
    try testing.expectEqual(types.Phase.update, e[1].scroll.phase);
    try testing.expectEqual(@as(f32, -2), e[1].scroll.dx);
    try testing.expectEqual(types.Phase.end, e[2].scroll.phase);
}

test "touch points by frame" {
    var s: Seat = .{};
    var r: Rec = .{};
    defer r.deinit();
    s.touchDown(1, w1, 4, .{ 10, 20 }, 240);
    s.touchDown(1, w1, 5, .{ 30, 40 }, 240);
    try s.touchFrame(&r);
    try testing.expectEqual(@as(usize, 2), r.events.items.len);
    s.touchMotion(4, .{ 6, 7 });
    s.touchUp(2, 5);
    try s.touchFrame(&r);
    try testing.expectEqual([2]f32{ 12, 14 }, r.events.items[2].touch.pos_px);
    try testing.expectEqual(types.Phase.update, r.events.items[2].touch.phase);
    try testing.expectEqual(types.Phase.end, r.events.items[3].touch.phase);
    try s.touchCancel(&r);
    try testing.expectEqual(types.Phase.cancel, r.events.items[4].touch.phase);
    try testing.expectEqual(@as(u8, 0), s.n_touches);
}
