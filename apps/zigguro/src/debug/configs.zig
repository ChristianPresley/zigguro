//! The configuration picker's rows (E07.F07.S01.T01): the workspace's
//! launch configurations and compounds, then the configurations
//! generated for a Zig project (only when the workspace has none of its
//! own, as in VS Code), then "Add Configuration…". Hidden
//! configurations are left out; disabled ones stay, with their reason, so
//! the picker says why they cannot start. Within a group rows follow
//! `presentation.order`, then the files' order.

const std = @import("std");
const zg_dap = @import("zg_dap");

const Allocator = std.mem.Allocator;
const ConfigSet = zg_dap.config.ConfigSet;
const LaunchConfig = zg_dap.config.LaunchConfig;

pub const Kind = enum { config, compound, auto, add };

pub const Entry = struct {
    kind: Kind,
    name: []const u8,
    /// The adapter type and request, or what a compound starts.
    description: []const u8 = "",
    /// Why it cannot start, when it cannot.
    disabled_reason: ?[]const u8 = null,
    /// The picker's group heading.
    group: []const u8,
    /// Index into `ConfigSet.configs`, `.compounds` or the auto list.
    index: usize = 0,

    pub fn enabled(e: Entry) bool {
        return e.disabled_reason == null;
    }
};

pub const add_label = "Add Configuration\u{2026}";

/// The rows, in `a` (strings point into `set` and `autos`).
pub fn entries(a: Allocator, set: *const ConfigSet, autos: []const LaunchConfig) Allocator.Error![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    const Ordered = struct { order: i64, i: usize };
    var order: std.ArrayList(Ordered) = .empty;
    for (set.configs, 0..) |c, i| {
        const p = c.presentation orelse LaunchConfig.Presentation{};
        if (p.hidden) continue;
        try order.append(a, .{ .order = p.order orelse std.math.maxInt(i64), .i = i });
    }
    std.mem.sort(Ordered, order.items, {}, struct {
        fn lt(_: void, x: Ordered, y: Ordered) bool {
            if (x.order != y.order) return x.order < y.order;
            return x.i < y.i;
        }
    }.lt);
    for (order.items) |o| {
        const c = &set.configs[o.i];
        try out.append(a, .{
            .kind = .config,
            .name = c.name,
            .description = try describe(a, c),
            .disabled_reason = if (c.enabled) null else c.disabled_reason orelse "disabled",
            .group = if (c.presentation) |p| p.group orelse sourceName(c.source) else sourceName(c.source),
            .index = o.i,
        });
    }
    for (set.compounds, 0..) |c, i| {
        try out.append(a, .{
            .kind = .compound,
            .name = c.name,
            .description = try std.mem.join(a, ", ", c.configurations),
            .disabled_reason = try compoundProblem(a, set, &c),
            .group = "compounds",
            .index = i,
        });
    }
    if (set.configs.len == 0) for (autos, 0..) |*c, i| {
        try out.append(a, .{
            .kind = .auto,
            .name = c.name,
            .description = try describe(a, c),
            .disabled_reason = if (c.enabled) null else c.disabled_reason orelse "disabled",
            .group = "generated for this Zig project",
            .index = i,
        });
    };
    try out.append(a, .{ .kind = .add, .name = add_label, .group = "" });
    return out.items;
}

fn describe(a: Allocator, c: *const LaunchConfig) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "{s} \u{00b7} {t}", .{ c.type, c.request });
}

fn sourceName(s: LaunchConfig.Source) []const u8 {
    return switch (s) {
        .zon => ".zigguro/launch.zon",
        .vscode => ".vscode/launch.json",
        .auto => "generated",
    };
}

/// Why a compound cannot start: a member is missing or disabled.
fn compoundProblem(a: Allocator, set: *const ConfigSet, c: *const ConfigSet.Compound) Allocator.Error!?[]const u8 {
    if (c.configurations.len == 0) return "it names no configurations";
    for (c.configurations) |name| {
        const cfg = set.find(name) orelse return try std.fmt.allocPrint(a, "there is no configuration \"{s}\"", .{name});
        if (!cfg.enabled) return try std.fmt.allocPrint(a, "\"{s}\" is disabled: {s}", .{ name, cfg.disabled_reason orelse "disabled" });
    }
    return null;
}

/// The text "Add Configuration…" writes to a new `.zigguro/launch.zon`
/// (the file then opens in the editor).
pub const template =
    \\.{
    \\    .version = 1,
    \\    .configurations = .{
    \\        .{
    \\            .name = "Debug zig build run",
    \\            .type = "lldb-dap",
    \\            .request = .launch,
    \\            .args = .{
    \\                .program = "${workspaceFolder}/zig-out/bin/app",
    \\                .args = .{},
    \\                .cwd = "${workspaceFolder}",
    \\            },
    \\            .pre_launch_task = "zig build install",
    \\            .windows = .{ .args = .{ .program = "${workspaceFolder}/zig-out/bin/app.exe" } },
    \\        },
    \\    },
    \\}
    \\
;

const testing = std.testing;

test "ui: config picker lists disabled configs with reasons" {
    const zon =
        \\.{
        \\    .version = 1,
        \\    .configurations = .{
        \\        .{ .name = "b", .type = "lldb-dap", .request = .launch, .args = .{ .program = "b" }, .presentation = .{ .order = 2 } },
        \\        .{ .name = "a", .type = "lldb-dap", .request = .attach, .args = .{ .pid = 1 }, .presentation = .{ .order = 1 } },
        \\        .{ .name = "secret", .type = "lldb-dap", .request = .launch, .args = .{}, .presentation = .{ .hidden = true } },
        \\        .{ .name = "odd", .type = "no-such-adapter", .request = .launch, .args = .{} },
        \\    },
        \\    .compounds = .{
        \\        .{ .name = "both", .configurations = .{ "a", "b" } },
        \\        .{ .name = "broken", .configurations = .{ "a", "missing" } },
        \\    },
        \\}
    ;
    var set = try ConfigSet.fromSources(testing.allocator, .{ .launch_zon = zon, .os = .linux, .trusted = true });
    defer set.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const rows = try entries(arena.allocator(), &set, &.{});
    var names: std.ArrayList(u8) = .empty;
    for (rows) |r| try names.print(arena.allocator(), "{s}{s};", .{ r.name, if (r.enabled()) "" else "!" });
    // Ordered, the hidden one left out, the unknown type and the broken
    // compound disabled, "Add Configuration…" last.
    try testing.expectEqualStrings("a;b;odd!;both;broken!;" ++ add_label ++ ";", names.items);
    try testing.expectEqualStrings("lldb-dap \u{00b7} attach", rows[0].description);
    try testing.expect(rows[2].disabled_reason.?.len > 0);
    try testing.expectEqualStrings("there is no configuration \"missing\"", rows[4].disabled_reason.?);

    // Untrusted: every configuration disabled with the trust reason.
    var untrusted = try ConfigSet.fromSources(testing.allocator, .{ .launch_zon = zon, .os = .linux, .trusted = false });
    defer untrusted.deinit();
    const rows2 = try entries(arena.allocator(), &untrusted, &.{});
    try testing.expect(!rows2[0].enabled());
    try testing.expectEqualStrings(ConfigSet.untrusted_reason, rows2[0].disabled_reason.?);
}

test "generated configurations only without the workspace's own" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var empty = try ConfigSet.fromSources(testing.allocator, .{ .os = .linux, .trusted = true });
    defer empty.deinit();
    const autos = [_]LaunchConfig{.{ .name = "Debug zig build run", .type = "lldb-dap", .request = .launch, .args = .empty, .source = .auto }};
    const rows = try entries(a, &empty, &autos);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqual(Kind.auto, rows[0].kind);
    try testing.expectEqual(Kind.add, rows[1].kind);
}
