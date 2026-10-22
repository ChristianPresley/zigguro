//! The Vulkan device zigguro renders with: loader, instance, the chosen
//! physical device, the logical device and its queues (E02.F02).
//!
//! `create` takes a few tens of milliseconds (loader ICD discovery
//! dominates), so the app runs it on a worker (`io.async`) while E01
//! creates the window. Every field is immutable after `create` except the
//! queues, whose mutexes guard submission.

const Gpu = @This();

const std = @import("std");
const vk = @import("../vk/vk.zig");
const vkl = @import("../loader/loader.zig");
const platform = @import("zg_platform");
const inst_mod = @import("instance.zig");
const debug_mod = @import("debug.zig");
const select = @import("select.zig");
const device = @import("device.zig");
const info_mod = @import("info.zig");
const lost_mod = @import("lost.zig");
const CrashMarker = @import("marker.zig").CrashMarker;

const log = std.log.scoped(.vk);
const tables = vkl.tables;

gpa: std.mem.Allocator,
io: std.Io,
loader: vkl.Loader,
instance: inst_mod.InstanceBundle,
pdev: vk.PhysicalDevice,
dev: vk.Device,
ddisp: tables.Device,
/// The enabled device extensions.
exts: vkl.ExtSet,
info: info_mod.GpuInfo,
gfx: device.Queue,
transfer: ?device.Queue,
debug: ?debug_mod.Debug,
/// Messenger counters; also receives instance creation messages.
sink: debug_mod.Sink,
/// Every probed device (for `zg doctor gpu` and recovery).
probes: []select.Probe,
chosen: usize,
select_opts: select.SelectOptions,
/// Latched by `checkLost`.
lost: std.atomic.Value(bool) = .init(false),
fault: ?lost_mod.Fault,

pub const CreateOptions = struct {
    instance: inst_mod.InstanceOptions = .{},
    prefer: select.Preference = .auto,
    /// The compositor's device (E01 `Presenter.drmDevice()`).
    drm_device: ?platform.surface.DrmDevice = null,
    /// `ZG_GPU` / `render.gpu`: a device index or a name substring.
    forced: ?[]const u8 = null,
    need_dmabuf_export: bool = false,
    /// `ZG_VK_LOADER_PATH`.
    loader_path: ?[]const u8 = null,
    /// Where the crash marker lives (`~/.cache/zigguro`); null skips it.
    marker_dir: ?std.Io.Dir = null,
    /// `ZG_VK_FAULT` (honoured in Debug and test builds only).
    fault: ?[]const u8 = null,
    /// Receives validation messages instead of the log (tests).
    log_emit: ?*const fn (level: std.log.Level, msg: []const u8) void = null,

    pub fn selectOptions(o: CreateOptions) select.SelectOptions {
        return .{ .surface = o.instance.surface, .prefer = o.prefer, .drm_device = o.drm_device, .forced = o.forced, .need_dmabuf_export = o.need_dmabuf_export };
    }
};

pub const CreateError = inst_mod.CreateError;

fn nowNs(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

/// Opens the loader, creates the instance, chooses a device and creates it.
pub fn create(gpa: std.mem.Allocator, io: std.Io, opts: CreateOptions) CreateError!*Gpu {
    const marker: ?CrashMarker = if (opts.marker_dir) |d| try CrashMarker.begin(io, d) else null;
    const t0 = nowNs(io);

    const self = try gpa.create(Gpu);
    errdefer gpa.destroy(self);
    self.sink = .{ .emit = opts.log_emit };
    self.gpa = gpa;
    self.io = io;
    self.select_opts = opts.selectOptions();
    self.fault = if (opts.fault) |f| lost_mod.Fault.parse(f) else null;
    self.lost = .init(false);

    self.loader = try vkl.Loader.open(.{ .path_override = opts.loader_path });
    errdefer self.loader.close();
    const g = try self.loader.loadGlobal(null);
    self.instance = try inst_mod.createInstance(gpa, &self.loader, &g, opts.instance, &self.sink);
    errdefer self.instance.destroy();
    const idisp = &self.instance.disp;
    self.debug = if (self.instance.debug_enabled) try debug_mod.Debug.init(self.instance.inst, idisp, &self.sink) else null;
    errdefer if (self.debug) |*d| d.deinit(self.instance.inst, idisp);
    const t_inst = nowNs(io);

    self.probes = try select.probeAll(gpa, self.instance.inst, idisp, self.instance.api, opts.instance.surface == .win32);
    errdefer select.freeProbes(gpa, self.probes);
    const chosen = select.choose(self.probes, self.select_opts);
    select.logTable(self.probes, chosen, self.select_opts);
    self.chosen = chosen orelse return error.NoSuitableDevice;
    const p = &self.probes[self.chosen];
    self.pdev = p.pdev;

    const uma = info_mod.isUma(p.kind(), &p.mem);
    const db = try device.createDevice(idisp, self.instance.exts, p, opts.instance.surface, uma);
    self.dev = db.dev;
    self.ddisp = db.disp;
    self.exts = db.exts;
    self.info = info_mod.gpuInfo(p, db.exts, db.queues.gfx);
    self.gfx = self.queue(db.queues.gfx, p);
    self.transfer = if (db.queues.transfer) |t| self.queue(t, p) else null;
    self.name(self.dev, "zigguro-device");
    self.name(self.gfx.handle, "gfx-queue");
    if (self.transfer) |t| self.name(t.handle, "transfer-queue");

    if (marker) |m| m.end(io);
    const t1 = nowNs(io);
    log.info("using {s} (Vulkan {d}.{d}, driver {s}); instance {d} us, device {d} us, validation {s}", .{
        self.info.name(),                              self.info.api_version.major,  self.info.api_version.minor,
        p.driverName(),                                @divTrunc(t_inst - t0, 1000), @divTrunc(t1 - t_inst, 1000),
        if (self.instance.validation) "on" else "off",
    });
    return self;
}

fn queue(self: *Gpu, family: u32, p: *const select.Probe) device.Queue {
    var h: vk.Queue = .null_handle;
    self.ddisp.get_device_queue(self.dev, family, 0, &h);
    return .{ .handle = h, .family = family, .timestamp_valid_bits = p.queues[family].timestamp_valid_bits };
}

/// Destroys everything. Waits for the device unless it was lost.
pub fn destroy(self: *Gpu) void {
    if (!self.lost.load(.acquire)) _ = self.ddisp.device_wait_idle(self.dev);
    self.ddisp.destroy_device(self.dev, null);
    if (self.debug) |*d| d.deinit(self.instance.inst, &self.instance.disp);
    self.instance.destroy();
    self.loader.close();
    select.freeProbes(self.gpa, self.probes);
    self.gpa.destroy(self);
}

/// Names `handle` for validation messages and GPU debuggers. A no-op
/// without `VK_EXT_debug_utils`.
pub fn name(self: *const Gpu, handle: anytype, label: [:0]const u8) void {
    if (self.debug == null) return;
    const H = @TypeOf(handle);
    const raw: u64 = @intFromEnum(handle);
    _ = self.ddisp.set_debug_utils_object_name_ext(self.dev, &.{ .object_type = debug_mod.objectType(H), .object_handle = raw, .p_object_name = label });
}

/// Turns `VK_ERROR_DEVICE_LOST` into `error.DeviceLost` and latches `lost`.
pub fn checkLost(self: *Gpu, r: vk.Result) error{DeviceLost}!void {
    return self.checkLostAt(r, null);
}

/// `checkLost` for a call that counts as a fault-injection event
/// (`ZG_VK_FAULT=lost@submit:N` or `lost@frame:N`).
pub fn checkLostAt(self: *Gpu, r: vk.Result, at: ?lost_mod.Fault.At) error{DeviceLost}!void {
    const injected = if (at) |a| (if (self.fault) |*f| f.tick(a) else false) else false;
    if (r != .error_device_lost and !injected and !self.lost.load(.acquire)) return;
    if (!self.lost.swap(true, .acq_rel)) {
        if (injected) log.info("device lost (injected by ZG_VK_FAULT)", .{}) else log.err("device lost", .{});
    }
    return error.DeviceLost;
}

/// The `zg doctor gpu` report for this device.
pub fn report(self: *const Gpu, losses: []const u64) info_mod.Report {
    return .{ .loader_path = self.loader.path, .loader_version = self.instance.loader_version, .probes = self.probes, .chosen = self.chosen, .opts = self.select_opts, .losses = losses };
}
