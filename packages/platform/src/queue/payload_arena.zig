//! Storage for event payloads (key text, preedit, clipboard data, paths)
//! without per-event allocation. The platform thread appends to one of two
//! fixed slabs; the UI thread calls `flip` at the start of each drain, which
//! moves the producer to the other slab once nothing queued still points
//! into it. A slice therefore stays valid until the drain after the one that
//! delivered it.

const std = @import("std");
const types = @import("../api/types.zig");
const Event = @import("../api/event.zig").Event;
const PayloadSlice = types.PayloadSlice;

/// Bytes per slab.
pub const slab_size = 256 * 1024;

/// Payloads larger than this go to a `LargePayload` instead.
pub const max_inline = 64 * 1024;

const busy_bit: u8 = 0b10;

/// Two payload slabs shared by one producer and one consumer.
pub const PayloadArena = struct {
    /// The slabs, `slab_size` bytes each.
    slabs: [2][]u8,
    /// Bytes used in each slab. Only the producer touches the active slab's
    /// entry; `flip` resets the inactive one.
    used: [2]u32 = .{ 0, 0 },
    /// Bit 0: the slab the producer writes. Bit 1: a `put` is in progress.
    active: std.atomic.Value(u8) = .init(0),
    /// Slices handed out from each slab whose events have not been retired.
    pending: [2]std.atomic.Value(u32) = .{ .init(0), .init(0) },

    /// Allocates both slabs.
    pub fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!PayloadArena {
        const a = try gpa.alloc(u8, slab_size);
        errdefer gpa.free(a);
        const b = try gpa.alloc(u8, slab_size);
        return .{ .slabs = .{ a, b } };
    }

    /// Frees both slabs.
    pub fn deinit(self: *PayloadArena, gpa: std.mem.Allocator) void {
        gpa.free(self.slabs[0]);
        gpa.free(self.slabs[1]);
        self.* = undefined;
    }

    /// Copies `bytes` into the active slab. Producer thread only. Returns
    /// `error.OutOfSpace` when the slab is full or `bytes` exceeds
    /// `max_inline`; the caller then uses a `LargePayload`.
    pub fn put(self: *PayloadArena, bytes: []const u8) error{OutOfSpace}!PayloadSlice {
        if (bytes.len == 0) return .empty;
        if (bytes.len > max_inline) return error.OutOfSpace;
        const s = self.begin();
        defer self.end();
        const off = self.used[s];
        if (slab_size - off < bytes.len) return error.OutOfSpace;
        @memcpy(self.slabs[s][off..][0..bytes.len], bytes);
        return self.commit(s, off, @intCast(bytes.len));
    }

    /// Like `put`, but replaces each invalid UTF-8 sequence with U+FFFD, for
    /// text that comes from the OS.
    pub fn putUtf8(self: *PayloadArena, bytes: []const u8) error{OutOfSpace}!PayloadSlice {
        if (std.unicode.utf8ValidateSlice(bytes)) return self.put(bytes);
        if (bytes.len * 3 > max_inline) return error.OutOfSpace;
        const s = self.begin();
        defer self.end();
        const off = self.used[s];
        const dst = self.slabs[s][off..];
        var n: usize = 0;
        var i: usize = 0;
        while (i < bytes.len) {
            const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 0;
            const ok = len != 0 and i + len <= bytes.len and std.unicode.utf8ValidateSlice(bytes[i..][0..len]);
            const piece: []const u8 = if (ok) bytes[i..][0..len] else "\u{FFFD}";
            if (dst.len - n < piece.len) return error.OutOfSpace;
            @memcpy(dst[n..][0..piece.len], piece);
            n += piece.len;
            i += if (ok) len else invalidRun(bytes[i..], len);
        }
        return self.commit(s, off, @intCast(n));
    }

    /// The bytes one U+FFFD replaces: a lead byte and the continuation
    /// bytes of its truncated sequence (the "maximal subpart" rule).
    fn invalidRun(rest: []const u8, len: u3) usize {
        var n: usize = 1;
        while (n < len and n < rest.len and rest[n] & 0xc0 == 0x80) n += 1;
        return n;
    }

    fn begin(self: *PayloadArena) u1 {
        return @intCast(self.active.fetchOr(busy_bit, .acquire) & 1);
    }

    fn end(self: *PayloadArena) void {
        _ = self.active.fetchAnd(~busy_bit, .release);
    }

    fn commit(self: *PayloadArena, s: u1, off: u32, len: u32) PayloadSlice {
        self.used[s] = off + len;
        _ = self.pending[s].fetchAdd(1, .monotonic);
        return .{ .off = @intCast(off), .slab = s, .len = len };
    }

    /// The bytes of an arena slice (not a large payload).
    pub fn get(self: *const PayloadArena, s: PayloadSlice) []const u8 {
        std.debug.assert(!s.large);
        if (s.len == 0) return &.{};
        return self.slabs[s.slab][s.off..][0..s.len];
    }

    /// Marks the payloads of popped events as delivered. The consumer calls
    /// it for every event it pops.
    pub fn retire(self: *PayloadArena, ev: *const Event) void {
        forEachPayload(ev, self, retireOne);
    }

    fn retireOne(self: *PayloadArena, s: PayloadSlice) void {
        if (s.len == 0 or s.large) return;
        _ = self.pending[s.slab].fetchSub(1, .monotonic);
    }

    /// Called by the consumer before each drain. Moves the producer to the
    /// other slab when no undelivered slice points into it and no `put` is
    /// running, which invalidates slices delivered two drains ago. Returns
    /// whether it flipped.
    pub fn flip(self: *PayloadArena) bool {
        const cur = self.active.load(.acquire);
        if (cur & busy_bit != 0) return false;
        const other: u8 = (cur & 1) ^ 1;
        if (self.pending[other].load(.acquire) != 0) return false;
        self.used[other] = 0;
        return self.active.cmpxchgStrong(cur, other, .acq_rel, .monotonic) == null;
    }
};

/// Calls `f(ctx, slice)` for every `PayloadSlice` inside `ev`.
pub fn forEachPayload(ev: *const Event, ctx: anytype, comptime f: fn (@TypeOf(ctx), PayloadSlice) void) void {
    switch (ev.*) {
        inline else => |*payload| visit(@TypeOf(payload.*), payload, ctx, f),
    }
}

fn visit(comptime T: type, v: *const T, ctx: anytype, comptime f: fn (@TypeOf(ctx), PayloadSlice) void) void {
    if (T == PayloadSlice) return f(ctx, v.*);
    if (@typeInfo(T) != .@"struct" or @typeInfo(T).@"struct".layout == .@"packed") return;
    inline for (@typeInfo(T).@"struct".fields) |fld| visit(fld.type, &@field(v.*, fld.name), ctx, f);
}

const testing = std.testing;

test "payload arena slices valid until next flip" {
    var a = try PayloadArena.init(testing.allocator);
    defer a.deinit(testing.allocator);
    const s1 = try a.put("hello");
    try testing.expectEqualStrings("hello", a.get(s1));
    const ev1: Event = .{ .text_input = .{ .win = @enumFromInt(1), .text = s1 } };

    // Drain 1: the producer moves to the other slab; s1 stays readable.
    try testing.expect(a.flip());
    const s2 = try a.put("world");
    try testing.expect(s2.slab != s1.slab);
    a.retire(&ev1);
    try testing.expectEqualStrings("hello", a.get(s1));

    // Drain 2: s1 was delivered, so its slab is reused from the start.
    try testing.expect(a.flip());
    const s3 = try a.put("again");
    try testing.expectEqual(s1.slab, s3.slab);
    try testing.expectEqual(@as(u30, 0), s3.off);
    try testing.expectEqualStrings("world", a.get(s2));

    // Drain 3: s2 is still undelivered, so its slab must not be reset.
    try testing.expect(!a.flip());
    const ev2: Event = .{ .text_input = .{ .win = @enumFromInt(1), .text = s2 } };
    a.retire(&ev2);
    try testing.expect(a.flip());
}

test "flip waits for undelivered slices" {
    var a = try PayloadArena.init(testing.allocator);
    defer a.deinit(testing.allocator);
    try testing.expect(a.flip()); // producer on slab 1
    const s = try a.put("x");
    try testing.expectEqual(@as(u1, 1), s.slab);
    const ev: Event = .{ .key = .{ .win = @enumFromInt(1), .ev = .{ .key = .key_x, .keysym = 'x', .codepoint = 'x', .mods = .{}, .action = .press, .text = s, .native_scancode = 0, .time_ns = 0 } } };
    try testing.expect(a.flip()); // slab 0 is free, so the producer moves there
    try testing.expect(!a.flip()); // slab 1 still has the undelivered key text
    a.retire(&ev);
    try testing.expect(a.flip());
}

test "put rejects oversize payloads and a full slab" {
    var a = try PayloadArena.init(testing.allocator);
    defer a.deinit(testing.allocator);
    const big = try testing.allocator.alloc(u8, max_inline + 1);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    try testing.expectError(error.OutOfSpace, a.put(big));
    for (0..slab_size / max_inline) |_| _ = try a.put(big[0..max_inline]);
    try testing.expectError(error.OutOfSpace, a.put("x"));
    try testing.expectEqual(PayloadSlice.empty, try a.put(""));
}

test "putUtf8 replaces invalid sequences" {
    var a = try PayloadArena.init(testing.allocator);
    defer a.deinit(testing.allocator);
    try testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}é", a.get(try a.putUtf8("a\xffb\xe2\x82é")));
    try testing.expectEqualStrings("ok ✓", a.get(try a.putUtf8("ok ✓")));
}

test "forEachPayload finds nested and drop payloads" {
    const Counter = struct {
        n: usize = 0,
        fn add(c: *@This(), s: PayloadSlice) void {
            c.n += s.len;
        }
    };
    var c: Counter = .{};
    const drop: Event = .{ .drop = .{ .win = @enumFromInt(1), .phase = .enter, .allowed = .{}, .pos_px = .{ 0, 0 }, .mimes = .{ .len = 4 }, .data = .{ .len = 3 } } };
    forEachPayload(&drop, &c, Counter.add);
    try testing.expectEqual(7, c.n);
    const wake: Event = .wake;
    forEachPayload(&wake, &c, Counter.add);
    try testing.expectEqual(7, c.n);
}
