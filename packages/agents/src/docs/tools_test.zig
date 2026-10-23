//! Document sessions and their tools with a fake review queue and a fake
//! clock.

const std = @import("std");
const zg_ai = @import("zg_ai");
const doc = @import("doc_session.zig");
const tools = @import("tools.zig");
const words = @import("words.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const FakeClock = zg_ai.ratelimit.FakeClock;

const essay =
    \\# Essay
    \\
    \\An opening paragraph that sets the scene.
    \\
    \\## Method
    \\
    \\We measured the thing twice, carefully, with a ruler.
    \\
    \\## Results
    \\
    \\The thing was long. The ruler was short.
    \\
;

const Review = struct {
    arena: std.heap.ArenaAllocator = .init(std.testing.allocator),
    items: std.ArrayList(doc.DocChange) = .empty,
    clock: ?*FakeClock = null,
    at_ms: std.ArrayList(i64) = .empty,

    fn port(r: *Review) doc.ChangePort {
        return .{ .ctx = r, .propose = propose };
    }

    fn propose(ctx: *anyopaque, c: doc.DocChange) anyerror!u64 {
        const r: *Review = @ptrCast(@alignCast(ctx));
        const a = r.arena.allocator();
        var copy = c;
        copy.base = try a.dupe(u8, c.base);
        copy.summary = try a.dupe(u8, c.summary);
        const hs = try a.dupe(words.Hunk, c.hunks);
        for (hs) |*h| h.new = try a.dupe(u8, h.new);
        copy.hunks = hs;
        try r.items.append(a, copy);
        try r.at_ms.append(a, if (r.clock) |k| k.now_ms.load(.acquire) else 0);
        return 100 + r.items.items.len;
    }

    fn deinit(r: *Review) void {
        r.arena.deinit();
    }

    /// The base with the last change's hunks applied.
    fn applied(r: *Review, a: std.mem.Allocator) ![]const u8 {
        const c = r.items.items[r.items.items.len - 1];
        var out: std.ArrayList(u8) = .empty;
        var at: usize = 0;
        for (c.hunks) |h| {
            try out.appendSlice(a, c.base[at..h.start]);
            try out.appendSlice(a, h.new);
            at = h.end;
        }
        try out.appendSlice(a, c.base[at..]);
        return out.items;
    }
};

const Fx = struct {
    review: Review = .{},
    clock: FakeClock = .init(1_000_000),
    session: *doc.DocSession = undefined,
    arena: std.heap.ArenaAllocator = .init(std.testing.allocator),

    fn init(f: *Fx, text: []const u8) !void {
        f.review.clock = &f.clock;
        f.session = try doc.DocSession.open(gpa, io, "notes/essay.md", text, 1, f.review.port(), .{ .clock = f.clock.clock() });
    }

    fn deinit(f: *Fx) void {
        f.session.close();
        f.review.deinit();
        f.arena.deinit();
    }

    fn propose(f: *Fx, scope: doc.Scope, old: []const u8, new: []const u8) !doc.ProposeResult {
        return f.session.propose(f.arena.allocator(), .{ .scope = scope, .old_text = old, .new_text = new }, .{});
    }

    fn type_(f: *Fx, at: []const u8, new: []const u8) !void {
        const text = f.session.text.items;
        const pos: u32 = @intCast(std.mem.indexOf(u8, text, at).?);
        try f.session.applyEdit(pos, @intCast(at.len), new, f.session.version + 1);
        f.session.noteTyping(pos + @as(u32, @intCast(new.len)));
    }
};

test "propose_exact_fuzzy_stale" {
    const Case = struct {
        name: []const u8,
        /// The person's edit before the proposal: (old, new).
        user_edit: ?[2][]const u8 = null,
        scope: doc.Scope,
        old: []const u8,
        new: []const u8,
        want: std.meta.Tag(doc.ProposeResult),
    };
    const cases = [_]Case{
        .{ .name = "exact", .scope = .{ .section = "1.1" }, .old = "with a ruler", .new = "with a laser", .want = .ok },
        .{ .name = "by slug", .scope = .{ .section = "results" }, .old = "The ruler was short.", .new = "The ruler was too short.", .want = .ok },
        .{ .name = "whitespace changed", .user_edit = .{ "twice, carefully,", "twice,\n  carefully," }, .scope = .{ .section = "1.1" }, .old = "We measured the thing twice, carefully, with a ruler.", .new = "We measured it twice.", .want = .ok },
        .{ .name = "a word changed", .user_edit = .{ "with a ruler", "with a wooden ruler" }, .scope = .{ .section = "method" }, .old = "We measured the thing twice, carefully, with a ruler indeed and then wrote everything down in a notebook for later.", .new = "We measured it.", .want = .stale },
        .{ .name = "rewritten", .user_edit = .{ "We measured the thing twice, carefully, with a ruler.", "Nobody measured anything." }, .scope = .{ .section = "1.1" }, .old = "We measured the thing twice", .new = "x", .want = .stale },
        .{ .name = "outside the scope", .scope = .{ .section = "1.1" }, .old = "The thing was long.", .new = "x", .want = .stale },
        .{ .name = "ambiguous", .scope = .document, .old = "The", .new = "A", .want = .not_found },
        .{ .name = "no section", .scope = .{ .section = "9" }, .old = "x", .new = "y", .want = .not_found },
        .{ .name = "unchanged", .scope = .document, .old = "An opening paragraph", .new = "An opening paragraph", .want = .not_found },
    };
    for (cases) |c| {
        var f: Fx = .{};
        try f.init(essay);
        defer f.deinit();
        if (c.user_edit) |e| try f.type_(e[0], e[1]);
        f.clock.advance(5000);
        const r = try f.propose(c.scope, c.old, c.new);
        errdefer std.debug.print("case {s}: {any}\n", .{ c.name, r });
        try testing.expectEqual(c.want, std.meta.activeTag(r));
        if (c.want == .stale) try testing.expect(r.stale.len > 0);
    }

    // Fuzzy by words: one word differs in a long sentence.
    var f: Fx = .{};
    try f.init("# T\n\nThe committee met on Tuesday to discuss the budget for the coming year and agreed to postpone the vote until the next session in March.\n");
    defer f.deinit();
    const r = try f.propose(.document, "The committee met on Monday to discuss the budget for the coming year and agreed to postpone the vote until the next session in March.", "The committee met and postponed the vote.");
    try testing.expectEqual(.ok, std.meta.activeTag(r));
    try testing.expect(std.mem.indexOf(u8, try f.review.applied(f.arena.allocator()), "met and postponed the vote.\n") != null);
}

test "changeset_word_hunks_golden" {
    var f: Fx = .{};
    try f.init(essay);
    defer f.deinit();
    _ = try f.propose(.{ .section = "results" }, "The thing was long. The ruler was short.", "The thing was very long. The tape was short!");
    const c = f.review.items.items[0];
    var out: std.Io.Writer.Allocating = .init(f.arena.allocator());
    for (c.hunks) |h| try out.writer.print("[{d},{d}) \"{s}\" -> \"{s}\"\n", .{ h.start, h.end, c.base[h.start..h.end], h.new });
    try testing.expectEqualStrings(
        \\[144,144) "" -> "very "
        \\[154,159) "ruler" -> "tape"
        \\[169,170) "." -> "!"
        \\
    , out.written());
    try testing.expectEqualStrings("notes/essay.md", c.path);
    try testing.expectEqual(1, c.base_version);
    try testing.expectEqualStrings("Edit Results", c.summary);
    // The session's document is untouched: changes wait for review.
    try testing.expectEqualStrings(essay, f.session.text.items);
}

test "queued_while_typing" {
    var f: Fx = .{};
    try f.init(essay);
    defer f.deinit();
    // The person types in Method.
    try f.type_("carefully", "very carefully");
    const typed_at = f.clock.now_ms.load(.acquire);
    f.clock.advance(500);
    // A proposal elsewhere goes at once.
    _ = try f.propose(.{ .section = "results" }, "long", "longer");
    try testing.expectEqual(typed_at + 500, f.review.at_ms.items[0]);
    // A proposal in Method waits until 2 s after the last keystroke.
    _ = try f.propose(.{ .section = "method" }, "with a ruler", "with a laser");
    try testing.expectEqual(typed_at + 2000, f.review.at_ms.items[1]);
    // The wait is against the text as it is then.
    try testing.expect(std.mem.indexOf(u8, f.review.items.items[1].base, "very carefully") != null);
}

test "read_section_truncates_large" {
    var f: Fx = .{};
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    try big.appendSlice(gpa, "# Book\n\nForeword.\n\n");
    for (0..40) |i| {
        try big.print(gpa, "## Chapter {d}\n\n", .{i + 1});
        for (0..30) |_| try big.appendSlice(gpa, "A sentence of filler prose that goes on for a while to use up tokens.\n");
        try big.appendSlice(gpa, "\n");
    }
    try f.init(big.items);
    defer f.deinit();
    var src: tools.Source = .{ .session = f.session, .max_section_tokens = 2000 };
    const a = f.arena.allocator();

    var r = try tools.run(&src, a, "doc_read_section", "{\"section\":\"1\"}");
    try testing.expect(!r.is_error);
    const Out = struct { id: []const u8, title: []const u8, text: []const u8, truncated: bool = false, subsections: ?[]const struct { id: []const u8, title: []const u8, words: u32 } = null };
    const o = try std.json.parseFromSliceLeaky(Out, a, r.text, .{});
    try testing.expect(o.truncated);
    try testing.expectEqualStrings("# Book\n\nForeword.\n\n", o.text);
    try testing.expectEqual(40, o.subsections.?.len);
    try testing.expectEqualStrings("1.40", o.subsections.?[39].id);

    r = try tools.run(&src, a, "doc_read_section", "{\"section\":\"chapter-3\"}");
    const o3 = try std.json.parseFromSliceLeaky(Out, a, r.text, .{});
    try testing.expect(!o3.truncated);
    try testing.expect(std.mem.startsWith(u8, o3.text, "## Chapter 3\n"));
    r = try tools.run(&src, a, "doc_read_section", "{\"section\":\"nope\"}");
    try testing.expect(r.is_error);
}

test "doc_rewrite_section_only" {
    // The tool calls an agent makes to rewrite one section: outline, read,
    // propose. Every hunk stays inside the section, and nothing is written.
    var f: Fx = .{};
    try f.init(essay);
    defer f.deinit();
    var exp: tools.ToolExporter = .{ .src = .{ .session = f.session, .prov = .{ .session = 7 } } };
    const e = exp.exporter();
    const a = f.arena.allocator();
    const listed = try e.list(e.ctx, a);
    try testing.expectEqual(5, listed.len);
    for (listed) |t| try testing.expect(t.read_only != t.mutates);

    const outline = try e.call(e.ctx, io, a, "doc_outline", "{}");
    try testing.expect(std.mem.indexOf(u8, outline.json, "\\\"id\\\":\\\"1.1\\\",\\\"slug\\\":\\\"method\\\"") != null);
    const read = try e.call(e.ctx, io, a, "doc_read_section", "{\"section\":\"1.1\",\"include_children\":false}");
    try testing.expect(std.mem.indexOf(u8, read.json, "with a ruler") != null);
    const edit = try e.call(e.ctx, io, a, "doc_propose_edit", "{\"section\":\"1.1\",\"old_text\":\"We measured the thing twice, carefully, with a ruler.\",\"new_text\":\"We measured the thing three times with a calibrated laser.\",\"rationale\":\"More precise.\"}");
    try testing.expectEqual(@as(?u64, 101), edit.changeset);
    const c = f.review.items.items[0];
    const method_start = std.mem.indexOf(u8, essay, "## Method").?;
    const results_start = std.mem.indexOf(u8, essay, "## Results").?;
    for (c.hunks) |h| try testing.expect(h.start >= method_start and h.end <= results_start);
    try testing.expectEqualStrings("More precise.", c.rationale.?);
    try testing.expectEqual(@as(?u128, 7), c.prov.session);
    try testing.expectEqualStrings("doc_propose_edit", c.prov.tool);

    const ins = try e.call(e.ctx, io, a, "doc_insert", "{\"after_section\":\"method\",\"text\":\"## Limitations\\n\\nOnly one ruler.\"}");
    try testing.expectEqual(@as(?u64, 102), ins.changeset);
    const after = try f.review.applied(a);
    try testing.expect(std.mem.indexOf(u8, after, "with a ruler.\n\n## Limitations\n\nOnly one ruler.\n\n## Results") != null);

    const search = try e.call(e.ctx, io, a, "doc_search", "{\"text\":\"RULER\"}");
    try testing.expect(std.mem.indexOf(u8, search.json, "\\\"section\\\":\\\"1.1\\\"") != null);
    const stale = try e.call(e.ctx, io, a, "doc_propose_edit", "{\"old_text\":\"not in the essay\",\"new_text\":\"x\"}");
    try testing.expect(stale.changeset == null);
    try testing.expect(std.mem.indexOf(u8, stale.json, "\"isError\":true") != null);
    // Only review saw changes.
    try testing.expectEqualStrings(essay, f.session.text.items);
    try testing.expectEqual(2, f.session.proposals);
}
