//! Crash annotations: a static, lock-free key/value table that the crash
//! path snapshots. Keys are comptime strings mapped to slots at comptime,
//! so an unknown key is a compile error. Each slot is a seqlock: writers
//! make `seq` odd, copy, make it even; readers retry up to 3 times and
//! report `<torn>` rather than block.
//!
//! Registered keys (owning epic): `ui.view`, `ui.modal` (E04), `cmd.last`
//! (E15), `gpu.device`, `gpu.driver`, `gpu.api` (E02), `boot_pending`,
//! `update.channel` (E17), `agent.state` (E10, state only, no content),
//! `scm.op` (E09). Add keys to `keys` below.

const std = @import("std");

/// Table capacity.
pub const max_keys = 64;
/// Longest key.
pub const max_key_len = 31;
/// Longest value; longer values are cut.
pub const max_value_len = 224;

/// Every key that may be set (plus two test-only keys in test builds).
pub const keys = [_][]const u8{
    "ui.view", "ui.modal",     "cmd.last",       "gpu.device",  "gpu.driver",
    "gpu.api", "boot_pending", "update.channel", "agent.state", "scm.op",
} ++ if (@import("builtin").is_test) [_][]const u8{ "test.a", "test.b" } else [_][]const u8{};

comptime {
    std.debug.assert(keys.len <= max_keys);
    for (keys) |k| std.debug.assert(k.len <= max_key_len);
}

const Slot = struct {
    seq: std.atomic.Value(u32) = .init(0),
    len: u8 = 0,
    value: [max_value_len]u8 = undefined,
};

var slots: [keys.len]Slot = @splat(.{});

fn slotIndex(comptime key: []const u8) usize {
    inline for (keys, 0..) |k, i| {
        if (comptime std.mem.eql(u8, k, key)) return i;
    }
    @compileError("unknown crash annotation key \"" ++ key ++ "\"; add it to zg_crash.annotations.keys");
}

/// Sets `key` to `value` (cut to `max_value_len`). Concurrent `set`s of
/// the same key are serialized by the seqlock's odd state.
pub fn set(comptime key: []const u8, value: []const u8) void {
    const s = &slots[comptime slotIndex(key)];
    // Claim: wait for even, then CAS to odd.
    while (true) {
        const cur = s.seq.load(.monotonic);
        if (cur & 1 == 0 and s.seq.cmpxchgWeak(cur, cur + 1, .acquire, .monotonic) == null) break;
        std.atomic.spinLoopHint();
    }
    const n = @min(value.len, max_value_len);
    @memcpy(s.value[0..n], value[0..n]);
    s.len = @intCast(n);
    _ = s.seq.fetchAdd(1, .release);
}

/// Clears `key`.
pub fn clear(comptime key: []const u8) void {
    set(key, "");
}

/// One snapshot entry; `value` points into the caller's storage.
pub const Pair = struct {
    key: []const u8,
    value: []const u8,
    torn: bool = false,
};

/// Storage a snapshot copies values into (lives in preallocated memory).
pub const SnapshotStorage = struct {
    values: [max_keys][max_value_len]u8 = undefined,
};

/// Copies every non-empty annotation into `out` (values into `storage`).
/// Never blocks; returns the count.
pub fn snapshot(out: *[max_keys]Pair, storage: *SnapshotStorage) usize {
    var n: usize = 0;
    for (&slots, keys, 0..) |*s, k, i| {
        var tries: u8 = 0;
        const pair: Pair = while (tries < 3) : (tries += 1) {
            const before = s.seq.load(.acquire);
            if (before & 1 != 0) continue;
            const len = @min(s.len, max_value_len);
            @memcpy(storage.values[i][0..len], s.value[0..len]);
            // An acq_rel no-op RMW orders the copy before the re-check
            // (0.16 has no standalone fence).
            if (s.seq.fetchAdd(0, .acq_rel) == before) break .{ .key = k, .value = storage.values[i][0..len] };
        } else .{ .key = k, .value = "<torn>", .torn = true };
        if (pair.value.len == 0) continue;
        out[n] = pair;
        n += 1;
    }
    return n;
}

/// Writes an ANNOTATIONS section body: `count: u32`, then for each entry
/// `key_len: u8, value_len: u8, key, value`.
pub fn encode(pairs: []const Pair, s: anytype) void {
    s.writeInt(u32, @intCast(pairs.len));
    for (pairs) |p| {
        const vl: u8 = @intCast(@min(p.value.len, 255));
        s.write(&.{ @intCast(p.key.len), vl });
        s.write(p.key);
        s.write(p.value[0..vl]);
    }
}

/// Decodes an ANNOTATIONS section into `out`; returns the count.
pub fn decode(data: []const u8, out: []Pair) usize {
    if (data.len < 4) return 0;
    const count = std.mem.readInt(u32, data[0..4], .little);
    var pos: usize = 4;
    var n: usize = 0;
    while (n < count and n < out.len and data.len - pos >= 2) : (n += 1) {
        const kl = data[pos];
        const vl = data[pos + 1];
        pos += 2;
        if (data.len - pos < @as(usize, kl) + vl) break;
        out[n] = .{ .key = data[pos..][0..kl], .value = data[pos + kl ..][0..vl] };
        pos += @as(usize, kl) + vl;
    }
    return n;
}

test "annotations: set and snapshot" {
    set("test.a", "hello");
    set("test.b", "x" ** 300);
    var out: [max_keys]Pair = undefined;
    var st: SnapshotStorage = .{};
    const n = snapshot(&out, &st);
    var found_a = false;
    for (out[0..n]) |p| {
        if (std.mem.eql(u8, p.key, "test.a")) {
            found_a = true;
            try std.testing.expectEqualStrings("hello", p.value);
        }
        if (std.mem.eql(u8, p.key, "test.b")) try std.testing.expectEqual(@as(usize, max_value_len), p.value.len);
    }
    try std.testing.expect(found_a);
    clear("test.a");
    clear("test.b");
}

test "annotations: concurrent set/snapshot torn detection" {
    const T = struct {
        fn writer(stop: *std.atomic.Value(bool), id: u8) void {
            var buf: [max_value_len]u8 = undefined;
            var i: usize = 0;
            while (!stop.load(.monotonic)) : (i += 1) {
                const len = 10 + (i % 200);
                @memset(buf[0..len], 'a' + id);
                set("test.a", buf[0..len]);
            }
        }
    };
    var stop: std.atomic.Value(bool) = .init(false);
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, T.writer, .{ &stop, @as(u8, @intCast(i)) });
    var out: [max_keys]Pair = undefined;
    var st: SnapshotStorage = .{};
    for (0..20_000) |_| {
        const n = snapshot(&out, &st);
        for (out[0..n]) |p| {
            if (!std.mem.eql(u8, p.key, "test.a") or p.torn) continue;
            // A consistent read is one writer's value: all bytes equal.
            for (p.value) |c| try std.testing.expectEqual(p.value[0], c);
        }
    }
    stop.store(true, .monotonic);
    for (threads) |t| t.join();
    clear("test.a");
}

test "annotations: encode/decode" {
    const pairs = [_]Pair{ .{ .key = "ui.view", .value = "editor" }, .{ .key = "scm.op", .value = "" } };
    const format = @import("format.zig");
    var out: [256]u8 = undefined;
    var ms: format.MemorySink = .{ .buf = &out };
    var wbuf: [256]u8 = undefined;
    var w: format.Writer = .{ .buf = &wbuf, .sink = ms.sink() };
    w.begin(0);
    var s = w.section(.annotations);
    encode(&pairs, &s);
    s.end();
    const sec = format.Reader.find(ms.bytes(), .annotations).?;
    var got: [4]Pair = undefined;
    try std.testing.expectEqual(@as(usize, 2), decode(sec.data, &got));
    try std.testing.expectEqualStrings("editor", got[0].value);
}
