//! Tests for `todo_write` (E10.F09.S02.T02).

const std = @import("std");
const proto = @import("zg_ai_proto");
const todos = @import("todos.zig");
const ev = @import("../loop/events.zig");
const resume_mod = @import("../session/resume.zig");
const ts = @import("../session/test_support.zig");
const th = @import("test_harness.zig");

const testing = std.testing;
const io = testing.io;
const script = th.script;

fn write(comptime list: []const u8) []const th.Step {
    return script.tools(&.{.{ "w", "todo_write", "{\"todos\":" ++ list ++ "}" }});
}

const two = "[{\"content\":\"Read the parser\",\"status\":\"completed\"},{\"content\":\"Rename parse\",\"status\":\"in_progress\",\"active_form\":\"Renaming parse\"}]";
const three = "[{\"content\":\"Read the parser\",\"status\":\"completed\"},{\"content\":\"Rename parse\",\"status\":\"completed\"},{\"id\":\"t9\",\"content\":\"Run tests\",\"status\":\"in_progress\"}]";

test "single_in_progress_enforced" {
    var h: th.Harness = undefined;
    try h.init(&.{
        write("[{\"content\":\"a\",\"status\":\"in_progress\"},{\"content\":\"b\",\"status\":\"in_progress\"}]"),
        script.text("Fixed."),
    }, null);
    defer h.deinit();
    try h.run("Go.");
    try testing.expect(h.isErrorIn(1));
    try testing.expectEqualStrings(todos.one_in_progress, h.resultIn(1));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try h.todos.snapshot(arena.allocator(), h.agent.ref)).len);
}

test "ids assigned and the summary names the current item" {
    var h: th.Harness = undefined;
    try h.init(&.{ write(three), script.text("Ok.") }, null);
    defer h.deinit();
    try h.run("Go.");
    try testing.expectEqualStrings("Todos updated: 2 of 3 done; now: Run tests.", h.resultIn(1));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const list = try h.todos.snapshot(arena.allocator(), h.agent.ref);
    try testing.expectEqualStrings("1", list[0].id);
    try testing.expectEqualStrings("2", list[1].id);
    try testing.expectEqualStrings("t9", list[2].id);
}

test "reminder_only_on_change" {
    var h: th.Harness = undefined;
    try h.init(&.{ write(two), write(two), write(three), script.text("Done.") }, null);
    defer h.deinit();
    var seen: Changes = .{};
    defer seen.last.deinit(testing.allocator);
    _ = try h.agent.subscribe(seen.sub());
    try h.run("Rename parse.");
    const reminder = "The todo list changed";
    try testing.expect(h.lastHas(1, reminder));
    try testing.expect(h.lastHas(1, "[~] Rename parse"));
    try testing.expect(!h.lastHas(2, reminder));
    try testing.expect(h.lastHas(3, reminder));
    try testing.expect(h.lastHas(3, "[~] Run tests"));
    // todo_changed only for real changes.
    try testing.expectEqual(@as(u32, 2), seen.n);
}

test "todos_persist_and_resume" {
    // The list a run publishes, recorded as the session writer does.
    var h: th.Harness = undefined;
    try h.init(&.{ write(two), script.text("Ok.") }, null);
    defer h.deinit();
    var seen: Changes = .{};
    defer seen.last.deinit(testing.allocator);
    _ = try h.agent.subscribe(seen.sub());
    try h.run("Go.");

    var f: ts.Fixture = undefined;
    try f.init(&.{});
    defer f.deinit();
    const id = try f.write("m", &.{
        .{ .user = f.msg(.user, "go") },
        ts.Fixture.event("todo_changed", "{\"todos\":[]}"),
        ts.Fixture.event("todo_changed", seen.last.items),
        .{ .assistant = f.msg(.assistant, "ok") },
    });
    var r = try resume_mod.resumeAgent(f.manager, io, id, .{}, .{ .store = &f.store, .config = .{ .model = "" } });
    defer r.deinit();
    defer f.manager.dispose(r.agent);

    var store: todos.TodoStore = .init(testing.allocator, io);
    defer store.deinit();
    try store.restore(r.agent.ref, r.state.todos_json.?);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const back = try store.snapshot(arena.allocator(), r.agent.ref);
    const orig = try h.todos.snapshot(arena.allocator(), h.agent.ref);
    try testing.expectEqualDeep(orig, back);
    try testing.expectEqualStrings("Renaming parse", back[1].active_form.?);
}

/// Counts `todo_changed` and keeps the last one as session JSON.
const Changes = struct {
    n: u32 = 0,
    last: std.ArrayList(u8) = .empty,

    fn sub(c: *Changes) @import("../loop/bus.zig").Subscriber {
        return .{ .ctx = c, .on_events = on, .mode = .inline_ };
    }

    fn on(ctx: *anyopaque, batch: []const ev.Envelope) void {
        const c: *Changes = @ptrCast(@alignCast(ctx));
        for (batch) |e| if (e.ev == .todo_changed) {
            c.n += 1;
            c.last.clearRetainingCapacity();
            var w: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &c.last);
            proto.json.encodeValue(&w.writer, .{ .todos = e.ev.todo_changed }) catch {};
            c.last = w.toArrayList();
        };
    }
};
