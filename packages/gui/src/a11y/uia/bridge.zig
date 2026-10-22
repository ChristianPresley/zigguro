//! The UI Automation bridge (E04.F09.S01.T02): exposes one window's
//! accessibility tree to Windows screen readers.
//!
//! The bridge hooks `WM_GETOBJECT` on the window's HWND (through
//! `NativeHooks.win32SetMessageHook`, on the platform thread). The first
//! UIA request turns the tree on and answers with the window's
//! fragment-root provider; providers for other nodes are made as clients
//! navigate (see `provider.zig`). After each frame's update the bridge
//! raises focus, property, structure, menu and notification events, but
//! only while `UiaClientsAreListening` says someone is.
//!
//! The bridge owns its `A11yTree`. Clients may hold providers after the
//! window closes, so the bridge is reference counted: each provider holds
//! a reference and `close` drops the bridge's own one on the UI thread
//! after any call the tree has already posted there. The last release
//! frees the bridge on whichever thread makes it, so `gpa` must be thread
//! safe.

const std = @import("std");
const zg_platform = @import("zg_platform");
const c = @import("com.zig");
const provider = @import("provider.zig");
const tree_mod = @import("../tree.zig");
const snap = @import("../snapshot.zig");
const window_mod = @import("../../core/window.zig");
const app_mod = @import("../../core/app.zig");

const Allocator = std.mem.Allocator;
const A11yTree = tree_mod.A11yTree;
const Update = tree_mod.Update;
const Element = provider.Element;
const Window = window_mod.Window;
const NativeHooks = zg_platform.NativeHooks;

/// See the module doc. Make with `create`, end with `close`.
pub const Bridge = struct {
    gpa: Allocator,
    api: c.Api,
    tree: A11yTree,
    /// The window node's id (the fragment root).
    root_id: u64 = 0,
    root_el: *Element = undefined,
    hwnd: ?*anyopaque = null,
    hooks: ?*const NativeHooks = null,
    win_id: zg_platform.WindowId = undefined,
    app: ?*app_mod.App = null,
    /// The bridge's own reference plus one per live provider.
    refs: std.atomic.Value(u32) = .init(1),
    closed: std.atomic.Value(bool) = .init(false),
    /// Events raised (tests).
    raised: u64 = 0,

    /// A bridge for window `win`, numbered `window_id` in node ids, with
    /// its tree attached. Call `install` to hook the HWND.
    pub fn create(gpa: Allocator, api: c.Api, win: *Window, window_id: u32) Allocator.Error!*Bridge {
        const b = try gpa.create(Bridge);
        b.* = .{ .gpa = gpa, .api = api, .tree = .init(gpa, window_id) };
        b.root_id = snap.idOf(window_id, win.root);
        b.app = win.app;
        b.root_el = Element.create(b, b.root_id) orelse {
            gpa.destroy(b);
            return error.OutOfMemory;
        };
        b.tree.listener = .{ .ctx = b, .f = onUpdate };
        b.tree.attach(win);
        return b;
    }

    /// Hooks `WM_GETOBJECT` on the HWND of platform window `id`.
    pub fn install(b: *Bridge, hooks: *const NativeHooks, id: zg_platform.WindowId) error{Unsupported}!void {
        const h = hooks.windowHandle(hooks.ptr, id);
        b.hwnd = switch (h) {
            .win32 => |p| p,
            else => return error.Unsupported,
        };
        try hooks.win32SetMessageHook(hooks.ptr, id, &.{c.WM_GETOBJECT}, onMessage, b);
        b.hooks = hooks;
        b.win_id = id;
    }

    /// Unhooks the HWND, disconnects clients and detaches the tree (UI
    /// thread). The bridge lives on until clients drop their providers.
    pub fn close(b: *Bridge) void {
        if (b.closed.swap(true, .acq_rel)) return;
        if (b.hooks) |hk| hk.win32SetMessageHook(hk.ptr, b.win_id, &.{c.WM_GETOBJECT}, null, b) catch {};
        if (b.hwnd) |w| _ = b.api.returnRawElementProvider(w, 0, 0, null);
        b.tree.listener = null;
        b.tree.activate(false);
        b.tree.detach();
        _ = b.root_el.release();
        // After any wake the tree already posted (posted calls run in order).
        if (b.app) |a| a.post(.{ .ctx = b, .f = dropSelf }) catch b.unref() else b.unref();
    }

    fn dropSelf(ctx: *anyopaque, _: *app_mod.App) void {
        const b: *Bridge = @ptrCast(@alignCast(ctx));
        b.unref();
    }

    pub fn retain(b: *Bridge) void {
        _ = b.refs.fetchAdd(1, .monotonic);
    }

    pub fn unref(b: *Bridge) void {
        if (b.refs.fetchSub(1, .acq_rel) != 1) return;
        b.tree.deinit();
        b.gpa.destroy(b);
    }

    /// Providers alive (tests).
    pub fn liveElements(b: *const Bridge) u32 {
        const r = b.refs.load(.acquire);
        return if (b.closed.load(.acquire)) r else r - 1;
    }

    /// The tree's current snapshot with a reference held; null once
    /// closed, so providers answer `UIA_E_ELEMENTNOTAVAILABLE`.
    pub fn snapshot(b: *Bridge) ?*snap.Snapshot {
        if (b.closed.load(.acquire)) return null;
        return b.tree.snapshot();
    }

    /// A provider for node `id` with one reference: the root for the
    /// window node, else a new element.
    pub fn element(b: *Bridge, id: u64) ?*Element {
        if (id == b.root_id) {
            _ = b.root_el.addRef();
            return b.root_el;
        }
        return Element.create(b, id);
    }

    /// The `WM_GETOBJECT` hook (platform thread).
    pub fn onMessage(ctx: *anyopaque, hwnd: *anyopaque, msg: u32, wp: usize, lp: isize) ?isize {
        const b: *Bridge = @ptrCast(@alignCast(ctx));
        if (msg != c.WM_GETOBJECT or b.closed.load(.acquire)) return null;
        // The object id is the low 32 bits, sign-extended or not.
        const obj: i32 = @truncate(lp);
        if (obj != c.UiaRootObjectId) return null;
        b.tree.activate(true);
        return b.api.returnRawElementProvider(hwnd, wp, lp, &b.root_el.simple);
    }

    /// The tree listener: raises UIA events for one update (UI thread).
    fn onUpdate(ctx: *anyopaque, u: *const Update) void {
        const b: *Bridge = @ptrCast(@alignCast(ctx));
        if (b.api.clientsAreListening() == 0) return;
        const s = u.snapshot;
        for (u.events) |ev| switch (ev) {
            .focus_changed => |id| if (id != 0) b.raiseEvent(id, c.event.focus_changed),
            .menu_opened => |id| b.raiseEvent(id, c.event.menu_opened),
            .menu_closed => |id| b.raiseEvent(id, c.event.menu_closed),
            .state_changed => |sc| {
                const n = s.find(sc.id) orelse continue;
                const st = n.state;
                if (sc.mask.checked) b.raiseProp(sc.id, c.prop.toggle_state, .int(@intFromBool(!st.checked)), .int(@intFromBool(st.checked)));
                if (sc.mask.expanded) b.raiseProp(sc.id, c.prop.expand_collapse_state, .int(@intFromBool(!st.expanded)), .int(@intFromBool(st.expanded)));
                if (sc.mask.selected) b.raiseProp(sc.id, c.prop.selection_item_is_selected, .boolean(!st.selected), .boolean(st.selected));
                if (sc.mask.disabled) b.raiseProp(sc.id, c.prop.is_enabled, .boolean(st.disabled), .boolean(!st.disabled));
                if (sc.mask.focused and st.focused) b.raiseProp(sc.id, c.prop.has_keyboard_focus, .boolean(false), .boolean(true));
            },
            .name_changed => |id| {
                const n = s.find(id) orelse continue;
                b.raiseText(id, c.prop.name, n.name);
            },
            .value_changed => |id| {
                const n = s.find(id) orelse continue;
                if (n.role == .textbox) {
                    b.raiseText(id, c.prop.value_value, n.text);
                } else if (n.value) |v| {
                    b.raiseProp(id, c.prop.range_value_value, .{}, .double(v));
                }
            },
            .text_changed => |tc| {
                const n = s.find(tc.id) orelse continue;
                b.raiseText(tc.id, c.prop.value_value, n.text);
            },
            .children_changed => |id| b.raiseStructure(id),
            .announcement => |a| b.raiseNotification(a.text, a.assertive),
        };
    }

    fn raiseEvent(b: *Bridge, id: u64, ev: i32) void {
        const e = b.element(id) orelse return;
        defer _ = e.release();
        _ = b.api.raiseAutomationEvent(&e.simple, ev);
        b.raised += 1;
    }

    fn raiseProp(b: *Bridge, id: u64, pid: i32, old: c.VARIANT, new: c.VARIANT) void {
        const e = b.element(id) orelse return;
        defer _ = e.release();
        _ = b.api.raisePropertyChangedEvent(&e.simple, pid, old, new);
        b.raised += 1;
    }

    fn raiseText(b: *Bridge, id: u64, pid: i32, text: []const u8) void {
        const s = b.api.bstrOf(b.gpa, text);
        defer b.api.sysFreeString(s);
        b.raiseProp(id, pid, .{}, .bstr(s));
    }

    fn raiseStructure(b: *Bridge, id: u64) void {
        const e = b.element(id) orelse return;
        defer _ = e.release();
        var rid = provider.runtimeIdOf(id);
        _ = b.api.raiseStructureChangedEvent(&e.simple, @intFromEnum(c.StructureChangeType.children_invalidated), &rid, rid.len);
        b.raised += 1;
    }

    fn raiseNotification(b: *Bridge, text: []const u8, assertive: bool) void {
        const f = b.api.raiseNotificationEvent orelse return;
        const s = b.api.bstrOf(b.gpa, text);
        defer b.api.sysFreeString(s);
        const act = b.api.bstrOf(b.gpa, "zigguro.announce");
        defer b.api.sysFreeString(act);
        const processing: c.NotificationProcessing = if (assertive) .important_most_recent else .all;
        _ = f(&b.root_el.simple, @intFromEnum(c.NotificationKind.other), @intFromEnum(processing), s, act);
        b.raised += 1;
    }
};
