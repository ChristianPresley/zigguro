//! Tests for the evaluation runner and graders (E10.F10.S02.T02).

const std = @import("std");
const eval = @import("eval.zig");
const graders = @import("graders.zig");

const testing = std.testing;
const io = testing.io;

const suite = @import("zg_options").package_root ++ "/testdata/eval";

const Work = struct {
    tmp: testing.TmpDir,
    buf: [std.fs.max_path_bytes]u8 = undefined,
    path: []const u8 = "",
    arena: std.heap.ArenaAllocator,

    fn init(w: *Work) !void {
        w.* = .{ .tmp = testing.tmpDir(.{}), .arena = .init(testing.allocator) };
        const n = try w.tmp.dir.realPath(io, &w.buf);
        w.path = w.buf[0..n];
    }

    fn deinit(w: *Work) void {
        w.arena.deinit();
        w.tmp.cleanup();
    }

    fn run(w: *Work, scenarios: []const eval.Scenario) ![]eval.Result {
        const a = w.arena.allocator();
        const results = try a.alloc(eval.Result, scenarios.len);
        try eval.runScenarios(io, testing.allocator, suite, scenarios, results, a, .{ .work_dir = w.path, .jobs = 4 });
        return results;
    }

    fn read(w: *Work, rel: []const u8) ![]const u8 {
        return w.tmp.dir.readFileAlloc(io, rel, w.arena.allocator(), .limited(1 << 20));
    }
};

test "scenario_zon_parse" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try eval.parseScenario(arena.allocator(),
        \\.{
        \\    .name = "edit",
        \\    .fixture = "notes",
        \\    .prompt = "Rename alpha.",
        \\    .script = .{
        \\        .{ .tools = .{.{ .name = "read_file", .input = "{\"path\":\"a.txt\"}" }} },
        \\        .{ .text = "Done.", .expect = .{"alpha"} },
        \\    },
        \\    .hooks = .{.{ .tool = "run_command", .input_contains = "rm" }},
        \\    .graders = .{
        \\        .{ .file_contains = .{ .path = "a.txt", .needle = "ALPHA" } },
        \\        .{ .file_unchanged = "sub/b.txt" },
        \\        .{ .command_succeeds = .{ .argv = .{ "zig", "version" } } },
        \\        .{ .tool_used = "read_file" },
        \\        .{ .max_turns = 3 },
        \\        .{ .max_cost_usd = 0.5 },
        \\        .{ .final_text_matches = "^Done" },
        \\        .no_permission_denials,
        \\    },
        \\}
    );
    try testing.expectEqualStrings("cassette", s.model);
    try testing.expectEqualStrings("accept-edits", s.permission_mode);
    try testing.expectEqual(@as(usize, 2), s.script.len);
    try testing.expectEqualStrings("{\"path\":\"a.txt\"}", s.script[0].tools[0].input);
    try testing.expectEqual(.deny, s.hooks[0].decision);
    try testing.expectEqual(@as(usize, 8), s.graders.len);
    try testing.expectEqual(graders.Grader.no_permission_denials, s.graders[7]);
    try testing.expectEqualStrings("version", s.graders[2].command_succeeds.argv[1]);
    try testing.expectError(error.ParseZon, eval.parseScenario(arena.allocator(), ".{ .name = \"x\" }"));
}

test "grader_table" {
    var w: Work = undefined;
    try w.init();
    defer w.deinit();
    const a = w.arena.allocator();
    try eval.copyTree(io, a, suite ++ "/fixtures/notes", try std.fs.path.join(a, &.{ w.path, "ws" }));
    try w.tmp.dir.writeFile(io, .{ .sub_path = "ws/a.txt", .data = "ALPHA\nbeta\n" });
    const f: graders.Facts = .{
        .workspace = try std.fs.path.join(a, &.{ w.path, "ws" }),
        .fixture = suite ++ "/fixtures/notes",
        .tools_used = &.{ "read_file", "edit_file" },
        .turns = 3,
        .cost_usd = 0.02,
        .denials = 1,
        .final_text = "Renamed alpha to ALPHA.",
    };
    const sh: []const []const u8 = if (@import("builtin").os.tag == .windows) &.{ "cmd.exe", "/c", "exit 0" } else &.{"true"};
    const sh_fail: []const []const u8 = if (@import("builtin").os.tag == .windows) &.{ "cmd.exe", "/c", "exit 3" } else &.{"false"};
    const Case = struct { graders.Grader, bool };
    const cases = [_]Case{
        .{ .{ .file_contains = .{ .path = "a.txt", .needle = "ALPHA" } }, true },
        .{ .{ .file_contains = .{ .path = "a.txt", .needle = "alpha" } }, false },
        .{ .{ .file_contains = .{ .path = "missing.txt", .needle = "x" } }, false },
        .{ .{ .file_unchanged = "sub/b.txt" }, true },
        .{ .{ .file_unchanged = "a.txt" }, false },
        .{ .{ .file_unchanged = "never.txt" }, true },
        .{ .{ .command_succeeds = .{ .argv = sh } }, true },
        .{ .{ .command_succeeds = .{ .argv = sh_fail } }, false },
        .{ .{ .command_succeeds = .{ .argv = &.{"zg-no-such-command"} } }, false },
        .{ .{ .tool_used = "edit_file" }, true },
        .{ .{ .tool_used = "write_file" }, false },
        .{ .{ .tool_not_used = "write_file" }, true },
        .{ .{ .tool_not_used = "read_file" }, false },
        .{ .{ .max_turns = 3 }, true },
        .{ .{ .max_turns = 2 }, false },
        .{ .{ .max_cost_usd = 0.05 }, true },
        .{ .{ .max_cost_usd = 0.01 }, false },
        .{ .{ .final_text_matches = "Renamed \\w+ to [A-Z]+" }, true },
        .{ .{ .final_text_matches = "^Failed" }, false },
        .{ .{ .final_text_matches = "(" }, false },
        .{ .no_permission_denials, false },
    };
    for (cases) |c| {
        const v = try graders.grade(io, a, c[0], &f);
        testing.expectEqual(c[1], v.ok) catch |e| {
            std.debug.print("{s}: {s}\n", .{ try graders.label(a, c[0]), v.detail });
            return e;
        };
    }
    const clean: graders.Facts = .{ .workspace = f.workspace, .fixture = f.fixture };
    try testing.expect((try graders.grade(io, a, .no_permission_denials, &clean)).ok);
}

fn editTo(comptime name: []const u8, comptime word: []const u8) eval.Scenario {
    return .{
        .name = name,
        .fixture = "notes",
        .prompt = "Replace alpha with " ++ word ++ ".",
        .script = &.{
            .{ .tools = &.{.{ .name = "read_file", .input = "{\"path\":\"a.txt\"}" }} },
            .{ .tools = &.{.{ .name = "edit_file", .input = "{\"path\":\"a.txt\",\"old_string\":\"alpha\",\"new_string\":\"" ++ word ++ "\"}" }}, .expect = &.{"alpha"} },
            .{ .text = "Replaced alpha with " ++ word ++ ".", .expect = &.{"a.txt"} },
        },
        .graders = &.{
            .{ .file_contains = .{ .path = "a.txt", .needle = word } },
            .{ .file_unchanged = "sub/b.txt" },
            .{ .tool_used = "edit_file" },
            .{ .max_turns = 3 },
            .no_permission_denials,
        },
    };
}

test "fixture_isolation_concurrent" {
    var w: Work = undefined;
    try w.init();
    defer w.deinit();
    const scenarios = [_]eval.Scenario{ editTo("one", "first"), editTo("two", "second"), editTo("three", "third"), editTo("four", "fourth"), editTo("five", "fifth") };
    const results = try w.run(&scenarios);
    for (results) |r| {
        testing.expect(r.passed) catch |e| {
            std.debug.print("{s}: {?s}\n", .{ r.name, r.error_text });
            for (r.graders) |g| std.debug.print("  {s}: {s}\n", .{ g.grader, g.detail });
            return e;
        };
        try testing.expectEqual(@as(u32, 3), r.turns);
    }
    // Every workspace has its own edit; the fixture is untouched.
    try testing.expectEqualStrings("third\nbeta\n", try w.read("three/a.txt"));
    try testing.expectEqualStrings("fifth\nbeta\n", try w.read("five/a.txt"));
    try testing.expectEqualStrings("alpha\nbeta\n", try Io.Dir.cwd().readFileAlloc(io, suite ++ "/fixtures/notes/a.txt", w.arena.allocator(), .limited(1 << 10)));
}

const Io = std.Io;

test "a dropped expectation fails the scenario" {
    var w: Work = undefined;
    try w.init();
    defer w.deinit();
    var s = editTo("lost", "gamma");
    s.script = &.{
        .{ .tools = &.{.{ .name = "read_file", .input = "{\"path\":\"a.txt\"}" }} },
        .{ .text = "Done.", .expect = &.{"no such text in the results"} },
        .{ .text = "never requested" },
    };
    const r = (try w.run(&.{s}))[0];
    try testing.expect(!r.passed);
    try testing.expect(std.mem.indexOf(u8, r.error_text.?, "turn 2: the request lacks \"no such text in the results\"") != null);
    try testing.expect(std.mem.indexOf(u8, r.error_text.?, "1 scripted turns were not used") != null);
}

test "report_json_schema" {
    var w: Work = undefined;
    try w.init();
    defer w.deinit();
    var report: eval.Report = .{ .gpa = testing.allocator, .arena = .init(testing.allocator), .results = &.{} };
    defer report.deinit();
    const a = report.arena.allocator();
    report.results = try a.alloc(eval.Result, 2);
    try eval.runScenarios(io, testing.allocator, suite, &.{ editTo("ok", "delta"), blk: {
        var bad = editTo("bad", "epsilon");
        bad.graders = &.{.{ .file_contains = .{ .path = "a.txt", .needle = "zeta" } }};
        break :blk bad;
    } }, report.results, a, .{ .work_dir = w.path });

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try report.writeJson(&out.writer);
    const Shape = struct {
        version: u32,
        passed: u32,
        total: u32,
        scenarios: []const struct {
            name: []const u8,
            passed: bool,
            error_text: ?[]const u8 = null,
            graders: []const struct { grader: []const u8, ok: bool, detail: []const u8 },
            exit_code: u8,
            turns: u32,
            input_tokens: u64,
            output_tokens: u64,
            cost_usd: f64,
            wall_ms: u64,
        },
    };
    const parsed = try std.json.parseFromSlice(Shape, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(u32, 1), parsed.value.passed);
    try testing.expectEqual(@as(u32, 2), parsed.value.total);
    try testing.expectEqualStrings("bad", parsed.value.scenarios[1].name);
    try testing.expectEqualStrings("a.txt does not contain \"zeta\"", parsed.value.scenarios[1].graders[0].detail);
    // 3 turns of 1000 in and 50 out at $3/$15 per Mtok.
    try testing.expectEqual(@as(u64, 3000), parsed.value.scenarios[0].input_tokens);
    try testing.expectApproxEqAbs(@as(f64, 0.01125), parsed.value.scenarios[0].cost_usd, 1e-9);

    var table: std.Io.Writer.Allocating = .init(testing.allocator);
    defer table.deinit();
    try report.writeTable(&table.writer);
    try testing.expect(std.mem.indexOf(u8, table.written(), "bad       FAIL") != null);
    try testing.expect(std.mem.indexOf(u8, table.written(), "1/2 scenarios passed") != null);
}

test "baseline_regression_detection" {
    var report: eval.Report = .{ .gpa = testing.allocator, .arena = .init(testing.allocator), .results = &.{} };
    defer report.deinit();
    var results = [_]eval.Result{
        .{ .name = "steady", .passed = true, .turns = 4, .cost_usd = 0.01 },
        .{ .name = "broken", .passed = false, .turns = 4, .cost_usd = 0.01 },
        .{ .name = "slower", .passed = true, .turns = 6, .cost_usd = 0.01 },
        .{ .name = "pricier", .passed = true, .turns = 4, .cost_usd = 0.02 },
        .{ .name = "slightly", .passed = true, .turns = 5, .cost_usd = 0.012 },
        .{ .name = "still_failing", .passed = false, .turns = 2 },
        .{ .name = "brand_new", .passed = false },
    };
    report.results = &results;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const baseline =
        \\{"scenarios":[
        \\ {"name":"steady","passed":true,"turns":4,"cost_usd":0.01},
        \\ {"name":"broken","passed":true,"turns":4,"cost_usd":0.01},
        \\ {"name":"slower","passed":true,"turns":4,"cost_usd":0.01},
        \\ {"name":"pricier","passed":true,"turns":4,"cost_usd":0.01},
        \\ {"name":"slightly","passed":true,"turns":4,"cost_usd":0.01},
        \\ {"name":"still_failing","passed":false,"turns":2,"cost_usd":0},
        \\ {"name":"removed","passed":true,"turns":1,"cost_usd":0}
        \\]}
    ;
    const regs = try eval.regressions(arena.allocator(), baseline, &report);
    try testing.expectEqual(@as(usize, 4), regs.len);
    try testing.expectEqualStrings("broken", regs[0].name);
    try testing.expectEqualStrings("passed in the baseline, fails now", regs[0].reason);
    try testing.expectEqualStrings("turns grew from 4 to 6", regs[1].reason);
    try testing.expectEqualStrings("cost grew from $0.0100 to $0.0200", regs[2].reason);
    try testing.expectEqualStrings("brand_new", regs[3].name);

    // A written baseline reads back with no regressions.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try eval.writeBaseline(&report, &out.writer);
    try testing.expectEqual(@as(usize, 0), (try eval.regressions(arena.allocator(), out.written(), &report)).len);
    results[0].passed = false;
    const again = try eval.regressions(arena.allocator(), out.written(), &report);
    try testing.expectEqual(@as(usize, 1), again.len);
    try testing.expectEqualStrings("steady", again[0].name);
}
