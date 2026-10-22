//! Validation-layer assertions for GPU tests (E02.F02.S01.T01).

const std = @import("std");
const Gpu = @import("../gpu/Gpu.zig");

/// Fails if the validation layer reported an error on `gpu`.
pub fn expectNoValidationErrors(gpu: *const Gpu) !void {
    const n = gpu.sink.errors.load(.acquire);
    if (n == 0) return;
    std.debug.print("{d} validation error(s); last: {s}\n", .{ n, gpu.sink.lastVuid() });
    return error.ValidationErrors;
}
