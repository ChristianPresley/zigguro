//! Memory accounting (E14.F04): tags, the tracked allocator and GPU
//! memory. docs/perf/memory.md says which package uses which tag.

/// `MemTag` and the per-tag counters.
pub const tags = @import("mem/tags.zig");
/// `TrackedAllocator`, `tracked` and `trackedWith`.
pub const tracked_alloc = @import("mem/tracked.zig");
/// GPU memory charges and the driver source.
pub const gpu = @import("mem/gpu.zig");

/// See `tags.MemTag`.
pub const MemTag = tags.MemTag;
/// See `tags.TagStats`.
pub const TagStats = tags.TagStats;
/// See `tracked_alloc.TrackedAllocator`.
pub const TrackedAllocator = tracked_alloc.TrackedAllocator;
/// See `tracked_alloc.tracked`.
pub const tracked = tracked_alloc.tracked;
/// See `tracked_alloc.trackedWith`.
pub const trackedWith = tracked_alloc.trackedWith;
/// See `tags.tagStats`.
pub const tagStats = tags.tagStats;
/// See `tags.allTagStats`.
pub const allTagStats = tags.allTagStats;

/// Process memory from the OS.
pub const process = @import("mem/process.zig");
/// `Sampler` and `Snapshot`.
pub const sampler = @import("mem/sampler.zig");
/// `writeReport` and `writeReportJson`.
pub const report = @import("mem/report.zig");

/// See `process.ProcessMem`.
pub const ProcessMem = process.ProcessMem;
/// See `process.readProcessMem`.
pub const readProcessMem = process.readProcessMem;
/// See `sampler.Sampler`.
pub const Sampler = sampler.Sampler;
/// See `sampler.Snapshot`.
pub const Snapshot = sampler.Snapshot;
/// See `sampler.Sampler.Observation`.
pub const Observation = Sampler.Observation;
/// See `report.writeReport`.
pub const writeReport = report.writeReport;
/// See `report.writeReportJson`.
pub const writeReportJson = report.writeReportJson;
