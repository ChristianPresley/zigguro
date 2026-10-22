//! zg_ext_sdk: write zigguro extensions in Zig. The protocol (ZEP) types are
//! shared with the host; see `packages/config/docs/zep.md` for the normative description.

const std = @import("std");

/// ZEP message types, method names, error codes and limits.
pub const protocol = @import("protocol.zig");
/// The `Extension` runtime: lifecycle, command dispatch, host methods.
pub const client = @import("client.zig");

pub const Extension = client.Extension;
pub const protocol_version = protocol.protocol_version;

test {
    std.testing.refAllDecls(@This());
    _ = @import("client_test.zig");
}
