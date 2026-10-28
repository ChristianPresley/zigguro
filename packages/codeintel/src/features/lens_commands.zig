//! Code lens commands zigguro runs itself (E07.F03.S02.T03): servers'
//! run and debug lenses become zigguro tasks and debug launches instead
//! of `workspace/executeCommand`. The table extends from settings
//! (`lsp.codeLens.commands`), whose entries come first.

const std = @import("std");

pub const Action = enum { run_task, debug_launch };

pub const LensMapping = struct { server_command: []const u8, action: Action };

/// The known run and debug lenses.
pub const default_mappings = [_]LensMapping{
    // rust-analyzer: Run / Debug above `fn main` and tests.
    .{ .server_command = "rust-analyzer.runSingle", .action = .run_task },
    .{ .server_command = "rust-analyzer.debugSingle", .action = .debug_launch },
    // gopls: "run test" above tests (`go test -run`).
    .{ .server_command = "gopls.test", .action = .run_task },
    .{ .server_command = "gopls.run_tests", .action = .run_task },
    // zls has no lenses; clangd's are references only.
};

/// What zigguro does with `command`: `extra` (settings) first, then the
/// defaults; null sends it to the server.
pub fn lookup(extra: []const LensMapping, command: []const u8) ?Action {
    for (extra) |m| if (std.mem.eql(u8, m.server_command, command)) return m.action;
    for (default_mappings) |m| if (std.mem.eql(u8, m.server_command, command)) return m.action;
    return null;
}
