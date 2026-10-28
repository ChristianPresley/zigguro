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

test {
    _ = @import("parse_test.zig");
    _ = @import("path_test.zig");
    _ = @import("interpolate_test.zig");
    _ = @import("journal_test.zig");
    _ = @import("replay_test.zig");
}
