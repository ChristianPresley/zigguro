//! Tests for args.zig (E10.F10.S01.T01).

const std = @import("std");
const args = @import("args.zig");

const testing = std.testing;

const Want = union(enum) {
    usage,
    ok: *const fn (o: args.HeadlessOptions) bool,
};

const Case = struct { argv: []const [:0]const u8, want: Want };

fn ok(comptime f: fn (o: args.HeadlessOptions) bool) Want {
    return .{ .ok = f };
}

const cases = [_]Case{
    // 1-10: basics.
    .{ .argv = &.{}, .want = ok(struct {
        fn f(o: args.HeadlessOptions) bool {
            return o.prompt == null and o.output_format == .text and o.permission_mode == .default;
        }
    }.f) },
    .{ .argv = &.{ "-p", "hello" }, .want = ok(struct {
        fn f(o: args.HeadlessOptions) bool {
            return std.mem.eql(u8, o.prompt.?, "hello");
        }
    }.f) },
    .{ .argv = &.{"--print=hi there"}, .want = ok(struct {
        fn f(o: args.HeadlessOptions) bool {
            return std.mem.eql(u8, o.prompt.?, "hi there");
        }
    }.f) },
    .{ .argv = &.{"-p"}, .want = .usage },
    .{ .argv = &.{ "-p", "a", "-p", "b" }, .want = .usage },
    .{ .argv = &.{"stray"}, .want = .usage },
    .{ .argv = &.{"--frobnicate"}, .want = .usage },
    .{ .argv = &.{ "--model", "opus", "-p", "x" }, .want = ok(struct {
        fn f(o: args.HeadlessOptions) bool {
            return std.mem.eql(u8, o.model.?, "opus");
        }
    }.f) },
    .{ .argv = &.{"--model="}, .want = .usage },
    .{ .argv = &.{ "-h", "--bogus-later-ignored-no" }, .want = .usage },
    // 11-18: formats.
    .{ .argv = &.{ "--output-format", "json", "-p", "x" }, .want = ok(struct {
        fn f(o: args.HeadlessOptions) bool {
            return o.output_format == .json;
        }
    }.f) },
    .{ .argv = &.{ "--output-format", "stream-json", "-p", "x" }, .want = ok(struct {
        fn f(o: args.HeadlessOptions) bool {
            return o.output_format == .stream_json;
        }
    }.f) },
    .{ .argv = &.{ "--output-format", "yaml" }, .want = .usage },
    .{ .argv = &.{ "--input-format", "stream-json", "--output-format", "stream-json" }, .want = ok(struct {
        fn f(o: args.HeadlessOptions) bool {
            return o.streamInput();
        }
    }.f) },
    .{ .argv = &.{ "--input-format", "stream-json" }, .want = .usage },
    .{ .argv = &.{ "--input-format", "stream-json", "--output-format", "stream-json", "-p", "x" }, .want = .usage },
    .{ .argv = &.{ "--include-partial", "-p", "x" }, .want = .usage },
    .{ .argv = &.{ "--include-partial", "--output-format=stream-json", "-p", "x" }, .want = ok(struct {
        fn f(o: args.HeadlessOptions) bool {
            return o.include_partial;
        }
    }.f) },
    // 19-25: sessions.
    .{ .argv = &.{ "--resume", "01J0000000000000000000000A" }, .want = ok(struct {
        fn f(o: args.HeadlessOptions) bool {
            return o.resume_session != null;
        }
    }.f) },
    .{ .argv = &.{"-c"}, .want = ok(struct {
        fn f(o: args.HeadlessOptions) bool {
            return o.continue_session;
        }
    }.f) },
    .{ .argv = &.{ "-c", "-r", "x" }, .want = .usage },
    .{ .argv = &.{"--fork-session"}, .want = .usage },
    .{ .argv = &.{ "--fork-session", "-c" }, .want = ok(struct {
        fn f(o: args.HeadlessOptions) bool {
            return o.fork_session and o.continue_session;
        }
    }.f) },
    .{ .argv = &.{ "--no-session-persistence", "-c" }, .want = .usage },
    .{ .argv = &.{"--continue=yes"}, .want = .usage },
    // 26-32: tools and permissions.
    .{ .argv = &.{ "--allowed-tools", "read_file,run_command(git diff:*)", "--allowed-tools", "grep" }, .want = ok(struct {
        fn f(o: args.HeadlessOptions) bool {
            return o.allowed_tools.len == 3 and std.mem.eql(u8, o.allowed_tools[1], "run_command(git diff:*)");
        }
    }.f) },
    .{ .argv = &.{ "--disallowed-tools", "run_command(rm -rf a,b), write_file" }, .want = ok(struct {
        fn f(o: args.HeadlessOptions) bool {
            return o.disallowed_tools.len == 2 and std.mem.eql(u8, o.disallowed_tools[0], "run_command(rm -rf a,b)");
        }
    }.f) },
    .{ .argv = &.{ "--allowed-tools", "run_command(git" }, .want = .usage },
    .{ .argv = &.{ "--permission-mode", "accept-edits" }, .want = ok(struct {
        fn f(o: args.HeadlessOptions) bool {
            return o.permission_mode == .accept_edits;
        }
    }.f) },
    .{ .argv = &.{ "--permission-mode", "bypass" }, .want = ok(struct {
        fn f(o: args.HeadlessOptions) bool {
            return o.permission_mode == .bypass_permissions;
        }
    }.f) },
    .{ .argv = &.{ "--permission-mode", "yolo" }, .want = .usage },
    .{ .argv = &.{ "--permission-prompts", "stream", "-p", "x" }, .want = .usage },
    // 33-40: limits and the rest.
    .{ .argv = &.{ "--max-turns", "5" }, .want = ok(struct {
        fn f(o: args.HeadlessOptions) bool {
            return o.max_turns.? == 5;
        }
    }.f) },
    .{ .argv = &.{ "--max-turns", "0" }, .want = .usage },
    .{ .argv = &.{ "--max-budget-usd", "0.25" }, .want = ok(struct {
        fn f(o: args.HeadlessOptions) bool {
            return o.max_budget_micros.? == 250_000;
        }
    }.f) },
    .{ .argv = &.{ "--max-budget-usd", "-1" }, .want = .usage },
    .{ .argv = &.{ "--max-time", "90s" }, .want = ok(struct {
        fn f(o: args.HeadlessOptions) bool {
            return o.max_time_ms.? == 90_000;
        }
    }.f) },
    .{ .argv = &.{ "--max-time", "soon" }, .want = .usage },
    .{ .argv = &.{ "--json-schema", "{\"type\":\"object\"}", "--agent", "reviewer", "--mcp-config", "a.json", "--mcp-config", "b.json", "--bare", "-v" }, .want = ok(struct {
        fn f(o: args.HeadlessOptions) bool {
            return o.json_schema != null and std.mem.eql(u8, o.agent.?, "reviewer") and o.mcp_configs.len == 2 and o.bare and o.verbose;
        }
    }.f) },
    .{ .argv = &.{ "--input-format", "stream-json", "--output-format", "stream-json", "--permission-prompts", "stream", "--append-system-prompt", "Be brief." }, .want = ok(struct {
        fn f(o: args.HeadlessOptions) bool {
            return o.permission_prompts == .stream and std.mem.eql(u8, o.append_system_prompt.?, "Be brief.");
        }
    }.f) },
};

test "parse args table" {
    try testing.expectEqual(@as(usize, 40), cases.len);
    for (cases, 0..) |c, i| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const got = args.parseArgs(arena.allocator(), c.argv);
        switch (c.want) {
            .usage => if (got) |_| {
                std.debug.print("case {d}: expected error.Usage\n", .{i + 1});
                return error.TestUnexpectedResult;
            } else |_| {},
            .ok => |check| {
                const o = got catch |e| {
                    std.debug.print("case {d}: {s}\n", .{ i + 1, @errorName(e) });
                    return e;
                };
                if (!check(o)) {
                    std.debug.print("case {d}: wrong options\n", .{i + 1});
                    return error.TestUnexpectedResult;
                }
            },
        }
    }
}

test "help is accepted alone and documents every exit code" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try args.parseArgs(arena.allocator(), &.{"--help"})).help);
    for ([_][]const u8{ "  0 ", "  1 ", "  2 ", "  3 ", "  4 ", "  130 ", "  143 " }) |c| try testing.expect(std.mem.indexOf(u8, args.usage_text, c) != null);
}

test "durations and amounts" {
    try testing.expectEqual(@as(?u64, 500), args.parseDuration("500ms"));
    try testing.expectEqual(@as(?u64, 300_000), args.parseDuration("5m"));
    try testing.expectEqual(@as(?u64, 7_200_000), args.parseDuration("2h"));
    try testing.expectEqual(@as(?u64, 30_000), args.parseDuration("30"));
    try testing.expectEqual(@as(?u64, null), args.parseDuration("0s"));
    try testing.expectEqual(@as(?u64, 1), args.parseUsd("0.000001"));
    try testing.expectEqual(@as(?u64, null), args.parseUsd("0"));
}
