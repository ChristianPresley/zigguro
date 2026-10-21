const std = @import("std");
const options = @import("zg_options");

/// The leaf value.
pub const value: u32 = 3;

test "c: zg_options visible" {
    _ = options.tracing;
    try std.testing.expect(options.package_root.len > 0);
}
