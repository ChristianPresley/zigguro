//! The edit policy (E12.F05.S01.T01): which proposed changes apply at
//! once, which wait for review, which are refused.

pub const rules = @import("rules.zig");
pub const protected = @import("protected.zig");
pub const policy = @import("policy.zig");

pub const ReviewPolicy = policy.ReviewPolicy;
pub const PolicyCtx = policy.PolicyCtx;
pub const Verdict = policy.Verdict;
pub const SecurityProbe = policy.SecurityProbe;
pub const Settings = rules.Settings;
pub const RuleConfig = rules.RuleConfig;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("policy_test.zig");
}
