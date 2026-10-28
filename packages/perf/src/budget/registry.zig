//! The budget registry: `budgets.zon` embedded at compile time, validated
//! in a comptime block, with comptime (`get`) and runtime (`byId`) lookup.

const std = @import("std");
const schema = @import("schema.zig");

/// The registry file. `packages/perf/build.zig` maps the import name to
/// `packages/perf/budgets.zon`.
pub const file: schema.File = @import("budgets.zon");

/// Every budget, in file order.
pub const all: []const schema.Budget = file.budgets;

comptime {
    validate(file);
}

/// Raises a compile error naming the first problem in `f`.
pub fn validate(comptime f: schema.File) void {
    @setEvalBranchQuota(1_000_000);
    if (schema.validateRuntime(&f)) |p| {
        @compileError(p.message() ++ ": " ++ (if (p.index < f.budgets.len) f.budgets[p.index].id else "(file)"));
    }
}

/// An enum with one tag per budget id (dots become `__`).
pub const BudgetId = blk: {
    @setEvalBranchQuota(1_000_000);
    var names: [all.len][]const u8 = undefined;
    var values: [all.len]u16 = undefined;
    for (all, 0..) |b, i| {
        var name: []const u8 = "";
        for (b.id) |c| name = name ++ (if (c == '.') "__" else &[_]u8{c});
        names[i] = name;
        values[i] = i;
    }
    break :blk @Enum(u16, .exhaustive, &names, &values);
};

/// The budget with `id`; a compile error if there is none.
pub fn get(comptime id: []const u8) *const schema.Budget {
    const index = comptime blk: {
        @setEvalBranchQuota(1_000_000);
        for (all, 0..) |b, i| {
            if (std.mem.eql(u8, b.id, id)) break :blk i;
        }
        @compileError("unknown budget id: " ++ id);
    };
    return &all[index];
}

/// The budget with `id`, or null.
pub fn byId(id: []const u8) ?*const schema.Budget {
    for (all) |*b| {
        if (std.mem.eql(u8, b.id, id)) return b;
    }
    return null;
}

/// The machine description for `class`, or null.
pub fn machine(class: schema.MachineClass) ?*const schema.Machine {
    for (file.machines) |*m| if (m.class == class) return m;
    return null;
}

test "budget: registry validates" {
    try std.testing.expectEqual(@as(?schema.Problem, null), schema.validateRuntime(&file));
    try std.testing.expect(all.len >= 80);
}

test "budget: get returns typed budget" {
    const b = get("input.key_to_photon");
    try std.testing.expectEqual(schema.Metric.duration_ns, b.metric);
    try std.testing.expectEqual(schema.Stat.p99, b.stat);
    try std.testing.expectEqual(@as(f64, 8_000_000), b.limit);
    try std.testing.expectEqualStrings("E14", b.owner);
    try std.testing.expect(@hasField(BudgetId, "input__key_to_photon"));
}

test "budget: byId unknown returns null" {
    try std.testing.expect(byId("no.such_budget") == null);
    try std.testing.expect(byId("idle.wakeups") != null);
    try std.testing.expect(machine(.ref_laptop_2024) != null);
}
