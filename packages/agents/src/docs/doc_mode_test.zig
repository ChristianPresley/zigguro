//! The model behind document mode: shortcut prompts, streaming tracked
//! changes, the person's edits over pending hunks, and moving sections.

const std = @import("std");
const shortcuts = @import("shortcuts.zig");
const tracked = @import("tracked.zig");
const sections = @import("sections.zig");

const testing = std.testing;
const gpa = testing.allocator;

test "shortcut template expansion golden" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("a {{x}} b", try shortcuts.expand(a, "a {{{{x}} b", &.{}));
    try testing.expectEqualStrings("hi Ann, ", try shortcuts.expand(a, "hi {{ name }}, {{missing}}", &.{.{ .name = "name", .value = "Ann" }}));

    const level = shortcuts.find("reading_level").?;
    try testing.expectEqualStrings(
        "Rewrite this passage from \"Intro\" for a high school reading level. Propose the change with doc_propose_edit.\n\nSome text.",
        try shortcuts.prompt(a, level, "Some text.", "Intro", &.{}, null),
    );
    const tone = shortcuts.find("change_tone").?;
    try testing.expectEqualStrings(
        "Rewrite this passage from \"Intro\" in a friendly tone. Propose the change with doc_propose_edit.\n\nX",
        try shortcuts.prompt(a, tone, "X", "Intro", &.{"friendly"}, null),
    );
    // The prompt library's override wins.
    const Lib = struct {
        fn get(_: ?*anyopaque, key: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, key, "doc/shorten")) "Cut: {{selection}}" else null;
        }
    };
    try testing.expectEqualStrings("Cut: X", try shortcuts.prompt(a, shortcuts.find("shorten").?, "X", "", &.{}, .{ .get = Lib.get }));
    for (shortcuts.default_shortcuts) |s| try testing.expect(std.mem.indexOf(u8, s.template, "{{selection}}") != null);
}

test "partial JSON strings" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(try tracked.partialString(a, "{\"old_te", "old_text") == null);
    const p1 = (try tracked.partialString(a, "{\"old_text\":\"The cat\",\"new_text\":\"A d", "new_text")).?;
    try testing.expectEqualStrings("A d", p1.text);
    try testing.expect(!p1.complete);
    const p2 = (try tracked.partialString(a, "{\"new_text\":\"a\\\"b\\nc\\u00e9\\ud83d\\ude00\"}", "new_text")).?;
    try testing.expectEqualStrings("a\"b\nc\u{e9}\u{1F600}", p2.text);
    try testing.expect(p2.complete);
    // A cut escape is left out until it completes.
    const p3 = (try tracked.partialString(a, "{\"new_text\":\"ab\\u00", "new_text")).?;
    try testing.expectEqualStrings("ab", p3.text);
}

const Decisions = struct {
    log: std.ArrayList(u8) = .empty,
    fn decide(ctx: *anyopaque, cs: u64, hunk: u32, d: tracked.Decision) anyerror!void {
        const s: *Decisions = @ptrCast(@alignCast(ctx));
        try s.log.print(gpa, "{d}.{d}:{t} ", .{ cs, hunk, d });
    }
};

test "streaming partial JSON renders incrementally" {
    const text = "# A\n\nThe cat sat on the mat.\n";
    var d: Decisions = .{};
    defer d.log.deinit(gpa);
    var t: tracked.TrackedChanges = .init(gpa, .{ .ctx = &d, .decide = Decisions.decide });
    defer t.deinit();
    // Nothing until the old text is complete.
    try t.streamDelta(7, "doc_propose_edit", "{\"old_text\":\"The c", text);
    try testing.expectEqual(@as(usize, 0), t.items.items.len);
    try t.streamDelta(7, "doc_propose_edit", "{\"old_text\":\"The cat\",\"new_text\":\"A d", text);
    try testing.expectEqual(@as(usize, 1), t.items.items.len);
    try testing.expectEqualStrings("A d", t.items.items[0].new);
    try testing.expect(t.items.items[0].provisional());
    try testing.expectEqual(@as(u32, 5), t.items.items[0].start);
    const rev = t.revision;
    try t.streamDelta(7, "doc_propose_edit", "{\"old_text\":\"The cat\",\"new_text\":\"A dog\"", text);
    try testing.expectEqualStrings("A dog", t.items.items[0].new);
    try testing.expect(t.revision > rev);
    // Provisional changes cannot be decided.
    try testing.expect(!try t.decide(0, .accept));
    try t.streamEnd(7, .{ .changeset = 41, .hunks = &.{.{ .start = 5, .end = 12, .new = "A dog" }} });
    try testing.expectEqual(@as(usize, 1), t.items.items.len);
    try testing.expect(!t.items.items[0].provisional());
    try testing.expect(try t.decide(0, .accept));
    try testing.expectEqualStrings("41.0:accept ", d.log.items);

    // An insert after a section streams at that section's end.
    try t.streamDelta(8, "doc_insert", "{\"after_section\":\"A\",\"text\":\"More.", text);
    try testing.expectEqual(@as(u32, @intCast(text.len)), t.items.items[0].start);
    try t.streamEnd(8, null);
    try testing.expectEqual(@as(usize, 0), t.items.items.len);
}

test "user edit inside hunk drops it, edits before shift it" {
    var d: Decisions = .{};
    defer d.log.deinit(gpa);
    var t: tracked.TrackedChanges = .init(gpa, .{ .ctx = &d, .decide = Decisions.decide });
    defer t.deinit();
    try t.add(3, &.{ .{ .start = 10, .end = 20, .new = "x" }, .{ .start = 40, .end = 40, .new = "ins" } });
    // Typing before both moves them.
    try testing.expectEqual(@as(u32, 0), t.onUserEdit(2, 0, 3));
    try testing.expectEqual(@as(u32, 13), t.items.items[0].start);
    try testing.expectEqual(@as(u32, 43), t.items.items[1].start);
    // Typing inside the first drops it as stale.
    try testing.expectEqual(@as(u32, 1), t.onUserEdit(15, 0, 1));
    try testing.expectEqualStrings("3.0:stale ", d.log.items);
    try testing.expectEqual(@as(usize, 1), t.items.items.len);
    try testing.expectEqual(@as(u32, 44), t.items.items[0].start);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const text = "a" ** 50;
    try testing.expectEqualStrings("insertion pending, 1 word", try t.describe(arena.allocator(), 0, text));
    try testing.expectEqual(@as(?usize, 0), t.at(44));
    try testing.expectEqual(@as(?usize, 0), t.next(0));
    try testing.expectEqual(@as(?usize, 0), t.prev(0));
    try testing.expect(t.pendingIn(.{ .start = 40, .end = 50 }));
    try testing.expectEqual(@as(u32, 1), try t.decideIn(.{ .start = 0, .end = 50 }, .reject));
    try testing.expectEqualStrings("3.0:stale 3.1:reject ", d.log.items);
}

fn applyMove(a: std.mem.Allocator, text: []const u8, m: sections.Move) ![]const u8 {
    return std.mem.concat(a, u8, &.{ text[0..m.start], m.new_text, text[m.start + m.old_len ..] });
}

test "move a section with its subsections" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "# A\na\n## A1\na1\n# B\nb\n# C\nc";
    const all = try sections.outline(a, text);
    const ia = sections.find(all, "A").?;
    const ib = sections.find(all, "B").?;
    const ic = sections.find(all, "C").?;
    // A (with A1) to the end.
    try testing.expectEqualStrings("# B\nb\n# C\nc\n# A\na\n## A1\na1\n", try applyMove(a, text, (try sections.moveSection(a, text, all, ia, null)).?));
    // C before B.
    try testing.expectEqualStrings("# A\na\n## A1\na1\n# C\nc\n# B\nb\n", try applyMove(a, text, (try sections.moveSection(a, text, all, ic, ib)).?));
    // Into itself, or where it is: nothing.
    try testing.expect(try sections.moveSection(a, text, all, ia, sections.find(all, "A1").?) == null);
    try testing.expect(try sections.moveSection(a, text, all, ia, ib) == null);
}
