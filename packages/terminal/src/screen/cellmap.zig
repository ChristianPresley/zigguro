//! A fixed-capacity open-addressing map from cell index to two u32 values,
//! stored inside a page buffer. Linear probing with backward-shift deletion,
//! so there are no tombstones and the table never needs rebuilding.

const std = @import("std");

/// One slot. `key` is the cell index + 1 (0 = empty).
pub const Slot = extern struct { key: u32, a: u32, b: u32 };

/// The map's location in a page buffer.
pub const CellMap = struct {
    off: u32,
    /// Slot count (a power of two).
    cap: u32,

    /// Mutable counters kept in the page header.
    pub const State = extern struct { count: u32 = 0 };

    /// Bytes needed for `cap` slots.
    pub fn bytes(cap: u32) u32 {
        return cap * @sizeOf(Slot);
    }

    fn slots(m: CellMap, base: [*]u8) []Slot {
        const p: [*]Slot = @ptrCast(@alignCast(base + m.off));
        return p[0..m.cap];
    }

    fn home(m: CellMap, key: u32) u32 {
        // Fibonacci hashing spreads consecutive cell indexes.
        return @truncate((@as(u64, key) *% 0x9E3779B97F4A7C15) >> 32 & (m.cap - 1));
    }

    /// The slot for `cell`, if present.
    pub fn get(m: CellMap, base: [*]u8, cell: u32) ?*Slot {
        const s = m.slots(base);
        const key = cell + 1;
        var i = m.home(key);
        while (s[i].key != 0) : (i = (i + 1) & (m.cap - 1)) {
            if (s[i].key == key) return &s[i];
        }
        return null;
    }

    /// Inserts or overwrites `cell`. Fails when the map is 3/4 full.
    pub fn put(m: CellMap, base: [*]u8, st: *State, cell: u32, a: u32, b: u32) error{MapFull}!void {
        if (m.get(base, cell)) |slot| {
            slot.a = a;
            slot.b = b;
            return;
        }
        if ((st.count + 1) * 4 > m.cap * 3) return error.MapFull;
        const s = m.slots(base);
        var i = m.home(cell + 1);
        while (s[i].key != 0) i = (i + 1) & (m.cap - 1);
        s[i] = .{ .key = cell + 1, .a = a, .b = b };
        st.count += 1;
    }

    /// Removes `cell` if present.
    pub fn remove(m: CellMap, base: [*]u8, st: *State, cell: u32) void {
        const s = m.slots(base);
        const mask = m.cap - 1;
        var i = m.home(cell + 1);
        while (s[i].key != cell + 1) : (i = (i + 1) & mask) {
            if (s[i].key == 0) return;
        }
        st.count -= 1;
        // Backward-shift deletion.
        var j = i;
        while (true) {
            j = (j + 1) & mask;
            if (s[j].key == 0) break;
            const h = m.home(s[j].key);
            // Move s[j] into the hole at i unless its home lies in (i, j].
            const in_range = if (i <= j) (h > i and h <= j) else (h > i or h <= j);
            if (in_range) continue;
            s[i] = s[j];
            i = j;
        }
        s[i] = .{ .key = 0, .a = 0, .b = 0 };
    }

    /// Empties the map.
    pub fn clear(m: CellMap, base: [*]u8, st: *State) void {
        @memset(std.mem.sliceAsBytes(m.slots(base)), 0);
        st.count = 0;
    }

    /// Iterates over occupied slots.
    pub fn items(m: CellMap, base: [*]u8) []Slot {
        return m.slots(base);
    }
};

test "CellMap put/get/remove keeps probe chains intact" {
    var buf: [CellMap.bytes(64)]u8 align(8) = undefined;
    const m: CellMap = .{ .off = 0, .cap = 64 };
    var st: CellMap.State = .{};
    m.clear(&buf, &st);
    var prng: std.Random.DefaultPrng = .init(1);
    const r = prng.random();
    var present: [200]bool = @splat(false);
    for (0..5000) |_| {
        const k = r.uintLessThan(u32, 200);
        if (r.boolean()) {
            m.put(&buf, &st, k, k * 3, 7) catch {
                try std.testing.expect(!present[k]);
                continue;
            };
            present[k] = true;
        } else {
            m.remove(&buf, &st, k);
            present[k] = false;
        }
        var n: u32 = 0;
        for (present, 0..) |p, key| {
            const got = m.get(&buf, @intCast(key));
            try std.testing.expectEqual(p, got != null);
            if (got) |g| try std.testing.expectEqual(@as(u32, @intCast(key)) * 3, g.a);
            if (p) n += 1;
        }
        try std.testing.expectEqual(n, st.count);
    }
}
