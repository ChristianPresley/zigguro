//! Recently accepted QuickPick items (E04.F05.S04.T01): the last 50 ids per
//! picker, most recent first. Boosts them when the query is empty and
//! breaks score ties in their favour.
//!
//! Persisting the lists (the `ui_state.zon` section) waits on
//! E04.F07.S03.T01; until then the owner keeps an `Mru` per picker.

const std = @import("std");

/// How many ids a list keeps.
pub const capacity = 50;

/// One picker's recently accepted ids.
pub const Mru = struct {
    ids: [capacity]u64 = undefined,
    len: u8 = 0,

    /// Moves `id` to the front.
    pub fn touch(m: *Mru, id: u64) void {
        var at: usize = m.len;
        for (m.ids[0..m.len], 0..) |x, i| if (x == id) {
            at = i;
            break;
        };
        if (at == m.len) {
            if (m.len < capacity) m.len += 1;
            at = m.len - 1;
        }
        // Shift [0, at) right by one.
        var i = at;
        while (i > 0) : (i -= 1) m.ids[i] = m.ids[i - 1];
        m.ids[0] = id;
    }

    /// 0 for the most recent id, null when `id` is not in the list.
    pub fn rank(m: *const Mru, id: u64) ?u8 {
        for (m.ids[0..m.len], 0..) |x, i| if (x == id) return @intCast(i);
        return null;
    }

    /// The ids, most recent first.
    pub fn items(m: *const Mru) []const u64 {
        return m.ids[0..m.len];
    }
};

test "touch moves to front and caps the list" {
    var m: Mru = .{};
    m.touch(1);
    m.touch(2);
    m.touch(3);
    try std.testing.expectEqualSlices(u64, &.{ 3, 2, 1 }, m.items());
    m.touch(1);
    try std.testing.expectEqualSlices(u64, &.{ 1, 3, 2 }, m.items());
    try std.testing.expectEqual(@as(?u8, 2), m.rank(2));
    try std.testing.expect(m.rank(99) == null);
    var i: u64 = 100;
    while (i < 200) : (i += 1) m.touch(i);
    try std.testing.expectEqual(@as(usize, capacity), m.items().len);
    try std.testing.expectEqual(@as(u64, 199), m.items()[0]);
}
