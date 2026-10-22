//! Tests for rewind.zig (E10.F08.S02.T01).

const std = @import("std");
const proto = @import("zg_ai_proto");
const records = @import("records.zig");
const rewind_mod = @import("rewind.zig");
const resume_mod = @import("resume.zig");
const compactor = @import("../context/compactor.zig");
const request = @import("../provider/request.zig");
const registry = @import("../models/registry.zig");
const scripted = @import("../provider/scripted.zig");
const deps_mod = @import("../loop/deps.zig");
const ts = @import("test_support.zig");

const testing = std.testing;
const io = ts.io;
const Fixture = ts.Fixture;

const two_turns = [_][]const ts.Step{ ts.script.text("First answer."), ts.script.text("Second answer.") };

/// Fake E12: numbered checkpoints, a restore that reports what it did.
const FakeE12 = struct {
    next: u64 = 100,
    labels: std.ArrayList([]const u8) = .empty,
    restored: ?u64 = null,

    fn checkpoints(e: *FakeE12) deps_mod.Checkpoints {
        return .{ .ctx = e, .create = create };
    }

    fn create(ctx: *anyopaque, _: std.Io, _: proto.AgentRef, _: u32, label: []const u8) u64 {
        const e: *FakeE12 = @ptrCast(@alignCast(ctx));
        e.labels.append(testing.allocator, testing.allocator.dupe(u8, label) catch "") catch {};
        defer e.next += 1;
        return e.next;
    }

    fn restore(e: *FakeE12) rewind_mod.CheckpointRestore {
        return .{ .ctx = e, .restore_to = restoreTo };
    }

    fn restoreTo(ctx: *anyopaque, _: std.Io, _: std.mem.Allocator, id: u64) anyerror!rewind_mod.RestoreOutcome {
        const e: *FakeE12 = @ptrCast(@alignCast(ctx));
        e.restored = id;
        return .{
            .restored_files = &.{"src/a.zig"},
            .untracked_changes = &.{"build/out.txt"},
            .skipped = &.{.{ .path = "link.zig", .reason = "symlink" }},
        };
    }

    fn deinit(e: *FakeE12) void {
        for (e.labels.items) |l| testing.allocator.free(l);
        e.labels.deinit(testing.allocator);
    }
};

test "rewind conversation only" {
    var f: Fixture = undefined;
    try f.init(&two_turns);
    defer f.deinit();
    const live = try f.liveAgent(f.deps());
    const a = live.agent;
    _ = try a.submit(.{ .text = "first question" });
    a.waitIdle();
    _ = try a.submit(.{ .text = "second question" });
    a.waitIdle();
    try testing.expectEqual(@as(usize, 4), a.messages().len);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // A rewind targets a user prompt.
    try testing.expectError(error.InvalidTarget, rewind_mod.rewind(a, io, arena.allocator(), .{ .index = 1 }, .conversation, null, .{ .log = live.writer }));
    const rep = try rewind_mod.rewind(a, io, arena.allocator(), .{ .index = 2 }, .conversation, null, .{ .log = live.writer });
    try testing.expectEqualStrings("second question", rep.prompt_text.?);
    try testing.expectEqual(@as(usize, 0), rep.restored_files.len);
    try testing.expectEqual(@as(usize, 2), a.messages().len);
    const id = a.ref.session;
    f.manager.dispose(a);
    live.writer.close();

    // The rewound records stay in the file but a resume skips them.
    const l = try f.store.open(io, id, .{ .mode = .full });
    defer l.deinit();
    var msg_records: usize = 0;
    for (l.tail) |x| if (x.record.message() != null) {
        msg_records += 1;
    };
    try testing.expectEqual(@as(usize, 4), msg_records);
    var r = try resume_mod.resumeAgent(f.manager, io, id, .{}, .{ .store = &f.store, .config = .{ .model = "" } });
    defer r.deinit();
    defer f.manager.dispose(r.agent);
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("ua", ts.roles(&buf, r.agent.messages()));
    try testing.expectEqualStrings("First answer.", ts.firstText(r.agent.messages()[1]));
}

test "rewind code calls E12 and reports untracked changes" {
    var f: Fixture = undefined;
    try f.init(&two_turns);
    defer f.deinit();
    var e12: FakeE12 = .{};
    defer e12.deinit();
    var d = f.deps();
    d.checkpoints = e12.checkpoints();
    const live = try f.liveAgent(d);
    const a = live.agent;
    _ = try a.submit(.{ .text = "first question" });
    a.waitIdle();
    _ = try a.submit(.{ .text = "second question\nwith more lines" });
    a.waitIdle();
    try testing.expectEqual(@as(usize, 2), e12.labels.items.len);
    try testing.expectEqualStrings("second question", e12.labels.items[1]);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.NoCheckpointStore, rewind_mod.rewind(a, io, arena.allocator(), .{ .index = 2 }, .code, null, .{}));
    const rep = try rewind_mod.rewind(a, io, arena.allocator(), .{ .index = 2 }, .code, null, .{ .log = live.writer, .checkpoints = e12.restore() });
    try testing.expectEqual(@as(?u64, 101), e12.restored);
    try testing.expectEqual(@as(?u64, 101), rep.checkpoint);
    try testing.expectEqualStrings("src/a.zig", rep.restored_files[0]);
    try testing.expectEqualStrings("build/out.txt", rep.untracked_changes[0]);
    try testing.expectEqualStrings("symlink", rep.skipped[0].reason);
    // Code only: the conversation is unchanged.
    try testing.expectEqual(@as(usize, 4), a.messages().len);
    try testing.expectEqual(@as(?[]const u8, null), rep.prompt_text);

    // Both: the first turn's checkpoint, and the conversation goes back.
    const both = try rewind_mod.rewind(a, io, arena.allocator(), .{ .index = 0 }, .code_and_conversation, null, .{ .log = live.writer, .checkpoints = e12.restore() });
    try testing.expectEqual(@as(?u64, 100), both.checkpoint);
    try testing.expectEqualStrings("first question", both.prompt_text.?);
    try testing.expectEqual(@as(usize, 0), a.messages().len);

    // Checkpoint records reach the session file, and a resume knows them.
    const id = a.ref.session;
    f.manager.dispose(a);
    live.writer.close();
    const l = try f.store.open(io, id, .{ .mode = .full });
    defer l.deinit();
    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(testing.allocator);
    for (l.tail) |x| if (x.record == .checkpoint) try ids.append(testing.allocator, x.record.checkpoint.id);
    try testing.expectEqualSlices(u64, &.{ 100, 101 }, ids.items);
}

test "rewind summarize from" {
    var f: Fixture = undefined;
    try f.init(&two_turns);
    defer f.deinit();
    const live = try f.liveAgent(f.deps());
    const a = live.agent;
    _ = try a.submit(.{ .text = "first question" });
    a.waitIdle();
    _ = try a.submit(.{ .text = "second question" });
    a.waitIdle();

    const model: registry.ModelInfo = .{ .id = "summarizer", .provider = .scripted, .display = "S", .family = "test", .context_window = 200_000, .max_output = 64_000, .caps = .{} };
    const turns = [_][]const ts.Step{ts.script.text("SUMMARY of the second exchange.")};
    const s = try scripted.ScriptedProvider.init(testing.allocator, &turns, .all);
    const p = s.provider();
    defer p.deinit();
    var c: compactor.Compactor = .{ .provider = p, .model = &model };
    const base: request.Request = .{ .model = "m", .messages = &.{} };

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.NoCompactor, rewind_mod.rewind(a, io, arena.allocator(), .{ .index = 2 }, .summarize_from, null, .{}));
    const rep = try rewind_mod.rewind(a, io, arena.allocator(), .{ .index = 2 }, .summarize_from, "the second question", .{ .log = live.writer, .compactor = &c, .base = &base });
    try testing.expectEqualStrings("SUMMARY of the second exchange.", rep.summary.?);
    const msgs = a.messages();
    try testing.expectEqual(@as(usize, 3), msgs.len);
    try testing.expectEqualStrings("first question", ts.firstText(msgs[0]));
    try testing.expectEqualStrings("SUMMARY of the second exchange.", msgs[2].content[1].text.text);
    const id = a.ref.session;
    f.manager.dispose(a);
    live.writer.close();

    // A resume reads the summarized history.
    var r = try resume_mod.resumeAgent(f.manager, io, id, .{}, .{ .store = &f.store, .config = .{ .model = "" } });
    defer r.deinit();
    defer f.manager.dispose(r.agent);
    try testing.expectEqual(@as(usize, 3), r.agent.messages().len);
    try testing.expectEqualStrings("SUMMARY of the second exchange.", r.agent.messages()[2].content[1].text.text);
}
