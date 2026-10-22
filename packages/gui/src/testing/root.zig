//! The headless test driver (E04.F01.S03).

const std = @import("std");

/// The `test_app.zig` module.
pub const test_app = @import("test_app.zig");
/// The `script.zig` module.
pub const script = @import("script.zig");

/// See `test_app.TestApp`.
pub const TestApp = test_app.TestApp;
/// See `test_app.Query`.
pub const Query = test_app.Query;
/// See `script.run`.
pub const runScript = script.run;

test {
    std.testing.refAllDecls(@This());
}
