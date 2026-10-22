//! AT-SPI2 interfaces (E04.F09.S01.T03): answers method calls on the
//! application object and on node paths, reading the window's current
//! snapshot. Runs on the accessibility bus's reader under `Bridge.lock`.
//!
//! Served: `Accessible`, `Application` (root), `Component`, `Action`,
//! `Value`, `Text` (read side), `Selection`, `DBus.Properties` and
//! `DBus.Introspectable`. A path whose node is gone answers
//! `org.freedesktop.Ddbus.conn.Error.UnknownObject`.

const std = @import("std");
const zg_platform = @import("zg_platform");
const zg_text = @import("zg_text");
const widget = @import("../../core/widget.zig");
const snap = @import("../snapshot.zig");
const bridge_mod = @import("bridge.zig");
const objects = @import("objects.zig");
const roles = @import("roles.zig");
const states = @import("states.zig");
const introspect = @import("introspect.zig");

const dbus = zg_platform.dbus;
const Bus = dbus.Bus;
const Incoming = dbus.conn.Incoming;
const Value = dbus.Value;
const Allocator = std.mem.Allocator;
const Bridge = bridge_mod.Bridge;
const Win = bridge_mod.Win;
const Snapshot = snap.Snapshot;
const Node = snap.Node;
const Ref = objects.Ref;
const word = zg_text.unicode.word;

pub const unknown_object = "org.freedesktop.Ddbus.conn.Error.UnknownObject";
pub const invalid_args = "org.freedesktop.Ddbus.conn.Error.InvalidArgs";
pub const unknown_property = "org.freedesktop.Ddbus.conn.Error.UnknownProperty";

const props_iface = "org.freedesktop.DBus.Properties";
const introspectable_iface = "org.freedesktop.DBus.Introspectable";
const accessible_iface = "org.a11y.atspi.Accessible";
const application_iface = "org.a11y.atspi.Application";
const component_iface = "org.a11y.atspi.Component";
const action_iface = "org.a11y.atspi.Action";
const value_iface = "org.a11y.atspi.Value";
const text_iface = "org.a11y.atspi.Text";
const selection_iface = "org.a11y.atspi.Selection";

/// `AtspiCoordType`.
pub const Coord = enum(u32) { screen = 0, window = 1, parent = 2, _ };

/// `AtspiTextGranularity`.
pub const Granularity = enum(u32) { char = 0, word = 1, sentence = 2, line = 3, paragraph = 4, _ };

/// A property of `GetAll`.
const Prop = struct { []const u8, Value };

/// Answers `in`; false lets the bus reply `UnknownMethod`.
pub fn dispatch(b: *Bridge, bus: *Bus, in: *const Incoming) bool {
    const hd = &in.msg.header;
    const path = hd.path orelse return false;
    const member = hd.member orelse return false;
    var cx: Cx = .{ .b = b, .bus = bus, .in = in, .a = in.arena, .iface = hd.interface orelse "", .member = member };
    const target = objects.parse(path) orelse {
        bus.replyError(in, unknown_object, "No such object") catch {};
        return true;
    };
    switch (target) {
        .application => return cx.application() catch true,
        .node => |id| {
            const h = hold(b, id) orelse {
                bus.replyError(in, unknown_object, "The object is gone") catch {};
                return true;
            };
            defer h.s.release();
            return cx.node(h) catch true;
        },
    }
}

/// A node with its snapshot held (release `s`).
pub const Held = struct { w: *Win, s: *Snapshot, n: *const Node };

/// Node `id` in its window's current snapshot (under `Bridge.lock`).
pub fn hold(b: *Bridge, id: u64) ?Held {
    const w = b.window(@truncate(id >> 32)) orelse return null;
    const s = w.tree.snapshot() orelse return null;
    const n = s.find(id) orelse {
        s.release();
        return null;
    };
    return .{ .w = w, .s = s, .n = n };
}

const Cx = struct {
    b: *Bridge,
    bus: *Bus,
    in: *const Incoming,
    a: Allocator,
    iface: []const u8,
    member: []const u8,

    const E = dbus.conn.Error || Allocator.Error || error{BadArgs};

    fn is(cx: *const Cx, iface: []const u8, member: []const u8) bool {
        // A call without an interface matches by member alone.
        return std.mem.eql(u8, cx.member, member) and (cx.iface.len == 0 or std.mem.eql(u8, cx.iface, iface));
    }

    fn reply(cx: *const Cx, comptime sig: []const u8, out: anytype) E!bool {
        try cx.bus.replyTo(cx.in, sig, out);
        return true;
    }

    fn fail(cx: *const Cx, name: []const u8, msg: []const u8) E!bool {
        try cx.bus.replyError(cx.in, name, msg);
        return true;
    }

    fn args(cx: *const Cx) E![]Value {
        return cx.in.args() catch error.BadArgs;
    }

    fn argI32(cx: *const Cx, i: usize) E!i32 {
        const a = try cx.args();
        if (i >= a.len) return error.BadArgs;
        return switch (a[i].unwrap()) {
            .i32 => |x| x,
            .u32 => |x| @bitCast(x),
            else => error.BadArgs,
        };
    }

    fn argU32(cx: *const Cx, i: usize) E!u32 {
        return @bitCast(try cx.argI32(i));
    }

    fn argStr(cx: *const Cx, i: usize) E![]const u8 {
        const a = try cx.args();
        if (i >= a.len) return error.BadArgs;
        return a[i].asString() orelse error.BadArgs;
    }

    fn refOf(cx: *const Cx, id: u64) E!Ref {
        return .{ .name = cx.bus.unique_name, .path = try objects.pathAlloc(cx.a, id) };
    }

    fn rootRef(cx: *const Cx) Ref {
        return .{ .name = cx.bus.unique_name, .path = objects.root_path };
    }

    fn refValue(cx: *const Cx, r: Ref) E!Value {
        const items = try cx.a.alloc(Value, 2);
        items[0] = .{ .string = r.name };
        items[1] = .{ .object_path = r.path };
        return .{ .structure = items };
    }

    // -- the application object ---------------------------------------------------------

    fn application(cx: *Cx) E!bool {
        const b = cx.b;
        if (cx.is(introspectable_iface, "Introspect")) return cx.reply("s", .{try introspect.xml(cx.a, roles.application_ifaces)});
        if (cx.is(props_iface, "Get") or cx.is(props_iface, "GetAll")) {
            const all = try cx.appProps(try cx.argStr(0));
            return cx.answerProps(all);
        }
        if (cx.is(props_iface, "Set")) {
            if (!std.mem.eql(u8, try cx.argStr(1), "Id")) return cx.fail(unknown_property, "Read-only property");
            const a = try cx.args();
            if (a.len < 3) return error.BadArgs;
            b.app_id = switch (a[2].unwrap()) {
                .i32 => |x| x,
                else => return error.BadArgs,
            };
            return cx.reply("", .{});
        }
        if (cx.is(accessible_iface, "GetChildAtIndex")) {
            const i = try cx.argI32(0);
            if (i < 0 or i >= b.windows.items.len) return cx.reply("(so)", .{Ref.none});
            return cx.reply("(so)", .{try cx.windowRef(b.windows.items[@intCast(i)])});
        }
        if (cx.is(accessible_iface, "GetChildren")) {
            var refs: std.ArrayList(Ref) = .empty;
            for (b.windows.items) |w| {
                const r = try cx.windowRef(w);
                if (r.path.ptr != Ref.none.path.ptr) try refs.append(cx.a, r);
            }
            return cx.reply("a(so)", .{refs.items});
        }
        if (cx.is(accessible_iface, "GetIndexInParent")) return cx.reply("i", .{@as(i32, -1)});
        if (cx.is(accessible_iface, "GetRelationSet")) return cx.reply("a(ua(so))", .{&[_]struct { u32, []const Ref }{}});
        if (cx.is(accessible_iface, "GetRole")) return cx.reply("u", .{roles.atspi.application});
        if (cx.is(accessible_iface, "GetRoleName") or cx.is(accessible_iface, "GetLocalizedRoleName")) return cx.reply("s", .{roles.name(roles.atspi.application)});
        if (cx.is(accessible_iface, "GetState")) return cx.reply("au", .{&[_]u32{ 0, 0 }});
        if (cx.is(accessible_iface, "GetAttributes")) return cx.reply("a{ss}", .{&[_]struct { []const u8, []const u8 }{.{ "toolkit", "zigguro" }}});
        if (cx.is(accessible_iface, "GetApplication")) return cx.reply("(so)", .{Ref.none});
        if (cx.is(accessible_iface, "GetInterfaces")) {
            var buf: [roles.Ifaces.names.len][]const u8 = undefined;
            return cx.reply("as", .{roles.application_ifaces.list(&buf)});
        }
        if (cx.is(application_iface, "GetLocale")) return cx.reply("s", .{@as([]const u8, "")});
        return false;
    }

    fn windowRef(cx: *const Cx, w: *Win) E!Ref {
        const s = w.tree.snapshot() orelse return Ref.none;
        defer s.release();
        const r = s.root() orelse return Ref.none;
        return cx.refOf(r.id);
    }

    fn appProps(cx: *const Cx, iface: []const u8) E![]const Prop {
        const b = cx.b;
        if (std.mem.eql(u8, iface, accessible_iface)) {
            const out = try cx.a.alloc(Prop, 7);
            out[0] = .{ "Name", .{ .string = b.app_name } };
            out[1] = .{ "Description", .{ .string = "" } };
            out[2] = .{ "Parent", try cx.refValue(b.parentRef()) };
            out[3] = .{ "ChildCount", .{ .i32 = @intCast(b.windows.items.len) } };
            out[4] = .{ "Locale", .{ .string = "" } };
            out[5] = .{ "AccessibleId", .{ .string = "" } };
            out[6] = .{ "HelpText", .{ .string = "" } };
            return out;
        }
        if (std.mem.eql(u8, iface, application_iface)) {
            const out = try cx.a.alloc(Prop, 4);
            out[0] = .{ "ToolkitName", .{ .string = "zigguro" } };
            out[1] = .{ "Version", .{ .string = b.version } };
            out[2] = .{ "AtspiVersion", .{ .string = "2.1" } };
            out[3] = .{ "Id", .{ .i32 = b.app_id } };
            return out;
        }
        return &.{};
    }

    /// Replies to `Properties.Get` (from `all`) or `GetAll`.
    fn answerProps(cx: *Cx, all: []const Prop) E!bool {
        if (std.mem.eql(u8, cx.member, "GetAll")) return cx.reply("a{sv}", .{all});
        const want = try cx.argStr(1);
        for (all) |p| if (std.mem.eql(u8, p[0], want)) return cx.reply("v", .{p[1]});
        return cx.fail(unknown_property, "No such property");
    }

    // -- nodes ---------------------------------------------------------------------------

    fn node(cx: *Cx, h: Held) E!bool {
        const n = h.n;
        const set = roles.ifacesOf(n);
        if (cx.is(introspectable_iface, "Introspect")) return cx.reply("s", .{try introspect.xml(cx.a, set)});
        if (cx.is(props_iface, "Get") or cx.is(props_iface, "GetAll")) {
            const iface = try cx.argStr(0);
            if (!set.has(iface)) return cx.fail(unknown_property, "No such interface");
            return cx.answerProps(try cx.nodeProps(h, iface));
        }
        if (cx.is(props_iface, "Set")) {
            if (!set.value or !std.mem.eql(u8, try cx.argStr(1), "CurrentValue")) return cx.fail(unknown_property, "Read-only property");
            const a = try cx.args();
            if (a.len < 3) return error.BadArgs;
            const v: f64 = switch (a[2].unwrap()) {
                .double => |d| d,
                else => return error.BadArgs,
            };
            h.w.tree.performAction(n.id, .set_value, .{ .number = v });
            return cx.reply("", .{});
        }
        if (std.mem.eql(u8, cx.iface, accessible_iface) or cx.iface.len == 0) {
            if (try cx.accessible(h, set)) return true;
        }
        if (set.component and (std.mem.eql(u8, cx.iface, component_iface) or cx.iface.len == 0)) {
            if (try cx.component(h)) return true;
        }
        if (set.action and (std.mem.eql(u8, cx.iface, action_iface) or cx.iface.len == 0)) {
            if (try cx.action(h)) return true;
        }
        if (set.text and (std.mem.eql(u8, cx.iface, text_iface) or cx.iface.len == 0)) {
            if (try cx.textIface(h)) return true;
        }
        if (set.selection and (std.mem.eql(u8, cx.iface, selection_iface) or cx.iface.len == 0)) {
            if (try cx.selection(h)) return true;
        }
        return false;
    }

    fn parentRef(cx: *const Cx, h: Held) E!Ref {
        if (h.n.parent == Node.no_parent) return cx.rootRef();
        return cx.refOf(h.s.nodes[h.n.parent].id);
    }

    fn indexInParent(cx: *const Cx, h: Held) i32 {
        if (h.n.parent == Node.no_parent) {
            for (cx.b.windows.items, 0..) |w, i| if (w == h.w) return @intCast(i);
            return -1;
        }
        const me = h.s.index.get(h.n.id).?;
        const at = std.mem.indexOfScalar(u32, h.s.children(&h.s.nodes[h.n.parent]), me) orelse return -1;
        return @intCast(at);
    }

    fn accessible(cx: *Cx, h: Held, set: roles.Ifaces) E!bool {
        const n = h.n;
        const s = h.s;
        if (cx.is(accessible_iface, "GetChildAtIndex")) {
            const i = try cx.argI32(0);
            const ks = s.children(n);
            if (i < 0 or i >= ks.len) return cx.reply("(so)", .{Ref.none});
            return cx.reply("(so)", .{try cx.refOf(s.nodes[ks[@intCast(i)]].id)});
        }
        if (cx.is(accessible_iface, "GetChildren")) {
            const ks = s.children(n);
            const refs = try cx.a.alloc(Ref, ks.len);
            for (ks, refs) |k, *r| r.* = try cx.refOf(s.nodes[k].id);
            return cx.reply("a(so)", .{refs});
        }
        if (cx.is(accessible_iface, "GetIndexInParent")) return cx.reply("i", .{cx.indexInParent(h)});
        if (cx.is(accessible_iface, "GetRelationSet")) return cx.reply("a(ua(so))", .{&[_]struct { u32, []const Ref }{}});
        if (cx.is(accessible_iface, "GetRole")) return cx.reply("u", .{roles.of(n.role)});
        if (cx.is(accessible_iface, "GetRoleName") or cx.is(accessible_iface, "GetLocalizedRoleName")) return cx.reply("s", .{roles.name(roles.of(n.role))});
        if (cx.is(accessible_iface, "GetState")) {
            const st = states.of(n, n.parent == Node.no_parent and s.active);
            return cx.reply("au", .{&st.words});
        }
        if (cx.is(accessible_iface, "GetAttributes")) return cx.reply("a{ss}", .{try cx.attributes(h)});
        if (cx.is(accessible_iface, "GetApplication")) return cx.reply("(so)", .{cx.rootRef()});
        if (cx.is(accessible_iface, "GetInterfaces")) {
            var buf: [roles.Ifaces.names.len][]const u8 = undefined;
            return cx.reply("as", .{set.list(&buf)});
        }
        return false;
    }

    const Attr = struct { []const u8, []const u8 };

    fn attributes(cx: *const Cx, h: Held) E![]const Attr {
        var out: std.ArrayList(Attr) = .empty;
        try out.append(cx.a, .{ "toolkit", "zigguro" });
        const n = h.n;
        if (n.level > 0) try out.append(cx.a, .{ "level", try std.fmt.allocPrint(cx.a, "{d}", .{n.level}) });
        if (n.row_index > 0) {
            try out.append(cx.a, .{ "posinset", try std.fmt.allocPrint(cx.a, "{d}", .{n.row_index}) });
            if (n.parent != Node.no_parent and h.s.nodes[n.parent].row_count > 0)
                try out.append(cx.a, .{ "setsize", try std.fmt.allocPrint(cx.a, "{d}", .{h.s.nodes[n.parent].row_count}) });
        }
        if (n.sort != .none) try out.append(cx.a, .{ "sort", @tagName(n.sort) });
        return out.items;
    }

    fn nodeProps(cx: *const Cx, h: Held, iface: []const u8) E![]const Prop {
        const n = h.n;
        if (std.mem.eql(u8, iface, accessible_iface)) {
            const out = try cx.a.alloc(Prop, 7);
            out[0] = .{ "Name", .{ .string = n.name } };
            out[1] = .{ "Description", .{ .string = "" } };
            out[2] = .{ "Parent", try cx.refValue(try cx.parentRef(h)) };
            out[3] = .{ "ChildCount", .{ .i32 = @intCast(n.kids_len) } };
            out[4] = .{ "Locale", .{ .string = "" } };
            out[5] = .{ "AccessibleId", .{ .string = if (n.test_id != 0) try std.fmt.allocPrint(cx.a, "t{x:0>16}", .{n.test_id}) else "" } };
            out[6] = .{ "HelpText", .{ .string = "" } };
            return out;
        }
        if (std.mem.eql(u8, iface, action_iface)) {
            const out = try cx.a.alloc(Prop, 1);
            out[0] = .{ "NActions", .{ .i32 = @intCast(roles.actionCount(n)) } };
            return out;
        }
        if (std.mem.eql(u8, iface, value_iface)) {
            const out = try cx.a.alloc(Prop, 5);
            out[0] = .{ "MinimumValue", .{ .double = 0 } };
            out[1] = .{ "MaximumValue", .{ .double = 1 } };
            out[2] = .{ "MinimumIncrement", .{ .double = 0.01 } };
            out[3] = .{ "CurrentValue", .{ .double = n.value orelse 0 } };
            out[4] = .{ "Text", .{ .string = "" } };
            return out;
        }
        if (std.mem.eql(u8, iface, text_iface)) {
            const out = try cx.a.alloc(Prop, 2);
            out[0] = .{ "CharacterCount", .{ .i32 = charCount(n.text) } };
            // The snapshot has no caret yet: report the end.
            out[1] = .{ "CaretOffset", .{ .i32 = charCount(n.text) } };
            return out;
        }
        if (std.mem.eql(u8, iface, selection_iface)) {
            var k: i32 = 0;
            for (h.s.children(n)) |i| {
                if (h.s.nodes[i].state.selected) k += 1;
            }
            const out = try cx.a.alloc(Prop, 1);
            out[0] = .{ "NSelectedChildren", .{ .i32 = k } };
            return out;
        }
        return &.{};
    }

    // -- Component ----------------------------------------------------------------------

    fn component(cx: *Cx, h: Held) E!bool {
        const n = h.n;
        if (cx.is(component_iface, "GetExtents")) {
            const r = extents(h, @enumFromInt(try cx.argU32(0)));
            return cx.reply("(iiii)", .{.{ r[0], r[1], r[2], r[3] }});
        }
        if (cx.is(component_iface, "GetPosition")) {
            const r = extents(h, @enumFromInt(try cx.argU32(0)));
            return cx.reply("ii", .{ r[0], r[1] });
        }
        if (cx.is(component_iface, "GetSize")) {
            const r = extents(h, .window);
            return cx.reply("ii", .{ r[2], r[3] });
        }
        if (cx.is(component_iface, "Contains")) {
            const p = toLogical(h, try cx.argI32(0), try cx.argI32(1), @enumFromInt(try cx.argU32(2)));
            const bx = n.bounds;
            return cx.reply("b", .{p[0] >= bx[0] and p[1] >= bx[1] and p[0] < bx[0] + bx[2] and p[1] < bx[1] + bx[3]});
        }
        if (cx.is(component_iface, "GetAccessibleAtPoint")) {
            const p = toLogical(h, try cx.argI32(0), try cx.argI32(1), @enumFromInt(try cx.argU32(2)));
            const at = h.s.nodeAt(p[0], p[1]) orelse return cx.reply("(so)", .{Ref.none});
            if (at.id == n.id or !isDescendant(h.s, at, n)) return cx.reply("(so)", .{Ref.none});
            return cx.reply("(so)", .{try cx.refOf(at.id)});
        }
        if (cx.is(component_iface, "GetLayer")) return cx.reply("u", .{@as(u32, if (n.parent == Node.no_parent) 7 else 3)});
        if (cx.is(component_iface, "GetMDIZOrder")) return cx.reply("n", .{@as(i16, 0)});
        if (cx.is(component_iface, "GetAlpha")) return cx.reply("d", .{@as(f64, 1)});
        if (cx.is(component_iface, "GrabFocus")) {
            if (!n.state.focusable or n.state.disabled) return cx.reply("b", .{false});
            h.w.tree.performAction(n.id, .focus, null);
            return cx.reply("b", .{true});
        }
        if (cx.is(component_iface, "ScrollTo")) {
            h.w.tree.performAction(n.id, .scroll_into_view, null);
            return cx.reply("b", .{true});
        }
        return false;
    }

    // -- Action -------------------------------------------------------------------------

    fn action(cx: *Cx, h: Held) E!bool {
        var buf: [4]roles.Action = undefined;
        const acts = roles.actions(h.n, &buf);
        if (cx.is(action_iface, "GetActions")) {
            const out = try cx.a.alloc(struct { []const u8, []const u8, []const u8 }, acts.len);
            for (acts, out) |x, *o| o.* = .{ x.name, x.name, "" };
            return cx.reply("a(sss)", .{out});
        }
        const names = [_][]const u8{ "GetName", "GetLocalizedName", "GetDescription", "GetKeyBinding", "DoAction" };
        for (names, 0..) |m, which| if (cx.is(action_iface, m)) {
            const i = try cx.argI32(0);
            if (i < 0 or i >= acts.len) return if (which == 4) cx.reply("b", .{false}) else cx.reply("s", .{@as([]const u8, "")});
            const x = acts[@intCast(i)];
            switch (which) {
                0, 1, 2 => return cx.reply("s", .{x.name}),
                3 => return cx.reply("s", .{@as([]const u8, "")}),
                else => {
                    if (h.n.state.disabled) return cx.reply("b", .{false});
                    h.w.tree.performAction(h.n.id, x.does, null);
                    return cx.reply("b", .{true});
                },
            }
        };
        return false;
    }

    // -- Text ---------------------------------------------------------------------------

    fn textIface(cx: *Cx, h: Held) E!bool {
        const t = h.n.text;
        const count = charCount(t);
        if (cx.is(text_iface, "GetText")) {
            const start = clampChar(try cx.argI32(0), count);
            const end_arg = try cx.argI32(1);
            const end = if (end_arg < 0) count else clampChar(end_arg, count);
            if (end <= start) return cx.reply("s", .{@as([]const u8, "")});
            return cx.reply("s", .{t[byteAt(t, start)..byteAt(t, end)]});
        }
        if (cx.is(text_iface, "GetStringAtOffset")) {
            const off = clampChar(try cx.argI32(0), count);
            const r = stringAt(t, off, @enumFromInt(try cx.argU32(1)));
            return cx.reply("sii", .{ t[byteAt(t, r[0])..byteAt(t, r[1])], r[0], r[1] });
        }
        if (cx.is(text_iface, "GetCharacterAtOffset")) {
            const off = try cx.argI32(0);
            if (off < 0 or off >= count) return cx.reply("i", .{@as(i32, 0)});
            const i = byteAt(t, off);
            const len = std.unicode.utf8ByteSequenceLength(t[i]) catch 1;
            const cp = std.unicode.utf8Decode(t[i..@min(i + len, t.len)]) catch 0xFFFD;
            return cx.reply("i", .{@as(i32, @intCast(cp))});
        }
        if (cx.is(text_iface, "GetCharacterExtents")) {
            // Per-character geometry needs the text layout (later); the
            // box is the best answer from a snapshot.
            const r = extents(h, @enumFromInt(try cx.argU32(1)));
            return cx.reply("iiii", .{ r[0], r[1], r[2], r[3] });
        }
        if (cx.is(text_iface, "GetNSelections")) return cx.reply("i", .{@as(i32, 0)});
        if (cx.is(text_iface, "GetSelection")) return cx.reply("ii", .{ @as(i32, 0), @as(i32, 0) });
        return false;
    }

    // -- Selection ----------------------------------------------------------------------

    fn selection(cx: *Cx, h: Held) E!bool {
        const ks = h.s.children(h.n);
        if (cx.is(selection_iface, "GetSelectedChild")) {
            var want = try cx.argI32(0);
            for (ks) |k| if (h.s.nodes[k].state.selected) {
                if (want == 0) return cx.reply("(so)", .{try cx.refOf(h.s.nodes[k].id)});
                want -= 1;
            };
            return cx.reply("(so)", .{Ref.none});
        }
        if (cx.is(selection_iface, "IsChildSelected")) {
            const i = try cx.argI32(0);
            if (i < 0 or i >= ks.len) return cx.reply("b", .{false});
            return cx.reply("b", .{h.s.nodes[ks[@intCast(i)]].state.selected});
        }
        if (cx.is(selection_iface, "SelectChild") or cx.is(selection_iface, "DeselectChild")) {
            const i = try cx.argI32(0);
            if (i < 0 or i >= ks.len) return cx.reply("b", .{false});
            const k = &h.s.nodes[ks[@intCast(i)]];
            const sel = std.mem.eql(u8, cx.member, "SelectChild");
            h.w.tree.performAction(k.id, if (sel) .select else .remove_from_selection, null);
            return cx.reply("b", .{true});
        }
        if (cx.is(selection_iface, "DeselectSelectedChild")) {
            var want = try cx.argI32(0);
            for (ks) |k| if (h.s.nodes[k].state.selected) {
                if (want == 0) {
                    h.w.tree.performAction(h.s.nodes[k].id, .remove_from_selection, null);
                    return cx.reply("b", .{true});
                }
                want -= 1;
            };
            return cx.reply("b", .{false});
        }
        if (cx.is(selection_iface, "SelectAll") or cx.is(selection_iface, "ClearSelection")) return cx.reply("b", .{false});
        return false;
    }
};

fn isDescendant(s: *const Snapshot, n: *const Node, of: *const Node) bool {
    var p = n.parent;
    while (p != Node.no_parent) : (p = s.nodes[p].parent) {
        if (s.nodes[p].id == of.id) return true;
    }
    return false;
}

/// A node's box in `coord` units: x, y, width, height (physical pixels).
/// Screen coordinates need the window's position, which Wayland doesn't
/// give; there they fall back to window coordinates.
pub fn extents(h: Held, coord: Coord) [4]i32 {
    const k = h.s.scale;
    var x = h.n.bounds[0];
    var y = h.n.bounds[1];
    var ox: f32 = 0;
    var oy: f32 = 0;
    switch (coord) {
        .parent => if (h.n.parent != Node.no_parent) {
            const pb = h.s.nodes[h.n.parent].bounds;
            x -= pb[0];
            y -= pb[1];
        },
        .window => {},
        else => if (h.s.screen_origin) |o| {
            ox = @floatFromInt(o[0]);
            oy = @floatFromInt(o[1]);
        },
    }
    return .{
        @intFromFloat(@round(x * k + ox)),
        @intFromFloat(@round(y * k + oy)),
        @intFromFloat(@round(h.n.bounds[2] * k)),
        @intFromFloat(@round(h.n.bounds[3] * k)),
    };
}

/// A point in `coord` units as window logical pixels.
fn toLogical(h: Held, px: i32, py: i32, coord: Coord) [2]f32 {
    const k = h.s.scale;
    var x: f32 = @as(f32, @floatFromInt(px)) / k;
    var y: f32 = @as(f32, @floatFromInt(py)) / k;
    switch (coord) {
        .parent => if (h.n.parent != Node.no_parent) {
            const pb = h.s.nodes[h.n.parent].bounds;
            x += pb[0];
            y += pb[1];
        },
        .window => {},
        else => if (h.s.screen_origin) |o| {
            x -= @as(f32, @floatFromInt(o[0])) / k;
            y -= @as(f32, @floatFromInt(o[1])) / k;
        },
    }
    return .{ x, y };
}

const charCount = @import("events.zig").chars;

fn clampChar(i: i32, count: i32) i32 {
    return std.math.clamp(i, 0, count);
}

/// The byte offset of character `ci`.
pub fn byteAt(s: []const u8, ci: i32) usize {
    var n: i32 = 0;
    for (s, 0..) |c, i| {
        if (c & 0xC0 != 0x80) {
            if (n == ci) return i;
            n += 1;
        }
    }
    return s.len;
}

/// `GetStringAtOffset`: the [start, end) characters of the `g` unit at
/// character `off`. Words run from a word's start to the next word's start
/// (UAX #29 boundaries); single-line text is one line, sentence and
/// paragraph.
pub fn stringAt(t: []const u8, off: i32, g: Granularity) [2]i32 {
    const count = charCount(t);
    switch (g) {
        .char => return if (off >= count) .{ count, count } else .{ off, off + 1 },
        .word => {
            if (t.len == 0) return .{ 0, 0 };
            const b = byteAt(t, off);
            const span = word.wordAt(t, b);
            const wordish = span.kind == .word or span.kind == .number;
            const start = if (wordish) span.start else word.prevWordStart(t, b);
            const end = word.nextWordStart(t, start);
            return .{ charCount(t[0..start]), charCount(t[0..end]) };
        },
        else => return .{ 0, count },
    }
}
