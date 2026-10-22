//! Per-document token storage: a gap buffer of line records (so splicing
//! lines at an edit is O(1) amortized for local edits) and one shared token
//! pool. A line whose new tokens fit in its old slot is rewritten in place;
//! otherwise its tokens are appended and the old slot becomes garbage,
//! which a compaction reclaims once it outweighs the live tokens.

const std = @import("std");
const Token = @import("../lex/scanner.zig").Token;
const StateId = @import("../lex/state.zig").StateId;

const Allocator = std.mem.Allocator;

pub const TokenStore = struct {
    /// One line's record (12 bytes).
    pub const LineRec = struct {
        end_state: StateId = .unknown,
        tok_off: u32 = 0,
        tok_len: u16 = 0,
        flags: Flags = .{},
    };

    pub const Flags = packed struct(u8) {
        /// Tokens are from an approximate start state (resync).
        approx: bool = false,
        /// Too long to tokenize: one plain token.
        long_line: bool = false,
        _: u6 = 0,
    };

    /// Compaction waits until the pool holds at least this many tokens.
    const compact_min = 4096;

    lines: []LineRec = &.{},
    gap_start: usize = 0,
    gap_end: usize = 0,
    pool: std.ArrayList(Token) = .empty,
    garbage: usize = 0,

    /// Frees the store.
    pub fn deinit(ts: *TokenStore, gpa: Allocator) void {
        gpa.free(ts.lines);
        ts.pool.deinit(gpa);
        ts.* = .{};
    }

    /// Number of lines.
    pub fn lineCount(ts: *const TokenStore) u64 {
        return ts.lines.len - (ts.gap_end - ts.gap_start);
    }

    fn index(ts: *const TokenStore, line: u64) usize {
        const i: usize = @intCast(line);
        return if (i < ts.gap_start) i else i + (ts.gap_end - ts.gap_start);
    }

    /// The record of `line`.
    pub fn rec(ts: *const TokenStore, line: u64) *LineRec {
        return &ts.lines[ts.index(line)];
    }

    /// The tokens of `line`.
    pub fn tokens(ts: *const TokenStore, line: u64) []const Token {
        const r = ts.rec(line);
        return ts.pool.items[r.tok_off..][0..r.tok_len];
    }

    /// Bytes used by records and the token pool (capacity included).
    pub fn memoryBytes(ts: *const TokenStore) usize {
        return ts.lines.len * @sizeOf(LineRec) + ts.pool.capacity * @sizeOf(Token);
    }

    /// Live tokens.
    pub fn liveTokens(ts: *const TokenStore) usize {
        return ts.pool.items.len - ts.garbage;
    }

    fn moveGap(ts: *TokenStore, at: usize) void {
        const gap = ts.gap_end - ts.gap_start;
        if (at < ts.gap_start) {
            const n = ts.gap_start - at;
            std.mem.copyBackwards(LineRec, ts.lines[ts.gap_end - n .. ts.gap_end], ts.lines[at..ts.gap_start]);
        } else if (at > ts.gap_start) {
            const n = at - ts.gap_start;
            std.mem.copyForwards(LineRec, ts.lines[ts.gap_start..][0..n], ts.lines[ts.gap_end..][0..n]);
        }
        ts.gap_start = at;
        ts.gap_end = at + gap;
    }

    /// Replaces `removed` lines at `at_line` with `inserted` empty lines.
    /// The new lines' end states are `unknown`, except that the last one
    /// keeps the last removed line's end state: relexing the edited lines
    /// then converges as soon as the block ends in the state it used to.
    pub fn spliceLines(ts: *TokenStore, gpa: Allocator, at_line: u64, removed: u64, inserted: u64) Allocator.Error!void {
        const at: usize = @intCast(at_line);
        const rm: usize = @intCast(removed);
        const ins: usize = @intCast(inserted);
        std.debug.assert(at + rm <= ts.lineCount());
        if (ins > rm and ts.gap_end - ts.gap_start < ins - rm) {
            // Grow, putting the gap at `at`.
            const len = ts.lineCount();
            const new_cap = @max(len + ins - rm + 64, (len + ins) * 3 / 2);
            const fresh = try gpa.alloc(LineRec, new_cap);
            ts.moveGap(at);
            @memcpy(fresh[0..at], ts.lines[0..at]);
            const tail = ts.lines[ts.gap_end..];
            @memcpy(fresh[new_cap - tail.len ..], tail);
            gpa.free(ts.lines);
            ts.lines = fresh;
            ts.gap_end = new_cap - tail.len;
        } else ts.moveGap(at);
        const last_end: StateId = if (rm > 0) ts.lines[ts.gap_end + rm - 1].end_state else .unknown;
        for (ts.lines[ts.gap_end..][0..rm]) |r| ts.garbage += r.tok_len;
        ts.gap_end += rm;
        @memset(ts.lines[ts.gap_start..][0..ins], .{});
        if (ins > 0) ts.lines[ts.gap_start + ins - 1].end_state = last_end;
        ts.gap_start += ins;
    }

    /// Stores `line`'s tokens and end state. Returns whether the end state
    /// changed.
    pub fn setLine(ts: *TokenStore, gpa: Allocator, line: u64, toks: []const Token, end: StateId, flags: Flags) Allocator.Error!bool {
        std.debug.assert(toks.len <= std.math.maxInt(u16));
        var r = ts.rec(line);
        if (toks.len > r.tok_len) {
            // A hard cap for edits between idle periods; `maintain` normally
            // compacts long before this.
            if (ts.garbage > ts.liveTokens() and ts.pool.items.len >= compact_min) try ts.compact(gpa);
            try ts.pool.ensureUnusedCapacity(gpa, toks.len);
            r = ts.rec(line);
            ts.garbage += r.tok_len;
            r.tok_off = @intCast(ts.pool.items.len);
            ts.pool.appendSliceAssumeCapacity(toks);
        } else {
            @memcpy(ts.pool.items[r.tok_off..][0..toks.len], toks);
            ts.garbage += r.tok_len - toks.len;
        }
        r.tok_len = @intCast(toks.len);
        r.flags = flags;
        const changed = r.end_state != end;
        r.end_state = end;
        return changed;
    }

    /// Compacts when garbage or spare capacity exceed a quarter of the live
    /// tokens. O(tokens); meant for idle time.
    pub fn maintain(ts: *TokenStore, gpa: Allocator) Allocator.Error!void {
        const live = ts.liveTokens();
        if (ts.pool.capacity < compact_min) return;
        if (ts.garbage * 4 > live or ts.pool.capacity > live + live / 4) try ts.compact(gpa);
    }

    /// Copies live tokens into a fresh pool, in line order, with 1/8 spare.
    fn compact(ts: *TokenStore, gpa: Allocator) Allocator.Error!void {
        var fresh: std.ArrayList(Token) = try .initCapacity(gpa, ts.liveTokens() + ts.liveTokens() / 8 + 64);
        const n = ts.lineCount();
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            const r = ts.rec(i);
            const off = fresh.items.len;
            fresh.appendSliceAssumeCapacity(ts.pool.items[r.tok_off..][0..r.tok_len]);
            r.tok_off = @intCast(off);
        }
        ts.pool.deinit(gpa);
        ts.pool = fresh;
        ts.garbage = 0;
    }
};

test "token_store: splice lines gap buffer" {
    const gpa = std.testing.allocator;
    var ts: TokenStore = .{};
    defer ts.deinit(gpa);
    // A model: per line, a token count and an end state.
    var model: std.ArrayList(struct { n: u16, end: u32 }) = .empty;
    defer model.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(41);
    const rnd = prng.random();
    var buf: [40]Token = undefined;

    for (0..3000) |step| {
        const len = model.items.len;
        if (len == 0 or rnd.uintLessThan(u8, 3) == 0) {
            const at = rnd.uintAtMost(usize, len);
            const rm = rnd.uintAtMost(usize, @min(len - at, 5));
            const ins = rnd.uintAtMost(usize, 8);
            try ts.spliceLines(gpa, at, rm, ins);
            const unknown = std.math.maxInt(u32);
            const last_end = if (rm > 0) model.items[at + rm - 1].end else unknown;
            for (0..rm) |_| _ = model.orderedRemove(at);
            for (0..ins) |_| try model.insert(gpa, at, .{ .n = 0, .end = unknown });
            if (ins > 0) model.items[at + ins - 1].end = last_end;
        } else {
            const line = rnd.uintLessThan(usize, len);
            const n = rnd.uintAtMost(u16, buf.len);
            const end: u32 = rnd.uintLessThan(u32, 4);
            for (buf[0..n], 0..) |*t, k| t.* = .{ .start = @intCast(k), .kind = @intCast(line % 7), .hl = @enumFromInt(step % 5) };
            const changed = try ts.setLine(gpa, line, buf[0..n], @enumFromInt(end), .{});
            try std.testing.expectEqual(model.items[line].end != end, changed);
            model.items[line] = .{ .n = n, .end = end };
            // Remember what was written in the token kinds and highlight.
            for (ts.tokens(line)) |t| try std.testing.expectEqual(@as(u16, @intCast(line % 7)), t.kind);
        }
        try std.testing.expectEqual(@as(u64, model.items.len), ts.lineCount());
        for (model.items, 0..) |m, i| {
            try std.testing.expectEqual(@as(usize, m.n), ts.tokens(i).len);
            try std.testing.expectEqual(m.end, @intFromEnum(ts.rec(i).end_state));
        }
    }
    // Live tokens are accounted exactly.
    var live: usize = 0;
    for (model.items) |m| live += m.n;
    try std.testing.expectEqual(live, ts.liveTokens());
}
