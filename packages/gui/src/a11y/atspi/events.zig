//! AT-SPI2 events (E04.F09.S01.T03): a tree update as
//! `org.a11y.atspi.Event.Object` signals, signature `siiva{sv}` (detail,
//! detail1, detail2, any data, properties), plus `Event.Focus.Focus` and
//! `Event.Window.Activate`/`Deactivate`.
//!
//! - focus: `StateChanged("focused", 1, 0)` and `Focus`;
//! - state flips: `StateChanged("checked" | "expanded" | "selected" |
//!   "enabled" | "sensitive", on, 0)`;
//! - names: `PropertyChange("accessible-name", 0, 0, name)`;
//! - range values: `PropertyChange("accessible-value", 0, 0, value)`;
//! - text edits: `TextChanged("delete" | "insert", start, length, text)`
//!   in characters (the deleted text is gone from the new snapshot, so its
//!   length is in bytes);
//! - nodes added: `ChildrenChanged("add", index, 0, child)` on the parent,
//!   for the topmost added node only; removed: `StateChanged("defunct")`
//!   on each (up to `max_defunct`) and `ChildrenChanged("remove", -1, 0,
//!   null)` on parents that lost children;
//! - announcements: `Announcement("", politeness, 0, text)`.

const std = @import("std");
const zg_platform = @import("zg_platform");
const tree_mod = @import("../tree.zig");
const snap = @import("../snapshot.zig");
const objects = @import("objects.zig");

const dbus = zg_platform.dbus;
const Bus = dbus.Bus;
const Value = dbus.Value;
const Update = tree_mod.Update;
const Snapshot = snap.Snapshot;
const Node = snap.Node;
const Ref = objects.Ref;

pub const object_iface = "org.a11y.atspi.Event.Object";
pub const focus_iface = "org.a11y.atspi.Event.Focus";
pub const window_iface = "org.a11y.atspi.Event.Window";
/// The signature of every event signal.
pub const sig = "siiva{sv}";

/// A property of the trailing `a{sv}` (always empty here).
pub const Prop = struct { []const u8, Value };

const no_props: []const Prop = &.{};

/// The body of an event signal.
pub fn Body(comptime Any: type) type {
    return struct { []const u8, i32, i32, Any, []const Prop };
}

/// The arguments of an event signal; `any` is a `variantOf(...)`.
pub fn body(detail: []const u8, d1: i32, d2: i32, any: anytype) Body(@TypeOf(any)) {
    return .{ detail, d1, d2, any, no_props };
}

/// The default any-data: `int32 0`.
pub fn zero() dbus.marshal.Variant("i", i32) {
    return dbus.marshal.variantOf("i", @as(i32, 0));
}

fn emit(bus: *Bus, path: []const u8, iface: []const u8, member: []const u8, detail: []const u8, d1: i32, d2: i32, any: anytype) dbus.conn.Error!void {
    try bus.emit(path, iface, member, sig, body(detail, d1, d2, any));
}

/// `StateChanged("defunct", 1, 0)`: the object at `path` is gone.
pub fn emitDefunct(bus: *Bus, path: []const u8) dbus.conn.Error!void {
    try emit(bus, path, object_iface, "StateChanged", "defunct", 1, 0, zero());
}

/// Nodes marked defunct per update at most (a closed list drops many).
pub const max_defunct = 64;

/// Emits the signals for update `u`; returns how many went out.
/// `was_active` tracks the window's activation between updates.
pub fn emitUpdate(bus: *Bus, u: *const Update, was_active: *bool) dbus.conn.Error!u64 {
    const s = u.snapshot;
    const me = bus.unique_name;
    var n: u64 = 0;
    var pb: objects.PathBuf = undefined;
    var cb: objects.PathBuf = undefined;

    if (s.active != was_active.*) {
        was_active.* = s.active;
        if (s.root()) |r| {
            const p = objects.pathOf(r.id, &pb);
            try emit(bus, p, window_iface, if (s.active) "Activate" else "Deactivate", "", 0, 0, dbus.marshal.variantOf("s", r.name));
            try emit(bus, p, object_iface, "StateChanged", "active", @intFromBool(s.active), 0, zero());
            n += 2;
        }
    }

    for (u.added) |id| {
        const i = s.index.get(id) orelse continue;
        const node = &s.nodes[i];
        if (node.parent == Node.no_parent) continue;
        const parent = &s.nodes[node.parent];
        // Only the topmost new node: its subtree comes with it.
        if (containsId(u.added, parent.id)) continue;
        const at = std.mem.indexOfScalar(u32, s.children(parent), i) orelse continue;
        const child: Ref = .{ .name = me, .path = objects.pathOf(id, &cb) };
        try emit(bus, objects.pathOf(parent.id, &pb), object_iface, "ChildrenChanged", "add", @intCast(at), 0, dbus.marshal.variantOf("(so)", child));
        n += 1;
    }
    for (u.removed[0..@min(u.removed.len, max_defunct)]) |id| {
        try emitDefunct(bus, objects.pathOf(id, &pb));
        n += 1;
    }

    for (u.events) |ev| switch (ev) {
        .focus_changed => |id| {
            if (id == 0) continue;
            const p = objects.pathOf(id, &pb);
            try emit(bus, p, object_iface, "StateChanged", "focused", 1, 0, zero());
            try emit(bus, p, focus_iface, "Focus", "", 0, 0, zero());
            n += 2;
        },
        .state_changed => |sc| {
            const node = s.find(sc.id) orelse continue;
            const st = node.state;
            const p = objects.pathOf(sc.id, &pb);
            const Flip = struct { on: bool, flipped: bool, name: []const u8 };
            const flips = [_]Flip{
                .{ .on = st.checked, .flipped = sc.mask.checked, .name = "checked" },
                .{ .on = st.expanded, .flipped = sc.mask.expanded, .name = "expanded" },
                .{ .on = st.selected, .flipped = sc.mask.selected, .name = "selected" },
                .{ .on = !st.disabled, .flipped = sc.mask.disabled, .name = "enabled" },
                .{ .on = !st.disabled, .flipped = sc.mask.disabled, .name = "sensitive" },
            };
            for (flips) |f| if (f.flipped) {
                try emit(bus, p, object_iface, "StateChanged", f.name, @intFromBool(f.on), 0, zero());
                n += 1;
            };
        },
        .name_changed => |id| {
            const node = s.find(id) orelse continue;
            try emit(bus, objects.pathOf(id, &pb), object_iface, "PropertyChange", "accessible-name", 0, 0, dbus.marshal.variantOf("s", node.name));
            n += 1;
        },
        .value_changed => |id| {
            const node = s.find(id) orelse continue;
            const v = node.value orelse continue;
            try emit(bus, objects.pathOf(id, &pb), object_iface, "PropertyChange", "accessible-value", 0, 0, dbus.marshal.variantOf("d", @as(f64, v)));
            n += 1;
        },
        .text_changed => |tc| {
            const node = s.find(tc.id) orelse continue;
            const text = node.text;
            const start = @min(tc.start, text.len);
            const end = @min(start + tc.inserted, text.len);
            const at = chars(text[0..start]);
            const p = objects.pathOf(tc.id, &pb);
            if (tc.removed > 0) {
                try emit(bus, p, object_iface, "TextChanged", "delete", at, @intCast(tc.removed), dbus.marshal.variantOf("s", @as([]const u8, "")));
                n += 1;
            }
            if (end > start) {
                const ins = validPrefix(text[start..end]);
                try emit(bus, p, object_iface, "TextChanged", "insert", at, chars(ins), dbus.marshal.variantOf("s", ins));
                n += 1;
            }
        },
        .children_changed => |id| {
            if (u.removed.len == 0) continue;
            try emit(bus, objects.pathOf(id, &pb), object_iface, "ChildrenChanged", "remove", -1, 0, dbus.marshal.variantOf("(so)", Ref.none));
            n += 1;
        },
        .announcement => |a| {
            const root = s.root() orelse continue;
            const politeness: i32 = if (a.assertive) 2 else 1;
            try emit(bus, objects.pathOf(root.id, &pb), object_iface, "Announcement", "", politeness, 0, dbus.marshal.variantOf("s", validPrefix(a.text)));
            n += 1;
        },
        .menu_opened, .menu_closed => {},
    };
    return n;
}

fn containsId(ids: []const u64, id: u64) bool {
    return std.mem.indexOfScalar(u64, ids, id) != null;
}

/// Code points in UTF-8 `s` (ill-formed bytes count one each).
pub fn chars(s: []const u8) i32 {
    var n: i32 = 0;
    for (s) |c| {
        if (c & 0xC0 != 0x80) n += 1;
    }
    return n;
}

/// The longest well-formed UTF-8 prefix (D-Bus strings must be valid).
fn validPrefix(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and !std.unicode.utf8ValidateSlice(s[0..end])) end -= 1;
    return s[0..end];
}
