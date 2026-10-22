//! Tests for invoke.zig (E10.F06.S01.T02): the order of validation, hooks,
//! permission, handler and bounding, and the decisions each path records.

const std = @import("std");
const proto = @import("zg_ai_proto");
const golden = @import("zg_core").testkit.golden;
const invoke = @import("invoke.zig");
const deps = @import("../loop/deps.zig");
const validate = @import("../schema/validate.zig");

const testing = std.testing;
const io = testing.io;
const Allocator = std.mem.Allocator;

/// A validator for the tests: `required` properties must be present and
/// `"type":"string"` properties must be strings.
const MiniValidator = struct {
    var ctx: u8 = 0;

    fn validator() validate.Validator {
        return .{ .ctx = &ctx, .compile = compile, .validate = check };
    }

    fn compile(_: *anyopaque, arena: Allocator, schema_json: []const u8) validate.CompileError!*const anyopaque {
        const v = try arena.create(std.json.Value);
        v.* = std.json.parseFromSliceLeaky(std.json.Value, arena, schema_json, .{}) catch return error.InvalidSchema;
        return v;
    }

    fn check(_: *anyopaque, compiled: *const anyopaque, _: Allocator, value: std.json.Value, errs: *validate.ErrorList) bool {
        const s: *const std.json.Value = @ptrCast(@alignCast(compiled));
        if (value != .object) {
            errs.add(.{ .pointer = "", .keyword = "type", .message = "expected an object" });
            return false;
        }
        var ok = true;
        if (s.object.get("required")) |req| for (req.array.items) |k| if (!value.object.contains(k.string)) {
            errs.add(.{ .pointer = "", .keyword = "required", .message = "missing required property" });
            ok = false;
        };
        if (s.object.get("properties")) |props| {
            var it = props.object.iterator();
            while (it.next()) |e| {
                const ty = e.value_ptr.object.get("type") orelse continue;
                const got = value.object.get(e.key_ptr.*) orelse continue;
                if (std.mem.eql(u8, ty.string, "string") and got != .string) {
                    errs.add(.{ .pointer = "/path", .keyword = "type", .message = "expected a string" });
                    ok = false;
                }
            }
        }
        return ok;
    }
};

const schema =
    \\{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}
;

/// Records what ran.
const Probe = struct {
    calls: u32 = 0,
    last_input: []const u8 = "",
    pre: u32 = 0,
    post: u32 = 0,
    post_failed: bool = false,
    checks: u32 = 0,
    last_hint: deps.Hint = .none,
    pre_decision: deps.PreToolDecision = .{},
    post_decision: deps.PostToolDecision = .{},
    permission: deps.Decision = .allow,
    handler_error: ?proto.ToolError = null,
    output: []const u8 = "ok",
    decisions: std.ArrayList(deps.ToolDecision) = .empty,
    started: u32 = 0,
    arena: std.heap.ArenaAllocator = .init(testing.allocator),

    fn deinit(p: *Probe) void {
        p.arena.deinit();
    }

    fn handler(ctx: *anyopaque, c: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        p.calls += 1;
        p.last_input = c.input_json;
        if (p.handler_error) |e| return e;
        return proto.ToolOutput.text(c.arena, p.output, false);
    }

    fn preHook(ctx: *anyopaque, _: std.Io, _: Allocator, _: proto.AgentRef, _: *const proto.ToolSpec, _: []const u8) anyerror!deps.PreToolDecision {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        p.pre += 1;
        return p.pre_decision;
    }

    fn postHook(ctx: *anyopaque, _: std.Io, _: Allocator, _: proto.AgentRef, _: *const proto.ToolSpec, _: []const u8, _: *const proto.ToolOutput, failed: bool) anyerror!deps.PostToolDecision {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        p.post += 1;
        p.post_failed = failed;
        return p.post_decision;
    }

    fn check(ctx: *anyopaque, x: std.Io, agent: proto.AgentRef, sp: *const proto.ToolSpec, input_json: []const u8) std.Io.Cancelable!deps.Decision {
        return checkHinted(ctx, x, agent, sp, input_json, .none);
    }

    fn checkHinted(ctx: *anyopaque, _: std.Io, _: proto.AgentRef, _: *const proto.ToolSpec, _: []const u8, hint: deps.Hint) std.Io.Cancelable!deps.Decision {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        p.checks += 1;
        p.last_hint = hint;
        return p.permission;
    }

    fn record(ctx: *anyopaque, _: std.Io, _: proto.AgentRef, d: deps.ToolDecision) void {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        var copy = d;
        copy.reason = p.arena.allocator().dupe(u8, d.reason) catch "";
        p.decisions.append(p.arena.allocator(), copy) catch {};
    }

    fn onStarted(ctx: *anyopaque, _: []const u8) void {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        p.started += 1;
    }

    fn onDecision(_: *anyopaque, _: deps.ToolDecision) void {}

    fn spec(p: *Probe) proto.ToolSpec {
        return .{ .name = "read_file", .description = "", .input_schema_json = schema, .read_only = true, .handler = .{ .ctx = p, .call = handler } };
    }

    fn pipeline(p: *Probe, schemas: *invoke.Schemas) invoke.Pipeline {
        return .{
            .permission = .{ .ctx = p, .check = check, .check_hinted = checkHinted },
            .hooks = .{ .ctx = p, .pre_tool_use = preHook, .post_tool_use = postHook },
            .audit = .{ .ctx = p, .record = record },
            .schemas = schemas,
            .observer = .{ .ctx = p, .started = onStarted, .decision = onDecision },
        };
    }

    /// "stage:outcome" for each recorded decision.
    fn trail(p: *Probe) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (p.decisions.items, 0..) |d, i| {
            if (i > 0) try out.append(p.arena.allocator(), ' ');
            try out.print(p.arena.allocator(), "{s}:{s}", .{ @tagName(d.stage), @tagName(d.outcome) });
        }
        return out.items;
    }
};

fn text(o: proto.ToolOutput) []const u8 {
    return o.parts[0].text;
}

const Fixture = struct {
    probe: Probe = .{},
    schemas: invoke.Schemas,
    arena: std.heap.ArenaAllocator,
    spec: proto.ToolSpec = undefined,

    fn init(f: *Fixture) void {
        f.* = .{ .schemas = .init(testing.allocator, io, MiniValidator.validator()), .arena = .init(testing.allocator) };
        f.spec = f.probe.spec();
    }

    fn deinit(f: *Fixture) void {
        f.schemas.deinit();
        f.arena.deinit();
        f.probe.deinit();
    }

    fn run(f: *Fixture, p: *const invoke.Pipeline, input: []const u8) proto.ToolOutput {
        return invoke.invoke(p, io, f.arena.allocator(), .{ .id = "toolu_1", .spec = &f.spec, .input_json = input });
    }
};

test "invalid_input_no_hooks" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = f.probe.pipeline(&f.schemas);
    const o = f.run(&p, "{\"path\":3}");
    try testing.expect(o.is_error);
    try testing.expectEqualStrings("Invalid input for read_file: /path: expected a string\nFix the input and call the tool again.", text(o));
    try testing.expectEqual(@as(u32, 0), f.probe.pre);
    try testing.expectEqual(@as(u32, 0), f.probe.checks);
    try testing.expectEqual(@as(u32, 0), f.probe.calls);
    try testing.expectEqualStrings("validation:deny", try f.probe.trail());
}

test "hook_deny_short_circuits" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    f.probe.pre_decision = .{ .decision = .deny, .reason = "no reading secrets" };
    const p = f.probe.pipeline(&f.schemas);
    const o = f.run(&p, "{\"path\":\"a\"}");
    try testing.expect(o.is_error);
    try testing.expectEqualStrings("Blocked by a PreToolUse hook: no reading secrets", text(o));
    try testing.expectEqual(@as(u32, 0), f.probe.checks);
    try testing.expectEqual(@as(u32, 0), f.probe.calls);
    try testing.expectEqual(@as(u32, 0), f.probe.post);
}

test "hook_allow_cannot_override_policy_deny" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    f.probe.pre_decision = .{ .decision = .allow };
    f.probe.permission = .{ .deny = "rule Read(.env*)" };
    const p = f.probe.pipeline(&f.schemas);
    const o = f.run(&p, "{\"path\":\".env\"}");
    try testing.expect(o.is_error);
    try testing.expectEqualStrings("Permission denied: rule Read(.env*)", text(o));
    try testing.expectEqual(deps.Hint.hook_allow, f.probe.last_hint);
    try testing.expectEqual(@as(u32, 0), f.probe.calls);
    try testing.expectEqualStrings("pre_hook:allow permission:deny", try f.probe.trail());
}

test "hook updated input is validated again" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    f.probe.pre_decision = .{ .updated_input_json = "{\"path\":\"b\"}" };
    var p = f.probe.pipeline(&f.schemas);
    _ = f.run(&p, "{\"path\":\"a\"}");
    try testing.expectEqualStrings("{\"path\":\"b\"}", f.probe.last_input);
    f.probe.pre_decision = .{ .updated_input_json = "{}" };
    const o = f.run(&p, "{\"path\":\"a\"}");
    try testing.expect(o.is_error);
    try testing.expectEqual(@as(u32, 1), f.probe.calls);
    // A hook ask forces the prompt.
    f.probe.pre_decision = .{ .decision = .ask };
    _ = f.run(&p, "{\"path\":\"a\"}");
    try testing.expectEqual(deps.Hint.hook_ask, f.probe.last_hint);
    // Without check_hinted the plain check runs.
    p.permission.check_hinted = null;
    f.probe.last_hint = .hook_allow;
    _ = f.run(&p, "{\"path\":\"a\"}");
    try testing.expectEqual(deps.Hint.none, f.probe.last_hint);
}

/// Blocks until canceled, like an open approval dialog.
const Waiting = struct {
    fn check(_: *anyopaque, x: std.Io, _: proto.AgentRef, _: *const proto.ToolSpec, _: []const u8) std.Io.Cancelable!deps.Decision {
        var e: std.Io.Event = .unset;
        try e.wait(x);
        return .allow;
    }
};

test "ask_waits_and_cancels" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var p = f.probe.pipeline(&f.schemas);
    var d: u8 = 0;
    p.permission = .{ .ctx = &d, .check = Waiting.check };
    var fut = try io.concurrent(Fixture.run, .{ &f, &p, "{\"path\":\"a\"}" });
    const o = fut.cancel(io);
    try testing.expect(o.is_error);
    try testing.expectEqualStrings(invoke.canceled_text, text(o));
    try testing.expectEqual(@as(u32, 0), f.probe.calls);
}

test "ask_edit_revalidates" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = f.probe.pipeline(&f.schemas);
    f.probe.permission = .{ .allow_edited = "{\"path\":\"edited\"}" };
    const ok = f.run(&p, "{\"path\":\"a\"}");
    try testing.expect(!ok.is_error);
    try testing.expectEqualStrings("{\"path\":\"edited\"}", f.probe.last_input);
    f.probe.permission = .{ .allow_edited = "{\"path\":1}" };
    const bad = f.run(&p, "{\"path\":\"a\"}");
    try testing.expect(bad.is_error);
    try testing.expectEqual(@as(u32, 1), f.probe.calls);
    try testing.expectEqualStrings("permission:edit permission:edit validation:deny", try f.probe.trail());
}

test "post_hook_additional_context" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = f.probe.pipeline(&f.schemas);
    f.probe.post_decision = .{ .additional_context = "Remember the style guide." };
    const o = f.run(&p, "{\"path\":\"a\"}");
    try testing.expectEqual(@as(usize, 2), o.parts.len);
    try testing.expectEqualStrings("ok", o.parts[0].text);
    try testing.expectEqualStrings("Remember the style guide.", o.parts[1].text);
    try testing.expect(!f.probe.post_failed);
    // A replaced output; a failing handler runs PostToolUseFailure.
    f.probe.post_decision = .{ .updated_output = .{ .parts = &.{.{ .text = "replaced" }} } };
    f.probe.handler_error = error.Failed;
    const r = f.run(&p, "{\"path\":\"a\"}");
    try testing.expect(f.probe.post_failed);
    try testing.expectEqualStrings("replaced", text(r));
    try testing.expectEqual(@as(u32, 2), f.probe.started);
}

test "bound_spills_and_formats" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = f.arena.allocator();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/spill", .{&tmp.sub_path});
    var p = f.probe.pipeline(&f.schemas);
    p.bounds = .{ .max_output_chars = 100, .preview_chars = 20, .tail_chars = 15, .spill_dir = dir };
    var long: std.ArrayList(u8) = .empty;
    for (0..30) |i| try long.print(a, "line {d:0>2}\n", .{i});
    f.probe.output = long.items;
    const o = f.run(&p, "{\"path\":\"a\"}");
    try testing.expect(o.truncated);
    const shown = try std.mem.replaceOwned(u8, a, text(o), dir, "<spill>");
    try golden.expectGoldenOpts(io, @src(), "bound_spill", shown, .{ .root = @import("zg_options").package_root, .dir = "testdata/golden/tools/invoke" });
    const saved = try std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/toolu_1.txt", .{dir}), a, .limited(4096));
    try testing.expectEqualStrings(long.items, saved);
    // Without a spill directory nothing is saved.
    p.bounds.spill_dir = null;
    try golden.expectGoldenOpts(io, @src(), "bound_no_spill", text(f.run(&p, "{\"path\":\"a\"}")), .{ .root = @import("zg_options").package_root, .dir = "testdata/golden/tools/invoke" });
    // Short output is untouched.
    f.probe.output = "short";
    try testing.expect(!f.run(&p, "{\"path\":\"a\"}").truncated);
}

test "handler_error_instructive_text" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const p = f.probe.pipeline(&f.schemas);
    f.probe.handler_error = error.Timeout;
    const o = f.run(&p, "{\"path\":\"a\"}");
    try testing.expect(o.is_error);
    try testing.expectEqualStrings(invoke.handlerErrorText(error.Timeout), text(o));
    try testing.expect(std.mem.indexOf(u8, text(o), "Try") != null);
}

test "audit_records_every_decision" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var p = f.probe.pipeline(&f.schemas);
    p.bounds.max_output_chars = 4;
    f.probe.output = "too long";
    f.probe.pre_decision = .{ .decision = .ask, .updated_input_json = "{\"path\":\"b\"}" };
    f.probe.post_decision = .{ .additional_context = "x" };
    _ = f.run(&p, "{\"path\":\"a\"}");
    try testing.expectEqualStrings("pre_hook:edit pre_hook:ask permission:allow post_hook:context bound:truncate", try f.probe.trail());
}

test "no hooks and allow: the fast path" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const s = f.probe.spec();
    const p: invoke.Pipeline = .{ .schemas = &f.schemas };
    const o = invoke.invoke(&p, io, f.arena.allocator(), .{ .id = "t", .spec = &s, .input_json = "{\"path\":\"a\"}" });
    try testing.expectEqualStrings("ok", text(o));
}
