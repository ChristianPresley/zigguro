//! The lazy (hybrid) DFA: DFA states are built on demand from sets of NFA
//! states and cached in a bounded per-thread cache.
//!
//! Design follows `regex-automata`'s hybrid DFA:
//! - A DFA state is the ordered list of "important" NFA states (byte
//!   consumers, matches and unresolved assertions) plus context: whether the
//!   previous byte was a word byte or `\r`, the assertions known to hold
//!   from look-behind (`look_have`) and the assertions still unresolved
//!   (`look_need`).
//! - Matches are delayed by one byte: the transition on unit `u` out of `S`
//!   leads to a state flagged as a match when `S` (with look-ahead resolved
//!   by `u`) contained an NFA match state. The final transition is on the
//!   byte after the span, or on the special end-of-input unit.
//! - Leftmost-first: while stepping, the first NFA match state in priority
//!   order drops every lower-priority state (including the unanchored
//!   prefix loop), so the search ends at the leftmost-first match end.
//! - Unicode word boundaries are not representable byte-wise; the DFA quits
//!   on any non-ASCII byte when the program has them, and the meta engine
//!   falls back to the PikeVM.
//! - When the cache is full it is cleared and rebuilt; after repeated clears
//!   with little progress the search gives up, and the caller falls back to
//!   the PikeVM. Memory is bounded by `Options.dfa_cache_bytes`.
//!
//! The same code runs forward programs over increasing positions and reverse
//! programs (whose assertions are mirrored) over decreasing positions.

const std = @import("std");
const prog = @import("../nfa/program.zig");
const input_mod = @import("../input.zig");
const look_mod = @import("look.zig");
const Look = @import("../syntax/hir.zig").Look;
const Prefilter = @import("../prefilter.zig").Prefilter;

const Allocator = std.mem.Allocator;
const Program = prog.Program;
const StateId = prog.StateId;
const Input = input_mod.Input;
const LookSet = prog.LookSet;

/// How matches are resolved.
pub const MatchKind = enum {
    /// Leftmost-first priority (forward searches).
    leftmost_first,
    /// Every match (reverse searches looking for the furthest start).
    all,
};

/// Search failures that require a fallback engine.
pub const Error = error{
    /// A byte the DFA cannot handle (non-ASCII with Unicode `\b`).
    Quit,
    /// The cache thrashed.
    GaveUp,
} || Allocator.Error;

// Transition table entries are premultiplied state offsets (`id * stride`)
// with tag bits, so the hot loop needs one load and one test per byte. The
// sentinels have every tag bit set, so they also take the slow path.
const unknown: u32 = std.math.maxInt(u32);
const dead: u32 = unknown - 1;
const quit: u32 = unknown - 2;
/// The target is a match state.
const tag_match: u32 = 1 << 31;
/// The target is an unanchored start state (only with `Cache.tag_starts`).
const tag_start: u32 = 1 << 30;
const tag_mask: u32 = tag_match | tag_start | (1 << 29);
/// Offsets stay below the tag bits.
const max_offset: u32 = 1 << 29;

const Flags = packed struct(u8) {
    is_match: bool = false,
    from_word: bool = false,
    half_crlf: bool = false,
    _pad: u5 = 0,
};

/// Fixed part of a state key; NFA state ids follow it.
const Header = extern struct {
    flags: u8,
    _pad: [3]u8 = .{ 0, 0, 0 },
    look_have: u32,
    look_need: u32,
    match_pid: u32,
};

const State = struct {
    key: []const u8,
    /// An unanchored start state: no match is in progress, so a prefilter
    /// may skip ahead.
    is_start: bool = false,
    flags: Flags,
    look_have: LookSet,
    look_need: LookSet,
    match_pid: u32,
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: []const u8) u64 {
        return std.hash.Wyhash.hash(0, k);
    }
    pub fn eql(_: KeyContext, a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};

/// The start-state context: what precedes the search start.
const StartKind = enum(u3) { text, lf, cr, word, nonword };

/// Per-thread mutable DFA state for one program and match kind.
pub const Cache = struct {
    gpa: Allocator,
    states: std.ArrayList(State) = .empty,
    trans: std.ArrayList(u32) = .empty,
    /// Owns every state key; reset when the cache is cleared.
    keys: std.heap.ArenaAllocator,
    key_bytes: usize = 0,
    map: std.HashMapUnmanaged([]const u8, u32, KeyContext, 80) = .empty,
    starts: [2][5]u32 = @splat(@splat(unknown)),
    // Builder scratch.
    set: std.ArrayList(StateId) = .empty,
    seen: std.DynamicBitSetUnmanaged = .{},
    stack: std.ArrayList(StateId) = .empty,
    key_buf: std.ArrayList(u8) = .empty,
    saved_key: std.ArrayList(u8) = .empty,
    capacity: usize,
    /// Tag transitions into unanchored start states so a prefilter can skip
    /// ahead. Set it when searches pass a prefilter; it costs a slow-path
    /// step per start-state transition otherwise.
    tag_starts: bool = false,
    clears: u32 = 0,
    progress: u64 = 0,
    /// Total states created over the cache's life (for tests).
    states_created: u64 = 0,

    /// A cache for `p` limited to about `capacity` bytes.
    pub fn init(gpa: Allocator, p: *const Program, capacity: usize) Allocator.Error!Cache {
        return .{ .gpa = gpa, .keys = .init(gpa), .seen = try .initEmpty(gpa, p.states.len), .capacity = capacity };
    }

    /// Frees the cache.
    pub fn deinit(c: *Cache) void {
        const gpa = c.gpa;
        c.states.deinit(gpa);
        c.trans.deinit(gpa);
        c.keys.deinit();
        c.map.deinit(gpa);
        c.set.deinit(gpa);
        c.seen.deinit(gpa);
        c.stack.deinit(gpa);
        c.key_buf.deinit(gpa);
        c.saved_key.deinit(gpa);
    }

    fn memory(c: *const Cache, stride: usize) usize {
        return c.key_bytes + c.states.items.len * (@sizeOf(State) + stride * 4 + 16);
    }

    fn reset(c: *Cache) void {
        c.states.clearRetainingCapacity();
        c.trans.clearRetainingCapacity();
        _ = c.keys.reset(.retain_capacity);
        c.key_bytes = 0;
        c.map.clearRetainingCapacity();
        c.starts = @splat(@splat(unknown));
    }
};

/// A lazy DFA over one program.
pub const Dfa = struct {
    program: *const Program,
    kind: MatchKind,
    reverse: bool,
    stride: usize,
    eoi_class: usize,
    quit_non_ascii: bool,

    /// A DFA for `p` (forward or reverse according to `p.reverse`).
    pub fn init(p: *const Program, kind: MatchKind) Dfa {
        return .{
            .program = p,
            .kind = kind,
            .reverse = p.reverse,
            .stride = @as(usize, p.classes.len) + 1,
            .eoi_class = p.classes.len,
            .quit_non_ascii = p.looks.hasUnicodeWord(),
        };
    }

    // -- state construction ----------------------------------------------

    /// Epsilon closure of `id` into `c.set` with assertions in `have`;
    /// unresolved assertions are added to `need`.
    fn closure(d: *const Dfa, c: *Cache, id0: StateId, have: LookSet, need: *LookSet) Allocator.Error!void {
        const states = d.program.states;
        try c.stack.append(c.gpa, id0);
        while (c.stack.pop()) |top| {
            var id = top;
            while (true) {
                if (c.seen.isSet(id)) break;
                c.seen.set(id);
                switch (states[id]) {
                    .byte_range, .sparse, .match => {
                        try c.set.append(c.gpa, id);
                        break;
                    },
                    .fail => break,
                    .empty => |n| id = n,
                    .capture => |cp| id = cp.next,
                    .look => |l| {
                        if (have.contains(l.look)) {
                            id = l.next;
                        } else {
                            need.insert(l.look);
                            try c.set.append(c.gpa, id);
                            break;
                        }
                    },
                    .binary_union => |u| {
                        try c.stack.append(c.gpa, u.alt2);
                        id = u.alt1;
                    },
                    .union_ => |alts| {
                        var k = alts.len;
                        while (k > 1) {
                            k -= 1;
                            try c.stack.append(c.gpa, alts[k]);
                        }
                        id = alts[0];
                    },
                }
            }
        }
    }

    fn resetSeen(c: *Cache) void {
        // `seen` also marks epsilon states visited on the way; clear fully.
        c.seen.unsetAll();
    }

    /// Interns the state described by the current builder set and context.
    fn intern(d: *const Dfa, c: *Cache, flags: Flags, have: LookSet, need: LookSet, pid: u32) Allocator.Error!?u32 {
        c.key_buf.clearRetainingCapacity();
        const hdr: Header = .{ .flags = @bitCast(flags), .look_have = if (need.isEmpty()) 0 else have.bits, .look_need = need.bits, .match_pid = pid };
        try c.key_buf.appendSlice(c.gpa, std.mem.asBytes(&hdr));
        try c.key_buf.appendSlice(c.gpa, std.mem.sliceAsBytes(c.set.items));
        const ctx: KeyContext = .{};
        if (c.map.getContext(c.key_buf.items, ctx)) |id| return id;
        // Room for one more state?
        const need_bytes = c.key_buf.items.len + @sizeOf(State) + d.stride * 4 + 16;
        if (c.memory(d.stride) + need_bytes > c.capacity) return null;
        if ((c.states.items.len + 1) * d.stride >= max_offset) return null;
        const key = try c.keys.allocator().dupe(u8, c.key_buf.items);
        c.key_bytes += key.len;
        const id: u32 = @intCast(c.states.items.len);
        try c.states.append(c.gpa, .{
            .key = key,
            .flags = flags,
            .look_have = if (need.isEmpty()) .{} else have,
            .look_need = need,
            .match_pid = pid,
        });
        try c.trans.appendNTimes(c.gpa, unknown, d.stride);
        try c.map.putContext(c.gpa, key, id, ctx);
        c.states_created += 1;
        return id;
    }

    fn keyOf(c: *const Cache, id: u32) []const u8 {
        return c.states.items[id].key;
    }

    /// The tagged transition entry for state `id`.
    fn ptrOf(d: *const Dfa, c: *const Cache, id: u32) u32 {
        const st = &c.states.items[id];
        var p: u32 = id * @as(u32, @intCast(d.stride));
        if (st.flags.is_match) p |= tag_match;
        if (st.is_start and c.tag_starts) p |= tag_start;
        return p;
    }

    /// Look-behind assertions that hold after `prev` (or at text start).
    /// In a reverse program the CRLF assertions are mirrored, so `\r` and
    /// `\n` swap roles for them.
    fn behind(prev: ?u8, comptime rev: bool) LookSet {
        const lf: u8 = if (rev) '\r' else '\n';
        var s: LookSet = .{};
        if (prev) |b| {
            if (b == '\n') s.insert(.start_line);
            if (b == lf) s.insert(.start_line_crlf);
            if (!look_mod.isWordByte(b)) {
                s.insert(.word_start_half_ascii);
                s.insert(.word_start_half_unicode);
            }
        } else {
            s.insert(.start_text);
            s.insert(.start_line);
            s.insert(.start_line_crlf);
            s.insert(.word_start_half_ascii);
            s.insert(.word_start_half_unicode);
        }
        return s;
    }

    /// Assertions resolved by the next unit (`null` = end of input) given
    /// the state's context.
    fn ahead(flags: Flags, unit: ?u8, comptime rev: bool) LookSet {
        const lf: u8 = if (rev) '\r' else '\n';
        const cr: u8 = if (rev) '\n' else '\r';
        var s: LookSet = .{};
        const w_next = if (unit) |b| look_mod.isWordByte(b) else false;
        if (unit) |b| {
            if (b == '\n') s.insert(.end_line);
            if (b == cr or (b == lf and !flags.half_crlf)) s.insert(.end_line_crlf);
            if (flags.half_crlf and b != lf) s.insert(.start_line_crlf);
        } else {
            s.insert(.end_text);
            s.insert(.end_line);
            s.insert(.end_line_crlf);
            if (flags.half_crlf) s.insert(.start_line_crlf);
        }
        const w_prev = flags.from_word;
        if (w_prev != w_next) {
            s.insert(.word_ascii);
            s.insert(.word_unicode);
        } else {
            s.insert(.word_ascii_negate);
            s.insert(.word_unicode_negate);
        }
        if (!w_prev and w_next) {
            s.insert(.word_start_ascii);
            s.insert(.word_start_unicode);
        }
        if (w_prev and !w_next) {
            s.insert(.word_end_ascii);
            s.insert(.word_end_unicode);
        }
        if (!w_next) {
            s.insert(.word_end_half_ascii);
            s.insert(.word_end_half_unicode);
        }
        return s;
    }

    fn contextFlags(prev: ?u8, comptime rev: bool) Flags {
        const cr: u8 = if (rev) '\n' else '\r';
        return .{
            .from_word = if (prev) |b| look_mod.isWordByte(b) else false,
            .half_crlf = if (prev) |b| b == cr else false,
        };
    }

    fn behindDyn(d: *const Dfa, prev: ?u8) LookSet {
        return if (d.reverse) behind(prev, true) else behind(prev, false);
    }

    fn aheadDyn(d: *const Dfa, flags: Flags, unit: ?u8) LookSet {
        return if (d.reverse) ahead(flags, unit, true) else ahead(flags, unit, false);
    }

    fn contextDyn(d: *const Dfa, prev: ?u8) Flags {
        return if (d.reverse) contextFlags(prev, true) else contextFlags(prev, false);
    }

    /// The start state for `anchored` after `prev` (null = text start).
    fn startState(d: *const Dfa, c: *Cache, anchored: bool, prev: ?u8) Error!u32 {
        if (prev) |b| if (d.quit_non_ascii and b >= 0x80) return error.Quit;
        const kind: StartKind = if (prev) |b| (if (b == '\n') .lf else if (b == '\r') .cr else if (look_mod.isWordByte(b)) .word else .nonword) else .text;
        const flags0 = d.contextDyn(prev);
        const slot = &c.starts[@intFromBool(anchored)][@intFromEnum(kind)];
        if (slot.* != unknown) return slot.*;
        const have = d.behindDyn(prev);
        var need: LookSet = .{};
        c.set.clearRetainingCapacity();
        resetSeen(c);
        try d.closure(c, if (anchored) d.program.start_anchored else d.program.start_unanchored, have, &need);
        const id = (try d.intern(c, flags0, have, need, 0)) orelse blk: {
            try d.clearCache(c);
            break :blk (try d.intern(c, flags0, have, need, 0)) orelse return error.GaveUp;
        };
        c.starts[@intFromBool(anchored)][@intFromEnum(kind)] = id;
        if (!anchored) c.states.items[id].is_start = true;
        return id;
    }

    fn clearCache(d: *const Dfa, c: *Cache) Error!void {
        _ = d;
        c.clears += 1;
        if (c.clears >= 3 and c.progress < 10 * @as(u64, @max(c.states.items.len, 1))) return error.GaveUp;
        c.progress = 0;
        c.reset();
    }

    /// Computes (and caches) the transition of `cur` on `unit`. Returns the
    /// possibly renumbered current state id (after a cache clear) and the
    /// tagged entry for the next state (or `dead` / `quit`).
    fn computeNext(d: *const Dfa, c: *Cache, cur_in: u32, unit: ?u8) Error!struct { cur: u32, next: u32 } {
        if (unit) |b| if (d.quit_non_ascii and b >= 0x80) {
            const cls = d.program.classes.get(b);
            c.trans.items[cur_in * d.stride + cls] = quit;
            return .{ .cur = cur_in, .next = quit };
        };
        const cur_state = c.states.items[cur_in];
        // Save the current key: building may clear the cache.
        c.saved_key.clearRetainingCapacity();
        try c.saved_key.appendSlice(c.gpa, keyOf(c, cur_in));
        const ids_bytes = c.saved_key.items[@sizeOf(Header)..];
        const cur_ids = std.mem.bytesAsSlice(StateId, ids_bytes);

        // Resolve look-ahead assertions, re-expanding the closure if needed.
        var have = cur_state.look_have;
        var work: std.ArrayList(StateId) = .empty;
        defer work.deinit(c.gpa);
        if (!cur_state.look_need.isEmpty()) {
            const added = d.aheadDyn(cur_state.flags, unit);
            const new_have = have.unionWith(added);
            if (new_have.bits & cur_state.look_need.bits != have.bits & cur_state.look_need.bits) {
                have = new_have;
                c.set.clearRetainingCapacity();
                resetSeen(c);
                var ignored: LookSet = .{};
                for (cur_ids) |id| try d.closure(c, id, have, &ignored);
                try work.appendSlice(c.gpa, c.set.items);
            }
        }
        if (work.items.len == 0) for (cur_ids) |id| try work.append(c.gpa, id);

        // Step.
        var flags: Flags = .{};
        var pid: u32 = 0;
        const next_have = d.behindDyn(unit);
        var need: LookSet = .{};
        c.set.clearRetainingCapacity();
        resetSeen(c);
        for (work.items) |id| {
            switch (d.program.states[id]) {
                .match => |p| {
                    if (!flags.is_match) pid = p;
                    flags.is_match = true;
                    if (d.kind == .leftmost_first) break;
                },
                .byte_range => |t| if (unit) |b| if (t.contains(b)) try d.closure(c, t.next, next_have, &need),
                .sparse => |ts| if (unit) |b| {
                    for (ts) |t| if (t.contains(b)) {
                        try d.closure(c, t.next, next_have, &need);
                        break;
                    };
                },
                else => {},
            }
        }
        if (unit) |_| {
            const ctx = d.contextDyn(unit);
            flags.from_word = ctx.from_word;
            flags.half_crlf = ctx.half_crlf;
        } else {
            // After end of input nothing more can happen.
            c.set.clearRetainingCapacity();
            need = .{};
        }
        const cls: usize = if (unit) |b| d.program.classes.get(b) else d.eoi_class;
        if (c.set.items.len == 0 and !flags.is_match) {
            c.trans.items[cur_in * d.stride + cls] = dead;
            return .{ .cur = cur_in, .next = dead };
        }
        var cur = cur_in;
        const next = (try d.intern(c, flags, next_have, need, pid)) orelse blk: {
            // Save the next key too, then clear and re-add both.
            var next_key: std.ArrayList(u8) = .empty;
            defer next_key.deinit(c.gpa);
            try next_key.appendSlice(c.gpa, c.key_buf.items);
            try d.clearCache(c);
            cur = try d.reinsert(c, c.saved_key.items);
            break :blk try d.reinsert(c, next_key.items);
        };
        const next_ptr = d.ptrOf(c, next);
        c.trans.items[cur * d.stride + cls] = next_ptr;
        return .{ .cur = cur, .next = next_ptr };
    }

    fn reinsert(d: *const Dfa, c: *Cache, key: []const u8) Error!u32 {
        const hdr = std.mem.bytesToValue(Header, key[0..@sizeOf(Header)]);
        c.set.clearRetainingCapacity();
        const ids = std.mem.bytesAsSlice(StateId, key[@sizeOf(Header)..]);
        for (ids) |id| try c.set.append(c.gpa, id);
        return (try d.intern(c, @bitCast(hdr.flags), .{ .bits = hdr.look_have }, .{ .bits = hdr.look_need }, hdr.match_pid)) orelse error.GaveUp;
    }

    inline fn isMatchPtr(p: u32) bool {
        return p != dead and p != quit and p & tag_match != 0;
    }

    // -- searches ----------------------------------------------------------

    /// Forward search for the leftmost-first match end in `in.span`.
    pub fn findFwd(d: *const Dfa, c: *Cache, in: *const Input) Error!?u64 {
        return d.findFwdPrefilter(c, in, null);
    }

    /// `findFwd` that jumps to the next `pf` candidate whenever the DFA is
    /// in an unanchored start state. `pf` must be complete: every match
    /// starts with one of its literals.
    pub fn findFwdPrefilter(d: *const Dfa, c: *Cache, in: *const Input, pf: ?*const Prefilter) Error!?u64 {
        std.debug.assert(!d.reverse);
        c.clears = 0;
        c.progress = 0;
        const span = in.span;
        const prev: ?u8 = if (span.start > 0) in.byteAt(span.start - 1) else null;
        const stride: u32 = @intCast(d.stride);
        // `cur` is the untagged offset of the current state.
        var cur: u32 = (try d.startState(c, in.anchored, prev)) * stride;
        var last: ?u64 = null;
        var at = span.start;
        const map = &d.program.classes.map;
        var trans = c.trans.items.ptr;
        // Hot loop over chunks.
        chunks: while (at < span.end) {
            const ch = in.chunkAt(at);
            const off: usize = @intCast(at - ch.base);
            const stop: usize = @intCast(@min(ch.end(), span.end) - ch.base);
            const bytes = ch.bytes;
            var i = off;
            // Bytes before `mark` are already counted in `c.progress`.
            var mark = off;
            while (i < stop) : (i += 1) {
                var next = trans[cur + map[bytes[i]]];
                if (next & tag_mask == 0) {
                    cur = next;
                    continue;
                }
                if (next >= quit) {
                    if (next == unknown) {
                        const r = try d.computeNext(c, cur / stride, bytes[i]);
                        trans = c.trans.items.ptr;
                        next = r.next;
                        c.progress += i - mark;
                        mark = i;
                    }
                    if (next == dead) return last;
                    if (next == quit) return error.Quit;
                    if (next & tag_mask == 0) {
                        cur = next;
                        continue;
                    }
                }
                cur = next & ~tag_mask;
                if (next & tag_match != 0) {
                    last = ch.base + i;
                    if (in.earliest) return last;
                } else if (next & tag_start != 0) if (pf) |p| {
                    // Nothing in progress: jump to the next candidate.
                    const pos = ch.base + i + 1;
                    const cand = p.find(in, pos) orelse return last;
                    if (cand != pos) {
                        cur = (try d.startState(c, false, in.byteAt(cand - 1))) * stride;
                        trans = c.trans.items.ptr;
                        at = cand;
                        continue :chunks;
                    }
                };
            }
            c.progress += stop - mark;
            at = ch.base + stop;
        }
        // Final transition: the byte after the span, or end of input.
        const unit: ?u8 = if (span.end < in.total_len) in.byteAt(span.end) else null;
        const cls: usize = if (unit) |b| map[b] else d.eoi_class;
        var next = c.trans.items[cur + cls];
        if (next == unknown) next = (try d.computeNext(c, cur / stride, unit)).next;
        if (next == quit) return error.Quit;
        if (isMatchPtr(next)) last = span.end;
        return last;
    }

    /// Reverse search from `in.span.end` towards `in.span.start` (always
    /// anchored at the end); returns the furthest match start.
    pub fn findRev(d: *const Dfa, c: *Cache, in: *const Input) Error!?u64 {
        std.debug.assert(d.reverse);
        c.clears = 0;
        c.progress = 0;
        const span = in.span;
        const prev: ?u8 = if (span.end < in.total_len) in.byteAt(span.end) else null;
        const stride: u32 = @intCast(d.stride);
        var cur: u32 = (try d.startState(c, true, prev)) * stride;
        var last: ?u64 = null;
        var at = span.end;
        const map = &d.program.classes.map;
        var trans = c.trans.items.ptr;
        while (at > span.start) {
            const ch = in.chunkAt(at - 1);
            const lo: usize = @intCast(@max(ch.base, span.start) - ch.base);
            const hi: usize = @intCast(at - ch.base);
            var i: usize = hi;
            var mark = hi;
            const bytes = ch.bytes;
            while (i > lo) {
                i -= 1;
                var next = trans[cur + map[bytes[i]]];
                if (next & tag_mask == 0) {
                    cur = next;
                    continue;
                }
                if (next >= quit) {
                    if (next == unknown) {
                        const r = try d.computeNext(c, cur / stride, bytes[i]);
                        trans = c.trans.items.ptr;
                        next = r.next;
                        c.progress += mark - i;
                        mark = i;
                    }
                    if (next == dead) return last;
                    if (next == quit) return error.Quit;
                }
                cur = next & ~tag_mask;
                if (next & tag_match != 0) last = ch.base + i + 1;
            }
            c.progress += mark - lo;
            at = ch.base + lo;
        }
        const unit: ?u8 = if (span.start > 0) in.byteAt(span.start - 1) else null;
        const cls: usize = if (unit) |b| map[b] else d.eoi_class;
        var next = c.trans.items[cur + cls];
        if (next == unknown) next = (try d.computeNext(c, cur / stride, unit)).next;
        if (next == quit) return error.Quit;
        if (isMatchPtr(next)) last = span.start;
        return last;
    }

    /// Whether any pattern matches in the span (forward, earliest).
    pub fn isMatchFwd(d: *const Dfa, c: *Cache, in: *const Input) Error!bool {
        var e = in.*;
        e.earliest = true;
        return (try d.findFwd(c, &e)) != null;
    }
};
