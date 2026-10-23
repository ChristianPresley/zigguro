const std = @import("std");
const task_mod = @import("../task.zig");
const map = @import("map.zig");
const types = @import("types.zig");

const testing = std.testing;

fn fieldsOf(a: std.mem.Allocator, bytes: []const u8) !map.Fields {
    const t = try task_mod.parse(a, "T-0001-x.md", bytes);
    return map.fromTask(a, &t, bytes);
}

test "map_roundtrip_table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { file: []const u8, title: []const u8, body: []const u8, state: map.SyncState, labels: []const []const u8, assignee: ?[]const u8 };
    const cases = [_]Case{
        .{
            .file = "---\nid: T-0001\ntitle: Fix the parser\nstatus: in_progress\nlabels: [bug, Parser, bug]\nassignee: octo\n---\n# Fix the parser\n\nIt crashes on `{`.\n",
            .title = "Fix the parser",
            .body = "It crashes on `{`.",
            .state = .open,
            .labels = &.{ "bug", "Parser" },
            .assignee = "octo",
        },
        .{
            .file = "---\r\nid: T-0001\r\ntitle: Done one\r\nstatus: done\r\nassignee: agent:writer\r\n---\r\nNo heading here.\r\nSecond line.\r\n",
            .title = "Done one",
            .body = "No heading here.\nSecond line.",
            .state = .done,
            .labels = &.{},
            .assignee = null,
        },
        .{
            .file = "---\nid: T-0001\ntitle: Dropped\nstatus: cancelled\n---\n# Dropped\n",
            .title = "Dropped",
            .body = "",
            .state = .cancelled,
            .labels = &.{},
            .assignee = null,
        },
    };
    for (cases) |c| {
        const f = try fieldsOf(a, c.file);
        try testing.expectEqualStrings(c.title, f.title);
        try testing.expectEqualStrings(c.body, f.body);
        try testing.expectEqual(c.state, f.state);
        try testing.expect(map.labelsEqual(c.labels, f.labels));
        try testing.expect(map.optEqual(c.assignee, f.assignee));

        // The same values as an issue map back to the same fields.
        const sf = f.state.issueFields();
        const issue: types.Issue = .{
            .number = 1,
            .title = f.title,
            .body = f.body,
            .state = if (std.mem.eql(u8, sf.state, "open")) .open else .closed,
            .state_reason = sf.reason,
            .labels = f.labels,
            .assignees = if (f.assignee) |x| &.{x} else &.{},
            .updated_at = "",
            .is_pull_request = false,
        };
        const back = try map.fromIssue(a, &issue);
        try testing.expectEqualStrings(f.title, back.title);
        try testing.expectEqualStrings(f.body, back.body);
        try testing.expectEqual(f.state, back.state);
        try testing.expect(map.labelsEqual(f.labels, back.labels));
        try testing.expect(map.optEqual(f.assignee, back.assignee));

        // Writing the body back keeps the file's shape and line ends.
        const body = try map.composeBody(a, c.file, f.title, f.body);
        const again = try map.localBody(a, try std.mem.concat(a, u8, &.{ c.file[0 .. c.file.len - task_mod.bodyOf(c.file).len], body }));
        try testing.expectEqualStrings(f.body, again);
        try testing.expectEqual(std.mem.indexOf(u8, c.file, "\r\n") != null, std.mem.indexOf(u8, body, "\r\n") != null);
    }
}

test "closed_completed_maps_done_not_planned_maps_cancelled" {
    const S = map.SyncState;
    const base: types.Issue = .{ .number = 1, .title = "", .body = null, .state = .closed, .state_reason = "completed", .labels = &.{}, .assignees = &.{}, .updated_at = "", .is_pull_request = false };
    var i = base;
    try testing.expectEqual(S.done, S.ofIssue(&i));
    i.state_reason = null;
    try testing.expectEqual(S.done, S.ofIssue(&i));
    i.state_reason = "not_planned";
    try testing.expectEqual(S.cancelled, S.ofIssue(&i));
    i.state_reason = "duplicate";
    try testing.expectEqual(S.cancelled, S.ofIssue(&i));
    i.state = .open;
    try testing.expectEqual(S.open, S.ofIssue(&i));
    // An open issue keeps an open status; a finished task reopens as ready.
    try testing.expectEqual(task_mod.Status.review, S.open.toStatus(.review));
    try testing.expectEqual(task_mod.Status.ready, S.open.toStatus(.done));
    try testing.expectEqual(task_mod.Status.ready, S.open.toStatus(.cancelled));
    try testing.expectEqual(task_mod.Status.cancelled, S.cancelled.toStatus(.in_progress));
    try testing.expectEqualStrings("not_planned", S.cancelled.issueFields().reason.?);
}

test "agent_log_section_stays_local" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const file =
        \\---
        \\id: T-0001
        \\title: Docs
        \\---
        \\# Docs
        \\
        \\Write them.
        \\
        \\## Agent log
        \\
        \\- 01JA: started
        \\
        \\## Notes
        \\
        \\Kept too.
        \\
    ;
    try testing.expectEqualStrings("Write them.\n\n## Notes\n\nKept too.", try map.localBody(a, file));
    const body = try map.composeBody(a, file, "Docs v2", "Rewritten on GitHub.\n\n## Notes\n\nKept too.");
    try testing.expectEqualStrings("# Docs v2\n\nRewritten on GitHub.\n\n## Notes\n\nKept too.\n\n## Agent log\n\n- 01JA: started\n", body);
}

test "label set merge and decisions" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Local adds docs and drops old; GitHub adds P1 and drops bug.
    const merged = try map.mergeLabels(a, &.{ "bug", "old", "keep" }, &.{ "bug", "keep", "docs" }, &.{ "old", "keep", "P1" });
    try testing.expect(map.labelsEqual(&.{ "docs", "keep", "P1" }, merged));
    try testing.expect(map.labelsEqual(&.{ "A", "b" }, try map.labelSet(a, &.{ "b", "a", "A", " " })));
    try testing.expectEqual(map.Decision.same, map.decide(true, true, true));
    try testing.expectEqual(map.Decision.conflict, map.decide(true, true, false));
    try testing.expectEqual(map.Decision.take_remote, map.decide(false, true, false));
    try testing.expectEqual(map.Decision.take_local, map.decide(true, false, false));
    const repo: types.Repo = .{ .owner = "octo", .name = "demo" };
    try testing.expectEqual(@as(?u32, 12), map.parseLink("octo/demo#12", repo));
    try testing.expectEqual(@as(?u32, 12), map.parseLink("Octo/Demo#12", repo));
    try testing.expectEqual(@as(?u32, null), map.parseLink("octo/other#12", repo));
    try testing.expectEqual(@as(?u32, null), map.parseLink("octo/demo#x", repo));
}
