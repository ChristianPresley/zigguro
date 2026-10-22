//! UIA provider objects (E04.F09.S01.T02): one small COM object per
//! element handed out, `{bridge, node id}`, implementing
//! `IRawElementProviderSimple` and `IRawElementProviderFragment` (and
//! `IRawElementProviderFragmentRoot` for the window), plus the control
//! patterns the node supports (Invoke, Toggle, Value, RangeValue,
//! ExpandCollapse, SelectionItem, ScrollItem) as sub-objects of the same
//! allocation. Every interface pointer is a field; its methods recover the
//! element with `@fieldParentPtr`, and all share one atomic refcount.
//!
//! Each call reads the tree's current snapshot (acquired and released
//! around the call), so providers work from any thread; a node that is
//! gone answers `UIA_E_ELEMENTNOTAVAILABLE`. Actions are posted to the UI
//! thread (`A11yTree.performAction`) and return at once.

const std = @import("std");
const c = @import("com.zig");
const widget = @import("../../core/widget.zig");
const snap = @import("../snapshot.zig");
const bridge_mod = @import("bridge.zig");

const Bridge = bridge_mod.Bridge;
const Snapshot = snap.Snapshot;
const Node = snap.Node;
const HRESULT = c.HRESULT;
const GUID = c.GUID;
const winapi = c.winapi;
const vt = c.vtbl;

fn Iface(comptime V: type) type {
    return extern struct { vtbl: *const V };
}

/// See the module doc.
pub const Element = struct {
    simple: Iface(vt.Simple) = .{ .vtbl = &simple_vtbl },
    fragment: Iface(vt.Fragment) = .{ .vtbl = &fragment_vtbl },
    root: Iface(vt.FragmentRoot) = .{ .vtbl = &root_vtbl },
    invoke: Iface(vt.Invoke) = .{ .vtbl = &invoke_vtbl },
    toggle: Iface(vt.Toggle) = .{ .vtbl = &toggle_vtbl },
    value: Iface(vt.Value) = .{ .vtbl = &value_vtbl },
    range: Iface(vt.RangeValue) = .{ .vtbl = &range_vtbl },
    expand: Iface(vt.ExpandCollapse) = .{ .vtbl = &expand_vtbl },
    selitem: Iface(vt.SelectionItem) = .{ .vtbl = &selitem_vtbl },
    scrollitem: Iface(vt.ScrollItem) = .{ .vtbl = &scrollitem_vtbl },
    refs: std.atomic.Value(u32) = .init(1),
    bridge: *Bridge,
    id: u64,

    /// A new element for node `id` with one reference.
    pub fn create(b: *Bridge, id: u64) ?*Element {
        const e = b.gpa.create(Element) catch return null;
        e.* = .{ .bridge = b, .id = id };
        b.retain();
        return e;
    }

    pub fn isRoot(e: *const Element) bool {
        return e.id == e.bridge.root_id;
    }

    pub fn addRef(e: *Element) u32 {
        return e.refs.fetchAdd(1, .monotonic) + 1;
    }

    pub fn release(e: *Element) u32 {
        const left = e.refs.fetchSub(1, .acq_rel) - 1;
        if (left == 0) {
            const b = e.bridge;
            b.gpa.destroy(e);
            b.unref();
        }
        return left;
    }

    /// `IUnknown::QueryInterface` for every interface of the element.
    pub fn query(e: *Element, riid: *const GUID, out: *?*anyopaque) HRESULT {
        out.* = null;
        const p: ?*anyopaque = if (riid.eql(&c.iid.IUnknown) or riid.eql(&c.iid.IRawElementProviderSimple))
            &e.simple
        else if (riid.eql(&c.iid.IRawElementProviderFragment))
            &e.fragment
        else if (riid.eql(&c.iid.IRawElementProviderFragmentRoot))
            (if (e.isRoot()) &e.root else null)
        else blk: {
            const pid: i32 = if (riid.eql(&c.iid.IInvokeProvider))
                c.pattern.invoke
            else if (riid.eql(&c.iid.IToggleProvider))
                c.pattern.toggle
            else if (riid.eql(&c.iid.IValueProvider))
                c.pattern.value
            else if (riid.eql(&c.iid.IRangeValueProvider))
                c.pattern.range_value
            else if (riid.eql(&c.iid.IExpandCollapseProvider))
                c.pattern.expand_collapse
            else if (riid.eql(&c.iid.ISelectionItemProvider))
                c.pattern.selection_item
            else if (riid.eql(&c.iid.IScrollItemProvider))
                c.pattern.scroll_item
            else
                break :blk null;
            break :blk e.patternIface(pid);
        };
        const q = p orelse return c.E_NOINTERFACE;
        _ = e.addRef();
        out.* = q;
        return c.S_OK;
    }

    /// The interface of pattern `pid` when the node supports it.
    fn patternIface(e: *Element, pid: i32) ?*anyopaque {
        const h = e.hold() orelse return null;
        defer h.s.release();
        if (!supports(h.n, pid, e.isRoot())) return null;
        return switch (pid) {
            c.pattern.invoke => &e.invoke,
            c.pattern.toggle => &e.toggle,
            c.pattern.value => &e.value,
            c.pattern.range_value => &e.range,
            c.pattern.expand_collapse => &e.expand,
            c.pattern.selection_item => &e.selitem,
            c.pattern.scroll_item => &e.scrollitem,
            else => null,
        };
    }

    const Held = struct { s: *Snapshot, n: *const Node };

    /// The current snapshot and this element's node (release `s`).
    fn hold(e: *Element) ?Held {
        const s = e.bridge.snapshot() orelse return null;
        const n = s.find(e.id) orelse {
            s.release();
            return null;
        };
        return .{ .s = s, .n = n };
    }

    fn act(e: *Element, a: widget.A11yAction, arg: ?widget.A11yArg) HRESULT {
        const h = e.hold() orelse return c.UIA_E_ELEMENTNOTAVAILABLE;
        const disabled = h.n.state.disabled;
        h.s.release();
        if (disabled and a != .scroll_into_view) return c.UIA_E_ELEMENTNOTENABLED;
        e.bridge.tree.performAction(e.id, a, arg);
        return c.S_OK;
    }
};

/// Whether a node exposes pattern `pid`.
pub fn supports(n: *const Node, pid: i32, is_root: bool) bool {
    return switch (pid) {
        c.pattern.invoke => switch (n.role) {
            .button, .link => true,
            .menuitem => !n.state.checkable and !n.state.expandable,
            else => false,
        },
        c.pattern.toggle => n.state.checkable,
        c.pattern.value => n.role == .textbox,
        c.pattern.range_value => n.role == .slider or n.role == .progressbar,
        c.pattern.expand_collapse => n.state.expandable,
        c.pattern.selection_item => n.state.selectable or n.role == .tab,
        c.pattern.scroll_item => !is_root,
        else => false,
    };
}

/// The UIA control type of a role.
pub fn controlType(r: widget.Role) i32 {
    const k = c.control;
    return switch (r) {
        .none, .group, .tabpanel => k.group,
        .text => k.text,
        .button => k.button,
        .link => k.hyperlink,
        .checkbox, .switch_ => k.check_box,
        .radio => k.radio_button,
        .slider => k.slider,
        .progressbar => k.progress_bar,
        .textbox => k.edit,
        .separator => k.separator,
        .status => k.status_bar,
        .list => k.list,
        .listitem => k.list_item,
        .tree => k.tree,
        .treeitem => k.tree_item,
        .tab => k.tab_item,
        .tablist => k.tab,
        .menu => k.menu,
        .menuitem => k.menu_item,
        .menubar => k.menu_bar,
        .dialog => k.window,
        .tooltip => k.tool_tip,
        .toolbar => k.tool_bar,
        .img => k.image,
        .window => k.window,
        .grid => k.data_grid,
        .row => k.data_item,
        .gridcell => k.text,
        .columnheader => k.header_item,
    };
}

fn from(comptime field: []const u8, this: *anyopaque) *Element {
    const p: *@FieldType(Element, field) = @ptrCast(@alignCast(this));
    return @fieldParentPtr(field, p);
}

fn Unknown(comptime field: []const u8) type {
    return struct {
        fn qi(this: *anyopaque, riid: *const GUID, out: *?*anyopaque) callconv(winapi) HRESULT {
            return from(field, this).query(riid, out);
        }
        fn add(this: *anyopaque) callconv(winapi) c.ULONG {
            return from(field, this).addRef();
        }
        fn rel(this: *anyopaque) callconv(winapi) c.ULONG {
            return from(field, this).release();
        }
    };
}

fn bstrOf(e: *Element, s: []const u8) c.BSTR {
    return e.bridge.api.bstrOf(e.bridge.gpa, s);
}

// -- IRawElementProviderSimple ------------------------------------------------------

const simple_vtbl: vt.Simple = .{
    .QueryInterface = Unknown("simple").qi,
    .AddRef = Unknown("simple").add,
    .Release = Unknown("simple").rel,
    .get_ProviderOptions = Simple.providerOptions,
    .GetPatternProvider = Simple.patternProvider,
    .GetPropertyValue = Simple.propertyValue,
    .get_HostRawElementProvider = Simple.hostProvider,
};

const Simple = struct {
    fn providerOptions(_: *anyopaque, out: *i32) callconv(winapi) HRESULT {
        out.* = c.ProviderOptions.server_side | c.ProviderOptions.use_com_threading;
        return c.S_OK;
    }

    fn patternProvider(this: *anyopaque, pid: i32, out: *?*anyopaque) callconv(winapi) HRESULT {
        const e = from("simple", this);
        out.* = e.patternIface(pid) orelse return c.S_OK;
        _ = e.addRef();
        return c.S_OK;
    }

    fn propertyValue(this: *anyopaque, pid: i32, out: *c.VARIANT) callconv(winapi) HRESULT {
        const e = from("simple", this);
        out.* = .{};
        const h = e.hold() orelse {
            // The window answers before its first snapshot.
            if (e.isRoot()) {
                if (pid == c.prop.control_type) out.* = .int(c.control.window);
                if (pid == c.prop.framework_id) out.* = .bstr(bstrOf(e, "zigguro"));
                return c.S_OK;
            }
            return c.UIA_E_ELEMENTNOTAVAILABLE;
        };
        defer h.s.release();
        const n = h.n;
        const st = n.state;
        out.* = switch (pid) {
            c.prop.control_type => .int(controlType(n.role)),
            c.prop.name => if (n.name.len > 0) .bstr(bstrOf(e, n.name)) else .{},
            c.prop.has_keyboard_focus => .boolean(st.focused),
            c.prop.is_keyboard_focusable => .boolean(st.focusable),
            c.prop.is_enabled => .boolean(!st.disabled),
            c.prop.is_offscreen => .boolean(st.offscreen),
            c.prop.is_control_element, c.prop.is_content_element => .boolean(true),
            c.prop.is_password => .boolean(false),
            c.prop.framework_id => .bstr(bstrOf(e, "zigguro")),
            c.prop.automation_id => if (n.test_id != 0) blk: {
                var buf: [20]u8 = undefined;
                break :blk .bstr(bstrOf(e, std.fmt.bufPrint(&buf, "t{x:0>16}", .{n.test_id}) catch "t"));
            } else .{},
            c.prop.value_value => if (n.role == .textbox) .bstr(bstrOf(e, n.text)) else .{},
            c.prop.range_value_value => if (n.value) |v| .double(v) else .{},
            c.prop.toggle_state => if (st.checkable) .int(@intFromEnum(if (st.checked) c.ToggleState.on else c.ToggleState.off)) else .{},
            c.prop.expand_collapse_state => if (st.expandable) .int(@intFromEnum(if (st.expanded) c.ExpandCollapseState.expanded else c.ExpandCollapseState.collapsed)) else .{},
            c.prop.selection_item_is_selected => if (st.selectable) .boolean(st.selected) else .{},
            c.prop.position_in_set => if (n.row_index > 0) .int(@intCast(@min(n.row_index, std.math.maxInt(i32)))) else .{},
            c.prop.size_of_set => if (n.row_index > 0 and n.parent != Node.no_parent and h.s.nodes[n.parent].row_count > 0)
                .int(@intCast(@min(h.s.nodes[n.parent].row_count, std.math.maxInt(i32))))
            else
                .{},
            c.prop.level => if (n.level > 0) .int(n.level) else .{},
            // RuntimeId and BoundingRectangle come from the fragment.
            else => .{},
        };
        return c.S_OK;
    }

    fn hostProvider(this: *anyopaque, out: *?*anyopaque) callconv(winapi) HRESULT {
        const e = from("simple", this);
        out.* = null;
        if (!e.isRoot()) return c.S_OK;
        const hwnd = e.bridge.hwnd orelse return c.S_OK;
        return e.bridge.api.hostProviderFromHwnd(hwnd, out);
    }
};

// -- IRawElementProviderFragment -----------------------------------------------------

const fragment_vtbl: vt.Fragment = .{
    .QueryInterface = Unknown("fragment").qi,
    .AddRef = Unknown("fragment").add,
    .Release = Unknown("fragment").rel,
    .Navigate = Fragment.navigate,
    .GetRuntimeId = Fragment.runtimeId,
    .get_BoundingRectangle = Fragment.bounds,
    .GetEmbeddedFragmentRoots = Fragment.embeddedRoots,
    .SetFocus = Fragment.setFocus,
    .get_FragmentRoot = Fragment.fragmentRoot,
};

const Fragment = struct {
    fn navigate(this: *anyopaque, dir: c.NavigateDirection, out: *?*anyopaque) callconv(winapi) HRESULT {
        const e = from("fragment", this);
        out.* = null;
        const h = e.hold() orelse return if (e.isRoot()) c.S_OK else c.UIA_E_ELEMENTNOTAVAILABLE;
        defer h.s.release();
        const s = h.s;
        const n = h.n;
        const target: ?*const Node = switch (dir) {
            // The window's parent and siblings come from its host HWND.
            .parent => if (e.isRoot() or n.parent == Node.no_parent) null else &s.nodes[n.parent],
            .first_child, .last_child => blk: {
                const ks = s.children(n);
                if (ks.len == 0) break :blk null;
                break :blk &s.nodes[if (dir == .first_child) ks[0] else ks[ks.len - 1]];
            },
            .next_sibling, .previous_sibling => blk: {
                if (e.isRoot() or n.parent == Node.no_parent) break :blk null;
                const ks = s.children(&s.nodes[n.parent]);
                const me = s.index.get(n.id).?;
                const at = std.mem.indexOfScalar(u32, ks, me) orelse break :blk null;
                if (dir == .next_sibling) {
                    break :blk if (at + 1 < ks.len) &s.nodes[ks[at + 1]] else null;
                }
                break :blk if (at > 0) &s.nodes[ks[at - 1]] else null;
            },
        };
        const tn = target orelse return c.S_OK;
        const te = e.bridge.element(tn.id) orelse return c.E_OUTOFMEMORY;
        out.* = &te.fragment;
        return c.S_OK;
    }

    fn runtimeId(this: *anyopaque, out: *?*c.SAFEARRAY) callconv(winapi) HRESULT {
        const e = from("fragment", this);
        out.* = null;
        // The window's id comes from its HWND.
        if (e.isRoot()) return c.S_OK;
        const rid = runtimeIdOf(e.id);
        const api = &e.bridge.api;
        const sa = api.safeArrayCreateVector(c.VT_I4, 0, rid.len) orelse return c.E_OUTOFMEMORY;
        for (rid, 0..) |v, i| {
            const idx: i32 = @intCast(i);
            _ = api.safeArrayPutElement(sa, &idx, &v);
        }
        out.* = sa;
        return c.S_OK;
    }

    fn bounds(this: *anyopaque, out: *c.UiaRect) callconv(winapi) HRESULT {
        const e = from("fragment", this);
        out.* = .{ .left = 0, .top = 0, .width = 0, .height = 0 };
        const h = e.hold() orelse return if (e.isRoot()) c.S_OK else c.UIA_E_ELEMENTNOTAVAILABLE;
        defer h.s.release();
        out.* = screenRect(h.s, h.n);
        return c.S_OK;
    }

    fn embeddedRoots(_: *anyopaque, out: *?*c.SAFEARRAY) callconv(winapi) HRESULT {
        out.* = null;
        return c.S_OK;
    }

    fn setFocus(this: *anyopaque) callconv(winapi) HRESULT {
        return from("fragment", this).act(.focus, null);
    }

    fn fragmentRoot(this: *anyopaque, out: *?*anyopaque) callconv(winapi) HRESULT {
        const e = from("fragment", this);
        const r = e.bridge.root_el;
        _ = r.addRef();
        out.* = &r.root;
        return c.S_OK;
    }
};

/// `[UiaAppendRuntimeId, low 32 bits, high 32 bits]` of a node id.
pub fn runtimeIdOf(id: u64) [3]i32 {
    return .{ c.UiaAppendRuntimeId, @bitCast(@as(u32, @truncate(id))), @bitCast(@as(u32, @truncate(id >> 32))) };
}

/// A node's bounds in screen pixels.
pub fn screenRect(s: *const Snapshot, n: *const Node) c.UiaRect {
    const o: [2]i32 = s.screen_origin orelse .{ 0, 0 };
    const k: f64 = s.scale;
    return .{
        .left = @as(f64, n.bounds[0]) * k + @as(f64, @floatFromInt(o[0])),
        .top = @as(f64, n.bounds[1]) * k + @as(f64, @floatFromInt(o[1])),
        .width = @as(f64, n.bounds[2]) * k,
        .height = @as(f64, n.bounds[3]) * k,
    };
}

// -- IRawElementProviderFragmentRoot -------------------------------------------------

const root_vtbl: vt.FragmentRoot = .{
    .QueryInterface = Unknown("root").qi,
    .AddRef = Unknown("root").add,
    .Release = Unknown("root").rel,
    .ElementProviderFromPoint = Root.fromPoint,
    .GetFocus = Root.focus,
};

const Root = struct {
    fn fromPoint(this: *anyopaque, x: f64, y: f64, out: *?*anyopaque) callconv(winapi) HRESULT {
        const e = from("root", this);
        out.* = null;
        const s = e.bridge.snapshot() orelse return c.S_OK;
        defer s.release();
        const o: [2]i32 = s.screen_origin orelse .{ 0, 0 };
        const lx: f32 = @floatCast((x - @as(f64, @floatFromInt(o[0]))) / s.scale);
        const ly: f32 = @floatCast((y - @as(f64, @floatFromInt(o[1]))) / s.scale);
        const n = s.nodeAt(lx, ly) orelse return c.S_OK;
        const te = e.bridge.element(n.id) orelse return c.E_OUTOFMEMORY;
        out.* = &te.fragment;
        return c.S_OK;
    }

    fn focus(this: *anyopaque, out: *?*anyopaque) callconv(winapi) HRESULT {
        const e = from("root", this);
        out.* = null;
        const s = e.bridge.snapshot() orelse return c.S_OK;
        defer s.release();
        if (s.focus == 0 or s.focus == e.id) return c.S_OK;
        const te = e.bridge.element(s.focus) orelse return c.E_OUTOFMEMORY;
        out.* = &te.fragment;
        return c.S_OK;
    }
};

// -- patterns --------------------------------------------------------------------------

const invoke_vtbl: vt.Invoke = .{
    .QueryInterface = Unknown("invoke").qi,
    .AddRef = Unknown("invoke").add,
    .Release = Unknown("invoke").rel,
    .Invoke = struct {
        fn f(this: *anyopaque) callconv(winapi) HRESULT {
            return from("invoke", this).act(.invoke, null);
        }
    }.f,
};

const toggle_vtbl: vt.Toggle = .{
    .QueryInterface = Unknown("toggle").qi,
    .AddRef = Unknown("toggle").add,
    .Release = Unknown("toggle").rel,
    .Toggle = struct {
        fn f(this: *anyopaque) callconv(winapi) HRESULT {
            return from("toggle", this).act(.toggle, null);
        }
    }.f,
    .get_ToggleState = struct {
        fn f(this: *anyopaque, out: *c.ToggleState) callconv(winapi) HRESULT {
            const e = from("toggle", this);
            const h = e.hold() orelse return c.UIA_E_ELEMENTNOTAVAILABLE;
            defer h.s.release();
            out.* = if (h.n.state.checked) .on else .off;
            return c.S_OK;
        }
    }.f,
};

const value_vtbl: vt.Value = .{
    .QueryInterface = Unknown("value").qi,
    .AddRef = Unknown("value").add,
    .Release = Unknown("value").rel,
    .SetValue = struct {
        fn f(this: *anyopaque, w: [*:0]const u16) callconv(winapi) HRESULT {
            const e = from("value", this);
            const gpa = e.bridge.gpa;
            const s = std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.span(w)) catch return c.E_INVALIDARG;
            defer gpa.free(s);
            // performAction copies the text.
            return e.act(.set_value, .{ .text = s });
        }
    }.f,
    .get_Value = struct {
        fn f(this: *anyopaque, out: *c.BSTR) callconv(winapi) HRESULT {
            const e = from("value", this);
            const h = e.hold() orelse return c.UIA_E_ELEMENTNOTAVAILABLE;
            defer h.s.release();
            out.* = bstrOf(e, h.n.text);
            return c.S_OK;
        }
    }.f,
    .get_IsReadOnly = struct {
        fn f(this: *anyopaque, out: *c.BOOL) callconv(winapi) HRESULT {
            const e = from("value", this);
            const h = e.hold() orelse return c.UIA_E_ELEMENTNOTAVAILABLE;
            defer h.s.release();
            out.* = @intFromBool(!h.n.state.editable or h.n.state.disabled);
            return c.S_OK;
        }
    }.f,
};

fn rangeGet(comptime what: enum { value, min, max, large, small }) *const fn (*anyopaque, *f64) callconv(winapi) HRESULT {
    return struct {
        fn f(this: *anyopaque, out: *f64) callconv(winapi) HRESULT {
            const e = from("range", this);
            const h = e.hold() orelse return c.UIA_E_ELEMENTNOTAVAILABLE;
            defer h.s.release();
            out.* = switch (what) {
                .value => h.n.value orelse 0,
                .min => 0,
                .max => 1,
                .large => 0.1,
                .small => 0.01,
            };
            return c.S_OK;
        }
    }.f;
}

const range_vtbl: vt.RangeValue = .{
    .QueryInterface = Unknown("range").qi,
    .AddRef = Unknown("range").add,
    .Release = Unknown("range").rel,
    .SetValue = struct {
        fn f(this: *anyopaque, v: f64) callconv(winapi) HRESULT {
            return from("range", this).act(.set_value, .{ .number = v });
        }
    }.f,
    .get_Value = rangeGet(.value),
    .get_IsReadOnly = struct {
        fn f(this: *anyopaque, out: *c.BOOL) callconv(winapi) HRESULT {
            const e = from("range", this);
            const h = e.hold() orelse return c.UIA_E_ELEMENTNOTAVAILABLE;
            defer h.s.release();
            out.* = @intFromBool(h.n.role == .progressbar or h.n.state.disabled);
            return c.S_OK;
        }
    }.f,
    .get_Maximum = rangeGet(.max),
    .get_Minimum = rangeGet(.min),
    .get_LargeChange = rangeGet(.large),
    .get_SmallChange = rangeGet(.small),
};

const expand_vtbl: vt.ExpandCollapse = .{
    .QueryInterface = Unknown("expand").qi,
    .AddRef = Unknown("expand").add,
    .Release = Unknown("expand").rel,
    .Expand = struct {
        fn f(this: *anyopaque) callconv(winapi) HRESULT {
            return from("expand", this).act(.expand, null);
        }
    }.f,
    .Collapse = struct {
        fn f(this: *anyopaque) callconv(winapi) HRESULT {
            return from("expand", this).act(.collapse, null);
        }
    }.f,
    .get_ExpandCollapseState = struct {
        fn f(this: *anyopaque, out: *c.ExpandCollapseState) callconv(winapi) HRESULT {
            const e = from("expand", this);
            const h = e.hold() orelse return c.UIA_E_ELEMENTNOTAVAILABLE;
            defer h.s.release();
            const st = h.n.state;
            out.* = if (!st.expandable) .leaf_node else if (st.expanded) .expanded else .collapsed;
            return c.S_OK;
        }
    }.f,
};

const selitem_vtbl: vt.SelectionItem = .{
    .QueryInterface = Unknown("selitem").qi,
    .AddRef = Unknown("selitem").add,
    .Release = Unknown("selitem").rel,
    .Select = struct {
        fn f(this: *anyopaque) callconv(winapi) HRESULT {
            return from("selitem", this).act(.select, null);
        }
    }.f,
    .AddToSelection = struct {
        fn f(this: *anyopaque) callconv(winapi) HRESULT {
            return from("selitem", this).act(.add_to_selection, null);
        }
    }.f,
    .RemoveFromSelection = struct {
        fn f(this: *anyopaque) callconv(winapi) HRESULT {
            return from("selitem", this).act(.remove_from_selection, null);
        }
    }.f,
    .get_IsSelected = struct {
        fn f(this: *anyopaque, out: *c.BOOL) callconv(winapi) HRESULT {
            const e = from("selitem", this);
            const h = e.hold() orelse return c.UIA_E_ELEMENTNOTAVAILABLE;
            defer h.s.release();
            out.* = @intFromBool(h.n.state.selected);
            return c.S_OK;
        }
    }.f,
    .get_SelectionContainer = struct {
        fn f(this: *anyopaque, out: *?*anyopaque) callconv(winapi) HRESULT {
            const e = from("selitem", this);
            out.* = null;
            const h = e.hold() orelse return c.UIA_E_ELEMENTNOTAVAILABLE;
            defer h.s.release();
            var p = h.n.parent;
            while (p != Node.no_parent) : (p = h.s.nodes[p].parent) {
                const pn = &h.s.nodes[p];
                switch (pn.role) {
                    .list, .tree, .tablist, .grid, .menu => {
                        const te = e.bridge.element(pn.id) orelse return c.E_OUTOFMEMORY;
                        out.* = &te.simple;
                        return c.S_OK;
                    },
                    else => {},
                }
            }
            return c.S_OK;
        }
    }.f,
};

const scrollitem_vtbl: vt.ScrollItem = .{
    .QueryInterface = Unknown("scrollitem").qi,
    .AddRef = Unknown("scrollitem").add,
    .Release = Unknown("scrollitem").rel,
    .ScrollIntoView = struct {
        fn f(this: *anyopaque) callconv(winapi) HRESULT {
            return from("scrollitem", this).act(.scroll_into_view, null);
        }
    }.f,
};
