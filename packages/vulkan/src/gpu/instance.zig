//! `VkInstance` creation: API version negotiation, the smallest extension
//! set for the surface kind, and the optional Khronos validation layer
//! (E02.F02.S01.T01).

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("../vk/vk.zig");
const loader = @import("../loader/loader.zig");
const tables = loader.tables;
const debug = @import("debug.zig");

const log = std.log.scoped(.vk);
const ExtSet = loader.ExtSet;
const ext_count = @typeInfo(vk.Extension).@"enum".fields.len;

/// Where frames go, which decides the instance and device extensions.
pub const SurfaceKind = enum {
    /// A `VK_KHR_win32_surface` swapchain.
    win32,
    /// Exported images handed to an E01 presenter (Wayland, X11).
    external,
    /// Offscreen.
    headless,
};

pub const Validation = enum {
    off,
    /// On in Debug builds built with `-Dvk_validation` when the layer is installed.
    auto,
    on,
    /// `on` plus synchronization validation.
    on_sync,
};

pub const InstanceOptions = struct {
    app_name: [:0]const u8 = "zigguro",
    validation: Validation = .auto,
    surface: SurfaceKind = .headless,
    /// `ZG_VK_VALIDATION`: forces validation on or off, also in release.
    env_validation: ?bool = null,
};

pub const CreateError = error{
    /// The loader is Vulkan 1.0 (no `vkEnumerateInstanceVersion`).
    LoaderTooOld,
    /// No device passes the requirements of E02.F02 (see `select`).
    NoSuitableDevice,
    /// The previous start crashed in GPU initialisation (crash marker).
    PreviousInitCrashed,
    OutOfMemory,
} || vk.Error || loader.LoadError;

/// A created instance.
pub const InstanceBundle = struct {
    inst: vk.Instance,
    disp: tables.Instance,
    /// The API version the instance was created with.
    api: vk.Version,
    /// The loader's own version.
    loader_version: vk.Version,
    /// The enabled instance extensions.
    exts: ExtSet,
    /// `VK_EXT_debug_utils` is enabled (validation or a forced messenger).
    debug_enabled: bool,
    /// `VK_LAYER_KHRONOS_validation` is enabled.
    validation: bool,

    /// Destroys the instance (destroy the messenger first).
    pub fn destroy(self: *InstanceBundle) void {
        self.disp.destroy_instance(self.inst, null);
        self.* = undefined;
    }
};

pub const validation_layer = "VK_LAYER_KHRONOS_validation";

/// The highest API version zigguro asks for.
pub const max_api: vk.Version = .fromInt(vk.api_version_1_4);

/// The instance API version: `min(loader, 1.4)`. A 1.0 loader is too old.
pub fn negotiateApi(loader_version: vk.Version) error{LoaderTooOld}!vk.Version {
    if (!loader_version.atLeast(1, 1)) return error.LoaderTooOld;
    const v: vk.Version = .fromInt(vk.makeApiVersion(0, loader_version.major, loader_version.minor, 0));
    return if (v.toInt() > max_api.toInt()) max_api else v;
}

/// The loader's version, or 1.0 when `vkEnumerateInstanceVersion` is absent.
pub fn loaderVersion(l: *const loader.Loader, g: *const tables.Global) vk.Version {
    if (l.get_instance_proc_addr(.null_handle, "vkEnumerateInstanceVersion") == null) return .fromInt(vk.api_version_1_0);
    var raw: u32 = vk.api_version_1_0;
    _ = vk.check(g.enumerate_instance_version(&raw)) catch return .fromInt(vk.api_version_1_0);
    return .fromInt(raw);
}

/// Whether to enable the validation layer.
pub fn wantValidation(v: Validation, env: ?bool, debug_build: bool, build_flag: bool, layer_present: bool) bool {
    if (!layer_present) return false;
    if (env) |e| return e;
    return switch (v) {
        .off => false,
        .auto => debug_build and build_flag,
        .on, .on_sync => true,
    };
}

/// The instance extensions to enable, given what is `supported`. Pure.
pub fn chooseExtensions(supported: ExtSet, kind: SurfaceKind, validation: bool) ExtSet {
    var want: ExtSet = .initEmpty();
    switch (kind) {
        .win32 => {
            want.insert(.khr_surface);
            want.insert(.khr_win32_surface);
            want.insert(.khr_get_surface_capabilities2);
            if (supported.contains(.khr_surface_maintenance1)) want.insert(.khr_surface_maintenance1) else want.insert(.ext_surface_maintenance1);
        },
        .external, .headless => {},
    }
    if (validation) {
        want.insert(.ext_debug_utils);
        want.insert(.ext_layer_settings);
    }
    return want.intersectWith(supported);
}

/// The instance extensions the loader (or `layer`) supports.
pub fn supportedExtensions(gpa: std.mem.Allocator, g: *const tables.Global, layer: ?[*:0]const u8) (vk.Error || error{OutOfMemory})!ExtSet {
    const props = try vk.enumerateAlloc(vk.ExtensionProperties, gpa, g.enumerate_instance_extension_properties, .{layer});
    defer gpa.free(props);
    return extSetOf(props);
}

/// The known extensions among `props`.
pub fn extSetOf(props: []const vk.ExtensionProperties) ExtSet {
    var set: ExtSet = .initEmpty();
    for (props) |*p| if (vk.extensionByName(std.mem.sliceTo(&p.extension_name, 0))) |e| set.insert(e);
    return set;
}

fn layerPresent(gpa: std.mem.Allocator, g: *const tables.Global) bool {
    const layers = vk.enumerateAlloc(vk.LayerProperties, gpa, g.enumerate_instance_layer_properties, .{}) catch return false;
    defer gpa.free(layers);
    for (layers) |*l| if (std.mem.eql(u8, std.mem.sliceTo(&l.layer_name, 0), validation_layer)) return true;
    return false;
}

/// Creates the instance. With validation, the messenger reporting into
/// `sink` is chained into the create info so that instance creation and
/// destruction are reported too; `Debug.init` then creates the real one.
pub fn createInstance(gpa: std.mem.Allocator, l: *const loader.Loader, g: *const tables.Global, opts: InstanceOptions, sink: *debug.Sink) CreateError!InstanceBundle {
    const loader_version = loaderVersion(l, g);
    const api = try negotiateApi(loader_version);
    const flag = @import("zg_options").vk_validation;
    const present = layerPresent(gpa, g);
    const validation = wantValidation(opts.validation, opts.env_validation, builtin.mode == .Debug, flag, present);
    if (!present and (opts.validation == .on or opts.validation == .on_sync or opts.env_validation == true or (opts.validation == .auto and flag and builtin.mode == .Debug)))
        log.info("{s} is not installed; running without validation", .{validation_layer});

    var supported = try supportedExtensions(gpa, g, null);
    if (validation) supported.setUnion(try supportedExtensions(gpa, g, validation_layer));
    const exts = chooseExtensions(supported, opts.surface, validation);

    var names: [ext_count][*:0]const u8 = undefined;
    var n: u32 = 0;
    var it = exts.iterator();
    while (it.next()) |e| : (n += 1) names[n] = vk.extensionInfo(e).name.ptr;

    const app: vk.ApplicationInfo = .{
        .p_application_name = opts.app_name,
        .application_version = 0,
        .p_engine_name = "zigguro",
        .engine_version = 0,
        .api_version = api.toInt(),
    };
    const layers = [_][*:0]const u8{validation_layer};
    var ci: vk.InstanceCreateInfo = .{
        .p_application_info = &app,
        .enabled_extension_count = n,
        .pp_enabled_extension_names = &names,
    };
    if (validation) {
        ci.enabled_layer_count = layers.len;
        ci.pp_enabled_layer_names = &layers;
    }
    var messenger_ci = debug.createInfo(sink);
    if (exts.contains(.ext_debug_utils)) vk.chain(&ci, &messenger_ci);

    // Settings names from the layer manifest (VkLayer_khronos_validation.json).
    const yes: vk.Bool32 = .true;
    const no: vk.Bool32 = .false;
    const settings = [_]vk.LayerSettingEXT{
        .{ .p_layer_name = validation_layer, .p_setting_name = "validate_sync", .type = .bool32, .value_count = 1, .p_values = if (opts.validation == .on_sync) &yes else &no },
        .{ .p_layer_name = validation_layer, .p_setting_name = "validate_best_practices", .type = .bool32, .value_count = 1, .p_values = &no },
    };
    var settings_ci: vk.LayerSettingsCreateInfoEXT = .{ .setting_count = settings.len, .p_settings = &settings };
    if (exts.contains(.ext_layer_settings)) {
        vk.chain(&ci, &settings_ci);
    } else if (validation and opts.validation == .on_sync) {
        // Without VK_EXT_layer_settings the layer reads its settings from
        // the environment: VK_VALIDATION_VALIDATE_SYNC=1.
        log.info("VK_EXT_layer_settings is absent; set VK_VALIDATION_VALIDATE_SYNC=1 for synchronization validation", .{});
    }

    var inst: vk.Instance = .null_handle;
    _ = try vk.check(g.create_instance(&ci, null, &inst));
    var diag: loader.Diagnostics = .{};
    const disp = l.loadInstance(inst, loader.apiNumber(api), exts, &diag) catch |err| {
        if (diag.missing) |m| log.err("instance command {s} is missing", .{m});
        // Best effort: destroy through the loader's trampoline.
        if (l.get_instance_proc_addr(inst, "vkDestroyInstance")) |f| {
            const destroy: vk.PfnDestroyInstance = @ptrCast(f);
            destroy(inst, null);
        }
        return err;
    };
    return .{ .inst = inst, .disp = disp, .api = api, .loader_version = loader_version, .exts = exts, .debug_enabled = exts.contains(.ext_debug_utils), .validation = validation };
}

test "instance: API version negotiation" {
    try std.testing.expectError(error.LoaderTooOld, negotiateApi(.fromInt(vk.api_version_1_0)));
    try std.testing.expectEqual(vk.api_version_1_3, (try negotiateApi(.fromInt(vk.makeApiVersion(0, 1, 3, 275)))).toInt());
    try std.testing.expectEqual(vk.api_version_1_4, (try negotiateApi(.fromInt(vk.makeApiVersion(0, 1, 5, 0)))).toInt());
}

test "instance: extension selection per surface kind" {
    var all: ExtSet = .initFull();
    const w = chooseExtensions(all, .win32, false);
    try std.testing.expect(w.contains(.khr_surface) and w.contains(.khr_win32_surface) and w.contains(.khr_get_surface_capabilities2));
    try std.testing.expect(w.contains(.khr_surface_maintenance1) and !w.contains(.ext_surface_maintenance1));
    try std.testing.expect(!w.contains(.ext_debug_utils) and !w.contains(.khr_portability_enumeration));
    try std.testing.expectEqual(@as(usize, 4), w.count());

    all.remove(.khr_surface_maintenance1);
    try std.testing.expect(chooseExtensions(all, .win32, false).contains(.ext_surface_maintenance1));

    try std.testing.expectEqual(@as(usize, 0), chooseExtensions(.initFull(), .external, false).count());
    try std.testing.expectEqual(@as(usize, 0), chooseExtensions(.initFull(), .headless, false).count());
    const d = chooseExtensions(.initFull(), .headless, true);
    try std.testing.expect(d.contains(.ext_debug_utils) and d.contains(.ext_layer_settings));
    // Unsupported extensions are never requested.
    try std.testing.expectEqual(@as(usize, 0), chooseExtensions(.initEmpty(), .win32, true).count());
}

test "instance: validation policy" {
    // Release: off unless forced by the environment.
    try std.testing.expect(!wantValidation(.auto, null, false, true, true));
    try std.testing.expect(wantValidation(.auto, true, false, false, true));
    // Debug: on with the build flag and the layer.
    try std.testing.expect(wantValidation(.auto, null, true, true, true));
    try std.testing.expect(!wantValidation(.auto, null, true, false, true));
    try std.testing.expect(!wantValidation(.on, null, true, true, false));
    try std.testing.expect(!wantValidation(.on, false, true, true, true));
    try std.testing.expect(wantValidation(.on_sync, null, false, false, true));
}
