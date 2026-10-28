//! Frame timing and latency measurement (E14.F03).

/// `FrameRecord`.
pub const record = @import("frame/record.zig");
/// `LatencyHistogram` and `RollingHistogram`.
pub const histogram = @import("frame/histogram.zig");
/// `FrameTimeline`.
pub const timeline = @import("frame/timeline.zig");
/// The latency clock contract (E14.F03.S02.T01).
pub const clock_contract = @import("frame/clock_contract.zig");
/// `bench-latency` results (E14.F03.S02.T02).
pub const latency_report = @import("frame/latency_report.zig");
/// `ai.chunk_to_photon` and `ai.tool_dispatch_overhead`.
pub const stream_latency = @import("frame/stream_latency.zig");

/// See `record.FrameRecord`.
pub const FrameRecord = record.FrameRecord;
/// See `histogram.LatencyHistogram`.
pub const LatencyHistogram = histogram.LatencyHistogram;
/// See `timeline.FrameTimeline`.
pub const FrameTimeline = timeline.FrameTimeline;
