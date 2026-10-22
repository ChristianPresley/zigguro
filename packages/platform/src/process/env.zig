//! Child environments: the caller's map filtered by the E16 spawn policy,
//! with zigguro internals (`ZG_*`) removed and `TERM` forced. Built in the
//! parent before forking, since the child may not allocate.

const std = @import("std");
const SpawnPolicy = @import("pty.zig").SpawnPolicy;

/// Whether `name` may pass from the caller's environment into the child.
pub fn allowed(name: []const u8, policy: ?*const SpawnPolicy) bool {
    if (std.mem.startsWith(u8, name, "ZG_")) return false;
    const p = policy orelse return true;
    const allow = p.env_allow orelse return true;
    for (allow) |a| if (std.mem.eql(u8, a, name)) return true;
    return false;
}

/// Builds a NULL-terminated `NAME=VALUE` array in `arena`. Policy `env_set`
/// entries override inherited ones, and `term`, when given, sets `TERM`.
/// Order is stable: inherited names in map order, then new names.
pub fn buildEnvp(
    arena: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    policy: ?*const SpawnPolicy,
    term: ?[]const u8,
) std.mem.Allocator.Error![:null]?[*:0]const u8 {
    var merged: std.process.Environ.Map = .init(arena);
    for (env.keys(), env.values()) |k, v| {
        if (allowed(k, policy)) try merged.put(k, v);
    }
    if (policy) |p| for (p.env_set) |kv| try merged.put(kv[0], kv[1]);
    if (term) |t| try merged.put("TERM", t);
    const out = try arena.allocSentinel(?[*:0]const u8, merged.count(), null);
    for (merged.keys(), merged.values(), 0..) |k, v, i| {
        out[i] = (try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ k, v }, 0)).ptr;
    }
    return out;
}

test "buildEnvp filters ZG_ internals, applies allow-list, set and TERM" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var env: std.process.Environ.Map = .init(a);
    try env.put("HOME", "/home/u");
    try env.put("ZG_PLATFORM", "headless");
    try env.put("SECRET", "x");
    try env.put("TERM", "dumb");

    const all = try buildEnvp(a, &env, null, "xterm-256color");
    try std.testing.expectEqual(3, all.len);
    try std.testing.expectEqualStrings("HOME=/home/u", std.mem.span(all[0].?));
    try std.testing.expectEqualStrings("SECRET=x", std.mem.span(all[1].?));
    try std.testing.expectEqualStrings("TERM=xterm-256color", std.mem.span(all[2].?));

    const policy: SpawnPolicy = .{ .env_allow = &.{ "HOME", "ZG_PLATFORM" }, .env_set = &.{.{ "LANG", "C.UTF-8" }} };
    const some = try buildEnvp(a, &env, &policy, null);
    try std.testing.expectEqual(2, some.len);
    try std.testing.expectEqualStrings("HOME=/home/u", std.mem.span(some[0].?));
    try std.testing.expectEqualStrings("LANG=C.UTF-8", std.mem.span(some[1].?));
    try std.testing.expectEqual(null, some[2]);
}
