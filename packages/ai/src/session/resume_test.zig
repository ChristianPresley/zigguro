//! Tests for resume.zig (E10.F08.S02.T01).

const std = @import("std");
const proto = @import("zg_ai_proto");
const records = @import("records.zig");
const loader = @import("loader.zig");
const resume_mod = @import("resume.zig");
const ts = @import("test_support.zig");

const testing = std.testing;
const io = ts.io;
const Fixture = ts.Fixture;

const Names = struct {
    fn exists(_: *anyopaque, name: []const u8) bool {
        return std.mem.eql(u8, name, "reviewer");
    }
};
var names_ctx: u8 = 0;
const resolver: resume_mod.AgentResolver = .{ .ctx = &names_ctx, .exists = Names.exists };

test "resume restores model, mode and agent" {
    var f: Fixture = undefined;
    try f.init(&.{ts.script.text("Second answer.")});
    defer f.deinit();
    const id = try f.write("m", &.{
        .{ .user = f.msg(.user, "first question") },
        .{ .assistant = f.msg(.assistant, "first answer") },
        Fixture.event("model_change", "{\"model\":\"m2\"}"),
        Fixture.event("mode", "{\"mode\":\"accept_edits\"}"),
        Fixture.event("agent", "{\"name\":\"reviewer\"}"),
        Fixture.event("task_started", "{\"id\":\"b1\",\"command\":\"zig build --watch\"}"),
        Fixture.event("task_started", "{\"id\":\"b2\",\"command\":\"make\"}"),
        Fixture.event("task_finished", "{\"id\":\"b2\"}"),
        .{ .title = "Questions" },
    });
    var r = try resume_mod.resumeAgent(f.manager, io, id, .{}, .{ .store = &f.store, .config = .{ .model = "" }, .resolver = resolver });
    try testing.expectEqual(id, r.agent.ref.session);
    try testing.expectEqualStrings("m2", r.agent.cfg.model);
    try testing.expectEqual(resume_mod.PermissionMode.accept_edits, r.state.mode);
    try testing.expectEqualStrings("reviewer", r.state.agent.?);
    try testing.expectEqualStrings("Questions", r.state.title.?);
    try testing.expectEqual(@as(usize, 1), r.state.notes.len);
    try testing.expect(std.mem.indexOf(u8, r.state.notes[0], "zig build --watch") != null);
    try testing.expectEqual(@as(usize, 2), r.agent.messages().len);
    try testing.expectEqual(@as(u64, 9), r.state.last_seq);

    // The conversation continues with the restored history; new records
    // get later sequence numbers.
    _ = try r.agent.submit(.{ .text = "second question" });
    r.agent.waitIdle();
    try testing.expectEqual(@as(usize, 4), r.agent.messages().len);
    try testing.expectEqualStrings("first question", ts.firstText(f.sp.requests()[0].messages[0]));
    try testing.expectEqualStrings("m2", f.sp.requests()[0].model);
    try testing.expect(r.agent.messageSeq(2) > 9);
    f.manager.dispose(r.agent);
    r.deinit();

    // A second resume sees all four messages; overrides win.
    var r2 = try resume_mod.resumeAgent(f.manager, io, id, .{ .model_override = "m", .mode_override = .plan }, .{ .store = &f.store, .config = .{ .model = "" } });
    defer r2.deinit();
    defer f.manager.dispose(r2.agent);
    try testing.expectEqual(@as(usize, 4), r2.agent.messages().len);
    try testing.expectEqualStrings("second question", ts.firstText(r2.agent.messages()[2]));
    try testing.expectEqualStrings("m", r2.agent.cfg.model);
    try testing.expectEqual(resume_mod.PermissionMode.plan, r2.state.mode);
}

test "bypass not restored, plan restored" {
    var f: Fixture = undefined;
    try f.init(&.{});
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { mode: []const u8, fork: bool, want: resume_mod.PermissionMode, warn: bool }{
        .{ .mode = "bypass_permissions", .fork = false, .want = .default, .warn = true },
        .{ .mode = "plan", .fork = false, .want = .plan, .warn = false },
        .{ .mode = "plan", .fork = true, .want = .default, .warn = false },
        .{ .mode = "accept_edits", .fork = true, .want = .accept_edits, .warn = false },
    };
    for (cases) |c| {
        const data = try std.fmt.allocPrint(a, "{{\"mode\":\"{s}\"}}", .{c.mode});
        const id = try f.write("m", &.{ .{ .user = f.msg(.user, "hi") }, Fixture.event("mode", data), Fixture.event("agent", "{\"name\":\"gone\"}") });
        const l = try f.store.open(io, id, .{ .mode = .full });
        defer l.deinit();
        const st = try resume_mod.restore(a, l, true, .{ .fork = c.fork }, resolver);
        try testing.expectEqual(c.want, st.mode);
        // The missing agent definition always warns.
        try testing.expectEqual(@as(usize, if (c.warn) 2 else 1), st.warnings.len);
        try testing.expectEqual(@as(?[]const u8, null), st.agent);
    }
}

test "resume marks interrupted tool calls" {
    var f: Fixture = undefined;
    try f.init(&.{});
    defer f.deinit();
    const id = try f.write("m", &.{
        .{ .user = f.msg(.user, "read a.zig") },
        .{ .assistant = .{ .role = .assistant, .content = &.{.{ .tool_use = .{ .id = "t1", .name = "read", .input_json = "{}" } }} } },
    });
    var r = try resume_mod.resumeAgent(f.manager, io, id, .{}, .{ .store = &f.store, .config = .{ .model = "" } });
    const msgs = r.agent.messages();
    try testing.expectEqual(@as(usize, 3), msgs.len);
    try testing.expect(msgs[2].meta.interrupted);
    try testing.expect(msgs[2].content[0].tool_result.is_error);
    try testing.expectEqualStrings(loader.interrupted_text, msgs[2].content[0].tool_result.parts[0].text);
    try testing.expectEqual(@as(u64, 3), r.agent.messageSeq(2));
    f.manager.dispose(r.agent);
    r.deinit();
    // The results were written: the next load has nothing to synthesize.
    const l = try f.store.open(io, id, .{ .mode = .full });
    defer l.deinit();
    try testing.expectEqual(@as(?proto.Message, null), l.interrupted);
    try testing.expect(l.tail[l.tail.len - 1].record == .tool_results);
}

test "resume reads from the latest compaction, and past it after a rewind" {
    var f: Fixture = undefined;
    try f.init(&.{});
    defer f.deinit();
    const id = try f.write("m", &.{
        .{ .user = f.msg(.user, "old question") }, // 1
        .{ .assistant = f.msg(.assistant, "old answer") }, // 2
        .{ .compaction = .{ .head_seq = 4, .trigger = "manual" } }, // 3
        .{ .user = f.msg(.user, "summary") }, // 4
        .{ .assistant = f.msg(.assistant, "ok") }, // 5
        .{ .user = f.msg(.user, "new question") }, // 6
    });
    {
        var r = try resume_mod.resumeAgent(f.manager, io, id, .{}, .{ .store = &f.store, .config = .{ .model = "" } });
        defer r.deinit();
        defer f.manager.dispose(r.agent);
        var buf: [8]u8 = undefined;
        try testing.expectEqualStrings("uau", ts.roles(&buf, r.agent.messages()));
        try testing.expectEqualStrings("summary", ts.firstText(r.agent.messages()[0]));
    }
    // A rewind to before the compaction undoes it.
    {
        const w = try f.store.reopen(io, id, 6);
        defer w.close();
        try w.append(7, .{ .rewind = .{ .to_seq = 1, .action = "conversation" } });
    }
    var r = try resume_mod.resumeAgent(f.manager, io, id, .{}, .{ .store = &f.store, .config = .{ .model = "" } });
    defer r.deinit();
    defer f.manager.dispose(r.agent);
    try testing.expectEqual(@as(usize, 1), r.agent.messages().len);
    try testing.expectEqualStrings("old question", ts.firstText(r.agent.messages()[0]));
}

test "resume after a compaction in the loop" {
    var f: Fixture = undefined;
    try f.init(&.{ ts.script.text("First."), ts.script.text("Second.") });
    defer f.deinit();
    const Fake = struct {
        var armed = false;
        fn should(_: *anyopaque, _: u64, _: u32) bool {
            return armed;
        }
        fn compact(_: *anyopaque, _: std.Io, arena: std.mem.Allocator, _: *const @import("../provider/request.zig").Request, history: []const proto.Message, _: bool) anyerror!@import("../loop/deps.zig").CompactedHistory {
            armed = false;
            const out = try arena.alloc(proto.Message, 3);
            const b = try arena.alloc(proto.ContentBlock, 1);
            b[0] = .{ .text = .{ .text = "SUMMARY" } };
            out[0] = .{ .role = .user, .content = b, .meta = .{ .synthetic = true } };
            const k = try arena.alloc(proto.ContentBlock, 1);
            k[0] = .{ .text = .{ .text = "ok" } };
            out[1] = .{ .role = .assistant, .content = k, .meta = .{ .synthetic = true } };
            out[2] = history[history.len - 1];
            return .{ .messages = out, .tokens_before = 100, .tokens_after = 10, .model = "s" };
        }
    };
    var dummy: u8 = 0;
    var d = f.deps();
    d.compaction = .{ .ctx = &dummy, .should_compact = Fake.should, .compact = Fake.compact };
    const live = try f.liveAgent(d);
    _ = try live.agent.submit(.{ .text = "one" });
    live.agent.waitIdle();
    Fake.armed = true;
    _ = try live.agent.submit(.{ .text = "two" });
    live.agent.waitIdle();
    try testing.expectEqual(@as(usize, 4), live.agent.messages().len);
    const id = live.agent.ref.session;
    f.manager.dispose(live.agent);
    live.writer.close();

    // The file holds the compaction record; a resume reads only the new history.
    const l = try f.store.open(io, id, .{});
    defer l.deinit();
    try testing.expect(l.tail[0].record == .compaction);
    var r = try resume_mod.resumeAgent(f.manager, io, id, .{}, .{ .store = &f.store, .config = .{ .model = "" } });
    defer r.deinit();
    defer f.manager.dispose(r.agent);
    const msgs = r.agent.messages();
    try testing.expectEqual(@as(usize, 4), msgs.len);
    try testing.expectEqualStrings("SUMMARY", ts.firstText(msgs[0]));
    try testing.expectEqualStrings("two", ts.firstText(msgs[2]));
    try testing.expectEqualStrings("Second.", ts.firstText(msgs[3]));
}
