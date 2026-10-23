//! Comment threads: the sidecar, re-anchoring after edits the app did
//! not see, renames, the agent's side through the document tools, and
//! the comment-only shortcut.

const std = @import("std");
const zg_ai = @import("zg_ai");
const comments = @import("comments.zig");
const tools = @import("tools.zig");
const shortcuts = @import("shortcuts.zig");
const doc_session = @import("doc_session.zig");
const runs = @import("../runs/root.zig");
const Range = @import("sections.zig").Range;

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const CommentStore = comments.CommentStore;

const doc =
    \\# Plan
    \\
    \\The launch happens in spring, after the beta closes.
    \\
    \\## Risks
    \\
    \\Hiring may slip. The budget is tight this year.
    \\
;

const Asks = struct {
    prompt: std.ArrayList(u8) = .empty,
    thread: ?u32 = null,
    fn ask(ctx: *anyopaque, t: u32, p: []const u8) anyerror!void {
        const s: *Asks = @ptrCast(@alignCast(ctx));
        s.thread = t;
        s.prompt.clearRetainingCapacity();
        try s.prompt.appendSlice(gpa, p);
    }
};

const Fx = struct {
    tmp: testing.TmpDir,
    clock: zg_ai.ratelimit.FakeClock,
    asks: Asks = .{},
    store: *CommentStore,

    fn init(f: *Fx) !void {
        f.* = .{ .tmp = testing.tmpDir(.{}), .clock = .init(1_000), .store = undefined };
        f.store = try f.open("notes/plan.md");
    }

    fn open(f: *Fx, path: []const u8) !*CommentStore {
        return CommentStore.open(gpa, io, path, f.tmp.dir, .{ .clock = f.clock.clock(), .ask = .{ .ctx = &f.asks, .ask = Asks.ask } });
    }

    fn deinit(f: *Fx) void {
        f.store.close();
        f.asks.prompt.deinit(gpa);
        f.tmp.cleanup();
    }

    fn rangeOf(text: []const u8, needle: []const u8) Range {
        const at: u32 = @intCast(std.mem.indexOf(u8, text, needle).?);
        return .{ .start = at, .end = at + @as(u32, @intCast(needle.len)) };
    }
};

fn anchored(text: []const u8, t: *const comments.Thread) ?[]const u8 {
    const r = t.anchor orelse return null;
    return text[r.start..r.end];
}

test "threads persist in a sidecar, never in the document" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const t = try f.store.add(doc, Fx.rangeOf(doc, "in spring"), "Which month?", .{ .user = "ann" });
    _ = try f.store.reply(t, "April, probably.", .{ .user = "bo" });
    try f.store.resolve(t);
    const t2 = try f.store.add(doc, Fx.rangeOf(doc, "budget is tight"), "How tight?", .{ .user = "ann" });
    f.store.close();
    f.store = try f.open("notes/plan.md");
    const all = f.store.threads();
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqualStrings("in spring", all[0].quote);
    try testing.expect(all[0].resolved);
    try testing.expectEqual(@as(usize, 2), all[0].comments.items.len);
    try testing.expectEqualStrings("bo", all[0].comments.items[1].author.user);
    try testing.expectEqual(t2, all[1].id);
    try testing.expectEqual(@as(i64, 1_000), all[1].created_ms);
    // Replying reopens a resolved thread.
    _ = try f.store.reply(t, "Actually May.", .{ .user = "ann" });
    try testing.expect(!f.store.get(t).?.resolved);
    // The sidecar lives under .zigguro/comments/.
    try testing.expect(std.mem.startsWith(u8, f.store.fileName(), ".zigguro/comments/"));
    const side = try f.tmp.dir.readFileAlloc(io, f.store.fileName(), gpa, .limited(1 << 16));
    defer gpa.free(side);
    try testing.expect(std.mem.indexOf(u8, side, "\"op\":\"thread\"") != null);
}

test "reanchor after external edit" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const ta = try f.store.add(doc, Fx.rangeOf(doc, "after the beta closes"), "a", .{ .user = "" });
    const tb = try f.store.add(doc, Fx.rangeOf(doc, "Hiring may slip."), "b", .{ .user = "" });
    const tc = try f.store.add(doc, Fx.rangeOf(doc, "The budget is tight this year."), "c", .{ .user = "" });

    const Case = struct { name: []const u8, text: []const u8, a: ?[]const u8, b: ?[]const u8, c: ?[]const u8 };
    const cases = [_]Case{
        // Text inserted before everything: all move.
        .{ .name = "insert before", .text = "Intro line.\n\n" ++ doc, .a = "after the beta closes", .b = "Hiring may slip.", .c = "The budget is tight this year." },
        // A word changed inside a quote: found fuzzily.
        .{ .name = "edit inside quote", .text = "# Plan\n\nThe launch happens in spring, after the public beta closes.\n\n## Risks\n\nHiring may slip. The budget is tight this year.\n", .a = "after the public beta closes", .b = "Hiring may slip.", .c = "The budget is tight this year." },
        // A sentence deleted: its thread is orphaned.
        .{ .name = "delete quote", .text = "# Plan\n\nThe launch happens in spring, after the beta closes.\n\n## Risks\n\nThe budget is tight this year.\n", .a = "after the beta closes", .b = null, .c = "The budget is tight this year." },
    };
    for (cases) |c| {
        _ = try f.store.reanchor(c.text);
        const got = [_]?[]const u8{ anchored(c.text, f.store.get(ta).?), anchored(c.text, f.store.get(tb).?), anchored(c.text, f.store.get(tc).?) };
        const want = [_]?[]const u8{ c.a, c.b, c.c };
        for (got, want) |g, w| {
            if (w) |ws| {
                testing.expectEqualStrings(ws, g orelse "(orphan)") catch |e| {
                    std.debug.print("case {s}\n", .{c.name});
                    return e;
                };
            } else try testing.expect(g == null);
        }
    }
    // The orphan stays listed and can be placed again.
    const last = cases[2].text;
    try testing.expectEqual(@as(?Range, null), f.store.get(tb).?.anchor);
    try f.store.setAnchor(tb, last, Fx.rangeOf(last, "The budget"));
    try testing.expectEqualStrings("The budget", anchored(last, f.store.get(tb).?).?);
    // The same text twice: context picks the right one.
    const twice = "x tight y\n\nThe budget is tight this year.\n";
    const second: u32 = @intCast(std.mem.lastIndexOf(u8, twice, "tight").?);
    const t4 = try f.store.add(twice, .{ .start = second, .end = second + 5 }, "which", .{ .user = "" });
    const moved = "Lead.\nx tight y\n\nThe budget is tight this year.\n";
    _ = try f.store.reanchor(moved);
    const r = f.store.get(t4).?.anchor.?;
    try testing.expectEqual(@as(u32, @intCast(std.mem.lastIndexOf(u8, moved, "tight").?)), r.start);
}

test "edits seen in the app move anchors; sync writes them" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const t = try f.store.add(doc, Fx.rangeOf(doc, "Hiring may slip."), "b", .{ .user = "" });
    f.store.applyEdit(0, 0, 4);
    const r = f.store.get(t).?.anchor.?;
    try testing.expectEqual(Fx.rangeOf(doc, "Hiring").start + 4, r.start);
    const edited = try std.mem.concat(gpa, u8, &.{ "New ", doc });
    defer gpa.free(edited);
    try f.store.sync(edited);
    f.store.close();
    f.store = try f.open("notes/plan.md");
    try testing.expectEqualStrings("Hiring may slip.", anchored(edited, f.store.get(t).?).?);
    // Deleting all of its text orphans it.
    f.store.applyEdit(r.start, r.end - r.start, 0);
    try testing.expect(f.store.get(t).?.anchor == null);
}

test "sidecar follows rename" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.store.add(doc, Fx.rangeOf(doc, "in spring"), "Which month?", .{ .user = "ann" });
    const old = try gpa.dupe(u8, f.store.fileName());
    defer gpa.free(old);
    try f.store.rename("notes/launch-plan.md");
    try testing.expectError(error.FileNotFound, f.tmp.dir.access(io, old, .{}));
    f.store.close();
    f.store = try f.open("notes/launch-plan.md");
    try testing.expectEqual(@as(usize, 1), f.store.threads().len);
    try testing.expectEqualStrings("notes/launch-plan.md", f.store.path);
}

const Changes = struct {
    next: u64 = 500,
    fn propose(ctx: *anyopaque, _: doc_session.DocChange) anyerror!u64 {
        const s: *Changes = @ptrCast(@alignCast(ctx));
        s.next += 1;
        return s.next;
    }
};

test "agent reply flow" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var changes: Changes = .{};
    const session = try doc_session.DocSession.open(gpa, io, "notes/plan.md", doc, 1, .{ .ctx = &changes, .propose = Changes.propose }, .{});
    defer session.close();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // The person asks the agent.
    const t = try f.store.add(doc, Fx.rangeOf(doc, "Hiring may slip."), "@agent can you soften this?", .{ .user = "ann" });
    try testing.expectEqual(@as(?u32, t), f.asks.thread);
    const p = f.asks.prompt.items;
    try testing.expect(std.mem.indexOf(u8, p, "> Hiring may slip.") != null);
    try testing.expect(std.mem.indexOf(u8, p, "in the section \"Risks\"") != null);
    try testing.expect(std.mem.indexOf(u8, p, "- ann: @agent can you soften this?") != null);
    try testing.expect(std.mem.indexOf(u8, p, "doc_reply (thread 1)") != null);
    // A comment without @agent does not.
    f.asks.thread = null;
    _ = try f.store.reply(t, "thanks", .{ .user = "ann" });
    try testing.expectEqual(@as(?u32, null), f.asks.thread);

    // The agent proposes an edit and replies with it.
    const run = runs.RunId.fromInt(42);
    var src: tools.Source = .{ .session = session, .comments = f.store, .prov = .{ .run = run } };
    const prop = try tools.run(&src, a, "doc_propose_edit", "{\"old_text\":\"Hiring may slip.\",\"new_text\":\"Hiring could take longer.\"}");
    const cs = prop.changeset.?;
    const reply_in = try std.fmt.allocPrint(a, "{{\"thread\":{d},\"text\":\"Softened it.\",\"proposal\":{d}}}", .{ t, cs });
    const r = try tools.run(&src, a, "doc_reply", reply_in);
    try testing.expect(!r.is_error);
    const th = f.store.get(t).?;
    const last = th.comments.items[th.comments.items.len - 1];
    try testing.expect(last.author == .agent);
    try testing.expectEqual(@as(?u64, cs), last.proposal);
    // The agent's own comments never ask the agent.
    try testing.expectEqual(@as(?u32, null), f.asks.thread);
    // Accepting the proposal resolves the thread.
    try f.store.onDecision(cs, true);
    try testing.expect(f.store.get(t).?.resolved);

    // The agent comments, lists and resolves.
    const add = try tools.run(&src, a, "doc_add_comment", "{\"anchor_text\":\"in spring\",\"text\":\"Spring is vague.\"}");
    try testing.expectEqualStrings("Comment added as thread 2.", add.text);
    const list = try tools.run(&src, a, "doc_list_comments", "{}");
    try testing.expect(std.mem.indexOf(u8, list.text, "\"quote\":\"in spring\"") != null);
    try testing.expect(std.mem.indexOf(u8, list.text, "Hiring may slip.") == null);
    _ = try tools.run(&src, a, "doc_resolve_comment", "{\"thread\":2}");
    try testing.expect(f.store.get(2).?.resolved);
    const bad = try tools.run(&src, a, "doc_add_comment", "{\"anchor_text\":\"not there\",\"text\":\"x\"}");
    try testing.expect(bad.is_error);
}

test "suggest edits uses the comment tool only" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var changes: Changes = .{};
    const session = try doc_session.DocSession.open(gpa, io, "notes/plan.md", doc, 1, .{ .ctx = &changes, .propose = Changes.propose }, .{});
    defer session.close();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const s = shortcuts.find("suggest_comments").?;
    var src: tools.Source = .{ .session = session, .comments = f.store, .allow = s.tools };
    const offered = try tools.list(&src, a);
    var names: std.ArrayList(u8) = .empty;
    for (offered) |t| try names.print(a, "{s} ", .{t.name});
    try testing.expectEqualStrings("doc_outline doc_read_section doc_search doc_add_comment doc_list_comments ", names.items);
    const r = try tools.run(&src, a, "doc_propose_edit", "{\"old_text\":\"Hiring may slip.\",\"new_text\":\"x\"}");
    try testing.expect(r.is_error);
    try testing.expectEqual(@as(u32, 0), session.proposals);
    try testing.expect(std.mem.indexOf(u8, s.template, "doc_add_comment") != null);
    // Without a comment store the comment tools are not offered.
    var plain: tools.Source = .{ .session = session };
    for (try tools.list(&plain, a)) |t| try testing.expect(std.mem.indexOf(u8, t.name, "comment") == null);
}
