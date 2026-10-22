//! zg_dap: the headless DAP client, debugger model and launch
//! configurations (E07). See issue #8 for the package design.

const std = @import("std");

/// Generated Debug Adapter Protocol types (`zig build dapgen`).
pub const protocol = @import("gen/protocol.zig");
/// `std.json` support for the protocol types: union decoding, null
/// omission, open enums.
pub const json = @import("proto/json.zig");
/// `${...}` variable substitution for launch configurations and tasks.
pub const variables = @import("config/variables.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("config/variables_test.zig");
    _ = @import("proto/protocol_test.zig");
    _ = @import("testing/fake_adapter_test.zig");
}
