//! OSC 8 hyperlinks for a page: a small refcounted link table whose URI and
//! id strings live in a bump arena, deduplicated by (uri, id). The arena is
//! reset when the last link is released. A `CellMap` maps cell → link id.

const std = @import("std");

/// A hyperlink as seen by callers.
pub const Link = struct {
    uri: []const u8,
    /// The explicit OSC 8 `id=` parameter, or empty.
    id: []const u8 = "",
};

/// One stored link. Id = index + 1.
pub const Entry = extern struct {
    uri_off: u32,
    uri_len: u32,
    id_off: u32,
    id_len: u32,
    refs: u32,
    hash: u32,
};

/// The link table and string arena in a page buffer.
pub const Table = struct {
    entries_off: u32,
    cap: u16,
    arena_off: u32,
    arena_len: u32,

    /// Mutable counters kept in the page header.
    pub const State = extern struct {
        used: u16 = 0,
        live: u16 = 0,
        arena_used: u32 = 0,
        /// Links dropped because the table or arena was full (debug stat).
        dropped: u32 = 0,
    };

    fn entries(t: Table, base: [*]u8) []Entry {
        const p: [*]Entry = @ptrCast(@alignCast(base + t.entries_off));
        return p[0..t.cap];
    }

    fn str(t: Table, base: [*]u8, off: u32, len: u32) []const u8 {
        return (base + t.arena_off)[off..][0..len];
    }

    fn hashOf(l: Link) u32 {
        var h: std.hash.Wyhash = .init(0);
        h.update(l.uri);
        h.update(&.{0});
        h.update(l.id);
        return @truncate(h.final());
    }

    /// The link with id `id`.
    pub fn get(t: Table, base: [*]u8, id: u16) Link {
        const e = t.entries(base)[id - 1];
        return .{ .uri = t.str(base, e.uri_off, e.uri_len), .id = t.str(base, e.id_off, e.id_len) };
    }

    /// The reference count of `id`.
    pub fn refs(t: Table, base: [*]u8, id: u16) u32 {
        return t.entries(base)[id - 1].refs;
    }

    /// Returns the id of `l` with one more reference, inserting it if needed.
    pub fn intern(t: Table, base: [*]u8, st: *State, l: Link) error{LinkTableFull}!u16 {
        const h = hashOf(l);
        const ents = t.entries(base);
        var free_slot: ?usize = null;
        for (ents[0..st.used], 0..) |*e, i| {
            if (e.refs == 0) {
                if (free_slot == null) free_slot = i;
                continue;
            }
            if (e.hash == h and std.mem.eql(u8, t.str(base, e.uri_off, e.uri_len), l.uri) and
                std.mem.eql(u8, t.str(base, e.id_off, e.id_len), l.id))
            {
                e.refs += 1;
                return @intCast(i + 1);
            }
        }
        const need = l.uri.len + l.id.len;
        if (st.arena_used + need > t.arena_len) {
            st.dropped += 1;
            return error.LinkTableFull;
        }
        const slot = free_slot orelse blk: {
            if (st.used == t.cap) {
                st.dropped += 1;
                return error.LinkTableFull;
            }
            st.used += 1;
            break :blk st.used - 1;
        };
        const a = base + t.arena_off;
        const uo = st.arena_used;
        @memcpy(a[uo..][0..l.uri.len], l.uri);
        const io = uo + @as(u32, @intCast(l.uri.len));
        @memcpy(a[io..][0..l.id.len], l.id);
        st.arena_used = io + @as(u32, @intCast(l.id.len));
        ents[slot] = .{ .uri_off = uo, .uri_len = @intCast(l.uri.len), .id_off = io, .id_len = @intCast(l.id.len), .refs = 1, .hash = h };
        st.live += 1;
        return @intCast(slot + 1);
    }

    /// Adds one reference to `id`.
    pub fn retain(t: Table, base: [*]u8, id: u16) void {
        t.entries(base)[id - 1].refs += 1;
    }

    /// Drops one reference to `id`.
    pub fn release(t: Table, base: [*]u8, st: *State, id: u16) void {
        const e = &t.entries(base)[id - 1];
        std.debug.assert(e.refs > 0);
        e.refs -= 1;
        if (e.refs != 0) return;
        st.live -= 1;
        if (st.live == 0) {
            st.used = 0;
            st.arena_used = 0;
        }
    }
};
