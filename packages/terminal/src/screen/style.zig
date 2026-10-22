//! Cell styles and the page-local, refcounted `StyleSet`.
//!
//! Ids are stable for as long as any cell holds a reference: entries live in
//! a fixed array (id = index + 1) and a separate open-addressing index maps
//! hashes to ids, so the index can be rebuilt (`gc`) without moving entries.

const std = @import("std");

/// A cell color.
pub const Color = extern struct {
    tag: Tag = .default,
    /// Palette index for `.palette`; red for `.rgb`.
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,

    /// Color kinds.
    pub const Tag = enum(u8) { default, palette, rgb };

    /// The default color.
    pub const default: Color = .{};

    /// A palette color.
    pub fn palette(i: u8) Color {
        return .{ .tag = .palette, .r = i };
    }

    /// A truecolor value.
    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .tag = .rgb, .r = r, .g = g, .b = b };
    }

    /// Exact equality.
    pub fn eql(a: Color, b: Color) bool {
        return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
    }
};

/// Underline styles (SGR 4 and 4:n).
pub const Underline = enum(u8) { none, single, double, curly, dotted, dashed };

/// Boolean attributes.
pub const Flags = packed struct(u16) {
    bold: bool = false,
    faint: bool = false,
    italic: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strike: bool = false,
    overline: bool = false,
    _p: u8 = 0,
};

/// A complete cell style (16 bytes, no implicit padding).
pub const Style = extern struct {
    fg: Color = .{},
    bg: Color = .{},
    ul_color: Color = .{},
    flags: Flags = .{},
    underline: Underline = .none,
    _pad: u8 = 0,

    /// The default style (id 0, never stored).
    pub const default: Style = .{};

    /// Exact equality.
    pub fn eql(a: Style, b: Style) bool {
        return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
    }

    /// Whether this is the default style.
    pub fn isDefault(s: Style) bool {
        return s.eql(default);
    }

    fn hash(s: Style) u32 {
        var n = s;
        n._pad = 0;
        n.flags._p = 0;
        return @truncate(std.hash.Wyhash.hash(0, std.mem.asBytes(&n)));
    }
};

comptime {
    std.debug.assert(@sizeOf(Style) == 16);
}

/// A stored style with its reference count.
pub const Entry = extern struct {
    style: Style,
    refs: u32,
    /// Next free entry index + 1 (0 ends the list) while `refs == 0`.
    next_free: u16,
    _pad: u16 = 0,
};

const empty_slot: u16 = 0;
const tomb_slot: u16 = 0xFFFF;

/// Index capacity for `cap` entries (power of two, at least twice `cap`).
pub fn indexCap(cap: u16) u32 {
    return std.math.ceilPowerOfTwoAssert(u32, @max(4, @as(u32, cap) * 2));
}

/// A refcounted style table living inside a page buffer at fixed offsets.
/// All state is in the buffer (`Header` fields are passed by pointer) so a
/// page can be cloned with one `@memcpy`.
pub const StyleSet = struct {
    /// Entry array offset from the page base.
    entries_off: u32,
    /// Index array offset from the page base.
    index_off: u32,
    /// Maximum number of distinct live styles (max id).
    cap: u16,

    /// Mutable counters kept in the page header.
    pub const State = extern struct {
        /// Entries ever handed out (bump pointer).
        used: u16 = 0,
        /// Head of the free list (index + 1).
        free_head: u16 = 0,
        live: u16 = 0,
        tombs: u32 = 0,
    };

    fn entries(s: StyleSet, base: [*]u8) []Entry {
        const p: [*]Entry = @ptrCast(@alignCast(base + s.entries_off));
        return p[0..s.cap];
    }

    fn index(s: StyleSet, base: [*]u8) []u16 {
        const p: [*]u16 = @ptrCast(@alignCast(base + s.index_off));
        return p[0..indexCap(s.cap)];
    }

    /// The style for `id` (0 is the default style).
    pub fn get(s: StyleSet, base: [*]u8, id: u16) *const Style {
        if (id == 0) return &Style.default;
        return &s.entries(base)[id - 1].style;
    }

    /// The reference count of `id`.
    pub fn refs(s: StyleSet, base: [*]u8, id: u16) u32 {
        return s.entries(base)[id - 1].refs;
    }

    /// Returns the id of `st` with one more reference, inserting it if needed.
    pub fn intern(s: StyleSet, base: [*]u8, st_ptr: *State, st: Style) error{StyleSetFull}!u16 {
        return s.internN(base, st_ptr, st, 1);
    }

    /// Like `intern`, adding `n` references at once (a run of cells).
    pub fn internN(s: StyleSet, base: [*]u8, state: *State, st: Style, n: u32) error{StyleSetFull}!u16 {
        if (st.isDefault()) return 0;
        const ents = s.entries(base);
        const idx = s.index(base);
        const mask = idx.len - 1;
        const h = st.hash();
        var i: usize = h & mask;
        var first_tomb: ?usize = null;
        while (true) : (i = (i + 1) & mask) {
            const v = idx[i];
            if (v == empty_slot) break;
            if (v == tomb_slot) {
                if (first_tomb == null) first_tomb = i;
                continue;
            }
            if (ents[v - 1].style.eql(st)) {
                ents[v - 1].refs += n;
                return v;
            }
        }
        // Insert a new entry.
        const id: u16 = if (state.free_head != 0) blk: {
            const id = state.free_head;
            state.free_head = ents[id - 1].next_free;
            break :blk id;
        } else if (state.used < s.cap) blk: {
            state.used += 1;
            break :blk state.used;
        } else return error.StyleSetFull;
        ents[id - 1] = .{ .style = st, .refs = n, .next_free = 0 };
        state.live += 1;
        if (first_tomb) |t| {
            idx[t] = id;
            state.tombs -= 1;
        } else idx[i] = id;
        // Keep probe chains short: rebuild when tombstones pile up.
        if (state.tombs > idx.len / 4) s.gc(base, state);
        return id;
    }

    /// Adds `n` references to `id` (0 is a no-op).
    pub fn retain(s: StyleSet, base: [*]u8, id: u16, n: u32) void {
        if (id == 0) return;
        s.entries(base)[id - 1].refs += n;
    }

    /// Drops `n` references to `id`; the entry is freed at zero.
    pub fn release(s: StyleSet, base: [*]u8, state: *State, id: u16, n: u32) void {
        if (id == 0) return;
        const ents = s.entries(base);
        const e = &ents[id - 1];
        std.debug.assert(e.refs >= n);
        e.refs -= n;
        if (e.refs != 0) return;
        const idx = s.index(base);
        const mask = idx.len - 1;
        var i: usize = e.style.hash() & mask;
        while (idx[i] != id) : (i = (i + 1) & mask) std.debug.assert(idx[i] != empty_slot);
        idx[i] = tomb_slot;
        state.tombs += 1;
        state.live -= 1;
        e.next_free = state.free_head;
        state.free_head = id;
    }

    /// Rebuilds the index from live entries, dropping tombstones.
    pub fn gc(s: StyleSet, base: [*]u8, state: *State) void {
        const ents = s.entries(base);
        const idx = s.index(base);
        @memset(idx, empty_slot);
        const mask = idx.len - 1;
        for (ents[0..state.used], 0..) |e, k| {
            if (e.refs == 0) continue;
            var i: usize = e.style.hash() & mask;
            while (idx[i] != empty_slot) i = (i + 1) & mask;
            idx[i] = @intCast(k + 1);
        }
        state.tombs = 0;
    }

    /// Zeroes the table.
    pub fn clear(s: StyleSet, base: [*]u8, state: *State) void {
        @memset(s.index(base), empty_slot);
        state.* = .{};
    }

    /// Checks that `counts[id]` (refs computed from cells) equals every
    /// entry's refcount and that the index finds every live entry.
    pub fn verify(s: StyleSet, base: [*]u8, state: *const State, counts: []const u32) !void {
        const ents = s.entries(base);
        var live: u16 = 0;
        for (ents[0..state.used], 0..) |e, k| {
            if (e.refs != counts[k + 1]) return error.StyleRefcountMismatch;
            if (e.refs == 0) continue;
            live += 1;
            const idx = s.index(base);
            const mask = idx.len - 1;
            var i: usize = e.style.hash() & mask;
            while (idx[i] != k + 1) : (i = (i + 1) & mask) {
                if (idx[i] == empty_slot) return error.StyleIndexMissing;
            }
        }
        if (live != state.live) return error.StyleLiveCount;
    }
};

test "StyleSet intern/release/refcount/gc; full → error after gc" {
    const cap = 8;
    var buf: [cap * @sizeOf(Entry) + 64 * 2]u8 align(8) = undefined;
    const set: StyleSet = .{ .entries_off = 0, .index_off = cap * @sizeOf(Entry), .cap = cap };
    var st: StyleSet.State = .{};
    set.clear(&buf, &st);
    const red: Style = .{ .fg = .palette(1) };
    const a = try set.intern(&buf, &st, red);
    const b = try set.intern(&buf, &st, red);
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(@as(u32, 2), set.refs(&buf, a));
    try std.testing.expectEqual(@as(u16, 0), try set.intern(&buf, &st, .{}));
    set.release(&buf, &st, a, 2);
    try std.testing.expectEqual(@as(u16, 0), st.live);
    var ids: [cap]u16 = undefined;
    for (&ids, 0..) |*id, i| id.* = try set.intern(&buf, &st, .{ .fg = .rgb(@intCast(i), 0, 0) });
    try std.testing.expectError(error.StyleSetFull, set.intern(&buf, &st, .{ .fg = .rgb(99, 0, 0) }));
    set.release(&buf, &st, ids[3], 1);
    set.gc(&buf, &st);
    const again = try set.intern(&buf, &st, .{ .fg = .rgb(99, 0, 0) });
    try std.testing.expectEqual(ids[3], again);
    for (ids, 0..) |id, i| try std.testing.expect(set.get(&buf, id).eql(if (i == 3) Style{ .fg = .rgb(99, 0, 0) } else Style{ .fg = .rgb(@intCast(i), 0, 0) }));
}
