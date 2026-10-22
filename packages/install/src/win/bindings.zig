//! Win32 externs and COM vtables the installer needs (advapi32 registry,
//! shell32, user32 broadcasts, ole32), declared in Windows SDK header
//! order. Only referenced from code compiled for Windows.

const std = @import("std");
const windows = std.os.windows;

pub const WINAPI: std.builtin.CallingConvention = .winapi;
pub const BOOL = i32;
pub const DWORD = u32;
pub const LONG = i32;
pub const ULONG = u32;
pub const HRESULT = i32;
pub const LPCWSTR = [*:0]const u16;
pub const LPWSTR = [*:0]u16;
pub const HKEY = windows.HKEY;
pub const HWND = *opaque {};
pub const GUID = windows.GUID;

pub const HKEY_CURRENT_USER = windows.HKEY_CURRENT_USER;

pub const ERROR_SUCCESS: LONG = 0;
pub const ERROR_FILE_NOT_FOUND: LONG = 2;
pub const ERROR_MORE_DATA: LONG = 234;

pub const KEY_QUERY_VALUE: DWORD = 0x0001;
pub const KEY_SET_VALUE: DWORD = 0x0002;
pub const KEY_ENUMERATE_SUB_KEYS: DWORD = 0x0008;
pub const KEY_READ: DWORD = 0x20019;
pub const KEY_WRITE: DWORD = 0x20006;
pub const DELETE: DWORD = 0x00010000;
pub const REG_OPTION_NON_VOLATILE: DWORD = 0;
pub const REG_CREATED_NEW_KEY: DWORD = 1;

pub const REG_NONE: DWORD = 0;
pub const REG_SZ: DWORD = 1;
pub const REG_EXPAND_SZ: DWORD = 2;
pub const REG_DWORD: DWORD = 4;

pub extern "advapi32" fn RegCreateKeyExW(key: HKEY, sub_key: LPCWSTR, reserved: DWORD, class: ?LPWSTR, options: DWORD, sam: DWORD, security: ?*anyopaque, result: *HKEY, disposition: ?*DWORD) callconv(WINAPI) LONG;
pub extern "advapi32" fn RegOpenKeyExW(key: HKEY, sub_key: LPCWSTR, options: DWORD, sam: DWORD, result: *HKEY) callconv(WINAPI) LONG;
pub extern "advapi32" fn RegCloseKey(key: HKEY) callconv(WINAPI) LONG;
pub extern "advapi32" fn RegQueryValueExW(key: HKEY, name: LPCWSTR, reserved: ?*DWORD, kind: ?*DWORD, data: ?[*]u8, len: ?*DWORD) callconv(WINAPI) LONG;
pub extern "advapi32" fn RegSetValueExW(key: HKEY, name: LPCWSTR, reserved: DWORD, kind: DWORD, data: ?[*]const u8, len: DWORD) callconv(WINAPI) LONG;
pub extern "advapi32" fn RegDeleteValueW(key: HKEY, name: LPCWSTR) callconv(WINAPI) LONG;
pub extern "advapi32" fn RegDeleteKeyW(key: HKEY, sub_key: LPCWSTR) callconv(WINAPI) LONG;
pub extern "advapi32" fn RegDeleteTreeW(key: HKEY, sub_key: ?LPCWSTR) callconv(WINAPI) LONG;
pub extern "advapi32" fn RegQueryInfoKeyW(
    key: HKEY,
    class: ?LPWSTR,
    class_len: ?*DWORD,
    reserved: ?*DWORD,
    sub_keys: ?*DWORD,
    max_sub_key_len: ?*DWORD,
    max_class_len: ?*DWORD,
    values: ?*DWORD,
    max_value_name_len: ?*DWORD,
    max_value_len: ?*DWORD,
    security_descriptor: ?*DWORD,
    last_write: ?*anyopaque,
) callconv(WINAPI) LONG;

pub const HWND_BROADCAST: usize = 0xffff;
pub const WM_SETTINGCHANGE: u32 = 0x001A;
pub const SMTO_ABORTIFHUNG: u32 = 0x0002;
pub extern "user32" fn SendMessageTimeoutW(hwnd: usize, msg: u32, wparam: usize, lparam: isize, flags: u32, timeout_ms: u32, result: ?*usize) callconv(WINAPI) isize;

pub const SHCNE_ASSOCCHANGED: i32 = 0x08000000;
pub const SHCNF_IDLIST: u32 = 0;
pub extern "shell32" fn SHChangeNotify(event: i32, flags: u32, item1: ?*const anyopaque, item2: ?*const anyopaque) callconv(WINAPI) void;
pub extern "shell32" fn SHGetKnownFolderPath(id: *const GUID, flags: DWORD, token: ?*anyopaque, path: *?LPWSTR) callconv(WINAPI) HRESULT;

pub const COINIT_APARTMENTTHREADED: DWORD = 0x2;
pub const CLSCTX_INPROC_SERVER: DWORD = 0x1;
pub const S_OK: HRESULT = 0;
pub const S_FALSE: HRESULT = 1;
pub const RPC_E_CHANGED_MODE: HRESULT = @bitCast(@as(u32, 0x80010106));
pub extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, coinit: DWORD) callconv(WINAPI) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(WINAPI) void;
pub extern "ole32" fn CoCreateInstance(clsid: *const GUID, outer: ?*anyopaque, ctx: DWORD, iid: *const GUID, out: *?*anyopaque) callconv(WINAPI) HRESULT;
pub extern "ole32" fn CoTaskMemFree(p: ?*anyopaque) callconv(WINAPI) void;

/// Parses `"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"` at compile time.
pub fn guid(comptime s: []const u8) GUID {
    return comptime blk: {
        if (s.len != 36) @compileError("bad GUID: " ++ s);
        var g: GUID = .{
            .Data1 = std.fmt.parseInt(u32, s[0..8], 16) catch unreachable,
            .Data2 = std.fmt.parseInt(u16, s[9..13], 16) catch unreachable,
            .Data3 = std.fmt.parseInt(u16, s[14..18], 16) catch unreachable,
            .Data4 = undefined,
        };
        g.Data4[0] = std.fmt.parseInt(u8, s[19..21], 16) catch unreachable;
        g.Data4[1] = std.fmt.parseInt(u8, s[21..23], 16) catch unreachable;
        for (0..6) |i| g.Data4[2 + i] = std.fmt.parseInt(u8, s[24 + 2 * i ..][0..2], 16) catch unreachable;
        break :blk g;
    };
}

pub const CLSID_ShellLink = guid("00021401-0000-0000-C000-000000000046");
pub const IID_IShellLinkW = guid("000214F9-0000-0000-C000-000000000046");
pub const IID_IPersistFile = guid("0000010B-0000-0000-C000-000000000046");
pub const IID_IPropertyStore = guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
pub const FOLDERID_Programs = guid("A77F5D77-2E2B-44C3-A6A2-ABA601054A51");
pub const FOLDERID_Desktop = guid("B4BFCC3A-DB2C-424C-B029-7FE99A87C641");

pub const PROPERTYKEY = extern struct { fmtid: GUID, pid: DWORD };
/// `System.AppUserModel.ID`.
pub const PKEY_AppUserModel_ID: PROPERTYKEY = .{ .fmtid = guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), .pid = 5 };

pub const VT_LPWSTR: u16 = 31;
/// The PROPVARIANT layout for a string value (16 bytes on 32-bit, 24 on
/// 64-bit: the union is as large as a DECIMAL or two pointers).
pub const PROPVARIANT = extern struct {
    vt: u16,
    reserved1: u16 = 0,
    reserved2: u16 = 0,
    reserved3: u16 = 0,
    value: extern union { pwszVal: ?LPWSTR, pad: [2]usize },
};

const This = *anyopaque;
const QueryInterface = *const fn (This, *const GUID, *?*anyopaque) callconv(WINAPI) HRESULT;
const AddRef = *const fn (This) callconv(WINAPI) ULONG;
const Release = *const fn (This) callconv(WINAPI) ULONG;
const Unused = *const anyopaque;

/// `IShellLinkW` (shobjidl_core.h).
pub const IShellLinkW = extern struct {
    vtbl: *const Vtbl,
    pub const Vtbl = extern struct {
        QueryInterface: QueryInterface,
        AddRef: AddRef,
        Release: Release,
        GetPath: *const fn (This, [*]u16, i32, ?*anyopaque, DWORD) callconv(WINAPI) HRESULT,
        GetIDList: Unused,
        SetIDList: Unused,
        GetDescription: *const fn (This, [*]u16, i32) callconv(WINAPI) HRESULT,
        SetDescription: *const fn (This, LPCWSTR) callconv(WINAPI) HRESULT,
        GetWorkingDirectory: Unused,
        SetWorkingDirectory: *const fn (This, LPCWSTR) callconv(WINAPI) HRESULT,
        GetArguments: *const fn (This, [*]u16, i32) callconv(WINAPI) HRESULT,
        SetArguments: *const fn (This, LPCWSTR) callconv(WINAPI) HRESULT,
        GetHotkey: Unused,
        SetHotkey: Unused,
        GetShowCmd: Unused,
        SetShowCmd: Unused,
        GetIconLocation: *const fn (This, [*]u16, i32, *i32) callconv(WINAPI) HRESULT,
        SetIconLocation: *const fn (This, LPCWSTR, i32) callconv(WINAPI) HRESULT,
        SetRelativePath: Unused,
        Resolve: Unused,
        SetPath: *const fn (This, LPCWSTR) callconv(WINAPI) HRESULT,
    };
};

/// `IPersistFile` (objidl.h).
pub const IPersistFile = extern struct {
    vtbl: *const Vtbl,
    pub const Vtbl = extern struct {
        QueryInterface: QueryInterface,
        AddRef: AddRef,
        Release: Release,
        GetClassID: Unused,
        IsDirty: Unused,
        Load: *const fn (This, LPCWSTR, DWORD) callconv(WINAPI) HRESULT,
        Save: *const fn (This, ?LPCWSTR, BOOL) callconv(WINAPI) HRESULT,
        SaveCompleted: Unused,
        GetCurFile: Unused,
    };
};

/// `IPropertyStore` (propsys.h).
pub const IPropertyStore = extern struct {
    vtbl: *const Vtbl,
    pub const Vtbl = extern struct {
        QueryInterface: QueryInterface,
        AddRef: AddRef,
        Release: Release,
        GetCount: Unused,
        GetAt: Unused,
        GetValue: *const fn (This, *const PROPERTYKEY, *PROPVARIANT) callconv(WINAPI) HRESULT,
        SetValue: *const fn (This, *const PROPERTYKEY, *const PROPVARIANT) callconv(WINAPI) HRESULT,
        Commit: *const fn (This) callconv(WINAPI) HRESULT,
    };
};

pub extern "kernel32" fn GetModuleHandleW(name: ?LPCWSTR) callconv(WINAPI) ?*anyopaque;
pub extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(WINAPI) ?*anyopaque;

/// True when running under Wine (ntdll exports `wine_get_version`).
pub fn underWine() bool {
    const ntdll = GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("ntdll.dll")) orelse return false;
    return GetProcAddress(ntdll, "wine_get_version") != null;
}

pub extern "ole32" fn PropVariantClear(pv: *PROPVARIANT) callconv(WINAPI) HRESULT;

test "bindings: vtable slot counts" {
    const slots = struct {
        fn n(comptime V: type) usize {
            return @sizeOf(V) / @sizeOf(usize);
        }
    }.n;
    try std.testing.expectEqual(@as(usize, 3 + 18), slots(IShellLinkW.Vtbl));
    try std.testing.expectEqual(@as(usize, 3 + 1 + 5), slots(IPersistFile.Vtbl));
    try std.testing.expectEqual(@as(usize, 3 + 5), slots(IPropertyStore.Vtbl));
    try std.testing.expectEqual(@as(u32, 0x000214F9), IID_IShellLinkW.Data1);
    try std.testing.expectEqual(@as(u8, 0x46), IID_IShellLinkW.Data4[7]);
    try std.testing.expectEqual(@as(usize, 8 + 2 * @sizeOf(usize)), @sizeOf(PROPVARIANT));
}
