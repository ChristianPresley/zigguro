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
/// The DAP wire peer: `DapConnection` and the message envelope.
pub const conn = struct {
    pub const DapConnection = @import("conn/DapConnection.zig");
    pub const message = @import("conn/message.zig");
};

/// Tasks (E07.F08): the task model and its sources, problem matchers.
pub const tasks = struct {
    pub const Task = @import("tasks/Task.zig");
    pub const TaskList = @import("tasks/TaskList.zig");
    pub const zig_build = @import("tasks/sources/zig_build.zig");
    pub const jsonc = @import("tasks/sources/jsonc.zig");
    pub const matcher = @import("tasks/matcher/ProblemMatcher.zig");
    pub const ansi = @import("tasks/matcher/ansi_strip.zig");
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("config/variables_test.zig");
    _ = @import("proto/protocol_test.zig");
    _ = @import("testing/fake_adapter_test.zig");
    _ = @import("conn/conn_test.zig");
    _ = @import("tasks/matcher/matcher_test.zig");
    _ = @import("tasks/task_sources_test.zig");
}
