const std = @import("std");
const workflow = @import("root.zig");
const PromptLibrary = @import("../library/index.zig");

const testing = std.testing;
const gpa = testing.allocator;

const valid = [_][]const u8{ "builtin_only", "command_step", "gate", "library_prompt", "limits", "loop_command", "loop_path", "map_command", "map_files", "parallel", "phases", "single_agent", "vote_judge", "vote_majority", "when" };
const invalid = [_][]const u8{ "bad_id", "bad_name", "bad_path", "bad_version", "command_no_profile", "duplicate_id", "forward_ref", "item_outside_map", "no_steps", "schema_contradiction", "too_many_agents", "too_parallel", "two_kinds", "undeclared_arg", "unknown_step" };

pub const test_builtins = [_][]const u8{ "files.glob", "scm.changed_files", "lanes.collect", "artifact.write_table", "research.verify", "research.write_report" };

fn fixture(comptime dir: []const u8, comptime name: []const u8) [:0]const u8 {
    return @embedFile("testdata/" ++ dir ++ "/" ++ name ++ ".zon");
}

fn env(lib: *PromptLibrary) workflow.ValidateEnv {
    return .{ .library = lib, .builtins = &test_builtins };
}

test "parse_and_validate_fixtures" {
    const lib = try PromptLibrary.open(gpa, testing.io, .{}, null);
    defer lib.deinit();
    inline for (valid) |name| {
        var diags: workflow.Diagnostics = .init(gpa);
        defer diags.deinit();
        var p = workflow.parseDef(gpa, fixture("valid", name), env(lib), &diags) catch |e| {
            var w: std.Io.Writer.Allocating = .init(gpa);
            defer w.deinit();
            try diags.format(name, &w.writer);
            std.debug.print("{s}: {t}\n{s}", .{ name, e, w.written() });
            return e;
        };
        defer p.deinit();
        try testing.expectEqual(@as(usize, 0), diags.count());
    }
    inline for (invalid) |name| {
        const src = fixture("invalid", name);
        const first = std.mem.sliceTo(src, '\n');
        const want = first["// expect: ".len..];
        var diags: workflow.Diagnostics = .init(gpa);
        defer diags.deinit();
        try testing.expectError(error.Invalid, workflow.parseDef(gpa, src, env(lib), &diags));
        var w: std.Io.Writer.Allocating = .init(gpa);
        defer w.deinit();
        try diags.format("", &w.writer);
        const got = std.mem.trimEnd(u8, w.written(), "\n");
        // One diagnostic each, exactly as expected.
        const shown = if (std.mem.startsWith(u8, got, ": ")) got[2..] else got;
        testing.expectEqualStrings(want, shown) catch |e| {
            std.debug.print("fixture {s}\n", .{name});
            return e;
        };
    }
}

test "syntax_errors_have_positions" {
    var diags: workflow.Diagnostics = .init(gpa);
    defer diags.deinit();
    try testing.expectError(error.ParseZon, workflow.parse.parseOnly(gpa, ".{ .version = 1, .name = \"x\",\n  .stepz = .{} }", &diags));
    try testing.expect(diags.count() >= 1);
    try testing.expectEqual(@as(u32, 2), diags.items.items[0].line);
}

test "forward_reference_rejected" {
    var diags: workflow.Diagnostics = .init(gpa);
    defer diags.deinit();
    const src = ".{ .version = 1, .name = \"x\", .steps = .{ .{ .id = \"a\", .gate = .{ .title = \"T\", .show = \"$.b\" } }, .{ .id = \"b\", .agent = .{ .prompt = \"B\" } } } }";
    try testing.expectError(error.Invalid, workflow.parseDef(gpa, src, .{}, &diags));
    try testing.expectEqualStrings("show: $.b reads step \"b\", which has not run yet", diags.items.items[0].message);
}

test "schema_contradiction_detected_nested" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"type\":\"object\",\"properties\":{\"findings\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"required\":[\"file\",\"line\"],\"properties\":{\"file\":{}},\"additionalProperties\":false}}}}", .{});
    try testing.expectEqualStrings("line", workflow.validate.contradiction(v).?);
    const ok = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"type\":\"object\",\"required\":[\"a\"],\"properties\":{\"a\":{}},\"additionalProperties\":false}", .{});
    try testing.expect(workflow.validate.contradiction(ok) == null);
}

test "command_step_requires_profile" {
    const src = ".{ .version = 1, .name = \"x\", .profile = \"readonly\", .steps = .{ .{ .id = \"t\", .command = .{ .argv = .{\"make\"} } } } }";
    const Deny = struct {
        fn allowed(_: ?*anyopaque, profile: []const u8) bool {
            return std.mem.eql(u8, profile, "unattended-lane-write");
        }
    };
    var diags: workflow.Diagnostics = .init(gpa);
    defer diags.deinit();
    try testing.expectError(error.Invalid, workflow.parseDef(gpa, src, .{ .commands_allowed = Deny.allowed }, &diags));
    try testing.expectEqualStrings("profile \"readonly\" does not allow commands", diags.items.items[0].message);
}

test "unknown_library_prompt_and_builtin" {
    const lib = try PromptLibrary.open(gpa, testing.io, .{}, null);
    defer lib.deinit();
    const src = ".{ .version = 1, .name = \"x\", .steps = .{ .{ .id = \"a\", .agent = .{ .prompt = \"@research/nope\" } }, .{ .id = \"b\", .builtin = .{ .name = \"web.crawl\" } } } }";
    var diags: workflow.Diagnostics = .init(gpa);
    defer diags.deinit();
    try testing.expectError(error.Invalid, workflow.parseDef(gpa, src, env(lib), &diags));
    try testing.expectEqual(@as(usize, 2), diags.count());
    try testing.expectEqualStrings("unknown library prompt \"@research/nope\"", diags.items.items[0].message);
    try testing.expectEqualStrings("unknown builtin \"web.crawl\"", diags.items.items[1].message);
}

test "validate_50_steps_fast" {
    var src: std.Io.Writer.Allocating = .init(gpa);
    defer src.deinit();
    try src.writer.writeAll(".{ .version = 1, .name = \"big\", .args = .{.{ .name = \"q\" }}, .steps = .{");
    for (0..50) |i| {
        if (i == 0) {
            try src.writer.writeAll(".{ .id = \"s0\", .agent = .{ .prompt = \"Start {{$args.q}}\" } },");
        } else try src.writer.print(".{{ .id = \"s{d}\", .agent = .{{ .prompt = \"Continue {{{{$.s{d}.text}}}} and {{{{$.s0}}}}\", .schema = \"{{\\\"type\\\":\\\"object\\\"}}\" }} }},", .{ i, i - 1 });
    }
    try src.writer.writeAll("} }");
    const z = try gpa.dupeZ(u8, src.written());
    defer gpa.free(z);
    var diags: workflow.Diagnostics = .init(gpa);
    defer diags.deinit();
    var p = try workflow.parse.parseOnly(gpa, z, &diags);
    defer p.deinit();
    const t0 = std.Io.Clock.awake.now(testing.io);
    try workflow.validate.validate(&p.def, .{}, &diags);
    const ns = t0.durationTo(std.Io.Clock.awake.now(testing.io)).nanoseconds;
    try testing.expectEqual(@as(usize, 0), diags.count());
    // Budget 1 ms in release builds; Debug gets slack.
    try testing.expect(ns < 50 * std.time.ns_per_ms);
}
