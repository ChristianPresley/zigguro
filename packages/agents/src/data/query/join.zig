//! Join-lite for query execution (E13.F06.S02.T03): the joined dataset's
//! rows in a hash table on its key column, probed once per left row.
//! Null keys never match. Up to `max_rows` rows (else
//! `error.JoinTooLarge`).

const std = @import("std");
const ev = @import("expr_eval.zig");

const Allocator = std.mem.Allocator;
const Value = ev.Value;

pub const max_rows = 10_000_000;

pub const JoinTable = struct {
    arena: Allocator,
    key: u32,
    width: usize,
    rows: std.ArrayListUnmanaged([]const Value) = .empty,
    heads: std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(u32)) = .empty,

    pub fn init(arena: Allocator, key: u32, width: usize) JoinTable {
        return .{ .arena = arena, .key = key, .width = width };
    }

    /// Adds a row (kept as given: the caller's copy must outlive the
    /// table).
    pub fn add(t: *JoinTable, row: []const Value) !void {
        if (t.rows.items.len >= max_rows) return error.JoinTooLarge;
        const idx: u32 = @intCast(t.rows.items.len);
        try t.rows.append(t.arena, row);
        const k = row[t.key];
        if (k == .null_) return;
        const gop = try t.heads.getOrPut(t.arena, ev.hashValue(k, 0));
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(t.arena, idx);
    }

    /// Calls `f(ctx, row)` for every row whose key equals `key`, in the
    /// joined dataset's order; returns how many matched.
    pub fn probe(t: *const JoinTable, key: Value, ctx: anytype, comptime f: fn (@TypeOf(ctx), []const Value, u32) anyerror!void) !u32 {
        if (key == .null_) return 0;
        const list = t.heads.get(ev.hashValue(key, 0)) orelse return 0;
        var n: u32 = 0;
        for (list.items) |i| {
            const row = t.rows.items[i];
            if (!ev.sameKey(row[t.key], key)) continue;
            try f(ctx, row, n);
            n += 1;
        }
        return n;
    }
};
