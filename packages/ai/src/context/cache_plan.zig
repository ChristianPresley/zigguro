//! Cache breakpoint placement for assembled requests (E10.F07.S02.T01).
//!
//! Up to four explicit breakpoints, stable-first:
//! 1. after the last tool;
//! 2. after the memory section of the system prompt;
//! 3. on the last message, so the next request (the next tool round or the
//!    next turn) reads the whole history from cache;
//! 4. on a compaction summary, which anchors the post-compaction prefix.
//!
//! A breakpoint whose prefix is shorter than the model's `cache_min_tokens`
//! is not placed: it would be ignored by the provider and waste a slot.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Message breakpoints. `prefix_tokens[i]` is the estimated input up to and
/// including message `i` (tools and system included).
pub fn messageBreaks(arena: Allocator, prefix_tokens: []const u64, min_tokens: u32, compaction_index: ?u32) Allocator.Error![]const u32 {
    var out: std.ArrayList(u32) = .empty;
    if (compaction_index) |c| if (c < prefix_tokens.len and c + 1 < prefix_tokens.len and prefix_tokens[c] >= min_tokens) try out.append(arena, c);
    if (prefix_tokens.len > 0) {
        const last: u32 = @intCast(prefix_tokens.len - 1);
        if (prefix_tokens[last] >= min_tokens) try out.append(arena, last);
    }
    return out.items;
}

/// Whether a system or tool breakpoint with this prefix is worth placing.
pub fn worth(prefix_tokens: u64, min_tokens: u32) bool {
    return prefix_tokens >= min_tokens;
}

test "breaks respect the minimum" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(usize, 0), (try messageBreaks(a, &.{ 100, 200 }, 1024, null)).len);
    try std.testing.expectEqualSlices(u32, &.{1}, try messageBreaks(a, &.{ 900, 2000 }, 1024, null));
    try std.testing.expectEqualSlices(u32, &.{ 1, 3 }, try messageBreaks(a, &.{ 900, 2000, 2100, 3000 }, 1024, 1));
    // A compaction summary that is the last message gets one break.
    try std.testing.expectEqualSlices(u32, &.{1}, try messageBreaks(a, &.{ 900, 2000 }, 1024, 1));
}
