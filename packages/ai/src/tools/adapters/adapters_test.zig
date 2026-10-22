//! Tests for the subsystem tool adapters (E10.F06.S03.T01), with a fake
//! exporter per subsystem.

const std = @import("std");
const proto = @import("zg_ai_proto");
const golden = @import("zg_core").testkit.golden;
const registry = @import("../registry.zig");
const foreign = @import("foreign.zig");
const all = @import("all.zig");
const ratelimit = @import("../../provider/ratelimit.zig");

const testing = std.testing;
const io = testing.io;
const Allocator = std.mem.Allocator;

const schema = "{\"type\":\"object\"}";

/// One fake subsystem: lists `tools` and answers calls by tool name.
const Fake = struct {
    tools: []const foreign.ForeignTool,
    calls: u32 = 0,

    fn list(ctx: *anyopaque, _: Allocator) anyerror![]const foreign.ForeignTool {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        return f.tools;
    }

    fn call(ctx: *anyopaque, x: std.Io, _: Allocator, tool: []const u8, _: []const u8) anyerror!foreign.Result {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.calls += 1;
        if (std.mem.eql(u8, tool, "task_run")) {
            // Never answers; only the deadline ends it.
            var e: std.Io.Event = .unset;
            try e.wait(x);
        }
        if (std.mem.eql(u8, tool, "rename_symbol")) return .{ .json = "{\"content\":[{\"type\":\"text\",\"text\":\"Renamed 3 references.\"}]}", .changeset = 7 };
        if (std.mem.eql(u8, tool, "create_note")) return .{ .json = "{\"content\":[{\"type\":\"text\",\"text\":\"Created.\"}]}" };
        if (std.mem.eql(u8, tool, "scm_commit_proposal")) return .{ .json = "{\"content\":[{\"type\":\"text\",\"text\":\"no staged changes\"}],\"isError\":true}" };
        if (std.mem.eql(u8, tool, "search")) return .{ .json = "{\"content\":[{\"type\":\"text\",\"text\":\"2 hits\"},{\"type\":\"resource_link\",\"uri\":\"https://docs/x\",\"name\":\"x\"}],\"structuredContent\":{\"hits\":2}}" };
        if (std.mem.eql(u8, tool, "status")) return .{ .json = "{\"structuredContent\":{\"ok\":true}}" };
        if (std.mem.eql(u8, tool, "broken")) return .{ .json = "[1,2]" };
        return .{ .json = "{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}" };
    }

    fn exporter(f: *Fake, name: []const u8, kind: foreign.Kind, trusted: bool) foreign.Exporter {
        return .{ .name = name, .kind = kind, .trusted = trusted, .ctx = f, .list = list, .call = call };
    }
};

fn ro(name: []const u8) foreign.ForeignTool {
    return .{ .name = name, .description = name, .input_schema_json = schema, .read_only = true };
}

fn mut(name: []const u8) foreign.ForeignTool {
    return .{ .name = name, .description = name, .input_schema_json = schema, .mutates = true };
}

const World = struct {
    lsp: Fake = .{ .tools = &.{ ro("find_references"), ro("hover"), mut("rename_symbol") } },
    debug: Fake = .{ .tools = &.{ mut("debug_start"), ro("debug_stack") } },
    tasks: Fake = .{ .tools = &.{.{ .name = "task_run", .description = "task_run", .input_schema_json = schema }} },
    workspace: Fake = .{ .tools = &.{ ro("find_files"), ro("glob"), ro("grep"), ro("find_symbol"), ro("list_dir") } },
    notes: Fake = .{ .tools = &.{ ro("search_notes"), ro("read_note"), ro("note_links"), mut("create_note"), mut("update_note"), mut("daily_note") } },
    scm: Fake = .{ .tools = &.{ ro("scm_status"), ro("scm_diff"), ro("scm_log"), ro("scm_show"), mut("scm_commit_proposal"), mut("scm_branch") } },
    // Claims to be read-only, but the server is not trusted.
    github: Fake = .{ .tools = &.{
        .{ .name = "create_issue", .description = "", .input_schema_json = schema, .annotations = .{ .read_only_hint = true } },
        .{ .name = "broken", .description = "", .input_schema_json = schema, .annotations = .{ .read_only_hint = true } },
    } },
    docs: Fake = .{ .tools = &.{
        .{ .name = "search", .description = "", .input_schema_json = schema, .annotations = .{ .read_only_hint = true, .open_world_hint = false } },
        .{ .name = "status", .description = "", .input_schema_json = schema, .annotations = .{ .read_only_hint = true, .idempotent_hint = true } },
        .{ .name = "purge", .description = "", .input_schema_json = schema, .annotations = .{ .read_only_hint = true, .destructive_hint = true } },
    } },
    mcp: [2]foreign.Exporter = undefined,

    fn services(w: *World) all.Services {
        w.mcp = .{ w.github.exporter("github", .mcp, false), w.docs.exporter("docs", .mcp, true) };
        return .{
            .lsp = w.lsp.exporter("lsp", .lsp, true),
            .debug = w.debug.exporter("debug", .debug, true),
            .tasks = w.tasks.exporter("tasks", .tasks, true),
            .workspace = w.workspace.exporter("workspace", .workspace, true),
            .notes = w.notes.exporter("notes", .notes, true),
            .scm = w.scm.exporter("scm", .scm, true),
            .mcp = &w.mcp,
        };
    }
};

const Setup = struct {
    world: World = .{},
    reg: registry.ToolRegistry,
    adapters: all.Adapters,
    fake_clock: ratelimit.FakeClock = .init(0),
    arena: std.heap.ArenaAllocator,

    /// With `fake_time`, deadlines pass at once.
    fn init(s: *Setup, flags: all.AdapterFlags, fake_time: bool) !void {
        s.* = .{ .reg = .init(testing.allocator, io), .adapters = .init(testing.allocator, io), .arena = .init(testing.allocator) };
        const services = s.world.services();
        try s.adapters.registerAll(&s.reg, &services, flags, .{ .clock = if (fake_time) s.fake_clock.clock() else .real });
    }

    fn deinit(s: *Setup) void {
        s.reg.deinit();
        s.adapters.deinit();
        s.arena.deinit();
    }

    fn call(s: *Setup, name: []const u8, input: []const u8) !proto.ToolOutput {
        const g = try s.reg.snapshot();
        const spec = g.find(name) orelse return error.NoSuchTool;
        const a = s.arena.allocator();
        var c: proto.ToolCall = .{ .id = "toolu_1", .name = name, .input_json = input, .input = try std.json.parseFromSliceLeaky(std.json.Value, a, input, .{}), .arena = a, .io = io };
        return spec.handler.call(spec.handler.ctx, &c);
    }
};

test "registered_names_golden" {
    var s: Setup = undefined;
    try s.init(.{ .debug = true }, false);
    defer s.deinit();
    const g = try s.reg.snapshot();
    var out: std.Io.Writer.Allocating = .init(s.arena.allocator());
    for (g.specs) |t| {
        const e = t.effectiveEffects();
        try out.writer.print("{s} origin={s} read_only={} writes={} open_world={} idempotent={} permission={s}\n", .{
            t.name,
            switch (t.origin) {
                .builtin => "builtin",
                .mcp => |m| m,
                .extension => |x| x,
            },
            e.read_only,
            e.writes_workspace,
            e.open_world,
            e.idempotent,
            @tagName(t.permission),
        });
    }
    for (g.warnings) |w| try out.writer.print("warning: {s}\n", .{w});
    try golden.expectGoldenOpts(io, @src(), "registered", out.written(), .{ .root = @import("zg_options").package_root, .dir = "testdata/golden/tools/adapters" });
}

test "debug tools are off by default and missing subsystems register nothing" {
    var s: Setup = undefined;
    try s.init(.{}, false);
    defer s.deinit();
    const g = try s.reg.snapshot();
    try testing.expect(g.find("debug_start") == null);
    try testing.expect(g.find("grep") != null);

    var empty: all.Adapters = .init(testing.allocator, io);
    defer empty.deinit();
    var reg: registry.ToolRegistry = .init(testing.allocator, io);
    defer reg.deinit();
    try empty.registerAll(&reg, &.{}, .{}, .{});
    try testing.expectEqual(@as(usize, 0), (try reg.snapshot()).specs.len);
}

test "mcp_untrusted_annotations_treated_mutating" {
    var s: Setup = undefined;
    try s.init(.{}, false);
    defer s.deinit();
    const g = try s.reg.snapshot();
    const untrusted = g.find("mcp__github__create_issue").?.effectiveEffects();
    try testing.expect(!untrusted.read_only);
    try testing.expect(untrusted.writes_workspace);
    const trusted = g.find("mcp__docs__search").?.effectiveEffects();
    try testing.expect(trusted.read_only);
    try testing.expect(!trusted.open_world);
    // A destructive hint outweighs a read-only one.
    try testing.expect(!g.find("mcp__docs__purge").?.effectiveEffects().read_only);
}

test "mutating_exporter_without_changeset_fails_closed" {
    var s: Setup = undefined;
    try s.init(.{}, false);
    defer s.deinit();
    const bad = try s.call("create_note", "{\"title\":\"x\"}");
    try testing.expect(bad.is_error);
    try testing.expect(std.mem.indexOf(u8, bad.parts[0].text, "without a reviewable changeset") != null);
    try testing.expectEqual(@as(u32, 1), s.adapters.list.items[3].fail_closed.load(.monotonic));
    const ok = try s.call("rename_symbol", "{\"uri\":\"file:///a.zig\"}");
    try testing.expect(!ok.is_error);
    try testing.expectEqual(@as(u64, 7), ok.changeset.?.id);
    // An error result needs no changeset.
    const failed = try s.call("scm_commit_proposal", "{}");
    try testing.expect(failed.is_error);
    try testing.expectEqualStrings("no staged changes", failed.parts[0].text);
}

test "deadline_applied" {
    var s: Setup = undefined;
    try s.init(.{}, true);
    defer s.deinit();
    const o = try s.call("task_run", "{\"task\":\"build\"}");
    try testing.expect(o.is_error);
    try testing.expectEqualStrings("task_run did not answer within 120s.", o.parts[0].text);
    try testing.expectEqual(@as(u64, 120_000), s.fake_clock.slept_ms.load(.acquire));
}

test "mcp results map to parts" {
    var s: Setup = undefined;
    try s.init(.{}, false);
    defer s.deinit();
    const o = try s.call("mcp__docs__search", "{\"q\":\"x\"}");
    try testing.expectEqual(@as(usize, 2), o.parts.len);
    try testing.expectEqualStrings("2 hits", o.parts[0].text);
    try testing.expectEqualStrings("https://docs/x", o.parts[1].resource_link.uri);
    try testing.expectEqualStrings("{\"hits\":2}", o.structured_json.?);
    const st = try s.call("mcp__docs__status", "{}");
    try testing.expectEqualStrings("{\"ok\":true}", st.parts[0].text);
    const broken = try s.call("mcp__github__broken", "{}");
    try testing.expect(broken.is_error);
    try testing.expectEqualStrings("mcp__github__broken returned a result that is not an MCP CallToolResult.", broken.parts[0].text);
}
