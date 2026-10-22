//! GPU memory management (E02.F03): the TLSF suballocator, the
//! device-memory manager, the upload ring, the uploader and textures.

/// See `tlsf.zig`.
pub const tlsf = @import("tlsf.zig");
/// See `tlsf.zig`.
pub const Tlsf = tlsf.Tlsf;
/// Usages, allocations, buffers, images and the pure helpers.
pub const types = @import("types.zig");
pub const Usage = types.Usage;
pub const Allocation = types.Allocation;
pub const Buffer = types.Buffer;
pub const Image = types.Image;
pub const findMemoryType = types.findMemoryType;
/// The device-memory manager.
pub const DeviceMemory = @import("DeviceMemory.zig");
/// The per-frame upload ring.
pub const UploadRing = @import("UploadRing.zig");
/// Batched texture and buffer uploads.
pub const Uploader = @import("Uploader.zig");
pub const Rect16 = Uploader.Rect16;
/// Sampled textures and render targets.
pub const Texture = @import("Texture.zig");
/// synchronization2 barrier helpers.
pub const barriers = @import("barriers.zig");

test {
    _ = tlsf;
    _ = types;
    _ = DeviceMemory;
    _ = UploadRing;
    _ = Uploader;
    _ = Texture;
    _ = barriers;
    _ = @import("gpu_test.zig");
}
