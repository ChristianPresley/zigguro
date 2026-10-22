//! Device bring-up: instance, validation, device selection and creation,
//! capability report and device-lost handling (E02.F02).

pub const Gpu = @import("Gpu.zig");
pub const CreateOptions = Gpu.CreateOptions;
pub const CreateError = Gpu.CreateError;

const instance = @import("instance.zig");
pub const SurfaceKind = instance.SurfaceKind;
pub const Validation = instance.Validation;
pub const InstanceOptions = instance.InstanceOptions;
pub const InstanceBundle = instance.InstanceBundle;
pub const createInstance = instance.createInstance;

const debug = @import("debug.zig");
pub const Debug = debug.Debug;
pub const Sink = debug.Sink;

const select = @import("select.zig");
pub const Probe = select.Probe;
pub const RejectReason = select.RejectReason;
pub const Preference = select.Preference;
pub const SelectOptions = select.SelectOptions;
pub const probeAll = select.probeAll;
pub const freeProbes = select.freeProbes;
pub const choose = select.choose;
pub const score = select.score;

pub const FeatureSet = @import("features.zig").FeatureSet;

const device = @import("device.zig");
pub const Queue = device.Queue;
pub const deviceExtensions = device.deviceExtensions;

const info = @import("info.zig");
pub const GpuInfo = info.GpuInfo;
pub const Caps = info.Caps;
pub const Report = info.Report;
pub const writeReport = info.writeReport;
pub const ReportFormat = info.ReportFormat;

const lost = @import("lost.zig");
pub const LostPolicy = lost.LostPolicy;
pub const Recovery = lost.Recovery;
pub const Fault = lost.Fault;

pub const CrashMarker = @import("marker.zig").CrashMarker;

test {
    _ = instance;
    _ = debug;
    _ = select;
    _ = @import("features.zig");
    _ = device;
    _ = info;
    _ = lost;
    _ = @import("marker.zig");
    _ = @import("gpu_test.zig");
}
