//! Tests for registry.zig, toolset.zig and search_tools.zig
//! (E10.F06.S01.T01).

const std = @import("std");
const proto = @import("zg_ai_proto");
const registry = @import("registry.zig");
const toolset = @import("toolset.zig");
const search_tools = @import("search_tools.zig");

const testing = std.testing;
const io = testing.io;
const ToolSpec = proto.ToolSpec;

const Noop = struct {
    var dummy: u8 = 0;
    fn call(_: *anyopaque, c: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
        return proto.ToolOutput.text(c.arena, "ok", false) catch error.OutOfMemory;
    }
    fn spec(name: []const u8, read_only: bool) ToolSpec {
        return .{ .name = name, .description = name, .input_schema_json = "{\"type\":\"object\"}", .read_only = read_only, .handler = .{ .ctx = &dummy, .call = call } };
    }
};

/// A source whose tool list tests can change.
const FakeSource = struct {
    specs: []const ToolSpec,
    cb: ?registry.ChangedCb = null,

    fn list(ctx: *anyopaque, gpa: std.mem.Allocator, out: *std.ArrayList(ToolSpec)) anyerror!void {
        const f: *FakeSource = @ptrCast(@alignCast(ctx));
        try out.appendSlice(gpa, f.specs);
    }

    fn subscribe(ctx: *anyopaque, cb: registry.ChangedCb) void {
        const f: *FakeSource = @ptrCast(@alignCast(ctx));
        f.cb = cb;
    }

    fn source(f: *FakeSource, name: []const u8, kind: registry.SourceKind) registry.ToolSource {
        return .{ .name = name, .ctx = f, .list = list, .subscribe_changed = subscribe, .kind = kind };
    }

    fn set(f: *FakeSource, specs: []const ToolSpec) void {
        f.specs = specs;
        if (f.cb) |cb| cb.changed(cb.ctx);
    }
};

fn names(a: std.mem.Allocator, specs: []const ToolSpec) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (specs, 0..) |s, i| {
        if (i > 0) try out.append(a, ' ');
        try out.appendSlice(a, s.name);
    }
    return out.items;
}

test "namespacing and collisions" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var reg: registry.ToolRegistry = .init(testing.allocator, io);
    defer reg.deinit();
    var b: FakeSource = .{ .specs = &.{ Noop.spec("read_file", true), Noop.spec("bad name!", true) } };
    var lsp: FakeSource = .{ .specs = &.{ Noop.spec("definition", true), Noop.spec("read_file", true) } };
    var lsp2: FakeSource = .{ .specs = &.{Noop.spec("definition", true)} };
    var gh: FakeSource = .{ .specs = &.{ Noop.spec("search", true), Noop.spec("create issue", false) } };
    var gh2: FakeSource = .{ .specs = &.{Noop.spec("search", true)} };
    try reg.addSource(b.source("builtin", .builtin));
    var lsp_src = lsp.source("lsp", .package);
    lsp_src.namespace = "lsp_";
    try reg.addSource(lsp_src);
    var lsp2_src = lsp2.source("lsp2", .package);
    lsp2_src.namespace = "lsp_";
    try reg.addSource(lsp2_src);
    try reg.addSource(gh.source("git hub", .mcp));
    // A second server whose sanitized name collides with the first.
    try reg.addSource(gh2.source("git/hub", .mcp));
    const g = try reg.snapshot();
    try testing.expectEqualStrings(
        "read_file lsp_definition lsp_read_file mcp__git_hub__create_issue mcp__git_hub__search",
        try names(arena.allocator(), g.specs),
    );
    try testing.expectEqualStrings("create issue", reg.originalName("mcp__git_hub__create_issue").?);
    try testing.expectEqualStrings("git hub", g.find("mcp__git_hub__search").?.origin.mcp);
    // The bad built-in name and the two collisions are reported.
    try testing.expectEqual(@as(usize, 3), g.warnings.len);
    try testing.expect(std.mem.indexOf(u8, g.warnings[0], "invalid name") != null);
    try testing.expect(std.mem.indexOf(u8, g.warnings[1], "lsp_definition from lsp2") != null);
    try testing.expect(std.mem.indexOf(u8, g.warnings[2], "mcp__git_hub__search from git/hub") != null);
}

test "long mcp name hashed and reversible" {
    var reg: registry.ToolRegistry = .init(testing.allocator, io);
    defer reg.deinit();
    const long = "a_very_long_tool_name_that_goes_on_and_on_past_the_provider_limit";
    var src: FakeSource = .{ .specs = &.{ Noop.spec(long, true), Noop.spec(long ++ "_2", true) } };
    try reg.addSource(src.source("server", .mcp));
    const g = try reg.snapshot();
    try testing.expectEqual(@as(usize, 2), g.specs.len);
    for (g.specs) |s| {
        try testing.expect(registry.validName(s.name));
        try testing.expectEqual(@as(usize, 64), s.name.len);
        try testing.expect(std.mem.startsWith(u8, s.name, "mcp__server__a_very_long"));
        try testing.expect(std.mem.startsWith(u8, reg.originalName(s.name).?, long));
    }
    try testing.expect(!std.mem.eql(u8, g.specs[0].name, g.specs[1].name));
}

test "ordering and stable hash" {
    var reg: registry.ToolRegistry = .init(testing.allocator, io);
    defer reg.deinit();
    var b: FakeSource = .{ .specs = &.{ Noop.spec("read_file", true), Noop.spec("edit_file", false), Noop.spec("run_command", false) } };
    var pkg: FakeSource = .{ .specs = &.{Noop.spec("scm_status", true)} };
    var z: FakeSource = .{ .specs = &.{ Noop.spec("b", true), Noop.spec("a", true) } };
    var y: FakeSource = .{ .specs = &.{Noop.spec("c", true)} };
    // Registration order differs from the result order for MCP and kinds.
    try reg.addSource(z.source("zeta", .mcp));
    try reg.addSource(pkg.source("scm", .package));
    try reg.addSource(y.source("alpha", .mcp));
    try reg.addSource(b.source("builtin", .builtin));
    var at: toolset.AgentTools = .init(testing.allocator, io, &reg, .{});
    defer at.deinit();
    const t = try at.refresh();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("read_file edit_file run_command scm_status mcp__alpha__c mcp__zeta__a mcp__zeta__b", try names(arena.allocator(), t.specs));
    // The hash only depends on the configuration (golden across runs).
    try testing.expectEqual(@as(u64, 0xf52b804c779f8410), t.hash);
    try testing.expectEqual(t, try at.refresh());
}

test "deny removes the tool" {
    var reg: registry.ToolRegistry = .init(testing.allocator, io);
    defer reg.deinit();
    var b: FakeSource = .{ .specs = &.{ Noop.spec("read_file", true), Noop.spec("run_command", false) } };
    var gh: FakeSource = .{ .specs = &.{ Noop.spec("search", true), Noop.spec("merge", false) } };
    try reg.addSource(b.source("builtin", .builtin));
    try reg.addSource(gh.source("gh", .mcp));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { allow: []const []const u8, deny: []const []const u8, want: []const u8 }{
        .{ .allow = &.{"*"}, .deny = &.{"run_command"}, .want = "read_file mcp__gh__merge mcp__gh__search" },
        .{ .allow = &.{"*"}, .deny = &.{"mcp__gh__*"}, .want = "read_file run_command" },
        .{ .allow = &.{ "read_file", "mcp__gh__*" }, .deny = &.{"mcp__gh__merge"}, .want = "read_file mcp__gh__search" },
        .{ .allow = &.{"run*"}, .deny = &.{"run*"}, .want = "" },
    };
    for (cases) |c| {
        var at: toolset.AgentTools = .init(testing.allocator, io, &reg, .{ .allow = c.allow, .deny = c.deny });
        defer at.deinit();
        const t = try at.refresh();
        try testing.expectEqualStrings(c.want, try names(arena.allocator(), t.specs));
        try testing.expectEqual(t.specs.len, t.decls.len);
    }
}

test "plan mode filter" {
    var reg: registry.ToolRegistry = .init(testing.allocator, io);
    defer reg.deinit();
    var b: FakeSource = .{ .specs = &.{ Noop.spec("read_file", true), Noop.spec("edit_file", false), Noop.spec("todo_write", false), Noop.spec("exit_plan_mode", false), Noop.spec("run_command", false) } };
    try reg.addSource(b.source("builtin", .builtin));
    var at: toolset.AgentTools = .init(testing.allocator, io, &reg, .{});
    at.warn_invalidations = false;
    defer at.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const tools = at.tools();
    try testing.expectEqual(@as(usize, 5), tools.list().len);
    at.setMode(.plan);
    try testing.expectEqualStrings("read_file todo_write exit_plan_mode run_command", try names(arena.allocator(), tools.list()));
    try testing.expectEqual(@as(?*const ToolSpec, null), tools.find("edit_file"));
    try testing.expectEqual(@as(u32, 1), at.invalidations);
    at.setMode(.default);
    try testing.expectEqual(@as(usize, 5), tools.list().len);
}

test "deferred threshold and promotion" {
    var reg: registry.ToolRegistry = .init(testing.allocator, io);
    defer reg.deinit();
    var b: FakeSource = .{ .specs = &.{Noop.spec("read_file", true)} };
    var deferred = [_]ToolSpec{
        Noop.spec("create_issue", false),
        Noop.spec("list_issues", true),
        Noop.spec("get_file", true),
    };
    for (&deferred) |*s| s.defer_loading = true;
    deferred[2].description = "Reads a file from a repository";
    var gh: FakeSource = .{ .specs = &deferred };
    try reg.addSource(b.source("builtin", .builtin));
    try reg.addSource(gh.source("gh", .mcp));
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Under the threshold nothing is deferred.
    {
        var at: toolset.AgentTools = .init(testing.allocator, io, &reg, .{});
        defer at.deinit();
        try testing.expectEqual(@as(usize, 4), at.tools().list().len);
    }

    var at: toolset.AgentTools = .init(testing.allocator, io, &reg, .{ .defer_threshold = 2, .include_deferred = &.{"mcp__gh__list_issues"} });
    at.warn_invalidations = false;
    defer at.deinit();
    const tools = at.tools();
    try testing.expectEqualStrings("read_file mcp__gh__list_issues tool_search", try names(a, tools.list()));
    const t = at.current().?;
    try testing.expectEqual(@as(usize, 2), t.deferred.len);

    // "cri" is a subsequence of create_issue; descriptions match too.
    try testing.expectEqualStrings("mcp__gh__create_issue", (try search_tools.search(a, t.deferred, "cri", 5))[0].name);
    try testing.expectEqualStrings("mcp__gh__get_file", (try search_tools.search(a, t.deferred, "repository", 5))[0].name);
    try testing.expectEqual(@as(usize, 0), (try search_tools.search(a, t.deferred, "zzz", 5)).len);

    // Calling tool_search promotes; the next request declares the tool.
    const search = tools.find("tool_search").?;
    var call: proto.ToolCall = .{ .id = "t1", .name = "tool_search", .input_json = "", .input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"query\":\"cri\"}", .{}), .arena = a, .io = io };
    const out = try search.handler.call(search.handler.ctx, &call);
    try testing.expect(!out.is_error);
    try testing.expect(std.mem.startsWith(u8, out.parts[0].text, "[{\"name\":\"mcp__gh__create_issue\",\"description\":\"create_issue\",\"input_schema\":{\"type\":\"object\"}}"));
    try testing.expectEqual(@as(?*const ToolSpec, null), tools.find("mcp__gh__create_issue"));
    try testing.expectEqualStrings("read_file mcp__gh__create_issue mcp__gh__list_issues tool_search", try names(a, tools.list()));
    try testing.expect(tools.find("mcp__gh__create_issue") != null);
    try testing.expectEqual(@as(u32, 1), at.invalidations);
}

test "list_changed rebuilds between requests" {
    var reg: registry.ToolRegistry = .init(testing.allocator, io);
    defer reg.deinit();
    var gh: FakeSource = .{ .specs = &.{Noop.spec("search", true)} };
    try reg.addSource(gh.source("gh", .mcp));
    var at: toolset.AgentTools = .init(testing.allocator, io, &reg, .{});
    at.warn_invalidations = false;
    defer at.deinit();
    const tools = at.tools();
    try testing.expectEqual(@as(usize, 1), tools.list().len);
    const first = at.current().?;

    // A change mid-request is not seen until the next list().
    gh.set(&.{ Noop.spec("search", true), Noop.spec("merge", false) });
    try testing.expect(tools.find("mcp__gh__search") != null);
    try testing.expectEqual(@as(?*const ToolSpec, null), tools.find("mcp__gh__merge"));
    try testing.expectEqual(first, at.current().?);
    // The old toolset is still valid.
    try testing.expectEqualStrings("mcp__gh__search", first.specs[0].name);

    try testing.expectEqual(@as(usize, 2), tools.list().len);
    try testing.expect(tools.find("mcp__gh__merge") != null);
    try testing.expectEqual(@as(u32, 1), at.invalidations);
    try testing.expect(first.hash != at.current().?.hash);
}
