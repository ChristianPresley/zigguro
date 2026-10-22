const std = @import("std");
const comments = @import("comments.zig");
const model = @import("../model/root.zig");

const testing = std.testing;
const gpa = testing.allocator;
const CommentStore = comments.CommentStore;
const CommentAnchor = comments.CommentAnchor;
const ChangesetId = model.ChangesetId;
const Hunk = model.changeset.Hunk;

const cs1: ChangesetId = @enumFromInt(1);

const text_v1 =
    \\const a = 1;
    \\fn main() void {
    \\    run(a);
    \\    log("done");
    \\}
    \\
;

/// Collects journaled records.
const Journal = struct {
    records: std.ArrayList([]u8) = .empty,

    fn deinit(j: *Journal) void {
        for (j.records.items) |r| gpa.free(r);
        j.records.deinit(gpa);
    }

    fn recorder(j: *Journal) comments.Recorder {
        return .{ .ctx = j, .record = struct {
            fn f(ctx: *anyopaque, json: []const u8) void {
                const self: *Journal = @ptrCast(@alignCast(ctx));
                self.records.append(gpa, gpa.dupe(u8, json) catch @panic("oom")) catch @panic("oom");
            }
        }.f };
    }

    fn replay(j: *const Journal, into: *CommentStore) !void {
        for (j.records.items) |r| try restoreJson(into, r);
    }
};

fn restoreJson(into: *CommentStore, json: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
    try into.restore(v);
}

fn anchorAt(path: []const u8, text: []const u8, start: u32, count: u32) !CommentAnchor {
    return CommentAnchor.at(gpa, path, .new, text, .{ .start = start, .count = count });
}

test "comments: re-anchor after insertion above (mapping)" {
    var s: CommentStore = .init(gpa, .{});
    defer s.deinit();
    const t = try s.create(cs1, try anchorAt("main.zig", text_v1, 2, 2), .issue, true, "issue (blocking): check the result", .{ .user = "dana" }, 10);
    // Two lines inserted above line 1; the mapping says so.
    const v2 = "const a = 1;\n// one\n// two\nfn main() void {\n    run(a);\n    log(\"done\");\n}\n";
    const map = [_]Hunk{.{ .id = 0, .base_lines = .{ .start = 1, .count = 0 }, .new_lines = .{ .start = 1, .count = 2 }, .replace_span = .{ 0, 1 } }};
    const rep = try s.reanchor(cs1, "main.zig", v2, .{ .map = &map });
    try testing.expectEqual(@as(u32, 1), rep.moved);
    const th = s.get(t).?;
    try testing.expectEqual(@as(u32, 4), th.anchor.lines.start);
    try testing.expectEqual(@as(u32, 2), th.anchor.lines.count);
    try testing.expect(!th.outdated);
    try testing.expectEqual(@as(u32, 1), s.unresolvedBlocking(cs1));
    try s.resolve(t, true);
    try testing.expectEqual(@as(u32, 0), s.unresolvedBlocking(cs1));
}

test "comments: re-anchor by hash search after revision" {
    var s: CommentStore = .init(gpa, .{});
    defer s.deinit();
    const t = try s.create(cs1, try anchorAt("main.zig", text_v1, 2, 1), null, false, "why run here?", .{ .user = "dana" }, 10);
    // The revision moved the line down and re-indented it; no mapping.
    const v2 = "const a = 1;\nconst b = 2;\nfn main() void {\n    setup();\n\trun(a);\n    log(\"done\");\n}\n";
    const rep = try s.reanchor(cs1, "main.zig", v2, .{});
    try testing.expectEqual(@as(u32, 1), rep.moved);
    try testing.expectEqual(@as(u32, 4), s.get(t).?.anchor.lines.start);
    // Unchanged text keeps it where it is.
    const again = try s.reanchor(cs1, "main.zig", v2, .{});
    try testing.expectEqual(@as(u32, 1), again.kept);
    // Other paths and sides are left alone.
    try testing.expectEqual(@as(u32, 0), (try s.reanchor(cs1, "other.zig", "", .{})).kept);
    try testing.expectEqual(@as(u32, 0), (try s.reanchor(cs1, "main.zig", "", .{ .side = .base })).outdated);
}

test "comments: outdated when lines removed; thread retained" {
    var s: CommentStore = .init(gpa, .{});
    defer s.deinit();
    const t = try s.create(cs1, try anchorAt("main.zig", text_v1, 3, 1), .nitpick, false, "nitpick: say why", .{ .user = "dana" }, 10);
    const v2 = "const a = 1;\nfn main() void {\n    run(a);\n}\n";
    const rep = try s.reanchor(cs1, "main.zig", v2, .{});
    try testing.expectEqual(@as(u32, 1), rep.outdated);
    const th = s.get(t).?;
    try testing.expect(th.outdated);
    try testing.expectEqualStrings("    log(\"done\");\n", th.anchor.text);
    try testing.expectEqual(@as(usize, 1), s.threadsOf(cs1).len);
    try testing.expectEqual(@as(u32, 1), s.counts(cs1).outdated);
    // The line comes back in a later revision: so does the thread.
    const v3 = "const a = 1;\nfn main() void {\n    run(a);\n    log(\"done\");\n}\n";
    const back = try s.reanchor(cs1, "main.zig", v3, .{});
    try testing.expectEqual(@as(u32, 1), back.recovered);
    try testing.expect(!s.get(t).?.outdated);
}

test "comments: journal round trip" {
    var j: Journal = .{};
    defer j.deinit();
    var s: CommentStore = .init(gpa, .{ .recorder = j.recorder(), .id_base = 7 << 32 });
    defer s.deinit();
    const sess = try @import("zg_ai_proto").agent_ref.parse("01JABCDEFGHJKMNPQRSTVWXYZ0");
    const t = try s.create(cs1, try anchorAt("main.zig", text_v1, 1, 2), .issue, false, "issue (security): leaks the token", .{ .user = "dana" }, 10);
    _ = try s.reply(t, "Fixed in the next revision.", .{ .agent = .{ .session = sess, .agent = 2, .tool_call = "tc1" } }, 20);
    const c3 = try s.reply(t, "thanks", .{ .code_review = 9 }, 30);
    try s.edit(t, c3, "thanks!", 31);
    try s.setLabel(t, .issue, true);
    _ = try s.reanchor(cs1, "main.zig", "\n" ++ text_v1, .{});
    try s.resolve(t, true);
    try testing.expectEqual(@as(usize, 7), j.records.items.len);
    try testing.expectEqual(@as(u64, 7 << 32 | 1), @intFromEnum(t));

    // Another process (or a reload) rebuilds the same thread; replaying
    // twice changes nothing.
    var r: CommentStore = .init(gpa, .{ .id_base = 7 << 32 });
    defer r.deinit();
    try j.replay(&r);
    try j.replay(&r);
    try expectSame(s.get(t).?, r.get(t).?);
    // New ids continue after the restored ones.
    const t2 = try r.create(cs1, try anchorAt("main.zig", text_v1, 0, 1), null, false, "note: fine", .{ .user = "dana" }, 40);
    try testing.expect(@intFromEnum(t2) > c3);

    // A compaction snapshot holds the same.
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try comments.writeSnapshot(gpa, &aw.writer, s.get(t).?);
    var q: CommentStore = .init(gpa, .{});
    defer q.deinit();
    try restoreJson(&q, aw.written());
    try expectSame(s.get(t).?, q.get(t).?);

    r.dropTarget(cs1);
    try testing.expectEqual(@as(usize, 0), r.threadsOf(cs1).len);
}

fn expectSame(a: *const comments.Thread, b: *const comments.Thread) !void {
    try testing.expectEqual(a.target, b.target);
    try testing.expectEqualStrings(a.anchor.path, b.anchor.path);
    try testing.expectEqual(a.anchor.lines, b.anchor.lines);
    try testing.expectEqual(a.anchor.content_hash, b.anchor.content_hash);
    try testing.expectEqualStrings(a.anchor.text, b.anchor.text);
    try testing.expectEqual(a.label, b.label);
    try testing.expectEqual(a.blocking, b.blocking);
    try testing.expectEqual(a.resolved, b.resolved);
    try testing.expectEqual(a.outdated, b.outdated);
    try testing.expectEqual(a.tags.len, b.tags.len);
    for (a.tags, b.tags) |x, y| try testing.expectEqualStrings(x, y);
    try testing.expectEqual(a.comments.items.len, b.comments.items.len);
    for (a.comments.items, b.comments.items) |x, y| {
        try testing.expectEqual(x.id, y.id);
        try testing.expectEqualStrings(x.body, y.body);
        try testing.expectEqual(x.created_ms, y.created_ms);
        try testing.expectEqual(x.edited_ms, y.edited_ms);
        try testing.expectEqual(std.meta.activeTag(x.author), std.meta.activeTag(y.author));
        switch (x.author) {
            .user => |u| try testing.expectEqualStrings(u, y.author.user),
            .agent => |g| {
                try testing.expectEqual(g.session, y.author.agent.session);
                try testing.expectEqual(g.agent, y.author.agent.agent);
                try testing.expectEqualStrings(g.tool_call.?, y.author.agent.tool_call.?);
            },
            .code_review => |run| try testing.expectEqual(run, y.author.code_review),
        }
    }
}

test "comments: tags from the body; empty bodies refused" {
    var s: CommentStore = .init(gpa, .{});
    defer s.deinit();
    const t = try s.create(cs1, try anchorAt("a", "x\n", 0, 1), .issue, true, "issue (security, blocking, perf): x", .{ .user = "u" }, 1);
    const th = s.get(t).?;
    try testing.expectEqual(@as(usize, 2), th.tags.len);
    try testing.expectEqualStrings("security", th.tags[0]);
    try testing.expectEqualStrings("perf", th.tags[1]);
    try testing.expectError(error.EmptyBody, s.reply(t, "  \n", .{ .user = "u" }, 2));
    try testing.expectError(error.UnknownThread, s.resolve(@enumFromInt(99), true));
}
