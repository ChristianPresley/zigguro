//! The runtime Vulkan loader (E02.F01.S02.T01): opens the OS loader, resolves
//! `vkGetInstanceProcAddr` and fills the global, instance and device tables
//! from `tables.zig`.
//!
//! A command is *required* when a provider of it is in effect: a core
//! version at or below the API version in use, or an enabled extension.
//! A required command that cannot be resolved (core name first, then its
//! aliases such as `vkCmdBeginRenderingKHR`) fails with `SymbolMissing`.
//! Any other unresolved command is filled with a stub that panics in safe
//! builds and returns `error_feature_not_present` (or zero) otherwise, so a
//! table never holds a null pointer.

const std = @import("std");
const vk = @import("../vk/vk.zig");
const dynlib = @import("dynlib.zig");
pub const tables = @import("tables.zig");

pub const LoadError = error{ VulkanNotInstalled, SymbolMissing, Unsupported };

/// The extensions a table is loaded for.
pub const ExtSet = std.EnumSet(vk.Extension);

/// Filled in when loading fails.
pub const Diagnostics = struct {
    /// The required command that could not be resolved.
    missing: ?[:0]const u8 = null,
};

pub const OpenOptions = struct {
    /// Overrides the library path (`ZG_VK_LOADER_PATH`, for tests).
    path_override: ?[]const u8 = null,
};

/// `vkGetInstanceProcAddr(instance, ...)` or `vkGetDeviceProcAddr(device, ...)`.
const Getter = union(enum) {
    instance: struct { gipa: vk.PfnGetInstanceProcAddr, handle: vk.Instance },
    device: struct { gdpa: vk.PfnGetDeviceProcAddr, handle: vk.Device },

    fn get(g: Getter, name: [*:0]const u8) ?vk.PfnVoidFunction {
        return switch (g) {
            .instance => |i| i.gipa(i.handle, name),
            .device => |d| d.gdpa(d.handle, name),
        };
    }
};

/// An opened Vulkan loader.
pub const Loader = struct {
    lib: ?dynlib.Lib,
    get_instance_proc_addr: vk.PfnGetInstanceProcAddr,
    /// The library that was opened.
    path: []const u8,

    /// Opens the system loader (`vulkan-1.dll` from System32, or
    /// `libvulkan.so.1`, then `libvulkan.so`) or `opts.path_override`.
    pub fn open(opts: OpenOptions) LoadError!Loader {
        if (!dynlib.supported) return error.Unsupported;
        const candidates: []const []const u8 = if (opts.path_override) |p|
            &.{p}
        else if (@import("builtin").os.tag == .linux)
            &.{ dynlib.default_name, "libvulkan.so" }
        else
            &.{dynlib.default_name};
        for (candidates) |name| {
            var lib = dynlib.Lib.open(name) catch |err| switch (err) {
                error.Unsupported => return error.Unsupported,
                else => continue,
            };
            const sym = lib.lookup("vkGetInstanceProcAddr") orelse {
                lib.close();
                return error.SymbolMissing;
            };
            return .{ .lib = lib, .get_instance_proc_addr = @ptrCast(@alignCast(sym)), .path = name };
        }
        return error.VulkanNotInstalled;
    }

    /// A loader around an existing `vkGetInstanceProcAddr` (tests, or a
    /// loader already opened by someone else).
    pub fn fromProcAddr(gipa: vk.PfnGetInstanceProcAddr) Loader {
        return .{ .lib = null, .get_instance_proc_addr = gipa, .path = "" };
    }

    pub fn close(self: *Loader) void {
        if (self.lib) |*l| l.close();
        self.* = undefined;
    }

    fn instanceGetter(self: *const Loader, inst: vk.Instance) Getter {
        return .{ .instance = .{ .gipa = self.get_instance_proc_addr, .handle = inst } };
    }

    /// Loads the global table (commands callable before an instance exists).
    pub fn loadGlobal(self: *const Loader, diag: ?*Diagnostics) LoadError!tables.Global {
        var t: tables.Global = undefined;
        try fill(tables.Global, &t, self.instanceGetter(.null_handle), 100, .initEmpty(), diag);
        // vkGetInstanceProcAddr(NULL, "vkGetInstanceProcAddr") is only valid from 1.2 on.
        t.get_instance_proc_addr = self.get_instance_proc_addr;
        return t;
    }

    /// Loads the instance table for `inst`, created with API version `api`
    /// (major * 100 + minor) and the instance extensions `enabled`.
    pub fn loadInstance(self: *const Loader, inst: vk.Instance, api: u32, enabled: ExtSet, diag: ?*Diagnostics) LoadError!tables.Instance {
        var t: tables.Instance = undefined;
        try fill(tables.Instance, &t, self.instanceGetter(inst), api, enabled, diag);
        return t;
    }
};

/// Loads the device table for `dev` through `vkGetDeviceProcAddr`, which
/// skips the loader's trampolines. `enabled` holds the instance and device
/// extensions in use.
pub fn loadDevice(inst: *const tables.Instance, dev: vk.Device, api: u32, enabled: ExtSet, diag: ?*Diagnostics) LoadError!tables.Device {
    var t: tables.Device = undefined;
    try fill(tables.Device, &t, .{ .device = .{ .gdpa = inst.get_device_proc_addr, .handle = dev } }, api, enabled, diag);
    return t;
}

/// The API version as major * 100 + minor.
pub fn apiNumber(v: vk.Version) u32 {
    return @as(u32, v.major) * 100 + v.minor;
}

/// True if a provider of `c` is in effect.
pub fn isRequired(comptime c: vk.Command, api: u32, enabled: ExtSet) bool {
    inline for (vk.info(c).provided_by) |p| switch (p) {
        .version => |v| if (v <= api) return true,
        .extension => |e| if (enabled.contains(e)) return true,
    };
    return false;
}

fn fill(comptime T: type, t: *T, getter: Getter, api: u32, enabled: ExtSet, diag: ?*Diagnostics) LoadError!void {
    inline for (@typeInfo(T).@"struct".fields) |fld| {
        const c = @field(vk.Command, fld.name);
        const info = vk.info(c);
        var f = getter.get(info.name);
        inline for (info.aliases) |alias| {
            if (f == null) f = getter.get(alias);
        }
        if (f) |ptr| {
            @field(t, fld.name) = @ptrCast(ptr);
        } else if (isRequired(c, api, enabled)) {
            if (diag) |d| d.missing = info.name;
            return error.SymbolMissing;
        } else {
            @field(t, fld.name) = missingStub(info.Pfn);
        }
    }
}

/// A function of type `P` for a command that was not loaded.
pub fn missingStub(comptime P: type) P {
    const F = @typeInfo(P).pointer.child;
    const params = @typeInfo(F).@"fn".params;
    const R = @typeInfo(F).@"fn".return_type.?;
    const S = struct {
        fn p(comptime i: usize) type {
            return params[i].type.?;
        }
        fn ret() R {
            if (std.debug.runtime_safety) @panic("called a Vulkan command that was not loaded");
            if (R == vk.Result) return .error_feature_not_present;
            if (R == void) return;
            return std.mem.zeroes(R);
        }
        fn f0() callconv(vk.cc) R {
            return ret();
        }
        fn f1(_: p(0)) callconv(vk.cc) R {
            return ret();
        }
        fn f2(_: p(0), _: p(1)) callconv(vk.cc) R {
            return ret();
        }
        fn f3(_: p(0), _: p(1), _: p(2)) callconv(vk.cc) R {
            return ret();
        }
        fn f4(_: p(0), _: p(1), _: p(2), _: p(3)) callconv(vk.cc) R {
            return ret();
        }
        fn f5(_: p(0), _: p(1), _: p(2), _: p(3), _: p(4)) callconv(vk.cc) R {
            return ret();
        }
        fn f6(_: p(0), _: p(1), _: p(2), _: p(3), _: p(4), _: p(5)) callconv(vk.cc) R {
            return ret();
        }
        fn f7(_: p(0), _: p(1), _: p(2), _: p(3), _: p(4), _: p(5), _: p(6)) callconv(vk.cc) R {
            return ret();
        }
        fn f8(_: p(0), _: p(1), _: p(2), _: p(3), _: p(4), _: p(5), _: p(6), _: p(7)) callconv(vk.cc) R {
            return ret();
        }
        fn f9(_: p(0), _: p(1), _: p(2), _: p(3), _: p(4), _: p(5), _: p(6), _: p(7), _: p(8)) callconv(vk.cc) R {
            return ret();
        }
        fn f10(_: p(0), _: p(1), _: p(2), _: p(3), _: p(4), _: p(5), _: p(6), _: p(7), _: p(8), _: p(9)) callconv(vk.cc) R {
            return ret();
        }
        fn f11(_: p(0), _: p(1), _: p(2), _: p(3), _: p(4), _: p(5), _: p(6), _: p(7), _: p(8), _: p(9), _: p(10)) callconv(vk.cc) R {
            return ret();
        }
        fn f12(_: p(0), _: p(1), _: p(2), _: p(3), _: p(4), _: p(5), _: p(6), _: p(7), _: p(8), _: p(9), _: p(10), _: p(11)) callconv(vk.cc) R {
            return ret();
        }
    };
    return switch (params.len) {
        0 => &S.f0,
        1 => &S.f1,
        2 => &S.f2,
        3 => &S.f3,
        4 => &S.f4,
        5 => &S.f5,
        6 => &S.f6,
        7 => &S.f7,
        8 => &S.f8,
        9 => &S.f9,
        10 => &S.f10,
        11 => &S.f11,
        12 => &S.f12,
        else => @compileError("missingStub: add an arity for " ++ @typeName(P)),
    };
}

// ---- tests ----------------------------------------------------------------

/// A fake `vkGetInstanceProcAddr` that knows a fixed set of names.
const Fake = struct {
    var known: []const []const u8 = &.{};
    var calls: u32 = 0;

    fn dummy() callconv(vk.cc) void {}

    fn gipa(_: vk.Instance, name: [*:0]const u8) callconv(vk.cc) ?vk.PfnVoidFunction {
        calls += 1;
        const n = std.mem.span(name);
        for (known) |k| if (std.mem.eql(u8, k, n)) return &dummy;
        return null;
    }
};

test "loader: alias resolution order" {
    const T = vk.Dispatch(.device, &.{.cmd_begin_rendering});
    // Only the KHR name is known: the core name is tried first, then the alias.
    Fake.known = &.{"vkCmdBeginRenderingKHR"};
    Fake.calls = 0;
    const l: Loader = .fromProcAddr(Fake.gipa);
    var t: T = undefined;
    try fill(T, &t, l.instanceGetter(.null_handle), 102, ExtSet.initOne(.khr_dynamic_rendering), null);
    try std.testing.expectEqual(@as(u32, 2), Fake.calls);
    try std.testing.expect(@intFromPtr(t.cmd_begin_rendering) == @intFromPtr(&Fake.dummy));
}

test "loader: missing required command is SymbolMissing with its name" {
    const T = vk.Dispatch(.instance, &.{ .destroy_instance, .enumerate_physical_devices });
    Fake.known = &.{"vkDestroyInstance"};
    const l: Loader = .fromProcAddr(Fake.gipa);
    var t: T = undefined;
    var d: Diagnostics = .{};
    try std.testing.expectError(error.SymbolMissing, fill(T, &t, l.instanceGetter(@enumFromInt(1)), 100, .initEmpty(), &d));
    try std.testing.expectEqualStrings("vkEnumeratePhysicalDevices", d.missing.?);
}

test "loader: optional command null tolerated" {
    // vkWaitForPresentKHR is required only with VK_KHR_present_wait enabled.
    const T = vk.Dispatch(.device, &.{ .destroy_device, .wait_for_present_khr });
    Fake.known = &.{"vkDestroyDevice"};
    const l: Loader = .fromProcAddr(Fake.gipa);
    var t: T = undefined;
    try fill(T, &t, l.instanceGetter(.null_handle), 104, .initEmpty(), null);
    try std.testing.expect(@intFromPtr(t.wait_for_present_khr) != 0);
    try std.testing.expectError(error.SymbolMissing, fill(T, &t, l.instanceGetter(.null_handle), 104, ExtSet.initOne(.khr_present_wait), null));
    // Promoted commands are required from their core version on.
    try std.testing.expect(isRequired(.cmd_begin_rendering, 103, .initEmpty()));
    try std.testing.expect(!isRequired(.cmd_begin_rendering, 102, .initEmpty()));
    try std.testing.expect(isRequired(.cmd_begin_rendering, 102, ExtSet.initOne(.khr_dynamic_rendering)));
}

test "loader: the zigguro tables have stubs for every arity" {
    // Instantiates a stub for every command in the tables.
    inline for (.{ tables.Global, tables.Instance, tables.Device }) |T| {
        inline for (@typeInfo(T).@"struct".fields) |fld| _ = missingStub(fld.type);
    }
}

test "loader: open without a usable library" {
    const r = Loader.open(.{ .path_override = "/nonexistent/libvulkan.so.1" });
    if (dynlib.supported) {
        try std.testing.expectError(error.VulkanNotInstalled, r);
    } else {
        try std.testing.expectError(error.Unsupported, r);
    }
}
