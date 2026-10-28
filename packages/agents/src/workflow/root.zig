//! Workflows (E13.F08.S01): declarative ZON definitions that orchestrate
//! many agents (map, parallel, reduce, vote, loop-until, gates, builtins,
//! commands), with JSONPath-lite data flow between steps. Format:
//! docs/formats/workflow.md.

pub const def = @import("def.zig");
pub const path = @import("path.zig");
pub const interpolate = @import("interpolate.zig");
pub const parse = @import("parse.zig");
pub const validate = @import("validate.zig");
pub const JournalStore = @import("journal.zig");
pub const replay = @import("replay.zig");
pub const WorkflowEngine = @import("exec.zig");
pub const BuiltinRegistry = @import("builtins.zig");
pub const progress = @import("progress.zig");
pub const tools = @import("tools.zig");
pub const HostWorkers = @import("host_workers.zig").HostWorkers;
pub const step_agent = @import("step_agent.zig");
pub const step_loop = @import("step_loop.zig");
/// A scripted worker port for tests and benches.
pub const fake_workers = @import("fake_workers.zig");

pub const WorkflowDef = def.WorkflowDef;
pub const NamedStep = def.NamedStep;
pub const Step = def.Step;
pub const StepKind = def.StepKind;
pub const AgentStep = def.AgentStep;
pub const Path = path.Path;
pub const Diagnostics = parse.Diagnostics;
pub const ValidateEnv = validate.ValidateEnv;
pub const parseDef = parse.parseDef;
pub const ReplayKey = JournalStore.ReplayKey;
pub const replayKey = JournalStore.replayKey;
pub const Replayer = replay.Replayer;
pub const WorkflowProgress = progress.WorkflowProgress;
pub const WorkerPort = WorkflowEngine.WorkerPort;
pub const WorkerRequest = WorkflowEngine.WorkerRequest;
pub const WorkerEvent = WorkflowEngine.WorkerEvent;
pub const CommandPort = WorkflowEngine.CommandPort;

test {
    _ = @import("parse_test.zig");
    _ = @import("path_test.zig");
    _ = @import("interpolate_test.zig");
    _ = @import("journal_test.zig");
    _ = @import("replay_test.zig");
    _ = @import("exec_test.zig");
    _ = @import("steps_test.zig");
}
