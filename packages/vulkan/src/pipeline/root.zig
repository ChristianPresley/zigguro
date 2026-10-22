//! Pipelines, the bindless descriptor heap and the persisted pipeline
//! cache (E02.F05.S02).

/// The descriptor set layout and pipeline layout.
pub const layout = @import("layout.zig");
/// The bindless descriptor set and texture slots.
pub const DescriptorHeap = @import("DescriptorHeap.zig");
pub const SamplerKind = DescriptorHeap.SamplerKind;
/// The persisted `VkPipelineCache`.
pub const cache = @import("cache.zig");
pub const PipelineCache = cache.PipelineCache;
/// The graphics pipelines.
pub const pipelines = @import("pipelines.zig");
pub const Pipelines = pipelines.Pipelines;
pub const createPipelines = pipelines.createPipelines;
pub const shaderIdentity = pipelines.shaderIdentity;

test {
    _ = layout;
    _ = DescriptorHeap;
    _ = cache;
    _ = pipelines;
    _ = @import("gpu_test.zig");
}
