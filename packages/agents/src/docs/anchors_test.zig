const std = @import("std");
const anchors = @import("anchors.zig");

const testing = std.testing;
const gpa = testing.allocator;

/// `text` with `[start, start+old_len)` replaced, and the anchors told.
fn edit(set: *anchors.Anchors, text: *std.ArrayList(u8), start: u32, old_len: u32, new: []const u8) !void {
    try text.replaceRange(gpa, start, old_len, new);
    set.applyEdit(start, old_len, @intCast(new.len));
}

test "anchor_survives_user_edit_before_and_inside" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "# Title\n\nThe quick brown fox jumps over the lazy dog.\n");
    var set: anchors.Anchors = .{};
    defer set.deinit(gpa);
    const fox = std.mem.indexOf(u8, text.items, "fox").?;
    const at_fox = try set.create(gpa, text.items, @intCast(fox), .right);
    const at_end = try set.create(gpa, text.items, @intCast(text.items.len), .left);
    const quick = std.mem.indexOf(u8, text.items, "quick").?;
    const in_quick = try set.create(gpa, text.items, @intCast(quick + 2), .left);

    // An edit before: everything shifts.
    try edit(&set, &text, 2, 5, "A much longer title");
    var r = set.resolve(at_fox, text.items).?;
    try testing.expect(r.exact);
    try testing.expectEqualStrings("fox", text.items[r.offset .. r.offset + 3]);
    try testing.expectEqual(text.items.len, set.resolve(at_end, text.items).?.offset);

    // An edit inside the anchored word: a left anchor moves to its start.
    const q = std.mem.indexOf(u8, text.items, "quick").?;
    try edit(&set, &text, @intCast(q), 5, "slow");
    try testing.expectEqual(q, set.get(in_quick).?.offset);
    // Insertions exactly at an anchor follow its bias.
    const f = set.get(at_fox).?.offset;
    try edit(&set, &text, f, 0, "red ");
    try testing.expectEqual(f + 4, set.get(at_fox).?.offset);
    r = set.resolve(at_fox, text.items).?;
    try testing.expectEqualStrings("fox", text.items[r.offset .. r.offset + 3]);

    // A change the session missed: the quote finds the place again.
    text.clearRetainingCapacity();
    try text.appendSlice(gpa, "Inserted elsewhere.\n\n# A much longer title\n\nThe slow brown red fox jumps over the lazy dog.\n");
    set.items.items[at_fox].offset = 3;
    r = set.resolve(at_fox, text.items).?;
    try testing.expect(r.exact);
    try testing.expectEqualStrings("fox", text.items[r.offset .. r.offset + 3]);
    // Gone entirely: the old offset, flagged.
    const gone = &set.items.items[at_fox];
    @memset(gone.quote[0..gone.quote_len], 'Z');
    try testing.expect(!set.resolve(at_fox, text.items).?.exact);
    set.remove(at_fox);
    try testing.expect(set.resolve(at_fox, text.items) == null);
}

test "resolving in a 1 MB document is fast" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    while (text.items.len < 1 << 20) try text.appendSlice(gpa, "## Heading\n\nSome words in a paragraph of prose.\n\n");
    var set: anchors.Anchors = .{};
    defer set.deinit(gpa);
    const id = try set.create(gpa, text.items, @intCast(text.items.len - 1000), .right);
    try edit(&set, &text, 10, 3, "longer text");
    const r = set.resolve(id, text.items).?;
    try testing.expect(r.exact);
}
