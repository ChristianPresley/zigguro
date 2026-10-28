//! The workflow definition (E13.F08.S01.T01): a declarative ZON file that
//! splits work across agents. Every step is a `NamedStep` with an id and
//! exactly one kind field set:
//!
//! ```zon
//! .{
//!     .version = 1,
//!     .name = "audit-files",
//!     .description = "Audit files for a problem",
//!     .args = .{ .{ .name = "glob" }, .{ .name = "check" } },
//!     .steps = .{
//!         .{ .id = "files", .builtin = .{ .name = "files.glob", .input = "$args.glob" } },
//!         .{ .id = "audit", .map = .{ .over = "$.files", .agent = .{ .prompt = "Check {{$item}} for {{$args.check}}" } } },
//!         .{ .id = "report", .reduce = .{ .prompt = "Rank these findings: {{$.audit}}" } },
//!     },
//! }
//! ```
//!
//! Format: docs/formats/workflow.md. Parsing is `parse.zig`, checks are
//! `validate.zig`.

const std = @import("std");

pub const max_parallel_cap = 64;
pub const max_agents_cap = 1000;
pub const max_map_items_cap = 4096;

pub const Isolation = enum { shared, lane };

/// Binds a library prompt's `{{variable}}` to a path.
pub const Binding = struct {
    name: []const u8,
    /// A path (`$args.question`, `$item.q`) or literal text.
    value: []const u8,
};

/// One subagent.
pub const AgentStep = struct {
    /// Text with `{{$.path}}` interpolation, or `"@library/id"`.
    prompt: []const u8,
    /// For `@library` prompts: their variables.
    with: []const Binding = &.{},
    /// E10 agent definition.
    agent_def: ?[]const u8 = null,
    /// Tool allowlist (default: the agent definition's tools).
    tools: ?[]const []const u8 = null,
    /// E10 model role ("plan", "assist", …).
    model_role: ?[]const u8 = null,
    /// Output JSON Schema: inline JSON or a `.json` file next to the
    /// workflow. With a schema the result is validated JSON.
    schema: ?[]const u8 = null,
    isolation: Isolation = .shared,
    label: ?[]const u8 = null,
    stall_ms: u32 = 600_000,
    max_retries: u8 = 5,
    /// The result must cite sources (research synthesis).
    citations: bool = false,
    /// Source ids the agent may cite (a path).
    sources: ?[]const u8 = null,
};

pub const CommandStep = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    /// Null accepts any exit code.
    expect_exit: ?i32 = 0,
};

pub const BuiltinStep = struct {
    name: []const u8,
    /// A path, or `$` for the whole scope.
    input: []const u8 = "$",
};

/// Fan-out: one body per item of `over`.
pub const MapStep = struct {
    over: []const u8,
    /// The item's name inside the body (`$item` always works too).
    as: []const u8 = "item",
    max_parallel: ?u16 = null,
    /// The step still succeeds when at most this share of items failed.
    max_fail_ratio: f32 = 0.2,
    agent: ?AgentStep = null,
    command: ?CommandStep = null,
    builtin: ?BuiltinStep = null,
};

pub const Decide = enum { majority, unanimous, judge };

/// n copies of one agent, then a decision on their results.
pub const VoteStep = struct {
    n: u8,
    decide: Decide = .majority,
    agent: AgentStep,
    /// For `decide = .judge`: sees every candidate as `$candidates`.
    judge: ?AgentStep = null,
};

pub const Check = struct {
    /// Passes when the command exits 0.
    command: ?[]const []const u8 = null,
    /// Passes when the value at this path is truthy.
    path: ?[]const u8 = null,
    /// Passes when the judge's result has `"pass": true`.
    judge: ?AgentStep = null,
};

/// Evaluator-optimizer: repeat the agent until the check passes.
pub const LoopStep = struct {
    agent: AgentStep,
    check: Check,
    max_rounds: u8 = 8,
    /// Stop after this many rounds in a row with the same failure.
    stop_when_no_progress: u8 = 2,
};

/// Human approval: the run waits in `needs_input`.
pub const GateStep = struct {
    title: []const u8,
    /// What to show on the approval card (a path).
    show: ?[]const u8 = null,
};

pub const ArgType = enum { string, number, bool, json, choice };

pub const ArgDecl = struct {
    name: []const u8,
    type: ArgType = .string,
    required: bool = true,
    default: ?[]const u8 = null,
    options: []const []const u8 = &.{},
    description: []const u8 = "",
};

pub const Limits = struct {
    max_parallel: u16 = 8,
    max_agents: u32 = max_agents_cap,
    max_map_items: u32 = max_map_items_cap,
    max_cost_micros: ?u64 = null,
    max_tokens: ?u64 = null,
    max_wall_ms: ?u64 = null,
};

/// A step with its id; exactly one of the kind fields is set.
pub const NamedStep = struct {
    id: []const u8,
    /// Groups steps in the progress view.
    phase: ?[]const u8 = null,
    /// Runs only when this path is truthy.
    when: ?[]const u8 = null,
    agent: ?AgentStep = null,
    map: ?MapStep = null,
    /// Fixed branches run at once; the result is an object keyed by
    /// branch id.
    parallel: ?[]const NamedStep = null,
    reduce: ?AgentStep = null,
    vote: ?VoteStep = null,
    loop_until: ?LoopStep = null,
    gate: ?GateStep = null,
    builtin: ?BuiltinStep = null,
    command: ?CommandStep = null,

    pub fn kind(s: *const NamedStep) ?StepKind {
        var k: ?StepKind = null;
        inline for (std.meta.fields(StepKind)) |f| {
            if (@field(s, f.name) != null) {
                if (k != null) return null;
                k = @enumFromInt(f.value);
            }
        }
        return k;
    }

    /// How many kind fields are set (validation wants exactly one).
    pub fn kindCount(s: *const NamedStep) u8 {
        var n: u8 = 0;
        inline for (std.meta.fields(StepKind)) |f| {
            if (@field(s, f.name) != null) n += 1;
        }
        return n;
    }

    pub fn step(s: *const NamedStep) ?Step {
        return switch (s.kind() orelse return null) {
            inline else => |k| @unionInit(Step, @tagName(k), @field(s, @tagName(k)).?),
        };
    }
};

pub const StepKind = enum { agent, map, parallel, reduce, vote, loop_until, gate, builtin, command };

pub const Step = union(StepKind) {
    agent: AgentStep,
    map: MapStep,
    parallel: []const NamedStep,
    reduce: AgentStep,
    vote: VoteStep,
    loop_until: LoopStep,
    gate: GateStep,
    builtin: BuiltinStep,
    command: CommandStep,
};

pub const WorkflowDef = struct {
    version: u8,
    name: []const u8,
    description: []const u8 = "",
    args: []const ArgDecl = &.{},
    steps: []const NamedStep,
    limits: Limits = .{},
    /// E16 permission profile for the workers; `command` steps need one
    /// that allows commands.
    profile: ?[]const u8 = null,

    pub fn findStep(d: *const WorkflowDef, id: []const u8) ?*const NamedStep {
        return findIn(d.steps, id);
    }
};

fn findIn(steps: []const NamedStep, id: []const u8) ?*const NamedStep {
    for (steps) |*s| {
        if (std.mem.eql(u8, s.id, id)) return s;
        if (s.parallel) |br| if (findIn(br, id)) |x| return x;
    }
    return null;
}

/// Step ids: `[a-z][a-z0-9_]{0,31}`.
pub fn validStepId(s: []const u8) bool {
    if (s.len == 0 or s.len > 32) return false;
    if (s[0] < 'a' or s[0] > 'z') return false;
    for (s) |c| switch (c) {
        'a'...'z', '0'...'9', '_' => {},
        else => return false,
    };
    return true;
}

/// Workflow names: `[a-z][a-z0-9-]{0,63}`.
pub fn validName(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    if (s[0] < 'a' or s[0] > 'z') return false;
    for (s) |c| switch (c) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}
