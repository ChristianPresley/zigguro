const std = @import("std");
const b = @import("diamond_b");
const c = @import("diamond_c");
const options = @import("zg_options");

test "a: both paths reach the same c" {
    _ = options.tracing;
    try std.testing.expectEqual(c.value + 1, b.value());
}
