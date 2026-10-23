//! Ghost-text completion (E12.F07.S01): when to ask (scheduler, cache),
//! request context, neighbour snippets, FIM templates and the providers
//! that fill the middle.

pub const context = @import("context.zig");
pub const neighbours = @import("neighbours.zig");
pub const fim = @import("fim.zig");
pub const scheduler = @import("scheduler.zig");
pub const cache = @import("cache.zig");
pub const providers = @import("providers.zig");
pub const engine = @import("engine.zig");
pub const postprocess = @import("postprocess.zig");
pub const telemetry = @import("telemetry.zig");
pub const provider_chat = @import("provider_chat.zig");

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
pub const FimProvider = providers.FimProvider;
pub const CompletionEngine = engine.CompletionEngine;
pub const HttpFim = providers.HttpFim;
pub const ChatFim = provider_chat.ChatFim;
pub const ChatPort = provider_chat.ChatPort;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("complete_test.zig");
    _ = @import("scheduler_test.zig");
    _ = @import("providers_test.zig");
    _ = @import("engine_test.zig");
    _ = @import("postprocess_test.zig");
}
