//! The audit record (E16.F01.S01.T02): one entry of the hash-chained audit
//! log. The log itself (chain, persistence, queries) is E16.F02.S02.T01.

const contracts = @import("../contracts.zig");

/// One audited event. `prev_hash`/`hash` are filled by the log when the
/// record is appended; callers leave them zero.
pub const AuditRecord = struct {
    seq: u64,
    ts_ms: i64,
    actor: contracts.Actor,
    kind: Kind,
    tool: ?[]const u8 = null,
    /// SHA-256 of the canonical tool input.
    input_hash: ?[32]u8 = null,
    resources_json: ?[]const u8 = null,
    decision: ?DecisionKind = null,
    /// The rule that produced the decision, as written.
    rule: ?[]const u8 = null,
    /// The layer the rule came from (`managed`, `user`, ...).
    source: ?[]const u8 = null,
    /// Free text, already redacted.
    detail: ?[]const u8 = null,
    prev_hash: [32]u8 = @splat(0),
    hash: [32]u8 = @splat(0),

    /// What happened.
    pub const Kind = enum {
        tool_decision,
        approval_answer,
        tool_result,
        policy_change,
        mode_change,
        trust_change,
        secret_access,
        sandbox_violation,
        egress_decision,
        session_start,
        session_end,
    };

    /// The decision recorded for `tool_decision` and `egress_decision`.
    pub const DecisionKind = enum { allow, ask, deny };
};
