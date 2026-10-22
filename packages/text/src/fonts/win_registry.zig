//! The registry reads Windows font discovery needs: the string values of
//! one key, through advapi32 (declared here; std has no advapi32
//! bindings and zg_text must not depend on zg_platform).
//!
//! advapi32 rather than ntdll's `NtOpenKeyEx`/`NtQueryValueKey` (which
//! std does declare): those take kernel object paths, so HKCU would need
//! the user's SID path (`\Registry\User\<SID>`), which advapi32 resolves
//! for us. advapi32 is part of every Windows install; no COM involved.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;

pub const HKEY = windows.HKEY;

pub const KEY_READ: u32 = 0x20019;
pub const KEY_WOW64_64KEY: u32 = 0x0100;
pub const REG_SZ: u32 = 1;
pub const REG_EXPAND_SZ: u32 = 2;
pub const ERROR_SUCCESS: i32 = 0;
pub const ERROR_FILE_NOT_FOUND: i32 = 2;
pub const ERROR_MORE_DATA: i32 = 234;
pub const ERROR_NO_MORE_ITEMS: i32 = 259;

pub extern "advapi32" fn RegOpenKeyExW(hKey: HKEY, lpSubKey: [*:0]const u16, ulOptions: u32, samDesired: u32, phkResult: *HKEY) callconv(.winapi) i32;
pub extern "advapi32" fn RegEnumValueW(hKey: HKEY, dwIndex: u32, lpValueName: [*]u16, lpcchValueName: *u32, lpReserved: ?*u32, lpType: ?*u32, lpData: ?[*]u8, lpcbData: ?*u32) callconv(.winapi) i32;
pub extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) i32;

pub const Root = enum { hklm, hkcu };

pub const Kind = enum { sz, expand_sz };

/// A string value, both halves UTF-8 (WTF-8 where the registry holds
/// unpaired surrogates, as std.Io paths expect).
pub const NameValue = struct {
    name: []const u8,
    value: []const u8,
    kind: Kind,
};

pub const Error = Allocator.Error || error{ RegistryError, Unsupported };

fn rootKey(r: Root) HKEY {
    return switch (r) {
        .hklm => windows.HKEY_LOCAL_MACHINE,
        .hkcu => windows.HKEY_CURRENT_USER,
    };
}

/// Appends the REG_SZ and REG_EXPAND_SZ values of `root\subkey` to
/// `out` (strings allocated from `gpa`; other value types are skipped).
/// A missing key adds nothing. Elsewhere: error.Unsupported.
pub const enumStringValues = if (builtin.os.tag == .windows) enumWindows else enumUnsupported;

fn enumUnsupported(_: Allocator, _: Root, _: []const u8, _: *std.ArrayList(NameValue)) Error!void {
    return error.Unsupported;
}

fn enumWindows(gpa: Allocator, root: Root, subkey: []const u8, out: *std.ArrayList(NameValue)) Error!void {
    const sub = std.unicode.wtf8ToWtf16LeAllocZ(gpa, subkey) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return error.RegistryError,
    };
    defer gpa.free(sub);
    var key: HKEY = undefined;
    switch (RegOpenKeyExW(rootKey(root), sub.ptr, 0, KEY_READ | KEY_WOW64_64KEY, &key)) {
        ERROR_SUCCESS => {},
        ERROR_FILE_NOT_FOUND => return,
        else => return error.RegistryError,
    }
    defer _ = RegCloseKey(key);

    var name: []u16 = try gpa.alloc(u16, 256);
    defer gpa.free(name);
    var data: []align(2) u8 = try gpa.alignedAlloc(u8, .@"2", 1024);
    defer gpa.free(data);
    var index: u32 = 0;
    while (true) {
        var name_len: u32 = @intCast(name.len);
        var data_len: u32 = @intCast(data.len);
        var ty: u32 = 0;
        switch (RegEnumValueW(key, index, name.ptr, &name_len, null, &ty, data.ptr, &data_len)) {
            ERROR_SUCCESS => {},
            ERROR_NO_MORE_ITEMS => return,
            ERROR_MORE_DATA => {
                // Grow and retry the same index; `name_len` is not
                // updated on this error, so double the name buffer.
                const new_name = try gpa.alloc(u16, name.len * 2);
                gpa.free(name);
                name = new_name;
                if (data_len > data.len) {
                    const new_data = try gpa.alignedAlloc(u8, .@"2", data_len + 2);
                    gpa.free(data);
                    data = new_data;
                }
                if (name.len > 1 << 16) return error.RegistryError;
                continue;
            },
            else => return error.RegistryError,
        }
        index += 1;
        const kind: Kind = switch (ty) {
            REG_SZ => .sz,
            REG_EXPAND_SZ => .expand_sz,
            else => continue,
        };
        const units = std.mem.bytesAsSlice(u16, data[0 .. data_len & ~@as(u32, 1)]);
        const n = try std.unicode.wtf16LeToWtf8Alloc(gpa, name[0..name_len]);
        errdefer gpa.free(n);
        const v = try std.unicode.wtf16LeToWtf8Alloc(gpa, trimNul(@alignCast(units)));
        errdefer gpa.free(v);
        try out.append(gpa, .{ .name = n, .value = v, .kind = kind });
    }
}

/// Frees the strings `enumStringValues` appended and the list.
pub fn freeValues(gpa: Allocator, list: *std.ArrayList(NameValue)) void {
    for (list.items) |v| {
        gpa.free(v.name);
        gpa.free(v.value);
    }
    list.deinit(gpa);
}

/// Registry strings may or may not carry their terminating NUL(s).
fn trimNul(s: []const u16) []const u16 {
    var n = s.len;
    while (n > 0 and s[n - 1] == 0) n -= 1;
    return s[0..n];
}
