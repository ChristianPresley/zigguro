//! Tests for fork.zig (E10.F08.S02.T01).

const std = @import("std");
const proto = @import("zg_ai_proto");
const records = @import("records.zig");
const fork_mod = @import("fork.zig");
const resume_mod = @import("resume.zig");
const ts = @import("test_support.zig");

const testing = std.testing;
const io = ts.io;
const Fixture = ts.Fixture;

test "fork reads the parent prefix" {
    var f: Fixture = undefined;
    try f.init(&.{});
    defer f.deinit();
    const src = try f.write("m", &.{
        .{ .user = f.msg(.user, "q1") },
        .{ .assistant = f.msg(.assistant, "a1") },
        .{ .user = f.msg(.user, "q2") },
        .{ .assistant = f.msg(.assistant, "a2") },
    });
    // The parent stays locked by its writer: the fork only reads it.
    const pw = try f.store.reopen(io, src, 4);
    defer pw.close();

    const child = try fork_mod.fork(&f.store, io, src, 2, "Try another way");
    try testing.expect(child != src);
    {
        const w = try f.store.reopen(io, child, 3);
        defer w.close();
        try w.append(4, .{ .user = f.msg(.user, "q2 (alternative)") });
    }
    const l = try fork_mod.openChain(&f.store, io, child, .{ .mode = .full });
    defer l.deinit();
    try testing.expectEqual(src, l.header.parent.?.session);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const msgs = try l.messages(arena.allocator());
    try testing.expectEqual(@as(usize, 3), msgs.len);
    try testing.expectEqualStrings("q1", ts.firstText(msgs[0]));
    try testing.expectEqualStrings("a1", ts.firstText(msgs[1]));
    try testing.expectEqualStrings("q2 (alternative)", ts.firstText(msgs[2]));
    // The child's file holds only its header, title and own records.
    const own = try f.store.open(io, child, .{ .mode = .full });
    defer own.deinit();
    try testing.expectEqual(@as(usize, 2), own.tail.len);
    try testing.expectEqualStrings("Try another way", own.tail[0].record.title);
    // The parent is unchanged.
    const p = try f.store.open(io, src, .{ .mode = .full, .repair = false });
    defer p.deinit();
    try testing.expectEqual(@as(usize, 4), p.tail.len);
}

test "fork chain depth materializes" {
    var f: Fixture = undefined;
    try f.init(&.{});
    defer f.deinit();
    var id = try f.write("m", &.{ .{ .user = f.msg(.user, "root") }, .{ .assistant = f.msg(.assistant, "r") } });
    var seq: u64 = 2;
    var i: u32 = 0;
    while (i < fork_mod.max_chain_depth + 1) : (i += 1) {
        const child = try fork_mod.fork(&f.store, io, id, seq, null);
        seq += 1; // title
        const w = try f.store.reopen(io, child, seq);
        seq += 1;
        var buf: [16]u8 = undefined;
        try w.append(seq, .{ .user = f.msg(.user, try f.arena.allocator().dupe(u8, try std.fmt.bufPrint(&buf, "level {d}", .{i + 1}))) });
        w.close();
        id = child;
    }
    // The last fork copied its prefix instead of linking a 33-deep chain.
    const own = try f.store.open(io, id, .{ .mode = .full });
    defer own.deinit();
    try testing.expect(own.header.parent.?.materialized);
    try testing.expectEqual(@as(u32, 0), try fork_mod.chainDepth(&f.store, io, id));

    const l = try fork_mod.openChain(&f.store, io, id, .{ .mode = .full });
    defer l.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const msgs = try l.messages(arena.allocator());
    try testing.expectEqual(@as(usize, 2 + fork_mod.max_chain_depth + 1), msgs.len);
    try testing.expectEqualStrings("root", ts.firstText(msgs[0]));
    try testing.expectEqualStrings("level 33", ts.firstText(msgs[msgs.len - 1]));
    // The one before it links a full-depth chain.
    try testing.expectEqual(@as(u32, fork_mod.max_chain_depth), try fork_mod.chainDepth(&f.store, io, own.header.parent.?.session));
}

test "branch keeps session grants in process only" {
    var f: Fixture = undefined;
    try f.init(&.{});
    defer f.deinit();
    const src = try f.write("m", &.{ .{ .user = f.msg(.user, "q") }, .{ .assistant = f.msg(.assistant, "a") }, Fixture.event("mode", "{\"mode\":\"plan\"}") });
    inline for (.{ true, false }) |in_process| {
        var r = try resume_mod.resumeAgent(f.manager, io, src, .{ .fork = true, .in_process = in_process }, .{ .store = &f.store, .config = .{ .model = "" } });
        defer r.deinit();
        defer f.manager.dispose(r.agent);
        try testing.expectEqual(in_process, r.carry_session_grants);
        try testing.expect(r.session != src);
        try testing.expectEqual(r.session, r.agent.ref.session);
        try testing.expectEqual(@as(usize, 2), r.agent.messages().len);
        // Plan mode is not carried into a fork.
        try testing.expectEqual(resume_mod.PermissionMode.default, r.state.mode);
    }
    // The source session is untouched.
    const p = try f.store.open(io, src, .{ .mode = .full });
    defer p.deinit();
    try testing.expectEqual(@as(usize, 3), p.tail.len);
}
