//! zg_scm agent tools through a stand-in for zg_ai's foreign-tool
//! contract.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const index_mod = @import("../graph/index.zig");
const mutable_mod = @import("../oplog/mutable_repo.zig");
const fx = @import("../oplog/test_fixture.zig");
const landing = @import("landing.zig");
const agent_tools = @import("agent_tools.zig");
const lt = @import("landing_test.zig");
const FakeReview = @import("testing/fake_review.zig").FakeReview;
const ObjectId = id_mod.ObjectId;
const Allocator = std.mem.Allocator;
const t = std.testing;
const gpa = t.allocator;

pub const Foreign = struct {
    pub const Kind = enum { lsp, debug, tasks, workspace, notes, scm, mcp };
    pub const Annotations = struct { title: ?[]const u8 = null };
    pub const ForeignTool = struct {
        name: []const u8,
        description: []const u8,
        input_schema_json: []const u8,
        read_only: bool = false,
        mutates: bool = false,
        annotations: Annotations = .{},
    };
    pub const Result = struct { json: []const u8, changeset: ?u64 = null };
    pub const Exporter = struct {
        name: []const u8,
        kind: Kind,
        trusted: bool = false,
        ctx: *anyopaque,
        list: *const fn (ctx: *anyopaque, arena: Allocator) anyerror![]const ForeignTool,
        call: *const fn (ctx: *anyopaque, io: std.Io, arena: Allocator, tool: []const u8, input_json: []const u8) anyerror!Result,
    };
};

const X = agent_tools.ToolExporter(Foreign);

const Parsed = struct {
    content: []const struct { type: []const u8, text: []const u8 },
    isError: bool,
};

fn callTool(e: Foreign.Exporter, arena: Allocator, tool: []const u8, input: []const u8) !Parsed {
    const r = try e.call(e.ctx, t.io, arena, tool, input);
    try t.expectEqual(@as(?u64, null), r.changeset);
    return std.json.parseFromSliceLeaky(Parsed, arena, r.json, .{});
}

fn contains(hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        std.debug.print("missing {s} in:\n{s}\n", .{ needle, hay });
        return error.TestExpectedSubstring;
    }
}

test "scm agent tools: log, show, status, op log and lane submit" {
    var f = try fx.Fixture.init(gpa);
    defer f.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const r0 = try f.initRepo();
    defer r0.close();
    const tx = try r0.startTransaction(fx.meta("setup"));
    const m = tx.mutRepo();
    const root = try lt.commit(m, &.{}, "root", &.{.{ "a.txt", "1" }});
    const c1 = try lt.commit(m, &.{root}, "add b\n\nBecause b.", &.{ .{ "a.txt", "2" }, .{ "b/x.zig", "1" } });
    var main: ?ObjectId = root;
    try m.setBookmark("main", fx.target(&main));
    try m.setWcCommit("default", c1);
    try lt.addLane(m, "l1", "default", root, c1, "");
    const r1 = try tx.commit();
    defer r1.close();

    var ix_dir = try f.tmp.dir.createDirPathOpen(f.io, "index", .{});
    defer ix_dir.close(f.io);
    const ix = try index_mod.CommitIndex.open(gpa, f.io, ix_dir, f.store, .{ .fsync = false });
    defer ix.close();
    var review = FakeReview.init(gpa, .pending);
    defer review.deinit();
    var q = landing.LandingQueue.init(gpa, r1, .{ .review = review.port() });
    defer q.deinit();

    var x: X = .{ .src = .{ .gpa = gpa, .io = f.io, .repo_dir = f.tmp.dir, .store = f.store, .index = ix, .landing = &q } };
    const e = x.exporter();
    try t.expectEqual(Foreign.Kind.scm, e.kind);
    const tools = try e.list(e.ctx, arena);
    try t.expectEqual(@as(usize, 5), tools.len);
    for (tools) |tool| {
        try t.expect(!tool.mutates);
        _ = try std.json.parseFromSliceLeaky(std.json.Value, arena, tool.input_schema_json, .{});
    }

    var res = try callTool(e, arena, "scm_log", "{}");
    try t.expect(!res.isError);
    try contains(res.content[0].text, "add b");
    try contains(res.content[0].text, "root");

    res = try callTool(e, arena, "scm_log", "{\"revset\":\"main\"}");
    try t.expect(!res.isError);
    try t.expect(std.mem.indexOf(u8, res.content[0].text, "add b") == null);

    // No change here has agent lines.
    res = try callTool(e, arena, "scm_log", "{\"revset\":\"human()\"}");
    try t.expect(!res.isError);
    try contains(res.content[0].text, "add b");
    res = try callTool(e, arena, "scm_log", "{\"revset\":\"agent()\"}");
    try t.expect(!res.isError);
    try t.expect(std.mem.indexOf(u8, res.content[0].text, "add b") == null);

    res = try callTool(e, arena, "scm_log", "{\"revset\":\"nonsense((\"}");
    try t.expect(res.isError);
    try contains(res.content[0].text, "Revset");

    res = try callTool(e, arena, "scm_show", "{\"rev\":\"@\"}");
    try t.expect(!res.isError);
    try contains(res.content[0].text, "Because b.");
    try contains(res.content[0].text, "M a.txt");
    try contains(res.content[0].text, "A b/x.zig");

    res = try callTool(e, arena, "scm_show", "{\"rev\":\"::@\"}");
    try t.expect(res.isError);

    res = try callTool(e, arena, "scm_status", "");
    try contains(res.content[0].text, "working copy (default)");
    try contains(res.content[0].text, "l1 (default, owner agent-7): active");

    res = try callTool(e, arena, "scm_lane_submit", "{\"lane\":\"l1\"}");
    try t.expect(!res.isError);
    try contains(res.content[0].text, "in_review");
    try t.expectEqual(@as(usize, 1), review.items.items.len);

    res = try callTool(e, arena, "scm_status", "{}");
    try contains(res.content[0].text, "awaiting_review, ticket 1 in_review");

    res = try callTool(e, arena, "scm_lane_submit", "{\"lane\":\"nope\"}");
    try t.expect(res.isError);
    res = try callTool(e, arena, "scm_log", "{\"limit\":\"x\"}");
    try t.expect(res.isError);

    res = try callTool(e, arena, "scm_op_log", "{\"limit\":3}");
    try contains(res.content[0].text, "submit lane for landing");
    try contains(res.content[0].text, "setup");
}
