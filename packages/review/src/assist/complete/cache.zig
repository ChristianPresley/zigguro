//! The completion cache (E12.F07.S01.T01): finished completions keyed by
//! the text around the cursor, so retyping or coming back to the same
//! spot paints without a request. `extend` reuses a completion the user is
//! typing through: after typing `t` where `c` was shown, `c[t.len..]` is
//! the answer at the new spot.
//!
//! Least recently used entries go first once the cache holds more than
//! `max_entries` completions or `max_bytes` of text.

const std = @import("std");

const Allocator = std.mem.Allocator;
const XxHash3 = std.hash.XxHash3;

/// Bytes of prefix and suffix that key a completion.
pub const prefix_tail = 2048;
pub const suffix_head = 256;

pub const CacheKey = struct {
    doc: u32,
    /// The last 2 KiB of the prefix.
    prefix_tail_hash: u64,
    /// The first 256 bytes of the suffix.
    suffix_head_hash: u64,
    model: u32,

    pub fn of(doc: u32, prefix: []const u8, suffix: []const u8, model: u32) CacheKey {
        return .{
            .doc = doc,
            .prefix_tail_hash = XxHash3.hash(0, prefix[prefix.len -| prefix_tail..]),
            .suffix_head_hash = XxHash3.hash(0, suffix[0..@min(suffix.len, suffix_head)]),
            .model = model,
        };
    }
};

const Entry = struct {
    text: []u8,
    used: u64,
};

pub const Cache = struct {
    gpa: Allocator,
    max_entries: u32,
    max_bytes: u32,
    map: std.AutoHashMapUnmanaged(CacheKey, Entry) = .empty,
    bytes: usize = 0,
    clock: u64 = 0,

    pub fn init(gpa: Allocator, max_entries: u32, max_bytes: u32) Cache {
        return .{ .gpa = gpa, .max_entries = max_entries, .max_bytes = max_bytes };
    }

    pub fn deinit(c: *Cache) void {
        var it = c.map.valueIterator();
        while (it.next()) |e| c.gpa.free(e.text);
        c.map.deinit(c.gpa);
    }

    pub fn count(c: *const Cache) usize {
        return c.map.count();
    }

    /// The completion at `k`, if cached (valid until the next `put`).
    pub fn get(c: *Cache, k: CacheKey) ?[]const u8 {
        const e = c.map.getPtr(k) orelse return null;
        c.clock += 1;
        e.used = c.clock;
        return e.text;
    }

    /// Stores `text` at `k` (copied), evicting the least recently used.
    pub fn put(c: *Cache, k: CacheKey, text: []const u8) !void {
        if (text.len > c.max_bytes) return;
        const copy = try c.gpa.dupe(u8, text);
        errdefer c.gpa.free(copy);
        c.clock += 1;
        const gop = try c.map.getOrPut(c.gpa, k);
        if (gop.found_existing) {
            c.bytes -= gop.value_ptr.text.len;
            c.gpa.free(gop.value_ptr.text);
        }
        gop.value_ptr.* = .{ .text = copy, .used = c.clock };
        c.bytes += copy.len;
        while (c.map.count() > c.max_entries or c.bytes > c.max_bytes) c.evictOldest();
    }

    /// The rest of the completion at `prev` after the user typed `typed`
    /// through it, stored and returned under `new`; null when `typed` is
    /// not its start or nothing is left.
    pub fn extend(c: *Cache, prev: CacheKey, typed: []const u8, new: CacheKey) !?[]const u8 {
        const old = c.get(prev) orelse return null;
        if (typed.len >= old.len or !std.mem.startsWith(u8, old, typed)) return null;
        // `put` may free `old`'s entry (eviction): copy the rest first.
        const rest = try c.gpa.dupe(u8, old[typed.len..]);
        defer c.gpa.free(rest);
        try c.put(new, rest);
        return c.get(new);
    }

    /// Drops every completion of `doc` (a non-typing edit before the
    /// cursor, a settings reload).
    pub fn invalidateDoc(c: *Cache, doc: u32) void {
        while (true) {
            var it = c.map.iterator();
            const k = while (it.next()) |e| {
                if (e.key_ptr.doc == doc) break e.key_ptr.*;
            } else return;
            c.remove(k);
        }
    }

    fn evictOldest(c: *Cache) void {
        var it = c.map.iterator();
        var oldest: ?CacheKey = null;
        var used: u64 = std.math.maxInt(u64);
        while (it.next()) |e| if (e.value_ptr.used < used) {
            used = e.value_ptr.used;
            oldest = e.key_ptr.*;
        };
        c.remove(oldest orelse return);
    }

    fn remove(c: *Cache, k: CacheKey) void {
        const kv = c.map.fetchRemove(k) orelse return;
        c.bytes -= kv.value.text.len;
        c.gpa.free(kv.value.text);
    }
};
