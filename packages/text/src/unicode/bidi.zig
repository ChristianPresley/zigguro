//! The Unicode Bidirectional Algorithm (UAX #9, Unicode 18.0.0) for one
//! paragraph: P2-P3, X1-X10 (max_depth 125, isolating run sequences), W1-W7,
//! N0 (bracket pairs), N1-N2, I1-I2, and per line L1-L2 and L4. The rules
//! are separate functions over structure-of-arrays state so a failing
//! BidiCharacterTest case can be traced rule by rule. Characters removed by
//! X9 stay in the arrays (marked by their original class) and take the
//! level of the preceding character. Text without right-to-left content
//! skips the algorithm (`hasRtl`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const p = @import("props.zig");
const decode = @import("decode.zig");
const BC = p.BidiClass;

/// An embedding level, 0..126.
pub const Level = u8;

/// UAX #9 max_depth.
pub const max_depth: Level = 125;

/// Requested paragraph direction; `auto` applies P2-P3 (LTR when no
/// strong character is found).
pub const Direction = enum { ltr, rtl, auto };

/// A logical range of code points at one level, emitted in visual order.
pub const VisualRun = struct { start_cp: u32, end_cp: u32, level: Level };

/// A resolved paragraph.
pub const Paragraph = struct {
    /// One level per code point (before L1, which is per line).
    levels: []Level,
    /// Byte offset of each code point.
    cp_offsets: []u32,
    /// Original Bidi_Class of each code point (L1 needs it).
    classes: []BC,
    /// Paragraph embedding level.
    base: Level,

    /// Frees the arrays.
    pub fn deinit(para: *Paragraph, gpa: Allocator) void {
        gpa.free(para.levels);
        gpa.free(para.cp_offsets);
        gpa.free(para.classes);
        para.* = undefined;
    }

    /// L1 and L2 for the line of code points [start_cp, end_cp): appends
    /// its runs to `out_runs` in visual order (left to right).
    pub fn reorderLine(para: *const Paragraph, gpa: Allocator, start_cp: u32, end_cp: u32, out_runs: *std.ArrayList(VisualRun)) !void {
        if (start_cp >= end_cp) return;
        const n = end_cp - start_cp;
        const lv = try gpa.alloc(Level, n);
        defer gpa.free(lv);
        lineLevels(para.classes[start_cp..end_cp], para.levels[start_cp..end_cp], para.base, lv);
        const first = out_runs.items.len;
        var i: u32 = 0;
        while (i < n) {
            var j = i + 1;
            while (j < n and lv[j] == lv[i]) j += 1;
            try out_runs.append(gpa, .{ .start_cp = start_cp + i, .end_cp = start_cp + j, .level = lv[i] });
            i = j;
        }
        reverseRuns(out_runs.items[first..]);
    }

    /// True if code point `i` was removed by X9 (embedding controls, BN):
    /// it has no meaningful level and is not displayed.
    pub fn isRemoved(para: *const Paragraph, i: usize) bool {
        return removedByX9(para.classes[i]);
    }
};

/// L2 on runs: from the highest level down to the lowest odd level,
/// reverse every maximal sequence of runs at that level or higher.
fn reverseRuns(runs: []VisualRun) void {
    if (runs.len == 0) return;
    var hi: Level = 0;
    var lo_odd: Level = 255;
    for (runs) |r| {
        hi = @max(hi, r.level);
        if (r.level & 1 == 1) lo_odd = @min(lo_odd, r.level);
    }
    if (lo_odd == 255) return;
    var k = hi;
    while (k >= lo_odd) : (k -= 1) {
        var i: usize = 0;
        while (i < runs.len) {
            if (runs[i].level < k) {
                i += 1;
                continue;
            }
            var j = i;
            while (j < runs.len and runs[j].level >= k) j += 1;
            std.mem.reverse(VisualRun, runs[i..j]);
            i = j;
        }
        if (k == 0) break;
    }
}

/// L1 for one line: segment and paragraph separators, and any run of
/// whitespace and isolate formatters (and removed characters) before them
/// or at the end of the line, go back to the paragraph level.
pub fn lineLevels(classes: []const BC, levels: []const Level, base: Level, out: []Level) void {
    @memcpy(out, levels);
    var trailing = true; // inside a run that reaches a separator or the end
    var i = classes.len;
    while (i > 0) {
        i -= 1;
        const c = classes[i];
        switch (c) {
            .S, .B => {
                out[i] = base;
                trailing = true;
            },
            .WS, .FSI, .LRI, .RLI, .PDI => if (trailing) {
                out[i] = base;
            },
            else => if (removedByX9(c)) {
                if (trailing) out[i] = base;
            } else {
                trailing = false;
            },
        }
    }
}

/// L4: the mirrored glyph to display for `cp` at `level`, if any.
pub fn mirrorGlyphNeeded(cp: u21, level: Level) ?u21 {
    if (level & 1 == 0) return null;
    return p.mirror(cp);
}

const V = @Vector(16, u8);

/// Classes that make the full algorithm necessary.
inline fn needsBidi(c: BC) bool {
    return switch (c) {
        .R, .AL, .AN, .RLE, .RLO, .RLI, .FSI, .LRE, .LRO, .LRI, .PDF, .PDI => true,
        else => false,
    };
}

/// Quick check: true if `bytes` contains any right-to-left or explicit
/// formatting character. When false and the direction is not RTL, every
/// level is 0 and callers may skip `resolve`.
pub fn hasRtl(bytes: []const u8) bool {
    var i: usize = 0;
    while (i < bytes.len) {
        if (i + 16 <= bytes.len) {
            const v: V = bytes[i..][0..16].*;
            if (@reduce(.And, v < @as(V, @splat(0x80)))) {
                i += 16;
                continue;
            }
        }
        if (bytes[i] < 0x80) {
            i += 1;
            continue;
        }
        const u = decode.at(bytes, i);
        if (u.valid and needsBidi(p.props(u.cp).bidi)) return true;
        i += u.len;
    }
    return false;
}

/// Resolves one paragraph of UTF-8 (the caller splits at paragraph
/// separators). Ill-formed bytes are U+FFFD.
pub fn resolve(gpa: Allocator, bytes: []const u8, dir: Direction) !Paragraph {
    var n: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) : (n += 1) i += decode.at(bytes, i).len;
    const offsets = try gpa.alloc(u32, n);
    errdefer gpa.free(offsets);
    const classes = try gpa.alloc(BC, n);
    errdefer gpa.free(classes);
    const levels = try gpa.alloc(Level, n);
    errdefer gpa.free(levels);
    const cps = try gpa.alloc(u21, n);
    defer gpa.free(cps);
    i = 0;
    var k: usize = 0;
    var rtl = false;
    while (i < bytes.len) : (k += 1) {
        const u = decode.at(bytes, i);
        offsets[k] = @intCast(i);
        cps[k] = u.cp;
        classes[k] = if (u.valid) p.props(u.cp).bidi else .ON;
        rtl = rtl or needsBidi(classes[k]);
        i += u.len;
    }
    var base: Level = 0;
    if (!rtl and dir != .rtl) {
        // Fast path: no R/AL/AN or explicit controls, LTR paragraph.
        @memset(levels, 0);
    } else {
        base = try resolveClasses(gpa, classes, cps, dir, levels);
    }
    return .{ .levels = levels, .cp_offsets = offsets, .classes = classes, .base = base };
}

inline fn removedByX9(c: BC) bool {
    return switch (c) {
        .RLE, .LRE, .RLO, .LRO, .PDF, .BN => true,
        else => false,
    };
}

inline fn isIsolateInitiator(c: BC) bool {
    return c == .LRI or c == .RLI or c == .FSI;
}

inline fn isStrong(c: BC) bool {
    return c == .L or c == .R or c == .AL;
}

/// Working state for one paragraph.
const Work = struct {
    gpa: Allocator,
    orig: []const BC,
    cps: ?[]const u21,
    /// Current class, rewritten by X1-N2.
    cls: []BC,
    levels: []Level,
    /// Explicit levels (after X1-X8), for sos/eos.
    explicit: []Level = &.{},
    /// BD9: for an isolate initiator, its matching PDI; for a matched PDI,
    /// its initiator; n otherwise.
    match: []u32,
    base: Level,
    n: usize,
};

/// Runs the algorithm over original classes (and code points for N0;
/// null means no brackets). Writes one level per input element (removed
/// elements get the preceding level) and returns the paragraph level.
pub fn resolveClasses(gpa: Allocator, orig: []const BC, cps: ?[]const u21, dir: Direction, levels: []Level) !Level {
    const n = orig.len;
    const cls = try gpa.dupe(BC, orig);
    defer gpa.free(cls);
    const match = try gpa.alloc(u32, n);
    defer gpa.free(match);
    var w: Work = .{ .gpa = gpa, .orig = orig, .cps = cps, .cls = cls, .levels = levels, .match = match, .base = 0, .n = n };
    try matchIsolates(&w);
    w.base = switch (dir) {
        .ltr => 0,
        .rtl => 1,
        .auto => firstStrong(&w, 0, n) orelse 0,
    };
    try explicitLevels(&w);
    w.explicit = try gpa.dupe(Level, levels);
    defer gpa.free(w.explicit);
    try runSequences(&w);
    // Removed characters take the level of the preceding character.
    var prev: Level = w.base;
    for (0..n) |i| {
        if (removedByX9(orig[i])) levels[i] = prev else prev = levels[i];
    }
    return w.base;
}

/// BD9: links each isolate initiator with its matching PDI (n when
/// none). A paragraph separator ends every open isolate.
fn matchIsolates(w: *Work) !void {
    @memset(w.match, @intCast(w.n));
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(w.gpa);
    for (w.orig, 0..) |c, i| {
        if (isIsolateInitiator(c)) {
            try stack.append(w.gpa, @intCast(i));
        } else if (c == .PDI) {
            if (stack.pop()) |o| {
                w.match[o] = @intCast(i);
                w.match[i] = o;
            }
        } else if (c == .B) {
            stack.clearRetainingCapacity();
        }
    }
}

/// P2-P3 over [from, to): 0 for L, 1 for R/AL, null if no strong
/// character; skips isolates (initiator to matching PDI).
fn firstStrong(w: *const Work, from: usize, to: usize) ?Level {
    var i = from;
    while (i < to) {
        const c = w.orig[i];
        switch (c) {
            .L => return 0,
            .R, .AL => return 1,
            .B => return null,
            .LRI, .RLI, .FSI => {
                const m = w.match[i];
                if (m >= to) return null;
                i = m;
            },
            else => {},
        }
        i += 1;
    }
    return null;
}

const Entry = struct { level: Level, override: enum(u2) { none, l, r }, isolate: bool };

/// X1-X8.
fn explicitLevels(w: *Work) !void {
    var stack: [max_depth + 2]Entry = undefined;
    var sp: usize = 1;
    stack[0] = .{ .level = w.base, .override = .none, .isolate = false };
    var overflow_isolate: usize = 0;
    var overflow_embedding: usize = 0;
    var valid_isolate: usize = 0;
    for (0..w.n) |i| {
        const c = w.orig[i];
        const top = stack[sp - 1];
        switch (c) {
            .RLE, .LRE, .RLO, .LRO => {
                // X2-X5.
                const rtl = c == .RLE or c == .RLO;
                const new: Level = if (rtl) (top.level + 1) | 1 else (top.level + 2) & ~@as(Level, 1);
                if (new <= max_depth and overflow_isolate == 0 and overflow_embedding == 0) {
                    stack[sp] = .{
                        .level = new,
                        .override = if (c == .RLO) .r else if (c == .LRO) .l else .none,
                        .isolate = false,
                    };
                    sp += 1;
                } else if (overflow_isolate == 0) {
                    overflow_embedding += 1;
                }
                w.levels[i] = top.level;
            },
            .RLI, .LRI, .FSI => {
                // X5a-X5c.
                w.levels[i] = top.level;
                applyOverride(w, i, top);
                var rtl = c == .RLI;
                if (c == .FSI) rtl = (firstStrong(w, i + 1, @min(w.match[i], w.n)) orelse 0) == 1;
                const new: Level = if (rtl) (top.level + 1) | 1 else (top.level + 2) & ~@as(Level, 1);
                if (new <= max_depth and overflow_isolate == 0 and overflow_embedding == 0) {
                    valid_isolate += 1;
                    stack[sp] = .{ .level = new, .override = .none, .isolate = true };
                    sp += 1;
                } else {
                    overflow_isolate += 1;
                }
            },
            .PDI => {
                // X6a.
                if (overflow_isolate > 0) {
                    overflow_isolate -= 1;
                } else if (valid_isolate > 0) {
                    overflow_embedding = 0;
                    while (!stack[sp - 1].isolate) sp -= 1;
                    sp -= 1;
                    valid_isolate -= 1;
                }
                const t = stack[sp - 1];
                w.levels[i] = t.level;
                applyOverride(w, i, t);
            },
            .PDF => {
                // X7.
                if (overflow_isolate > 0) {} else if (overflow_embedding > 0) {
                    overflow_embedding -= 1;
                } else if (!top.isolate and sp >= 2) {
                    sp -= 1;
                }
                w.levels[i] = stack[sp - 1].level;
            },
            .B => {
                // X8: a paragraph separator ends everything.
                w.levels[i] = w.base;
                sp = 1;
                overflow_isolate = 0;
                overflow_embedding = 0;
                valid_isolate = 0;
            },
            .BN => w.levels[i] = top.level,
            else => {
                // X6.
                w.levels[i] = top.level;
                applyOverride(w, i, top);
            },
        }
    }
}

inline fn applyOverride(w: *Work, i: usize, e: Entry) void {
    switch (e.override) {
        .none => {},
        .l => w.cls[i] = .L,
        .r => w.cls[i] = .R,
    }
}

/// X9-X10, then the weak, neutral and implicit rules per isolating run
/// sequence.
fn runSequences(w: *Work) !void {
    const gpa = w.gpa;
    // Retained characters in logical order.
    var kept: std.ArrayList(u32) = .empty;
    defer kept.deinit(gpa);
    for (0..w.n) |i| if (!removedByX9(w.orig[i])) try kept.append(gpa, @intCast(i));
    if (kept.items.len == 0) return;
    // Level runs over retained characters: [run_start[r], run_start[r+1]).
    var run_start: std.ArrayList(u32) = .empty;
    defer run_start.deinit(gpa);
    // Run index of each retained position whose run starts there.
    const run_of = try gpa.alloc(u32, w.n);
    defer gpa.free(run_of);
    @memset(run_of, std.math.maxInt(u32));
    for (kept.items, 0..) |ci, k| {
        if (k == 0 or w.levels[ci] != w.levels[kept.items[k - 1]]) {
            run_of[ci] = @intCast(run_start.items.len);
            try run_start.append(gpa, @intCast(k));
        }
    }
    const nruns = run_start.items.len;
    try run_start.append(gpa, @intCast(kept.items.len));

    var seq: std.ArrayList(u32) = .empty;
    defer seq.deinit(gpa);
    for (0..nruns) |r| {
        const first = kept.items[run_start.items[r]];
        // A run starting with a matched PDI continues an earlier sequence.
        if (w.orig[first] == .PDI and isMatchedPdi(w, first)) continue;
        seq.clearRetainingCapacity();
        var cur = r;
        while (true) {
            for (kept.items[run_start.items[cur]..run_start.items[cur + 1]]) |ci| try seq.append(gpa, ci);
            const last = seq.items[seq.items.len - 1];
            if (!isIsolateInitiator(w.orig[last])) break;
            const m = w.match[last];
            if (m >= w.n) break;
            const next_run = run_of[m];
            if (next_run == std.math.maxInt(u32)) break;
            cur = next_run;
        }
        try resolveSequence(w, seq.items);
    }
}

inline fn isMatchedPdi(w: *const Work, i: usize) bool {
    return w.match[i] < w.n;
}

inline fn dirOf(level: Level) BC {
    return if (level & 1 == 1) .R else .L;
}

/// Level of the nearest retained character before `i`, or null.
fn levelBefore(w: *const Work, i: usize) ?Level {
    var j = i;
    while (j > 0) {
        j -= 1;
        if (!removedByX9(w.orig[j])) return w.explicit[j];
    }
    return null;
}

fn levelAfter(w: *const Work, i: usize) ?Level {
    var j = i + 1;
    while (j < w.n) : (j += 1) {
        if (!removedByX9(w.orig[j])) return w.explicit[j];
    }
    return null;
}

/// W1-W7, N0-N2, I1-I2 on one isolating run sequence (indices into the
/// paragraph, in order).
fn resolveSequence(w: *Work, seq: []const u32) !void {
    const level = w.explicit[seq[0]];
    const first = seq[0];
    const last = seq[seq.len - 1];
    const sos = dirOf(@max(level, levelBefore(w, first) orelse w.base));
    const eos_other: Level = if (isIsolateInitiator(w.orig[last])) w.base else levelAfter(w, last) orelse w.base;
    const eos = dirOf(@max(level, eos_other));
    weakRules(w, seq, sos);
    try bracketPairs(w, seq, sos, level);
    neutralRules(w, seq, sos, eos, level);
    implicitLevels(w, seq);
}

/// W1-W7.
fn weakRules(w: *Work, seq: []const u32, sos: BC) void {
    const cls = w.cls;
    // W1: NSM takes the previous type (ON after an isolate formatter).
    var prev: BC = sos;
    for (seq) |i| {
        if (cls[i] == .NSM) {
            cls[i] = switch (prev) {
                .LRI, .RLI, .FSI, .PDI => .ON,
                else => prev,
            };
        }
        prev = cls[i];
    }
    // W2: EN after AL (searching back to sos) becomes AN. W3: AL -> R.
    var strong: BC = sos;
    for (seq) |i| {
        switch (cls[i]) {
            .L, .R, .AL => strong = cls[i],
            .EN => if (strong == .AL) {
                cls[i] = .AN;
            },
            else => {},
        }
    }
    for (seq) |i| if (cls[i] == .AL) {
        cls[i] = .R;
    };
    // W4: a single ES between ENs, or a single CS between numbers of the
    // same type.
    if (seq.len >= 3) {
        for (1..seq.len - 1) |k| {
            const c = cls[seq[k]];
            if (c != .ES and c != .CS) continue;
            const a = cls[seq[k - 1]];
            const b = cls[seq[k + 1]];
            if (a == .EN and b == .EN) {
                cls[seq[k]] = .EN;
            } else if (c == .CS and a == .AN and b == .AN) {
                cls[seq[k]] = .AN;
            }
        }
    }
    // W5: a sequence of ETs next to an EN becomes EN.
    var k: usize = 0;
    while (k < seq.len) {
        if (cls[seq[k]] != .ET) {
            k += 1;
            continue;
        }
        var e = k;
        while (e < seq.len and cls[seq[e]] == .ET) e += 1;
        const touches = (k > 0 and cls[seq[k - 1]] == .EN) or (e < seq.len and cls[seq[e]] == .EN);
        if (touches) {
            for (seq[k..e]) |i| cls[i] = .EN;
        }
        k = e;
    }
    // W6: remaining separators and terminators become ON.
    for (seq) |i| switch (cls[i]) {
        .ES, .ET, .CS => cls[i] = .ON,
        else => {},
    };
    // W7: EN after L (searching back to sos) becomes L.
    strong = sos;
    for (seq) |i| switch (cls[i]) {
        .L, .R => strong = cls[i],
        .EN => if (strong == .L) {
            cls[i] = .L;
        },
        else => {},
    };
}

/// Strong direction for N0/N1: EN and AN count as R.
inline fn strongDir(c: BC) ?BC {
    return switch (c) {
        .L => .L,
        .R, .EN, .AN => .R,
        else => null,
    };
}

/// BD16 stack size.
const bracket_stack = 63;

const Pair = struct { open: u32, close: u32 };

inline fn canonBracket(cp: u21) u21 {
    return switch (cp) {
        0x2329 => 0x3008,
        0x232A => 0x3009,
        else => cp,
    };
}

/// N0: bracket pairs take the embedding direction, or the context
/// direction, from the strong types they enclose.
fn bracketPairs(w: *Work, seq: []const u32, sos: BC, level: Level) !void {
    const cps = w.cps orelse return;
    const cls = w.cls;
    // BD16 over positions in `seq`.
    var pairs: std.ArrayList(Pair) = .empty;
    defer pairs.deinit(w.gpa);
    var stack: [bracket_stack]struct { closer: u21, pos: u32 } = undefined;
    var sp: usize = 0;
    scan: for (seq, 0..) |i, k| {
        if (cls[i] != .ON) continue;
        const cp = cps[i];
        const x = p.props(cp);
        switch (x.bpt) {
            .o => {
                if (sp == bracket_stack) break :scan;
                stack[sp] = .{ .closer = canonBracket(p.pairedBracket(cp) orelse continue), .pos = @intCast(k) };
                sp += 1;
            },
            .c => {
                const me = canonBracket(cp);
                var s = sp;
                while (s > 0) {
                    s -= 1;
                    if (stack[s].closer == me) {
                        try pairs.append(w.gpa, .{ .open = stack[s].pos, .close = @intCast(k) });
                        sp = s;
                        break;
                    }
                }
            },
            .n => {},
        }
    }
    std.mem.sort(Pair, pairs.items, {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            return a.open < b.open;
        }
    }.lt);
    const e = dirOf(level);
    for (pairs.items) |pr| {
        var found_e = false;
        var found_o = false;
        for (seq[pr.open + 1 .. pr.close]) |i| {
            const d = strongDir(cls[i]) orelse continue;
            if (d == e) {
                found_e = true;
                break;
            }
            found_o = true;
        }
        var to: ?BC = null;
        if (found_e) {
            to = e;
        } else if (found_o) {
            // N0 c: the first strong type before the opening bracket.
            var ctx: BC = sos;
            var k = pr.open;
            while (k > 0) {
                k -= 1;
                if (strongDir(cls[seq[k]])) |d| {
                    ctx = d;
                    break;
                }
            }
            to = if (ctx != e) ctx else e;
        }
        if (to) |d| {
            for ([_]u32{ pr.open, pr.close }) |pos| {
                cls[seq[pos]] = d;
                // Original NSMs right after the bracket follow it.
                var k = pos + 1;
                while (k < seq.len and w.orig[seq[k]] == .NSM) : (k += 1) cls[seq[k]] = d;
            }
        }
    }
}

inline fn isNeutral(c: BC) bool {
    return switch (c) {
        .B, .S, .WS, .ON, .FSI, .LRI, .RLI, .PDI => true,
        else => false,
    };
}

/// N1-N2.
fn neutralRules(w: *Work, seq: []const u32, sos: BC, eos: BC, level: Level) void {
    const cls = w.cls;
    const e = dirOf(level);
    var k: usize = 0;
    while (k < seq.len) {
        if (!isNeutral(cls[seq[k]])) {
            k += 1;
            continue;
        }
        var end = k;
        while (end < seq.len and isNeutral(cls[seq[end]])) end += 1;
        const before: BC = if (k == 0) sos else strongDir(cls[seq[k - 1]]) orelse e;
        const after: BC = if (end == seq.len) eos else strongDir(cls[seq[end]]) orelse e;
        const d = if (before == after) before else e;
        for (seq[k..end]) |i| cls[i] = d;
        k = end;
    }
}

/// I1-I2.
fn implicitLevels(w: *Work, seq: []const u32) void {
    for (seq) |i| {
        const lv = w.levels[i];
        const c = w.cls[i];
        if (lv & 1 == 0) {
            if (c == .R) w.levels[i] = lv + 1 else if (c == .AN or c == .EN) w.levels[i] = lv + 2;
        } else {
            if (c == .L or c == .EN or c == .AN) w.levels[i] = lv + 1;
        }
    }
}

test {
    _ = @import("bidi_test.zig");
}
