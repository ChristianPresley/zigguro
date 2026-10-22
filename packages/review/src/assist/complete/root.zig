//! Ghost-text completion (E12.F07.S01): when to ask (scheduler, cache),
//! request context, neighbour snippets and FIM templates.

pub const context = @import("context.zig");
pub const neighbours = @import("neighbours.zig");
pub const fim = @import("fim.zig");
pub const scheduler = @import("scheduler.zig");
pub const cache = @import("cache.zig");

pub const CompletionRequest = context.CompletionRequest;
pub const ContextBudget = context.ContextBudget;
pub const TokenEstimate = context.TokenEstimate;
pub const buildRequest = context.buildRequest;
pub const NeighbourIndex = neighbours.NeighbourIndex;
pub const Snippet = neighbours.Snippet;
pub const FimTemplate = fim.FimTemplate;
pub const Scheduler = scheduler.Scheduler;
pub const Gate = scheduler.Gate;
pub const Cache = cache.Cache;
pub const CacheKey = cache.CacheKey;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("complete_test.zig");
    _ = @import("scheduler_test.zig");
}
