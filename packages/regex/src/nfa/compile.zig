//! HIR -> Thompson NFA compiler (forward with captures, or reverse).
//!
//! Construction is classic Thompson with patching: each fragment has a
//! start state and an end state whose outgoing edge is patched later.
//! Unicode classes go through a UTF-8 compiler that builds a trie of the
//! byte sequences and shares identical suffixes through a cache (the
//! `regex-automata` Utf8Compiler design), so `\w` costs a few hundred states
//! rather than thousands. Reverse programs compile each sequence reversed
//! with a suffix cache keyed by (range, next).

const std = @import("std");
const hir_mod = @import("../syntax/hir.zig");
const prog = @import("program.zig");
const utf8_seq = @import("utf8_seq.zig");

const Allocator = std.mem.Allocator;
const Hir = hir_mod.Hir;
const Look = hir_mod.Look;
const StateId = prog.StateId;
const Transition = prog.Transition;

/// Compiler options.
pub const Config = struct {
    /// Build a reverse program (no captures).
    reverse: bool = false,
    /// Emit capture states (ignored for reverse and multi-pattern builds).
    captures: bool = true,
    /// Fail with `error.SizeLimitExceeded` above this many bytes.
    size_limit: usize = 10 << 20,
};

/// Compile errors.
pub const Error = error{SizeLimitExceeded} || Allocator.Error;

const BState = union(enum) {
    byte_range: Transition,
    sparse: []const Transition,
    look: struct { look: Look, next: StateId },
    union_: std.ArrayList(StateId),
    capture: struct { slot: u32, next: StateId },
    empty: StateId,
    fail,
    match: prog.PatternId,
};

const Ref = struct { start: StateId, end: StateId };

const none: StateId = std.math.maxInt(StateId);

const Builder = struct {
    gpa: Allocator, // the program arena
    states: std.ArrayList(BState) = .empty,
    cfg: Config,
    looks: prog.LookSet = .{},
    bytes: usize = 0,
    utf8_cache: std.StringHashMapUnmanaged(StateId) = .empty,
    rev_cache: std.AutoHashMapUnmanaged(Transition, StateId) = .empty,

    fn add(b: *Builder, s: BState) Error!StateId {
        b.bytes += @sizeOf(prog.State) + switch (s) {
            .sparse => |ts| ts.len * @sizeOf(Transition),
            else => 0,
        };
        if (b.bytes > b.cfg.size_limit) return error.SizeLimitExceeded;
        try b.states.append(b.gpa, s);
        return @intCast(b.states.items.len - 1);
    }

    fn patch(b: *Builder, from: StateId, to: StateId) Error!void {
        switch (b.states.items[from]) {
            .byte_range => |*t| t.next = to,
            .look => |*l| l.next = to,
            .capture => |*c| c.next = to,
            .empty => |*n| n.* = to,
            .union_ => |*alts| {
                b.bytes += @sizeOf(StateId);
                if (b.bytes > b.cfg.size_limit) return error.SizeLimitExceeded;
                try alts.append(b.gpa, to);
            },
            .sparse, .fail, .match => unreachable,
        }
    }

    fn empty(b: *Builder) Error!StateId {
        return b.add(.{ .empty = none });
    }

    fn unionState(b: *Builder) Error!StateId {
        return b.add(.{ .union_ = .empty });
    }

    fn compile(b: *Builder, h: *const Hir) Error!Ref {
        switch (h.*) {
            .empty => {
                const s = try b.empty();
                return .{ .start = s, .end = s };
            },
            .literal => |bytes| {
                if (bytes.len == 0) {
                    const s = try b.empty();
                    return .{ .start = s, .end = s };
                }
                var first: StateId = none;
                var prev: StateId = none;
                var i: usize = 0;
                while (i < bytes.len) : (i += 1) {
                    const byte = if (b.cfg.reverse) bytes[bytes.len - 1 - i] else bytes[i];
                    const s = try b.add(.{ .byte_range = .{ .lo = byte, .hi = byte, .next = none } });
                    if (prev == none) first = s else try b.patch(prev, s);
                    prev = s;
                }
                return .{ .start = first, .end = prev };
            },
            .class_bytes => |set| {
                var buf: [128][2]u8 = undefined;
                const rs = set.ranges(&buf);
                if (rs.len == 0) {
                    const f = try b.add(.fail);
                    return .{ .start = f, .end = try b.empty() };
                }
                if (rs.len == 1) {
                    const s = try b.add(.{ .byte_range = .{ .lo = rs[0][0], .hi = rs[0][1], .next = none } });
                    return .{ .start = s, .end = s };
                }
                const end = try b.empty();
                const ts = try b.gpa.alloc(Transition, rs.len);
                for (rs, ts) |r, *t| t.* = .{ .lo = r[0], .hi = r[1], .next = end };
                return .{ .start = try b.add(.{ .sparse = ts }), .end = end };
            },
            .class_unicode => |set| {
                if (set.ranges.len == 0) {
                    const f = try b.add(.fail);
                    return .{ .start = f, .end = try b.empty() };
                }
                const end = try b.empty();
                const start = if (b.cfg.reverse) try b.utf8Reverse(set.ranges, end) else try b.utf8Forward(set.ranges, end);
                return .{ .start = start, .end = end };
            },
            .look => |l| {
                const look = if (b.cfg.reverse) mirror(l) else l;
                b.looks.insert(look);
                const s = try b.add(.{ .look = .{ .look = look, .next = none } });
                return .{ .start = s, .end = s };
            },
            .capture => |c| {
                if (b.cfg.reverse or !b.cfg.captures) return b.compile(c.sub);
                const open = try b.add(.{ .capture = .{ .slot = c.index * 2, .next = none } });
                const sub = try b.compile(c.sub);
                const close = try b.add(.{ .capture = .{ .slot = c.index * 2 + 1, .next = none } });
                try b.patch(open, sub.start);
                try b.patch(sub.end, close);
                return .{ .start = open, .end = close };
            },
            .concat => |items| {
                var ref: ?Ref = null;
                var i: usize = 0;
                while (i < items.len) : (i += 1) {
                    const it = if (b.cfg.reverse) items[items.len - 1 - i] else items[i];
                    const r = try b.compile(it);
                    if (ref) |*acc| {
                        try b.patch(acc.end, r.start);
                        acc.end = r.end;
                    } else ref = r;
                }
                if (ref) |r| return r;
                const s = try b.empty();
                return .{ .start = s, .end = s };
            },
            .alternation => |items| {
                const u = try b.unionState();
                const end = try b.empty();
                for (items) |it| {
                    const r = try b.compile(it);
                    try b.patch(u, r.start);
                    try b.patch(r.end, end);
                }
                return .{ .start = u, .end = end };
            },
            .repetition => |r| return b.repetition(r.sub, r.min, r.max, r.greedy),
        }
    }

    fn repetition(b: *Builder, sub: *const Hir, min: u32, max: ?u32, greedy: bool) Error!Ref {
        if (max == null) {
            if (min == 0) {
                // x*: u -> (x -> u | end)
                const u = try b.unionState();
                const end = try b.empty();
                const x = try b.compile(sub);
                if (greedy) {
                    try b.patch(u, x.start);
                    try b.patch(u, end);
                } else {
                    try b.patch(u, end);
                    try b.patch(u, x.start);
                }
                try b.patch(x.end, u);
                return .{ .start = u, .end = end };
            }
            // x{n,}: n-1 copies, then x+.
            var acc: ?Ref = null;
            for (0..min - 1) |_| acc = try b.chain(acc, try b.compile(sub));
            const x = try b.compile(sub);
            const u = try b.unionState();
            const end = try b.empty();
            try b.patch(x.end, u);
            if (greedy) {
                try b.patch(u, x.start);
                try b.patch(u, end);
            } else {
                try b.patch(u, end);
                try b.patch(u, x.start);
            }
            return (try b.chain(acc, .{ .start = x.start, .end = end }));
        }
        const m = max.?;
        var acc: ?Ref = null;
        for (0..min) |_| acc = try b.chain(acc, try b.compile(sub));
        if (m == min) {
            if (acc) |a| return a;
            const s = try b.empty();
            return .{ .start = s, .end = s };
        }
        // Optional copies all skip to one shared end.
        const end = try b.empty();
        var prev_end: StateId = if (acc) |a| a.end else none;
        const start: StateId = if (acc) |a| a.start else none;
        var first_union: StateId = none;
        for (0..m - min) |_| {
            const u = try b.unionState();
            if (prev_end != none) try b.patch(prev_end, u);
            if (first_union == none) first_union = u;
            const x = try b.compile(sub);
            if (greedy) {
                try b.patch(u, x.start);
                try b.patch(u, end);
            } else {
                try b.patch(u, end);
                try b.patch(u, x.start);
            }
            prev_end = x.end;
        }
        try b.patch(prev_end, end);
        return .{ .start = if (start != none) start else first_union, .end = end };
    }

    fn chain(b: *Builder, acc: ?Ref, r: Ref) Error!Ref {
        if (acc) |a| {
            try b.patch(a.end, r.start);
            return .{ .start = a.start, .end = r.end };
        }
        return r;
    }

    // -- UTF-8 (forward): trie with suffix sharing ----------------------

    const Node = struct {
        trans: std.ArrayList(Transition) = .empty,
        last: ?utf8_seq.ByteRange = null,

        fn setLast(n: *Node, gpa: Allocator, next: StateId) Allocator.Error!void {
            if (n.last) |l| {
                try n.trans.append(gpa, .{ .lo = l.lo, .hi = l.hi, .next = next });
                n.last = null;
            }
        }
    };

    fn utf8Forward(b: *Builder, ranges: []const [2]u21, target: StateId) Error!StateId {
        var nodes: std.ArrayList(Node) = .empty;
        try nodes.append(b.gpa, .{});
        var it = utf8_seq.Sequences.init(ranges);
        while (it.next()) |seq| {
            const rs = seq.slice();
            // Length of the shared prefix with the uncompiled path.
            var prefix: usize = 0;
            while (prefix < rs.len and prefix < nodes.items.len) : (prefix += 1) {
                const l = nodes.items[prefix].last orelse break;
                if (l.lo != rs[prefix].lo or l.hi != rs[prefix].hi) break;
            }
            try b.compileFrom(&nodes, prefix, target);
            // Add the suffix.
            nodes.items[nodes.items.len - 1].last = rs[prefix];
            for (rs[prefix + 1 ..]) |r| try nodes.append(b.gpa, .{ .last = r });
        }
        try b.compileFrom(&nodes, 0, target);
        return b.freeze(nodes.items[0].trans.items);
    }

    fn compileFrom(b: *Builder, nodes: *std.ArrayList(Node), from: usize, target: StateId) Error!void {
        var next = target;
        while (from + 1 < nodes.items.len) {
            var n = nodes.pop().?;
            try n.setLast(b.gpa, next);
            next = try b.freeze(n.trans.items);
        }
        try nodes.items[nodes.items.len - 1].setLast(b.gpa, next);
    }

    /// Returns a state with exactly `trans`, reusing an identical one.
    fn freeze(b: *Builder, trans: []const Transition) Error!StateId {
        const key = std.mem.sliceAsBytes(trans);
        if (b.utf8_cache.get(key)) |id| return id;
        const owned = try b.gpa.dupe(Transition, trans);
        const id = if (owned.len == 1)
            try b.add(.{ .byte_range = owned[0] })
        else
            try b.add(.{ .sparse = owned });
        try b.utf8_cache.put(b.gpa, std.mem.sliceAsBytes(owned), id);
        return id;
    }

    // -- UTF-8 (reverse): reversed chains with a suffix cache ----------

    fn utf8Reverse(b: *Builder, ranges: []const [2]u21, target: StateId) Error!StateId {
        b.rev_cache.clearRetainingCapacity();
        const u = try b.unionState();
        var it = utf8_seq.Sequences.init(ranges);
        while (it.next()) |seq| {
            const rs = seq.slice();
            // The reversed chain consumes the last byte first; build it from
            // the target backwards, sharing (range, next) states.
            var next = target;
            for (rs) |r| {
                const key: Transition = .{ .lo = r.lo, .hi = r.hi, .next = next };
                if (b.rev_cache.get(key)) |id| {
                    next = id;
                } else {
                    const id = try b.add(.{ .byte_range = key });
                    try b.rev_cache.put(b.gpa, key, id);
                    next = id;
                }
            }
            try b.patch(u, next);
        }
        return u;
    }
};

/// The mirror image of an assertion, for reverse programs.
pub fn mirror(l: Look) Look {
    return switch (l) {
        .start_text => .end_text,
        .end_text => .start_text,
        .start_line => .end_line,
        .end_line => .start_line,
        .start_line_crlf => .end_line_crlf,
        .end_line_crlf => .start_line_crlf,
        .word_start_unicode => .word_end_unicode,
        .word_end_unicode => .word_start_unicode,
        .word_start_half_unicode => .word_end_half_unicode,
        .word_end_half_unicode => .word_start_half_unicode,
        .word_start_ascii => .word_end_ascii,
        .word_end_ascii => .word_start_ascii,
        .word_start_half_ascii => .word_end_half_ascii,
        .word_end_half_ascii => .word_start_half_ascii,
        else => l,
    };
}

/// Compiles one or more patterns into a program owned by the result.
/// `group_names[i]` are the names of pattern i's groups (index 0 unnamed);
/// only used for single-pattern forward programs.
pub fn compile(gpa: Allocator, patterns: []const *const Hir, group_names: []const ?[]const u8, cfg: Config) Error!prog.Program {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var c = cfg;
    if (patterns.len != 1) c.captures = false;
    if (c.reverse) c.captures = false;
    var b: Builder = .{ .gpa = a, .cfg = c };

    const starts = try a.alloc(StateId, patterns.len);
    for (patterns, 0..) |p, pid| {
        var r = try b.compile(p);
        if (c.captures) {
            const open = try b.add(.{ .capture = .{ .slot = 0, .next = r.start } });
            const close = try b.add(.{ .capture = .{ .slot = 1, .next = none } });
            try b.patch(r.end, close);
            r = .{ .start = open, .end = close };
        }
        const m = try b.add(.{ .match = @intCast(pid) });
        try b.patch(r.end, m);
        starts[pid] = r.start;
    }
    const start_anchored = if (patterns.len == 1) starts[0] else blk: {
        const u = try b.unionState();
        for (starts) |s| try b.patch(u, s);
        break :blk u;
    };
    // Unanchored: (?s-u:.)*? then the anchored start.
    const loop = try b.unionState();
    const any = try b.add(.{ .byte_range = .{ .lo = 0, .hi = 255, .next = loop } });
    try b.patch(loop, start_anchored);
    try b.patch(loop, any);

    // Freeze states.
    const states = try a.alloc(prog.State, b.states.items.len);
    var bound: std.StaticBitSet(256) = .initEmpty();
    for (b.states.items, states) |bs, *s| {
        s.* = switch (bs) {
            .byte_range => |t| blk: {
                markRange(&bound, t.lo, t.hi);
                break :blk .{ .byte_range = t };
            },
            .sparse => |ts| blk: {
                for (ts) |t| markRange(&bound, t.lo, t.hi);
                break :blk .{ .sparse = ts };
            },
            .look => |l| .{ .look = .{ .look = l.look, .next = l.next } },
            .union_ => |alts| switch (alts.items.len) {
                0 => .fail,
                1 => .{ .empty = alts.items[0] },
                2 => .{ .binary_union = .{ .alt1 = alts.items[0], .alt2 = alts.items[1] } },
                else => .{ .union_ = alts.items },
            },
            .capture => |cp| .{ .capture = .{ .slot = cp.slot, .next = cp.next } },
            .empty => |n| .{ .empty = n },
            .fail => .fail,
            .match => |pid| .{ .match = pid },
        };
    }
    // Assertions distinguish line terminators and word bytes.
    if (!b.looks.isEmpty()) {
        markRange(&bound, '\n', '\n');
        markRange(&bound, '\r', '\r');
        if (b.looks.hasWord()) {
            markRange(&bound, '0', '9');
            markRange(&bound, 'A', 'Z');
            markRange(&bound, '_', '_');
            markRange(&bound, 'a', 'z');
            if (b.looks.hasUnicodeWord()) markRange(&bound, 0x80, 0xFF);
        }
    }
    var slot_count: u32 = 0;
    if (c.captures) slot_count = @intCast(group_names.len * 2);
    // Allocate before `arena` is copied into the result.
    const names: []const ?[]const u8 = if (c.captures) try a.dupe(?[]const u8, group_names) else &.{};
    return .{
        .arena = arena,
        .states = states,
        .start_anchored = start_anchored,
        .start_unanchored = loop,
        .pattern_starts = starts,
        .slot_count = slot_count,
        .group_names = names,
        .looks = b.looks,
        .classes = .fromBoundaries(&bound),
        .reverse = c.reverse,
        .memory_bytes = b.bytes,
    };
}

fn markRange(bound: *std.StaticBitSet(256), lo: u8, hi: u8) void {
    if (lo > 0) bound.set(lo - 1);
    bound.set(hi);
}

test "compile: \\w forward is compact" {
    const unicode = @import("../syntax/unicode.zig");
    var h: Hir = .{ .class_unicode = .{ .ranges = unicode.perlWord() } };
    var p = try compile(std.testing.allocator, &.{&h}, &.{null}, .{});
    defer p.deinit();
    // The suffix-sharing trie keeps \w well under a thousand states.
    try std.testing.expect(p.states.len < 1500);
    var r = try compile(std.testing.allocator, &.{&h}, &.{null}, .{ .reverse = true });
    defer r.deinit();
    try std.testing.expect(r.reverse);
}

test "compile: size limit" {
    var lit: Hir = .{ .literal = "abcdefgh" };
    var rep: Hir = .{ .repetition = .{ .min = 1000, .max = 1000, .greedy = true, .sub = &lit } };
    var outer: Hir = .{ .repetition = .{ .min = 1000, .max = 1000, .greedy = true, .sub = &rep } };
    try std.testing.expectError(error.SizeLimitExceeded, compile(std.testing.allocator, &.{&outer}, &.{null}, .{ .size_limit = 1 << 20 }));
}
