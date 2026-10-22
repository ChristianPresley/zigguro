//! Tests for compactor.zig with a scripted summarizer.

const std = @import("std");
const proto = @import("zg_ai_proto");
const zg_core = @import("zg_core");
const cmp = @import("compactor.zig");
const asm_mod = @import("assembler.zig");
const memory = @import("memory.zig");
const request = @import("../provider/request.zig");
const registry = @import("../models/registry.zig");
const sp = @import("../provider/scripted.zig");

const testing = std.testing;
const ScriptedProvider = sp.ScriptedProvider;

const model: registry.ModelInfo = .{ .id = "summarizer", .provider = .scripted, .display = "S", .family = "test", .context_window = 200_000, .max_output = 64_000, .caps = .{} };

fn history(a: std.mem.Allocator) ![]const proto.Message {
    var out: std.ArrayList(proto.Message) = .empty;
    const texts = [_]struct { proto.Role, []const u8 }{
        .{ .user, "Fix the auth bug." },
        .{ .assistant, "Looking." },
        .{ .user, "It fails on refresh." },
        .{ .assistant, "Found it." },
        .{ .user, "Now add a test." },
        .{ .assistant, "Done." },
    };
    for (texts) |t| {
        const b = try a.alloc(proto.ContentBlock, 1);
        b[0] = .{ .text = .{ .text = t[1] } };
        try out.append(a, .{ .role = t[0], .content = b });
    }
    return out.items;
}

const base: request.Request = .{ .model = "main", .system = &.{.{ .text = "system", .cache_break = true }}, .messages = &.{}, .tools = &.{.{ .name = "read_file", .description = "r", .input_schema_json = "{}" }} };

test "threshold trigger" {
    const turns = [_][]const ScriptedProvider.Step{};
    const s = try ScriptedProvider.init(testing.allocator, &turns, .all);
    const p = s.provider();
    defer p.deinit();
    const c: cmp.Compactor = .{ .provider = p, .model = &model };
    try testing.expectEqual(@as(?cmp.Trigger, null), c.shouldCompact(159_999, 200_000));
    try testing.expectEqual(cmp.Trigger.auto_threshold, c.shouldCompact(160_000, 200_000).?);
}

test "manual compaction with focus" {
    const turns = [_][]const ScriptedProvider.Step{sp.script.text("SUMMARY: auth refresh bug fixed; test pending.")};
    const s = try ScriptedProvider.init(testing.allocator, &turns, .all);
    const p = s.provider();
    defer p.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: cmp.Compactor = .{ .provider = p, .model = &model };
    const h = try history(a);
    const r = try c.compact(testing.io, a, &base, h, .{}, .{ .trigger = .manual, .focus = "the auth bug" });
    const req = s.requests()[0];
    try testing.expectEqual(request.ToolChoice.none, req.tool_choice);
    try testing.expectEqual(@as(u32, 8192), req.max_output_tokens);
    try testing.expectEqualStrings("system", req.system[0].text);
    const last = req.messages[req.messages.len - 1];
    try testing.expectEqual(proto.Role.user, last.role);
    try testing.expect(std.mem.indexOf(u8, last.content[last.content.len - 1].text.text, "Focus the summary on: the auth bug") != null);
    try testing.expectEqual(@as(usize, 1), r.messages.len);
    try testing.expectEqualStrings(asm_mod.compaction_marker, r.messages[0].content[0].text.text);
    try testing.expect(r.messages[0].meta.synthetic);
    try testing.expect(!r.fallback);
}

const memset: memory.MemorySet = .{ .files = &.{
    .{ .path = "/r/ZIGGURO.md", .scope = .project, .text = "Use zig build.\n", .version_hash = 1, .tokens = 4 },
    .{ .path = "/r/.zigguro/rules/t.md", .scope = .rule, .text = "Scoped.\n", .paths_globs = &.{"*.zig"}, .version_hash = 2, .tokens = 2 },
} };

test "re-injection contents (golden) and the five-file cap" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const turns = [_][]const ScriptedProvider.Step{};
    const s = try ScriptedProvider.init(testing.allocator, &turns, .all);
    const p = s.provider();
    defer p.deinit();
    const c: cmp.Compactor = .{ .provider = p, .model = &model };
    const huge = try a.alloc(u8, 30_000);
    @memset(huge, 'h');
    const text = try c.reinjection(a, .{
        .memory = &memset,
        .plan = "1. fix\n2. test",
        .skills = &.{.{ .name = "release", .description = "Cut a release" }},
        .todos = &.{ .{ .text = "fix", .status = .completed }, .{ .text = "test", .status = .in_progress } },
        .recent_files = &.{
            .{ .path = "src/a.zig", .text = "const a = 1;\n" },
            .{ .path = "src/huge.zig", .text = huge },
            .{ .path = "src/c.zig", .text = "c" },
            .{ .path = "src/d.zig", .text = null },
            .{ .path = "src/e.zig", .text = "e" },
            .{ .path = "src/sixth.zig", .text = "never" },
        },
        .background = &.{"zig build test (running 3m)"},
    });
    try testing.expect(std.mem.indexOf(u8, text, "sixth") == null);
    try testing.expect(std.mem.indexOf(u8, text, "Referenced file src/huge.zig") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Scoped.") == null);
    try zg_core.testkit.golden.expectGoldenOpts(testing.io, @src(), "reinjection", text, .{ .root = @import("zg_options").package_root, .dir = "testdata/context" });
}

test "range summaries: from and up to" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const turns = [_][]const ScriptedProvider.Step{ sp.script.text("S-from"), sp.script.text("S-to") };
    const s = try ScriptedProvider.init(testing.allocator, &turns, .all);
    const p = s.provider();
    defer p.deinit();
    var c: cmp.Compactor = .{ .provider = p, .model = &model };
    const h = try history(a);
    // From message 2: keep 0..1, summarize the rest.
    const from = try c.compact(testing.io, a, &base, h, .{}, .{ .trigger = .manual, .range = .{ .from = 2 } });
    try testing.expectEqual(@as(usize, 3), from.messages.len);
    try testing.expectEqualStrings("Fix the auth bug.", from.messages[0].content[0].text.text);
    try testing.expectEqualStrings("S-from", from.messages[2].content[1].text.text);
    // Up to message 3: summarize 0..3, keep 4..5.
    const to = try c.compact(testing.io, a, &base, h, .{}, .{ .trigger = .manual, .range = .{ .to = 3 } });
    try testing.expectEqual(@as(usize, 3), to.messages.len);
    try testing.expectEqualStrings("S-to", to.messages[0].content[1].text.text);
    try testing.expectEqualStrings("Now add a test.", to.messages[1].content[0].text.text);
    // The summarizer saw only messages 0..3 for "up to", plus the instruction.
    const req = s.requests()[1].messages;
    try testing.expectEqual(@as(usize, 5), req.len);
    try testing.expectEqual(.user, req[4].role);
}

test "failure falls back to clearing tool results" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const turns = [_][]const ScriptedProvider.Step{&.{.{ .fail = error.Overloaded }}};
    const s = try ScriptedProvider.init(testing.allocator, &turns, .all);
    const p = s.provider();
    defer p.deinit();
    var c: cmp.Compactor = .{ .provider = p, .model = &model, .cfg = .{ .keep_tool_results = 1 } };
    var h: std.ArrayList(proto.Message) = .empty;
    try h.appendSlice(a, try history(a));
    for (0..3) |i| {
        const parts = try a.alloc(proto.ResultPart, 1);
        parts[0] = .{ .text = try std.fmt.allocPrint(a, "output {d}", .{i}) };
        const b = try a.alloc(proto.ContentBlock, 1);
        b[0] = .{ .tool_result = .{ .tool_use_id = "t", .parts = parts } };
        try h.append(a, .{ .role = .user, .content = b });
    }
    const r = try c.compact(testing.io, a, &base, h.items, .{}, .{ .trigger = .auto_threshold });
    try testing.expect(r.fallback and r.warning != null);
    try testing.expectEqual(h.items.len, r.messages.len);
    try testing.expectEqualStrings(asm_mod.cleared_text, r.messages[6].content[0].tool_result.parts[0].text);
    try testing.expectEqualStrings("output 2", r.messages[8].content[0].tool_result.parts[0].text);
    // User messages survive.
    try testing.expectEqualStrings("Fix the auth bug.", r.messages[0].content[0].text.text);
}

test "PreCompact blocks automatic runs only" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const turns = [_][]const ScriptedProvider.Step{sp.script.text("S")};
    const s = try ScriptedProvider.init(testing.allocator, &turns, .all);
    const p = s.provider();
    defer p.deinit();
    const Hk = struct {
        posts: u32 = 0,
        fn pre(_: *anyopaque, _: std.Io, _: cmp.Trigger, _: ?[]const u8) anyerror!cmp.PreDecision {
            return .block;
        }
        fn post(ctx: *anyopaque, _: std.Io, _: cmp.Trigger, _: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.posts += 1;
        }
    };
    var hk: Hk = .{};
    var c: cmp.Compactor = .{ .provider = p, .model = &model, .hooks = .{ .ctx = &hk, .pre = Hk.pre, .post = Hk.post } };
    const h = try history(a);
    try testing.expectError(error.Blocked, c.compact(testing.io, a, &base, h, .{}, .{ .trigger = .auto_threshold }));
    _ = try c.compact(testing.io, a, &base, h, .{}, .{ .trigger = .manual });
    try testing.expectEqual(@as(u32, 1), hk.posts);
}

test "anthropic context editing encoding (golden)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ce: cmp.ContextEditing = .{ .clear_thinking = true, .clear_tool_uses = .{ .trigger_tokens = 30_000, .keep_tool_uses = 3, .exclude_tools = &.{"web_search"} } };
    var req: request.Request = .{ .model = "m", .messages = &.{} };
    try ce.apply(a, &req);
    try testing.expectEqualStrings("anthropic-beta", req.extra_headers[0].name);
    try testing.expectEqualStrings(cmp.ContextEditing.beta, req.extra_headers[0].value);
    try zg_core.testkit.golden.expectGoldenOpts(testing.io, @src(), "context_editing", req.extra_body_json.?, .{ .root = @import("zg_options").package_root, .dir = "testdata/context" });
}
