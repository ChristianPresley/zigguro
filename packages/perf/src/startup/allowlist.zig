//! The critical-path allowlist (E14.F05.S01.T02): packages/perf/
//! startup_allowlist.zon lists the services allowed before the first
//! frame, each with the budget it counts against.

const std = @import("std");
const budget = @import("../budget.zig");

pub const Entry = struct { name: []const u8, budget: []const u8 };
pub const File = struct { services: []const Entry };

/// The embedded allowlist.
pub const file: File = @import("startup_allowlist.zon");

comptime {
    @setEvalBranchQuota(100_000);
    for (file.services) |e| {
        if (budget.registry.byId(e.budget) == null) @compileError("startup_allowlist.zon: " ++ e.name ++ " names unknown budget " ++ e.budget);
    }
}

/// Whether `name` is allowlisted.
pub fn allowed(name: []const u8) bool {
    for (file.services) |e| if (std.mem.eql(u8, e.name, name)) return true;
    return false;
}

/// What a registry's critical services and the allowlist disagree on.
pub const Mismatch = struct {
    /// Critical but not allowlisted.
    unlisted: []const []const u8,
    /// Allowlisted but not registered.
    missing: []const []const u8,

    pub fn ok(m: Mismatch) bool {
        return m.unlisted.len == 0 and m.missing.len == 0;
    }
};

/// Compares `critical` (a registry's critical service names) with the
/// allowlist. Slices are allocated in `arena`.
pub fn compare(arena: std.mem.Allocator, critical: []const []const u8) !Mismatch {
    var unlisted: std.ArrayList([]const u8) = .empty;
    var missing: std.ArrayList([]const u8) = .empty;
    for (critical) |n| if (!allowed(n)) try unlisted.append(arena, n);
    for (file.services) |e| {
        const found = for (critical) |n| {
            if (std.mem.eql(u8, n, e.name)) break true;
        } else false;
        if (!found) try missing.append(arena, e.name);
    }
    return .{ .unlisted = unlisted.items, .missing = missing.items };
}

test "allowlist: compare" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var names: std.ArrayList([]const u8) = .empty;
    for (file.services) |e| try names.append(arena.allocator(), e.name);
    try std.testing.expect((try compare(arena.allocator(), names.items)).ok());
    try names.append(arena.allocator(), "lsp registry");
    _ = names.orderedRemove(0);
    const m = try compare(arena.allocator(), names.items);
    try std.testing.expectEqualStrings("lsp registry", m.unlisted[0]);
    try std.testing.expectEqualStrings(file.services[0].name, m.missing[0]);
}
