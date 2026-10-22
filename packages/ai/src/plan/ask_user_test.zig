//! Tests for `ask_user` (E10.F09.S02.T02).

const std = @import("std");
const proto = @import("zg_ai_proto");
const golden = @import("zg_core").testkit.golden;
const ask_user = @import("ask_user.zig");
const ev = @import("../loop/events.zig");
const th = @import("test_harness.zig");

const testing = std.testing;
const io = testing.io;
const script = th.script;

const ask_db = script.tools(&.{.{ "q1", "ask_user", "{\"questions\":[{\"question\":\"Which database?\",\"header\":\"Storage\",\"options\":[{\"label\":\"SQLite\",\"description\":\"One file\"},{\"label\":\"Postgres\"}]}]}" }});

/// Answers the first open ticket from another task, like the UI.
fn answerWhenAsked(q: *ask_user.AskQueue, answers: []const ask_user.Answer) void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    while (true) {
        const open = q.pending(arena.allocator()) catch return;
        if (open.len > 0) {
            _ = q.answer(open[0].id, answers) catch return;
            return;
        }
        io.sleep(.fromMilliseconds(1), .awake) catch return;
    }
}

test "ask_user_ui_answer" {
    var q: ask_user.AskQueue = .init(testing.allocator, io);
    defer q.deinit();
    var h: th.Harness = undefined;
    try h.init(&.{ ask_db, script.text("Using SQLite.") }, q.asker());
    defer h.deinit();
    var seen: Seen = .{};
    defer seen.out.deinit(testing.allocator);
    _ = try h.agent.subscribe(seen.sub());

    var ui = try io.concurrent(answerWhenAsked, .{ &q, &[_]ask_user.Answer{.{ .question = "Which database?", .selected = &.{"SQLite"}, .other = "keep it in .zigguro" }} });
    try h.run("Add storage.");
    ui.await(io);

    try testing.expect(!h.isErrorIn(1));
    try testing.expectEqualStrings("The user answered:\n- Which database? → SQLite; in their own words: keep it in .zigguro", h.resultIn(1));
    try testing.expectEqualStrings("question q1 Which database?\n", seen.out.items);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try q.pending(arena.allocator())).len);
}

test "ask_user_noninteractive_error_and_removed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var h: th.Harness = undefined;
    try h.init(&.{ ask_db, script.text("Assuming SQLite.") }, null);
    defer h.deinit();
    try testing.expectEqualStrings("todo_write", try h.names(arena.allocator()));
    try h.run("Add storage.");
    // A call made anyway is answered with the fallback instruction.
    try testing.expect(h.isErrorIn(1));
    try testing.expect(std.mem.startsWith(u8, h.resultIn(1), "Unknown tool: ask_user"));

    var direct: ask_user.AskUserTool = .{ .asker = null };
    var c: proto.ToolCall = .{ .id = "x", .name = "ask_user", .input_json = "{}", .input = .null, .arena = arena.allocator(), .io = io };
    const out = try direct.specs()[0].handler.call(&direct, &c);
    try testing.expect(out.is_error);
    try testing.expectEqualStrings(ask_user.no_user, out.parts[0].text);
}

test "ask_user_cancel" {
    var q: ask_user.AskQueue = .init(testing.allocator, io);
    defer q.deinit();
    var h: th.Harness = undefined;
    try h.init(&.{ ask_db, script.text("never") }, q.asker());
    defer h.deinit();
    _ = try h.agent.submit(.{ .text = "Add storage." });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    while ((try q.pending(arena.allocator())).len == 0) try io.sleep(.fromMilliseconds(1), .awake);
    h.agent.cancel(.turn);
    h.agent.waitIdle();
    try testing.expectEqual(@as(usize, 0), (try q.pending(arena.allocator())).len);
    try testing.expectEqual(@as(usize, 1), h.sp.requests().len);
}

test "ask_user timeout and dismiss" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var q: ask_user.AskQueue = .init(testing.allocator, io);
    defer q.deinit();
    q.timeout_ms = 5;
    const req: ask_user.Request = .{ .id = "a", .agent = .{ .session = 1 }, .questions = &.{} };
    try testing.expectEqual(ask_user.Reply.timed_out, try q.asker().ask(&q, io, arena.allocator(), req));
    q.close();
    try testing.expectEqual(ask_user.Reply.unavailable, try q.asker().ask(&q, io, arena.allocator(), req));
}

test "cli asker rendering and choices" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const questions = [_]ask_user.Question{
        .{ .question = "Which database?", .header = "Storage", .options = &.{ .{ .label = "SQLite", .description = "One file" }, .{ .label = "Postgres" } } },
        .{ .question = "Which features?", .multi_select = true, .options = &.{ .{ .label = "Search" }, .{ .label = "Sync" }, .{ .label = "Export" } } },
    };
    var in: std.Io.Reader = .fixed("9\n3\nDuckDB\n1, 3\n");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var cli: ask_user.CliAsker = .{ .in = &in, .out = &out.writer };
    const a = cli.asker();
    const reply = try a.ask(a.ctx, io, arena.allocator(), .{ .id = "q", .agent = .{ .session = 1, .agent = 2 }, .label = "explore", .questions = &questions });
    try testing.expectEqualStrings("DuckDB", reply.answered[0].other.?);
    try testing.expectEqual(@as(usize, 0), reply.answered[0].selected.len);
    try testing.expectEqualStrings("Search", reply.answered[1].selected[0]);
    try testing.expectEqualStrings("Export", reply.answered[1].selected[1]);
    try golden.expectGoldenOpts(io, @src(), "cli_ask", out.written(), .{ .root = @import("zg_options").package_root, .dir = "testdata/plan" });
}

/// Records `approval_needed` as `kind id question`.
const Seen = struct {
    out: std.ArrayList(u8) = .empty,

    fn sub(s: *Seen) @import("../loop/bus.zig").Subscriber {
        return .{ .ctx = s, .on_events = on, .mode = .inline_ };
    }

    fn on(ctx: *anyopaque, batch: []const ev.Envelope) void {
        const s: *Seen = @ptrCast(@alignCast(ctx));
        for (batch) |e| if (e.ev == .approval_needed) {
            const x = e.ev.approval_needed;
            const q = if (std.mem.indexOf(u8, x.json, "Which database?") != null) "Which database?" else "?";
            s.out.print(testing.allocator, "{s} {s} {s}\n", .{ @tagName(x.kind), x.id, q }) catch {};
        };
    }
};
