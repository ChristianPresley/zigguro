//! UI Automation ABI pieces (E04.F09.S01.T02): interface ids, the
//! constants zigguro's providers use (UIAutomationClient.h /
//! UIAutomationCoreApi.h numbering), `VARIANT`, and `Api`, the
//! uiautomationcore.dll and oleaut32.dll entry points. `Api.windows()`
//! binds the DLLs on Windows; tests on every OS pass fakes.

const std = @import("std");
const builtin = @import("builtin");
const zg_platform = @import("zg_platform");

const t = zg_platform.win32.types;
pub const com = zg_platform.win32.com;
pub const GUID = t.GUID;
pub const HRESULT = t.HRESULT;
pub const ULONG = t.ULONG;
pub const BOOL = t.BOOL;
pub const winapi = t.winapi;
pub const S_OK = t.S_OK;
pub const E_NOINTERFACE = t.E_NOINTERFACE;
pub const E_POINTER = t.E_POINTER;
pub const E_FAIL = t.E_FAIL;
pub const E_OUTOFMEMORY = t.E_OUTOFMEMORY;
pub const E_INVALIDARG: HRESULT = @bitCast(@as(u32, 0x80070057));
/// The element's node is gone.
pub const UIA_E_ELEMENTNOTAVAILABLE: HRESULT = @bitCast(@as(u32, 0x80040201));
/// The element can't do that now (disabled).
pub const UIA_E_ELEMENTNOTENABLED: HRESULT = @bitCast(@as(u32, 0x80040200));

/// `WM_GETOBJECT`.
pub const WM_GETOBJECT: u32 = 0x003D;
/// `UiaRootObjectId`: the object id of a `WM_GETOBJECT` for UIA.
pub const UiaRootObjectId: i32 = -25;
/// First element of a runtime id that UIA completes with the host's.
pub const UiaAppendRuntimeId: i32 = 3;

pub const iid = struct {
    pub const IUnknown = com.guid("00000000-0000-0000-c000-000000000046");
    pub const IRawElementProviderSimple = com.guid("d6dd68d1-86fd-4332-8666-9abedea2d24c");
    pub const IRawElementProviderFragment = com.guid("f7063da8-8359-439c-9297-bbc5299a7d87");
    pub const IRawElementProviderFragmentRoot = com.guid("620ce2a5-ab8f-40a9-86cb-de3c75599b58");
    pub const IInvokeProvider = com.guid("54fcb24b-e18e-47a2-b4d3-eccbe77599a2");
    pub const IToggleProvider = com.guid("56d00bd0-c4f4-433c-a836-1a52a57e0892");
    pub const IValueProvider = com.guid("c7935180-6fb3-4201-b174-7df73adbf64a");
    pub const IRangeValueProvider = com.guid("36dc7aef-33e6-4691-afe1-2be7274b3d33");
    pub const IExpandCollapseProvider = com.guid("d847d3a5-cab0-4a98-8c32-ecb45c59ad24");
    pub const ISelectionItemProvider = com.guid("2acad808-b2d4-452d-a407-91ff1ad167b2");
    pub const IScrollItemProvider = com.guid("2360c714-4bf1-4b26-ba65-9b21316127eb");
};

/// Pattern ids (`UIA_*PatternId`).
pub const pattern = struct {
    pub const invoke: i32 = 10000;
    pub const value: i32 = 10002;
    pub const range_value: i32 = 10003;
    pub const expand_collapse: i32 = 10005;
    pub const selection_item: i32 = 10010;
    pub const toggle: i32 = 10015;
    pub const scroll_item: i32 = 10017;
};

/// Property ids (`UIA_*PropertyId`).
pub const prop = struct {
    pub const runtime_id: i32 = 30000;
    pub const bounding_rectangle: i32 = 30001;
    pub const control_type: i32 = 30003;
    pub const name: i32 = 30005;
    pub const has_keyboard_focus: i32 = 30008;
    pub const is_keyboard_focusable: i32 = 30009;
    pub const is_enabled: i32 = 30010;
    pub const automation_id: i32 = 30011;
    pub const help_text: i32 = 30013;
    pub const is_control_element: i32 = 30016;
    pub const is_content_element: i32 = 30017;
    pub const is_password: i32 = 30019;
    pub const is_offscreen: i32 = 30022;
    pub const framework_id: i32 = 30024;
    pub const value_value: i32 = 30045;
    pub const range_value_value: i32 = 30047;
    pub const expand_collapse_state: i32 = 30070;
    pub const selection_item_is_selected: i32 = 30079;
    pub const toggle_state: i32 = 30086;
    pub const position_in_set: i32 = 30152;
    pub const size_of_set: i32 = 30153;
    pub const level: i32 = 30154;
};

/// Control type ids (`UIA_*ControlTypeId`).
pub const control = struct {
    pub const button: i32 = 50000;
    pub const check_box: i32 = 50002;
    pub const edit: i32 = 50004;
    pub const hyperlink: i32 = 50005;
    pub const image: i32 = 50006;
    pub const list_item: i32 = 50007;
    pub const list: i32 = 50008;
    pub const menu: i32 = 50009;
    pub const menu_bar: i32 = 50010;
    pub const menu_item: i32 = 50011;
    pub const progress_bar: i32 = 50012;
    pub const radio_button: i32 = 50013;
    pub const slider: i32 = 50015;
    pub const status_bar: i32 = 50017;
    pub const tab: i32 = 50018;
    pub const tab_item: i32 = 50019;
    pub const text: i32 = 50020;
    pub const tool_bar: i32 = 50021;
    pub const tool_tip: i32 = 50022;
    pub const tree: i32 = 50023;
    pub const tree_item: i32 = 50024;
    pub const group: i32 = 50026;
    pub const data_grid: i32 = 50028;
    pub const data_item: i32 = 50029;
    pub const window: i32 = 50032;
    pub const pane: i32 = 50033;
    pub const header_item: i32 = 50035;
    pub const separator: i32 = 50038;
};

/// Event ids (`UIA_*EventId`).
pub const event = struct {
    pub const structure_changed: i32 = 20002;
    pub const menu_opened: i32 = 20003;
    pub const focus_changed: i32 = 20005;
    pub const menu_closed: i32 = 20007;
};

pub const NavigateDirection = enum(i32) { parent = 0, next_sibling = 1, previous_sibling = 2, first_child = 3, last_child = 4 };
pub const ProviderOptions = struct {
    pub const server_side: i32 = 0x2;
    pub const use_com_threading: i32 = 0x20;
};
pub const ToggleState = enum(i32) { off = 0, on = 1, indeterminate = 2 };
pub const ExpandCollapseState = enum(i32) { collapsed = 0, expanded = 1, partially_expanded = 2, leaf_node = 3 };
pub const StructureChangeType = enum(i32) { child_added = 0, child_removed = 1, children_invalidated = 2, children_bulk_added = 3, children_bulk_removed = 4, children_reordered = 5 };
pub const NotificationKind = enum(i32) { item_added = 0, item_removed = 1, action_completed = 2, action_aborted = 3, other = 4 };
pub const NotificationProcessing = enum(i32) { important_all = 0, important_most_recent = 1, all = 2, most_recent = 3, current_then_most_recent = 4 };

/// `UiaRect`: screen pixels.
pub const UiaRect = extern struct { left: f64, top: f64, width: f64, height: f64 };

/// A `BSTR` (length-prefixed UTF-16 from `SysAllocStringLen`).
pub const BSTR = ?[*:0]u16;

pub const VT_EMPTY: u16 = 0;
pub const VT_I4: u16 = 3;
pub const VT_R8: u16 = 5;
pub const VT_BSTR: u16 = 8;
pub const VT_BOOL: u16 = 11;
pub const VT_UNKNOWN: u16 = 13;
pub const VARIANT_TRUE: i16 = -1;
pub const VARIANT_FALSE: i16 = 0;

/// `VARIANT` (oaidl.h), the members zigguro sets.
pub const VARIANT = extern struct {
    vt: u16 = VT_EMPTY,
    r1: u16 = 0,
    r2: u16 = 0,
    r3: u16 = 0,
    v: extern union {
        lVal: i32,
        dblVal: f64,
        boolVal: i16,
        bstrVal: BSTR,
        punkVal: ?*anyopaque,
        pad: [2]usize,
    } = .{ .pad = .{ 0, 0 } },

    pub fn int(x: i32) VARIANT {
        return .{ .vt = VT_I4, .v = .{ .lVal = x } };
    }
    pub fn boolean(b: bool) VARIANT {
        return .{ .vt = VT_BOOL, .v = .{ .boolVal = if (b) VARIANT_TRUE else VARIANT_FALSE } };
    }
    pub fn double(x: f64) VARIANT {
        return .{ .vt = VT_R8, .v = .{ .dblVal = x } };
    }
    pub fn bstr(s: BSTR) VARIANT {
        return .{ .vt = VT_BSTR, .v = .{ .bstrVal = s } };
    }
};

/// An opaque `SAFEARRAY`.
pub const SAFEARRAY = opaque {};

/// The DLL entry points the providers and the bridge call.
pub const Api = struct {
    sysAllocStringLen: *const fn (s: ?[*]const u16, len: u32) callconv(winapi) BSTR,
    sysFreeString: *const fn (s: BSTR) callconv(winapi) void,
    safeArrayCreateVector: *const fn (vt: u16, lbound: i32, n: u32) callconv(winapi) ?*SAFEARRAY,
    safeArrayPutElement: *const fn (psa: *SAFEARRAY, idx: *const i32, v: *const anyopaque) callconv(winapi) HRESULT,
    returnRawElementProvider: *const fn (hwnd: *anyopaque, wp: usize, lp: isize, el: ?*anyopaque) callconv(winapi) isize,
    hostProviderFromHwnd: *const fn (hwnd: *anyopaque, out: *?*anyopaque) callconv(winapi) HRESULT,
    raiseAutomationEvent: *const fn (p: *anyopaque, id: i32) callconv(winapi) HRESULT,
    raisePropertyChangedEvent: *const fn (p: *anyopaque, id: i32, old: VARIANT, new: VARIANT) callconv(winapi) HRESULT,
    raiseStructureChangedEvent: *const fn (p: *anyopaque, kind: i32, rid: [*]i32, len: i32) callconv(winapi) HRESULT,
    clientsAreListening: *const fn () callconv(winapi) BOOL,
    /// Windows 10 1709 and later (looked up at run time).
    raiseNotificationEvent: ?*const fn (p: *anyopaque, kind: i32, processing: i32, display: BSTR, activity: BSTR) callconv(winapi) HRESULT = null,

    /// A BSTR copy of UTF-8 `s` (null when it can't be made).
    pub fn bstrOf(api: *const Api, gpa: std.mem.Allocator, s: []const u8) BSTR {
        const w = std.unicode.utf8ToUtf16LeAlloc(gpa, s) catch return null;
        defer gpa.free(w);
        return api.sysAllocStringLen(w.ptr, @intCast(w.len));
    }

    /// The real DLLs (Windows only).
    pub fn windows() Api {
        if (builtin.os.tag != .windows) @compileError("UIA is Windows only");
        const dll = struct {
            extern "oleaut32" fn SysAllocStringLen(?[*]const u16, u32) callconv(.winapi) BSTR;
            extern "oleaut32" fn SysFreeString(BSTR) callconv(.winapi) void;
            extern "oleaut32" fn SafeArrayCreateVector(u16, i32, u32) callconv(.winapi) ?*SAFEARRAY;
            extern "oleaut32" fn SafeArrayPutElement(*SAFEARRAY, *const i32, *const anyopaque) callconv(.winapi) HRESULT;
            extern "uiautomationcore" fn UiaReturnRawElementProvider(*anyopaque, usize, isize, ?*anyopaque) callconv(.winapi) isize;
            extern "uiautomationcore" fn UiaHostProviderFromHwnd(*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT;
            extern "uiautomationcore" fn UiaRaiseAutomationEvent(*anyopaque, i32) callconv(.winapi) HRESULT;
            extern "uiautomationcore" fn UiaRaiseAutomationPropertyChangedEvent(*anyopaque, i32, VARIANT, VARIANT) callconv(.winapi) HRESULT;
            extern "uiautomationcore" fn UiaRaiseStructureChangedEvent(*anyopaque, i32, [*]i32, i32) callconv(.winapi) HRESULT;
            extern "uiautomationcore" fn UiaClientsAreListening() callconv(.winapi) BOOL;
        };
        var api: Api = .{
            .sysAllocStringLen = dll.SysAllocStringLen,
            .sysFreeString = dll.SysFreeString,
            .safeArrayCreateVector = dll.SafeArrayCreateVector,
            .safeArrayPutElement = dll.SafeArrayPutElement,
            .returnRawElementProvider = dll.UiaReturnRawElementProvider,
            .hostProviderFromHwnd = dll.UiaHostProviderFromHwnd,
            .raiseAutomationEvent = dll.UiaRaiseAutomationEvent,
            .raisePropertyChangedEvent = dll.UiaRaiseAutomationPropertyChangedEvent,
            .raiseStructureChangedEvent = dll.UiaRaiseStructureChangedEvent,
            .clientsAreListening = dll.UiaClientsAreListening,
        };
        const k32 = zg_platform.win32.kernel32;
        const name = std.unicode.utf8ToUtf16LeStringLiteral("uiautomationcore.dll");
        if (k32.GetModuleHandleW(name)) |m| if (k32.GetProcAddress(m, "UiaRaiseNotificationEvent")) |f| {
            api.raiseNotificationEvent = @ptrCast(@alignCast(f));
        };
        return api;
    }
};

/// The vtable layouts, in UIAutomationCore.idl order.
pub const vtbl = struct {
    pub const This = *anyopaque;
    pub const QueryInterface = *const fn (This, *const GUID, *?*anyopaque) callconv(winapi) HRESULT;
    pub const AddRef = *const fn (This) callconv(winapi) ULONG;
    pub const Release = *const fn (This) callconv(winapi) ULONG;
    pub const Void = *const fn (This) callconv(winapi) HRESULT;

    pub const Simple = extern struct {
        QueryInterface: QueryInterface,
        AddRef: AddRef,
        Release: Release,
        get_ProviderOptions: *const fn (This, *i32) callconv(winapi) HRESULT,
        GetPatternProvider: *const fn (This, i32, *?*anyopaque) callconv(winapi) HRESULT,
        GetPropertyValue: *const fn (This, i32, *VARIANT) callconv(winapi) HRESULT,
        get_HostRawElementProvider: *const fn (This, *?*anyopaque) callconv(winapi) HRESULT,
    };
    pub const Fragment = extern struct {
        QueryInterface: QueryInterface,
        AddRef: AddRef,
        Release: Release,
        Navigate: *const fn (This, NavigateDirection, *?*anyopaque) callconv(winapi) HRESULT,
        GetRuntimeId: *const fn (This, *?*SAFEARRAY) callconv(winapi) HRESULT,
        get_BoundingRectangle: *const fn (This, *UiaRect) callconv(winapi) HRESULT,
        GetEmbeddedFragmentRoots: *const fn (This, *?*SAFEARRAY) callconv(winapi) HRESULT,
        SetFocus: Void,
        get_FragmentRoot: *const fn (This, *?*anyopaque) callconv(winapi) HRESULT,
    };
    pub const FragmentRoot = extern struct {
        QueryInterface: QueryInterface,
        AddRef: AddRef,
        Release: Release,
        ElementProviderFromPoint: *const fn (This, f64, f64, *?*anyopaque) callconv(winapi) HRESULT,
        GetFocus: *const fn (This, *?*anyopaque) callconv(winapi) HRESULT,
    };
    pub const Invoke = extern struct {
        QueryInterface: QueryInterface,
        AddRef: AddRef,
        Release: Release,
        Invoke: Void,
    };
    pub const Toggle = extern struct {
        QueryInterface: QueryInterface,
        AddRef: AddRef,
        Release: Release,
        Toggle: Void,
        get_ToggleState: *const fn (This, *ToggleState) callconv(winapi) HRESULT,
    };
    pub const Value = extern struct {
        QueryInterface: QueryInterface,
        AddRef: AddRef,
        Release: Release,
        SetValue: *const fn (This, [*:0]const u16) callconv(winapi) HRESULT,
        get_Value: *const fn (This, *BSTR) callconv(winapi) HRESULT,
        get_IsReadOnly: *const fn (This, *BOOL) callconv(winapi) HRESULT,
    };
    pub const RangeValue = extern struct {
        QueryInterface: QueryInterface,
        AddRef: AddRef,
        Release: Release,
        SetValue: *const fn (This, f64) callconv(winapi) HRESULT,
        get_Value: *const fn (This, *f64) callconv(winapi) HRESULT,
        get_IsReadOnly: *const fn (This, *BOOL) callconv(winapi) HRESULT,
        get_Maximum: *const fn (This, *f64) callconv(winapi) HRESULT,
        get_Minimum: *const fn (This, *f64) callconv(winapi) HRESULT,
        get_LargeChange: *const fn (This, *f64) callconv(winapi) HRESULT,
        get_SmallChange: *const fn (This, *f64) callconv(winapi) HRESULT,
    };
    pub const ExpandCollapse = extern struct {
        QueryInterface: QueryInterface,
        AddRef: AddRef,
        Release: Release,
        Expand: Void,
        Collapse: Void,
        get_ExpandCollapseState: *const fn (This, *ExpandCollapseState) callconv(winapi) HRESULT,
    };
    pub const SelectionItem = extern struct {
        QueryInterface: QueryInterface,
        AddRef: AddRef,
        Release: Release,
        Select: Void,
        AddToSelection: Void,
        RemoveFromSelection: Void,
        get_IsSelected: *const fn (This, *BOOL) callconv(winapi) HRESULT,
        get_SelectionContainer: *const fn (This, *?*anyopaque) callconv(winapi) HRESULT,
    };
    pub const ScrollItem = extern struct {
        QueryInterface: QueryInterface,
        AddRef: AddRef,
        Release: Release,
        ScrollIntoView: Void,
    };
};
