//! COM in Zig: comptime GUIDs, the interface vtables the backend uses
//! (declared in Windows SDK header order: oleidl.h, objidl.h and
//! shobjidl_core.h), and `ComObject`, which turns a Zig struct into a COM
//! object with an atomic refcount and QueryInterface. Pure Zig: the tests
//! run on every OS.

const std = @import("std");
const t = @import("bindings/types.zig");
const GUID = t.GUID;
const HRESULT = t.HRESULT;
const ULONG = t.ULONG;
const DWORD = t.DWORD;
const BOOL = t.BOOL;

/// Parses `"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"` at compile time.
pub fn guid(comptime s: []const u8) GUID {
    return comptime parseGuid(s) catch @compileError("bad GUID: " ++ s);
}

/// Parses a GUID string (no braces).
pub fn parseGuid(s: []const u8) error{InvalidGuid}!GUID {
    if (s.len != 36 or s[8] != '-' or s[13] != '-' or s[18] != '-' or s[23] != '-') return error.InvalidGuid;
    const hex = struct {
        fn int(comptime T: type, x: []const u8) error{InvalidGuid}!T {
            return std.fmt.parseInt(T, x, 16) catch error.InvalidGuid;
        }
    };
    var g: GUID = .{ .data1 = try hex.int(u32, s[0..8]), .data2 = try hex.int(u16, s[9..13]), .data3 = try hex.int(u16, s[14..18]), .data4 = undefined };
    g.data4[0] = try hex.int(u8, s[19..21]);
    g.data4[1] = try hex.int(u8, s[21..23]);
    for (0..6) |i| g.data4[2 + i] = try hex.int(u8, s[24 + 2 * i ..][0..2]);
    return g;
}

/// `this` of every COM method.
pub const This = *anyopaque;

/// The three IUnknown methods, which start every vtable.
const U = struct {
    const QueryInterface = *const fn (This, *const GUID, *?*anyopaque) callconv(t.winapi) HRESULT;
    const AddRef = *const fn (This) callconv(t.winapi) ULONG;
    const Release = *const fn (This) callconv(t.winapi) ULONG;
};

/// `IUnknown`.
pub const IUnknown = extern struct {
    vtbl: *const Vtbl,
    /// Its vtable.
    pub const Vtbl = extern struct {
        QueryInterface: U.QueryInterface,
        AddRef: U.AddRef,
        Release: U.Release,
        /// `IID_IUnknown`.
        pub const iid = guid("00000000-0000-0000-c000-000000000046");
    };
    /// Calls `Release` on any interface pointer.
    pub fn release(p: anytype) ULONG {
        return p.vtbl.Release(p);
    }
};

/// `IDropTarget` (oleidl.h).
pub const IDropTarget = extern struct {
    vtbl: *const Vtbl,
    /// Its vtable.
    pub const Vtbl = extern struct {
        QueryInterface: U.QueryInterface,
        AddRef: U.AddRef,
        Release: U.Release,
        DragEnter: *const fn (This, *IDataObject, key_state: DWORD, pt: t.POINTL, effect: *DWORD) callconv(t.winapi) HRESULT,
        DragOver: *const fn (This, key_state: DWORD, pt: t.POINTL, effect: *DWORD) callconv(t.winapi) HRESULT,
        DragLeave: *const fn (This) callconv(t.winapi) HRESULT,
        Drop: *const fn (This, *IDataObject, key_state: DWORD, pt: t.POINTL, effect: *DWORD) callconv(t.winapi) HRESULT,
        /// `IID_IDropTarget`.
        pub const iid = guid("00000122-0000-0000-c000-000000000046");
    };
};

/// `IDropSource` (oleidl.h).
pub const IDropSource = extern struct {
    vtbl: *const Vtbl,
    /// Its vtable.
    pub const Vtbl = extern struct {
        QueryInterface: U.QueryInterface,
        AddRef: U.AddRef,
        Release: U.Release,
        QueryContinueDrag: *const fn (This, escape: BOOL, key_state: DWORD) callconv(t.winapi) HRESULT,
        GiveFeedback: *const fn (This, effect: DWORD) callconv(t.winapi) HRESULT,
        /// `IID_IDropSource`.
        pub const iid = guid("00000121-0000-0000-c000-000000000046");
    };
};

/// `IDataObject` (objidl.h).
pub const IDataObject = extern struct {
    vtbl: *const Vtbl,
    /// Its vtable.
    pub const Vtbl = extern struct {
        QueryInterface: U.QueryInterface,
        AddRef: U.AddRef,
        Release: U.Release,
        GetData: *const fn (This, *const t.FORMATETC, *t.STGMEDIUM) callconv(t.winapi) HRESULT,
        GetDataHere: *const fn (This, *const t.FORMATETC, *t.STGMEDIUM) callconv(t.winapi) HRESULT,
        QueryGetData: *const fn (This, *const t.FORMATETC) callconv(t.winapi) HRESULT,
        GetCanonicalFormatEtc: *const fn (This, *const t.FORMATETC, *t.FORMATETC) callconv(t.winapi) HRESULT,
        SetData: *const fn (This, *const t.FORMATETC, *t.STGMEDIUM, release: BOOL) callconv(t.winapi) HRESULT,
        EnumFormatEtc: *const fn (This, direction: DWORD, *?*IEnumFORMATETC) callconv(t.winapi) HRESULT,
        DAdvise: *const fn (This, *const t.FORMATETC, advf: DWORD, sink: ?*anyopaque, connection: *DWORD) callconv(t.winapi) HRESULT,
        DUnadvise: *const fn (This, connection: DWORD) callconv(t.winapi) HRESULT,
        EnumDAdvise: *const fn (This, *?*anyopaque) callconv(t.winapi) HRESULT,
        /// `IID_IDataObject`.
        pub const iid = guid("0000010e-0000-0000-c000-000000000046");
    };
};

/// `IEnumFORMATETC` (objidl.h).
pub const IEnumFORMATETC = extern struct {
    vtbl: *const Vtbl,
    /// Its vtable.
    pub const Vtbl = extern struct {
        QueryInterface: U.QueryInterface,
        AddRef: U.AddRef,
        Release: U.Release,
        Next: *const fn (This, n: ULONG, out: [*]t.FORMATETC, fetched: ?*ULONG) callconv(t.winapi) HRESULT,
        Skip: *const fn (This, n: ULONG) callconv(t.winapi) HRESULT,
        Reset: *const fn (This) callconv(t.winapi) HRESULT,
        Clone: *const fn (This, *?*IEnumFORMATETC) callconv(t.winapi) HRESULT,
        /// `IID_IEnumFORMATETC`.
        pub const iid = guid("00000103-0000-0000-c000-000000000046");
    };
};

/// `IShellItem` (shobjidl_core.h).
pub const IShellItem = extern struct {
    vtbl: *const Vtbl,
    /// Its vtable.
    pub const Vtbl = extern struct {
        QueryInterface: U.QueryInterface,
        AddRef: U.AddRef,
        Release: U.Release,
        BindToHandler: *const fn (This, bc: ?*anyopaque, bhid: *const GUID, riid: *const GUID, out: *?*anyopaque) callconv(t.winapi) HRESULT,
        GetParent: *const fn (This, *?*IShellItem) callconv(t.winapi) HRESULT,
        GetDisplayName: *const fn (This, sigdn: u32, name: *?t.LPWSTR) callconv(t.winapi) HRESULT,
        GetAttributes: *const fn (This, mask: u32, attrs: *u32) callconv(t.winapi) HRESULT,
        Compare: *const fn (This, other: *IShellItem, hint: u32, order: *i32) callconv(t.winapi) HRESULT,
        /// `IID_IShellItem`.
        pub const iid = guid("43826d1e-e718-42ee-bc55-a1e261c37bfe");
    };
    /// `SIGDN_FILESYSPATH`.
    pub const SIGDN_FILESYSPATH: u32 = 0x80058000;
};

/// `IShellItemArray` (shobjidl_core.h).
pub const IShellItemArray = extern struct {
    vtbl: *const Vtbl,
    /// Its vtable.
    pub const Vtbl = extern struct {
        QueryInterface: U.QueryInterface,
        AddRef: U.AddRef,
        Release: U.Release,
        BindToHandler: *const fn (This, bc: ?*anyopaque, bhid: *const GUID, riid: *const GUID, out: *?*anyopaque) callconv(t.winapi) HRESULT,
        GetPropertyStore: *const fn (This, flags: u32, riid: *const GUID, out: *?*anyopaque) callconv(t.winapi) HRESULT,
        GetPropertyDescriptionList: *const fn (This, key: *const anyopaque, riid: *const GUID, out: *?*anyopaque) callconv(t.winapi) HRESULT,
        GetAttributes: *const fn (This, flags: u32, mask: u32, attrs: *u32) callconv(t.winapi) HRESULT,
        GetCount: *const fn (This, *DWORD) callconv(t.winapi) HRESULT,
        GetItemAt: *const fn (This, index: DWORD, *?*IShellItem) callconv(t.winapi) HRESULT,
        EnumItems: *const fn (This, *?*anyopaque) callconv(t.winapi) HRESULT,
        /// `IID_IShellItemArray`.
        pub const iid = guid("b63ea76d-1f85-456f-a19c-48159efa858b");
    };
};

/// `IFileDialog` (shobjidl_core.h), which extends `IModalWindow`.
pub const IFileDialog = extern struct {
    vtbl: *const Vtbl,
    /// Its vtable; `Show` is `IModalWindow`'s.
    pub const Vtbl = FileDialogVtbl(struct {});
    /// `CLSID_FileOpenDialog`.
    pub const clsid_open = guid("dc1c5a9c-e88a-4dde-a5a1-60f82a20aef7");
    /// `CLSID_FileSaveDialog`.
    pub const clsid_save = guid("c0b4e2f3-ba21-4773-8dba-335ec946eb8b");
    /// `FOS_PICKFOLDERS`.
    pub const FOS_PICKFOLDERS: u32 = 0x20;
    /// `FOS_FORCEFILESYSTEM`.
    pub const FOS_FORCEFILESYSTEM: u32 = 0x40;
    /// `FOS_ALLOWMULTISELECT`.
    pub const FOS_ALLOWMULTISELECT: u32 = 0x200;
};

/// `IFileOpenDialog`: `IFileDialog` plus GetResults/GetSelectedItems.
pub const IFileOpenDialog = extern struct {
    vtbl: *const Vtbl,
    /// Its vtable.
    pub const Vtbl = FileDialogVtbl(struct {
        GetResults: *const fn (This, *?*IShellItemArray) callconv(t.winapi) HRESULT,
        GetSelectedItems: *const fn (This, *?*IShellItemArray) callconv(t.winapi) HRESULT,
    });
};

/// IFileDialog's vtable followed by `Extra`'s fields.
fn FileDialogVtbl(comptime Extra: type) type {
    const Base = extern struct {
        QueryInterface: U.QueryInterface,
        AddRef: U.AddRef,
        Release: U.Release,
        Show: *const fn (This, owner: ?t.HWND) callconv(t.winapi) HRESULT,
        SetFileTypes: *const fn (This, n: t.UINT, specs: [*]const t.COMDLG_FILTERSPEC) callconv(t.winapi) HRESULT,
        SetFileTypeIndex: *const fn (This, t.UINT) callconv(t.winapi) HRESULT,
        GetFileTypeIndex: *const fn (This, *t.UINT) callconv(t.winapi) HRESULT,
        Advise: *const fn (This, events: *anyopaque, cookie: *DWORD) callconv(t.winapi) HRESULT,
        Unadvise: *const fn (This, cookie: DWORD) callconv(t.winapi) HRESULT,
        SetOptions: *const fn (This, u32) callconv(t.winapi) HRESULT,
        GetOptions: *const fn (This, *u32) callconv(t.winapi) HRESULT,
        SetDefaultFolder: *const fn (This, *IShellItem) callconv(t.winapi) HRESULT,
        SetFolder: *const fn (This, *IShellItem) callconv(t.winapi) HRESULT,
        GetFolder: *const fn (This, *?*IShellItem) callconv(t.winapi) HRESULT,
        GetCurrentSelection: *const fn (This, *?*IShellItem) callconv(t.winapi) HRESULT,
        SetFileName: *const fn (This, t.LPCWSTR) callconv(t.winapi) HRESULT,
        GetFileName: *const fn (This, *?t.LPWSTR) callconv(t.winapi) HRESULT,
        SetTitle: *const fn (This, t.LPCWSTR) callconv(t.winapi) HRESULT,
        SetOkButtonLabel: *const fn (This, t.LPCWSTR) callconv(t.winapi) HRESULT,
        SetFileNameLabel: *const fn (This, t.LPCWSTR) callconv(t.winapi) HRESULT,
        GetResult: *const fn (This, *?*IShellItem) callconv(t.winapi) HRESULT,
        AddPlace: *const fn (This, *IShellItem, place: u32) callconv(t.winapi) HRESULT,
        SetDefaultExtension: *const fn (This, t.LPCWSTR) callconv(t.winapi) HRESULT,
        Close: *const fn (This, HRESULT) callconv(t.winapi) HRESULT,
        SetClientGuid: *const fn (This, *const GUID) callconv(t.winapi) HRESULT,
        ClearClientData: *const fn (This) callconv(t.winapi) HRESULT,
        SetFilter: *const fn (This, filter: ?*anyopaque) callconv(t.winapi) HRESULT,
    };
    const extra = @typeInfo(Extra).@"struct".fields;
    if (extra.len == 0) return extern struct {
        base: Base,
        /// `IID_IFileDialog`.
        pub const iid = guid("42f85136-db7e-439c-85f1-e4075d135fc8");
    };
    return extern struct {
        base: Base,
        GetResults: extra[0].type,
        GetSelectedItems: extra[1].type,
        /// `IID_IFileOpenDialog`.
        pub const iid = guid("d57c7288-d4ad-4768-be02-9d969532d960");
    };
}

/// A COM object implementing the interface whose vtable is `Vtbl`.
/// `Impl` provides each method after IUnknown's by name, taking `*Impl`
/// first, and optionally `deinit(*Impl)`, called on the last `Release`.
/// QueryInterface answers IUnknown, `Vtbl.iid` and `Impl.extra_iids`.
/// Objects start with one reference; `iface` is the pointer to hand out.
pub fn ComObject(comptime Vtbl: type, comptime Impl: type) type {
    return struct {
        const Self = @This();
        const Header = extern struct { vtbl: *const Vtbl };

        header: Header = .{ .vtbl = &vtable },
        refs: std.atomic.Value(u32) = .init(1),
        gpa: std.mem.Allocator,
        /// The implementation.
        impl: Impl,

        /// Allocates an object holding `impl`, with one reference.
        pub fn create(gpa: std.mem.Allocator, impl: Impl) error{OutOfMemory}!*Self {
            const s = try gpa.create(Self);
            s.* = .{ .gpa = gpa, .impl = impl };
            return s;
        }

        /// The interface pointer.
        pub fn iface(s: *Self) *anyopaque {
            return &s.header;
        }

        /// The object behind an interface pointer from `iface`.
        pub fn fromIface(p: *anyopaque) *Self {
            const h: *Header = @ptrCast(@alignCast(p));
            return @fieldParentPtr("header", h);
        }

        /// The current reference count (for tests).
        pub fn refCount(s: *const Self) u32 {
            return s.refs.load(.acquire);
        }

        const vtable: Vtbl = blk: {
            var v: Vtbl = undefined;
            for (@typeInfo(Vtbl).@"struct".fields) |f| fill(&v, f.name, f.type);
            break :blk v;
        };

        fn fill(v: anytype, comptime name: []const u8, comptime F: type) void {
            if (@typeInfo(F) == .@"struct") {
                // A nested base vtable (IFileDialog's).
                for (@typeInfo(F).@"struct".fields) |f| fill(&@field(v, name), f.name, f.type);
                return;
            }
            @field(v, name) = if (comptime std.mem.eql(u8, name, "QueryInterface"))
                &queryInterface
            else if (comptime std.mem.eql(u8, name, "AddRef"))
                &addRef
            else if (comptime std.mem.eql(u8, name, "Release"))
                &release
            else
                thunk(name, F);
        }

        fn queryInterface(this: This, riid: *const GUID, out: *?*anyopaque) callconv(t.winapi) HRESULT {
            const s = fromIface(this);
            if (answers(riid)) {
                _ = s.refs.fetchAdd(1, .monotonic);
                out.* = this;
                return t.S_OK;
            }
            out.* = null;
            return t.E_NOINTERFACE;
        }

        fn answers(riid: *const GUID) bool {
            if (riid.eql(&IUnknown.Vtbl.iid) or riid.eql(&Vtbl.iid)) return true;
            if (@hasDecl(Impl, "extra_iids")) for (&Impl.extra_iids) |*g| if (riid.eql(g)) return true;
            return false;
        }

        fn addRef(this: This) callconv(t.winapi) ULONG {
            return fromIface(this).refs.fetchAdd(1, .monotonic) + 1;
        }

        fn release(this: This) callconv(t.winapi) ULONG {
            const s = fromIface(this);
            const left = s.refs.fetchSub(1, .acq_rel) - 1;
            if (left == 0) {
                if (@hasDecl(Impl, "deinit")) s.impl.deinit();
                s.gpa.destroy(s);
            }
            return left;
        }

        fn thunk(comptime name: []const u8, comptime F: type) F {
            if (!@hasDecl(Impl, name)) @compileError(@typeName(Impl) ++ " does not implement " ++ name);
            const info = @typeInfo(@typeInfo(F).pointer.child).@"fn";
            const p = info.params;
            const R = info.return_type.?;
            const m = @field(Impl, name);
            return switch (p.len) {
                1 => &struct {
                    fn f(this: This) callconv(t.winapi) R {
                        return m(&fromIface(this).impl);
                    }
                }.f,
                2 => &struct {
                    fn f(this: This, a: p[1].type.?) callconv(t.winapi) R {
                        return m(&fromIface(this).impl, a);
                    }
                }.f,
                3 => &struct {
                    fn f(this: This, a: p[1].type.?, b: p[2].type.?) callconv(t.winapi) R {
                        return m(&fromIface(this).impl, a, b);
                    }
                }.f,
                4 => &struct {
                    fn f(this: This, a: p[1].type.?, b: p[2].type.?, c: p[3].type.?) callconv(t.winapi) R {
                        return m(&fromIface(this).impl, a, b, c);
                    }
                }.f,
                5 => &struct {
                    fn f(this: This, a: p[1].type.?, b: p[2].type.?, c: p[3].type.?, d: p[4].type.?) callconv(t.winapi) R {
                        return m(&fromIface(this).impl, a, b, c, d);
                    }
                }.f,
                6 => &struct {
                    fn f(this: This, a: p[1].type.?, b: p[2].type.?, c: p[3].type.?, d: p[4].type.?, e: p[5].type.?) callconv(t.winapi) R {
                        return m(&fromIface(this).impl, a, b, c, d, e);
                    }
                }.f,
                else => @compileError("COM method with too many parameters: " ++ name),
            };
        }
    };
}

const testing = std.testing;

test "guid parse" {
    const g = guid("00000122-0000-0000-c000-000000000046");
    try testing.expectEqual(0x122, g.data1);
    try testing.expectEqualSlices(u8, &.{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 }, &g.data4);
    // Little-endian Data1-3, then Data4 as bytes: the in-memory IID.
    try testing.expectEqualSlices(u8, &.{ 0x22, 0x01, 0, 0, 0, 0, 0, 0, 0xc0, 0, 0, 0, 0, 0, 0, 0x46 }, std.mem.asBytes(&g));
    try testing.expectError(error.InvalidGuid, parseGuid("00000122-0000-0000-c000-00000000004"));
    try testing.expectError(error.InvalidGuid, parseGuid("0000012g-0000-0000-c000-000000000046"));
}

const TestSource = struct {
    calls: *u32,
    freed: *bool,

    /// Not an interface method: QueryInterface also answers this IID.
    pub const extra_iids = [_]GUID{guid("11111111-2222-3333-4444-555555555555")};

    /// Cancels on escape, drops when the button (bit 0) is up.
    pub fn QueryContinueDrag(s: *TestSource, escape: BOOL, key_state: DWORD) HRESULT {
        s.calls.* += 1;
        if (escape != 0) return t.DRAGDROP_S_CANCEL;
        return if (key_state & 1 == 0) t.DRAGDROP_S_DROP else t.S_OK;
    }

    /// Uses the default cursors.
    pub fn GiveFeedback(s: *TestSource, effect: DWORD) HRESULT {
        _ = effect;
        s.calls.* += 1;
        return t.DRAGDROP_S_USEDEFAULTCURSORS;
    }

    /// Records that the last reference went.
    pub fn deinit(s: *TestSource) void {
        s.freed.* = true;
    }
};

test "ComObject refcount & QueryInterface" {
    var calls: u32 = 0;
    var freed = false;
    const Obj = ComObject(IDropSource.Vtbl, TestSource);
    const o = try Obj.create(testing.allocator, .{ .calls = &calls, .freed = &freed });
    const src: *IDropSource = @ptrCast(@alignCast(o.iface()));

    try testing.expectEqual(t.DRAGDROP_S_CANCEL, src.vtbl.QueryContinueDrag(src, 1, 0));
    try testing.expectEqual(t.S_OK, src.vtbl.QueryContinueDrag(src, 0, 1));
    try testing.expectEqual(t.DRAGDROP_S_USEDEFAULTCURSORS, src.vtbl.GiveFeedback(src, 1));
    try testing.expectEqual(3, calls);

    var out: ?*anyopaque = null;
    try testing.expectEqual(t.S_OK, src.vtbl.QueryInterface(src, &IUnknown.Vtbl.iid, &out));
    try testing.expectEqual(o.iface(), out.?);
    try testing.expectEqual(t.S_OK, src.vtbl.QueryInterface(src, &TestSource.extra_iids[0], &out));
    try testing.expectEqual(3, o.refCount());
    try testing.expectEqual(t.E_NOINTERFACE, src.vtbl.QueryInterface(src, &IDropTarget.Vtbl.iid, &out));
    try testing.expectEqual(null, out);

    try testing.expectEqual(4, src.vtbl.AddRef(src));
    for (0..3) |_| _ = IUnknown.release(src);
    try testing.expect(!freed);
    try testing.expectEqual(0, IUnknown.release(src));
    try testing.expect(freed);
}

test "vtable layouts follow the SDK order" {
    const ptr = @sizeOf(usize);
    try testing.expectEqual(7 * ptr, @sizeOf(IDropTarget.Vtbl));
    try testing.expectEqual(5 * ptr, @sizeOf(IDropSource.Vtbl));
    try testing.expectEqual(12 * ptr, @sizeOf(IDataObject.Vtbl));
    try testing.expectEqual(7 * ptr, @sizeOf(IEnumFORMATETC.Vtbl));
    try testing.expectEqual(8 * ptr, @sizeOf(IShellItem.Vtbl));
    try testing.expectEqual(10 * ptr, @sizeOf(IShellItemArray.Vtbl));
    try testing.expectEqual(27 * ptr, @sizeOf(IFileDialog.Vtbl));
    try testing.expectEqual(29 * ptr, @sizeOf(IFileOpenDialog.Vtbl));
    try testing.expectEqual(3 * ptr, @offsetOf(IFileDialog.Vtbl, "base") + @offsetOf(@FieldType(IFileDialog.Vtbl, "base"), "Show"));
    try testing.expectEqual(27 * ptr, @offsetOf(IFileOpenDialog.Vtbl, "GetResults"));
}
