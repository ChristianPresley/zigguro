//! Agent runs (E13.F01.S01): the run model, the registry and its
//! journals, and the host that drives runs as E10 agents.

pub const run = @import("run.zig");
pub const journal = @import("journal.zig");
pub const index = @import("index.zig");
pub const RunRegistry = @import("registry.zig");
pub const queue = @import("queue.zig");
pub const port = @import("port.zig");
pub const untrusted = @import("untrusted.zig");
pub const RunHost = @import("host.zig");
pub const E10Agents = @import("bridge_e10.zig").E10Agents;

pub const RunId = run.RunId;
pub const RunKind = run.RunKind;
pub const RunStatus = run.RunStatus;
pub const RunSpec = run.RunSpec;
pub const RunRecord = run.RunRecord;
pub const RunEvent = run.RunEvent;
pub const Update = run.Update;
pub const Output = run.Output;
pub const Cost = run.Cost;
pub const RunsView = RunRegistry.RunsView;

test {
    _ = run;
    _ = journal;
    _ = index;
    _ = RunRegistry;
    _ = queue;
    _ = untrusted;
    _ = RunHost;
}
