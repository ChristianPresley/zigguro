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
/// Debug adapters (E07.F06.S01.T04): the built-in definitions, the
/// registry that finds them and argument normalization.
pub const adapters = struct {
    pub const Registry = @import("adapters/Registry.zig");
    pub const builtin_adapters = @import("adapters/builtin_adapters.zig");
    pub const normalize = @import("adapters/normalize.zig");
};
/// Launch configurations (E07.F06.S01.T02).
pub const config = struct {
    pub const LaunchConfig = @import("config/LaunchConfig.zig");
    pub const zig_autoconfig = @import("config/zig_autoconfig.zig");
};
/// The DAP wire peer: `DapConnection` and the message envelope.
pub const conn = struct {
    pub const DapConnection = @import("conn/DapConnection.zig");
    pub const message = @import("conn/message.zig");
};

/// Tasks (E07.F08): the task model and its sources, problem matchers.
pub const tasks = struct {
    pub const Task = @import("tasks/Task.zig");
    pub const TaskList = @import("tasks/TaskList.zig");
    pub const TaskRunner = @import("tasks/TaskRunner.zig");
    pub const graph = @import("tasks/graph.zig");
    pub const shell_quote = @import("tasks/shell_quote.zig");
    pub const headless_exec = @import("tasks/headless_exec.zig");
    pub const agent_tool = @import("tasks/agent_tool.zig");
    pub const commands = @import("tasks/commands.zig");
    pub const zig_build = @import("tasks/sources/zig_build.zig");
    pub const jsonc = @import("tasks/sources/jsonc.zig");
    pub const matcher = @import("tasks/matcher/ProblemMatcher.zig");
    pub const ansi = @import("tasks/matcher/ansi_strip.zig");
};

/// The tasks without a GUI (E07.F05.S01.T04): `zg task` and the check
/// task of `zg lsp diagnostics`.
pub const headless = struct {
    pub const HeadlessTasks = @import("headless/HeadlessTasks.zig");
    pub const cli = @import("headless/cli.zig");
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("config/variables_test.zig");
    _ = @import("proto/protocol_test.zig");
    _ = @import("testing/fake_adapter_test.zig");
    _ = @import("conn/conn_test.zig");
    _ = @import("tasks/matcher/matcher_test.zig");
    _ = @import("tasks/task_sources_test.zig");
    _ = @import("tasks/shell_quote_test.zig");
    _ = @import("tasks/task_runner_test.zig");
    _ = @import("headless/headless_test.zig");
    _ = @import("adapters/adapters_test.zig");
}
