//! The UI Automation bridge (E04.F09.S01.T02), against a fake `Api` so it
//! runs on every OS.

const std = @import("std");
const ui_mod = @import("../core/ui.zig");
const controls = @import("../widgets/controls.zig");
const widget = @import("../core/widget.zig");
const TestApp = @import("../testing/test_app.zig").TestApp;
const uia = @import("uia/root.zig");
const snap = @import("snapshot.zig");

const c = uia.com;
const vt = c.vtbl;
const Ui = ui_mod.Ui;
const Bridge = uia.Bridge;
const Element = uia.Element;
const winapi = c.winapi;
const testing = std.testing;

/// What the fake DLLs saw.
const Fake = struct {
    var listening: c.BOOL = 1;
    var returned: u32 = 0;
    var last_el: ?*anyopaque = null;
    var events: [32]i32 = undefined;
    var n_events: usize = 0;
    var props: [32]struct { pid: i32, new: c.VARIANT } = undefined;
    var n_props: usize = 0;
    var structure: u32 = 0;
    var notes: u32 = 0;

    fn reset() void {
        listening = 1;
        returned = 0;
        last_el = null;
        n_events = 0;
        n_props = 0;
        structure = 0;
        notes = 0;
    }

    const SA = struct { v: [4]i32 = .{ 0, 0, 0, 0 }, n: u32 };

    fn alloc(s: ?[*]const u16, len: u32) callconv(winapi) c.BSTR {
        const m = std.heap.page_allocator.allocSentinel(u16, len, 0) catch return null;
        if (s) |p| @memcpy(m, p[0..len]) else @memset(m, 0);
        return m.ptr;
    }
    fn free(s: c.BSTR) callconv(winapi) void {
        const p = s orelse return;
        std.heap.page_allocator.free(std.mem.span(p));
    }
    fn saCreate(_: u16, _: i32, n: u32) callconv(winapi) ?*c.SAFEARRAY {
        const sa = std.heap.page_allocator.create(SA) catch return null;
        sa.* = .{ .n = n };
        return @ptrCast(sa);
    }
    fn saPut(psa: *c.SAFEARRAY, idx: *const i32, v: *const anyopaque) callconv(winapi) c.HRESULT {
        const sa: *SA = @ptrCast(@alignCast(psa));
        sa.v[@intCast(idx.*)] = @as(*const i32, @ptrCast(@alignCast(v))).*;
        return c.S_OK;
    }
    fn ret(_: *anyopaque, _: usize, _: isize, el: ?*anyopaque) callconv(winapi) isize {
        returned += 1;
        last_el = el;
        return 0x1234;
    }
    fn host(_: *anyopaque, out: *?*anyopaque) callconv(winapi) c.HRESULT {
        out.* = null;
        return c.S_OK;
    }
    fn event(_: *anyopaque, id: i32) callconv(winapi) c.HRESULT {
        events[n_events] = id;
        n_events += 1;
        return c.S_OK;
    }
    fn prop(_: *anyopaque, id: i32, _: c.VARIANT, new: c.VARIANT) callconv(winapi) c.HRESULT {
        props[n_props] = .{ .pid = id, .new = new };
        n_props += 1;
        return c.S_OK;
    }
    fn structureChanged(_: *anyopaque, _: i32, _: [*]i32, _: i32) callconv(winapi) c.HRESULT {
        structure += 1;
        return c.S_OK;
    }
    fn listen() callconv(winapi) c.BOOL {
        return listening;
    }
    fn note(_: *anyopaque, _: i32, _: i32, _: c.BSTR, _: c.BSTR) callconv(winapi) c.HRESULT {
        notes += 1;
        return c.S_OK;
    }

    const api: c.Api = .{
        .sysAllocStringLen = alloc,
        .sysFreeString = free,
        .safeArrayCreateVector = saCreate,
        .safeArrayPutElement = saPut,
        .returnRawElementProvider = ret,
        .hostProviderFromHwnd = host,
        .raiseAutomationEvent = event,
        .raisePropertyChangedEvent = prop,
        .raiseStructureChangedEvent = structureChanged,
        .clientsAreListening = listen,
        .raiseNotificationEvent = note,
    };

    fn sawEvent(id: i32) bool {
        return std.mem.indexOfScalar(i32, events[0..n_events], id) != null;
    }

    fn propNew(pid: i32) ?c.VARIANT {
        var i = n_props;
        while (i > 0) {
            i -= 1;
            if (props[i].pid == pid) return props[i].new;
        }
        return null;
    }
};

const Form = struct {
    clicks: u32 = 0,
    on: bool = false,

    pub fn build(f: *Form, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .gap = 8, .padding = .all(8) } });
        defer ui.close();
        ui.open(.{ .style = .{ .dir = .row }, .role = .toolbar, .label = "Tools" });
        if (controls.button(ui, .{ .label = "Run" }).clicked) {
            f.clicks += 1;
            ui.window().markViewDirty(ui.currentView());
        }
        ui.close();
        if (controls.checkbox(ui, "Wrap", &f.on).changed) ui.window().markViewDirty(ui.currentView());
    }
};

const Fixture = struct {
    t: *TestApp,
    b: *Bridge,
    view: *Form,

    fn init(view: *Form) !Fixture {
        Fake.reset();
        const t = try TestApp.init(testing.allocator, .{ .root = .of(view) });
        errdefer t.deinit();
        _ = t.settle();
        const b = try Bridge.create(testing.allocator, Fake.api, t.win, 3);
        b.hwnd = @ptrFromInt(0x1000);
        return .{ .t = t, .b = b, .view = view };
    }

    fn deinit(f: *Fixture) void {
        f.b.close();
        _ = f.t.settle();
        f.t.deinit();
    }

    /// Answers a UIA `WM_GETOBJECT` and runs a frame.
    fn connect(f: *Fixture) !void {
        const r = Bridge.onMessage(f.b, f.b.hwnd.?, c.WM_GETOBJECT, 0, c.UiaRootObjectId);
        try testing.expectEqual(@as(?isize, 0x1234), r);
        _ = f.t.settle();
    }

    /// A provider for the node named `name`.
    fn el(f: *Fixture, name: []const u8) !*Element {
        const s = f.b.tree.snapshot() orelse return error.NoSnapshot;
        defer s.release();
        for (s.nodes) |*n| if (std.mem.eql(u8, n.name, name)) return f.b.element(n.id) orelse error.OutOfMemory;
        return error.NotFound;
    }
};

fn nameOf(e: *Element) ![]u8 {
    var v: c.VARIANT = .{};
    try testing.expectEqual(c.S_OK, e.simple.vtbl.GetPropertyValue(&e.simple, c.prop.name, &v));
    if (v.vt != c.VT_BSTR) return testing.allocator.dupe(u8, "");
    defer Fake.free(v.v.bstrVal);
    return std.unicode.utf16LeToUtf8Alloc(testing.allocator, std.mem.span(v.v.bstrVal.?));
}

test "uia: roles map to control types and runtime ids carry the node id" {
    inline for (@typeInfo(widget.Role).@"enum".fields) |f| {
        const k = uia.provider.controlType(@enumFromInt(f.value));
        try testing.expect(k >= 50000 and k <= 50040);
    }
    try testing.expectEqual(c.control.button, uia.provider.controlType(.button));
    try testing.expectEqual(c.control.tree_item, uia.provider.controlType(.treeitem));
    const rid = uia.provider.runtimeIdOf(0x0000_0007_0100_0002);
    try testing.expectEqualSlices(i32, &.{ c.UiaAppendRuntimeId, 0x0100_0002, 7 }, &rid);
}

test "uia: vtable slots follow UIAutomationCore.idl" {
    const p = @sizeOf(usize);
    try testing.expectEqual(3 * p, @offsetOf(vt.Simple, "get_ProviderOptions"));
    try testing.expectEqual(5 * p, @offsetOf(vt.Simple, "GetPropertyValue"));
    try testing.expectEqual(6 * p, @offsetOf(vt.Simple, "get_HostRawElementProvider"));
    try testing.expectEqual(3 * p, @offsetOf(vt.Fragment, "Navigate"));
    try testing.expectEqual(7 * p, @offsetOf(vt.Fragment, "SetFocus"));
    try testing.expectEqual(8 * p, @offsetOf(vt.Fragment, "get_FragmentRoot"));
    try testing.expectEqual(4 * p, @offsetOf(vt.FragmentRoot, "GetFocus"));
    try testing.expectEqual(4 * p, @offsetOf(vt.Toggle, "get_ToggleState"));
    try testing.expectEqual(9 * p, @offsetOf(vt.RangeValue, "get_SmallChange"));
    try testing.expectEqual(7 * p, @offsetOf(vt.SelectionItem, "get_SelectionContainer"));
    // VARIANT is 16 bytes on 32-bit and 24 on 64-bit Windows.
    try testing.expectEqual(@as(usize, if (p == 8) 24 else 16), @sizeOf(c.VARIANT));
}

test "uia: WM_GETOBJECT activates the tree and returns the window provider" {
    var view: Form = .{};
    var f = try Fixture.init(&view);
    defer f.deinit();
    // Other object ids (OBJID_CLIENT) go to the default handling.
    try testing.expectEqual(@as(?isize, null), Bridge.onMessage(f.b, f.b.hwnd.?, c.WM_GETOBJECT, 0, -4));
    try testing.expect(f.b.tree.snapshot() == null);
    try f.connect();
    try testing.expectEqual(@as(?*anyopaque, &f.b.root_el.simple), Fake.last_el);
    const s = f.b.tree.snapshot().?;
    s.release();
    // The window answers its control type.
    var v: c.VARIANT = .{};
    const r = f.b.root_el;
    try testing.expectEqual(c.S_OK, r.simple.vtbl.GetPropertyValue(&r.simple, c.prop.control_type, &v));
    try testing.expectEqual(c.control.window, v.v.lVal);
}

test "uia: navigation follows the snapshot and providers free themselves" {
    var view: Form = .{};
    var f = try Fixture.init(&view);
    defer f.deinit();
    try f.connect();
    const r = f.b.root_el;
    var out: ?*anyopaque = null;
    try testing.expectEqual(c.S_OK, r.fragment.vtbl.Navigate(&r.fragment, .first_child, &out));
    const tf: *@FieldType(Element, "fragment") = @ptrCast(@alignCast(out.?));
    const te: *Element = @fieldParentPtr("fragment", tf);
    {
        const n = try nameOf(te);
        defer testing.allocator.free(n);
        try testing.expectEqualStrings("Tools", n);
    }
    // Its first child is the Run button; the button's parent is Tools.
    var kid: ?*anyopaque = null;
    try testing.expectEqual(c.S_OK, tf.vtbl.Navigate(tf, .first_child, &kid));
    const kf: *@FieldType(Element, "fragment") = @ptrCast(@alignCast(kid.?));
    const ke: *Element = @fieldParentPtr("fragment", kf);
    {
        const n = try nameOf(ke);
        defer testing.allocator.free(n);
        try testing.expectEqualStrings("Run", n);
    }
    var up: ?*anyopaque = null;
    try testing.expectEqual(c.S_OK, kf.vtbl.Navigate(kf, .parent, &up));
    try testing.expectEqual(te.id, @as(*Element, @fieldParentPtr("fragment", @as(*@FieldType(Element, "fragment"), @ptrCast(@alignCast(up.?))))).id);
    // The window has no parent of its own (UIA asks the host HWND).
    var none: ?*anyopaque = null;
    try testing.expectEqual(c.S_OK, r.fragment.vtbl.Navigate(&r.fragment, .parent, &none));
    try testing.expect(none == null);
    // Runtime ids.
    var sa: ?*c.SAFEARRAY = null;
    try testing.expectEqual(c.S_OK, kf.vtbl.GetRuntimeId(kf, &sa));
    const fsa: *Fake.SA = @ptrCast(@alignCast(sa.?));
    defer std.heap.page_allocator.destroy(fsa);
    try testing.expectEqual(@as(u32, 3), fsa.n);
    try testing.expectEqual(c.UiaAppendRuntimeId, fsa.v[0]);
    // QueryInterface counts references on the shared count.
    var inv: ?*anyopaque = null;
    try testing.expectEqual(c.S_OK, ke.query(&c.iid.IInvokeProvider, &inv));
    try testing.expectEqual(c.E_NOINTERFACE, ke.query(&c.iid.IToggleProvider, &inv));
    try testing.expectEqual(@as(u32, 2), ke.refs.load(.monotonic));
    // Everything handed out is released: only the window's provider stays.
    _ = ke.release();
    _ = ke.release();
    _ = @as(*Element, @fieldParentPtr("fragment", @as(*@FieldType(Element, "fragment"), @ptrCast(@alignCast(up.?))))).release();
    _ = te.release();
    try testing.expectEqual(@as(u32, 1), f.b.liveElements());
}

test "uia: patterns post actions to the UI thread; stale nodes are unavailable" {
    var view: Form = .{};
    var f = try Fixture.init(&view);
    defer f.deinit();
    try f.connect();
    const run = try f.el("Run");
    defer _ = run.release();
    var p: ?*anyopaque = null;
    try testing.expectEqual(c.S_OK, run.simple.vtbl.GetPatternProvider(&run.simple, c.pattern.invoke, &p));
    const inv: *@FieldType(Element, "invoke") = @ptrCast(@alignCast(p.?));
    try testing.expectEqual(c.S_OK, inv.vtbl.Invoke(inv));
    _ = inv.vtbl.Release(inv);
    _ = f.t.settle();
    try testing.expectEqual(@as(u32, 1), view.clicks);

    const wrap = try f.el("Wrap");
    defer _ = wrap.release();
    var tp: ?*anyopaque = null;
    try testing.expectEqual(c.S_OK, wrap.query(&c.iid.IToggleProvider, &tp));
    const tog: *@FieldType(Element, "toggle") = @ptrCast(@alignCast(tp.?));
    defer _ = tog.vtbl.Release(tog);
    try testing.expectEqual(c.S_OK, tog.vtbl.Toggle(tog));
    _ = f.t.settle();
    try testing.expect(view.on);
    var st: c.ToggleState = .off;
    try testing.expectEqual(c.S_OK, tog.vtbl.get_ToggleState(tog, &st));
    try testing.expectEqual(c.ToggleState.on, st);
    // The flip went out as a property event.
    try testing.expectEqual(@as(i32, 1), Fake.propNew(c.prop.toggle_state).?.v.lVal);

    // A node that isn't in the tree.
    const gone = f.b.element(f.b.root_id + 0x7777).?;
    defer _ = gone.release();
    var v: c.VARIANT = .{};
    try testing.expectEqual(c.UIA_E_ELEMENTNOTAVAILABLE, gone.simple.vtbl.GetPropertyValue(&gone.simple, c.prop.name, &v));
    try testing.expectEqual(c.UIA_E_ELEMENTNOTAVAILABLE, gone.invoke.vtbl.Invoke(&gone.invoke));
}

test "uia: events go out only while clients listen" {
    var view: Form = .{};
    var f = try Fixture.init(&view);
    defer f.deinit();
    try f.connect();
    try f.t.click(.{ .name_contains = "Run" });
    _ = f.t.settle();
    try testing.expect(Fake.sawEvent(c.event.focus_changed));
    f.b.tree.announce("Saved", false);
    _ = f.t.settle();
    try testing.expectEqual(@as(u32, 1), Fake.notes);

    Fake.listening = 0;
    const before = f.b.raised;
    try f.t.click(.{ .name_contains = "Wrap" });
    _ = f.t.settle();
    try testing.expectEqual(before, f.b.raised);
}

test "uia: the bridge outlives close while a client holds a provider" {
    var view: Form = .{};
    var f = try Fixture.init(&view);
    try f.connect();
    const run = try f.el("Run");
    f.deinit();
    // The window is gone; the provider answers without crashing.
    var v: c.VARIANT = .{};
    try testing.expectEqual(c.UIA_E_ELEMENTNOTAVAILABLE, run.simple.vtbl.GetPropertyValue(&run.simple, c.prop.name, &v));
    _ = run.release();
}
