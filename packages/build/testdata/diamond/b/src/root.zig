const std = @import("std");
const c = @import("diamond_c");
const options = @import("zg_options");

/// Depends on c.
pub fn value() u32 {
    return c.value + 1;
}

test "b: value" {
    _ = options.tracing;
    try std.testing.expectEqual(@as(u32, 4), value());
}
