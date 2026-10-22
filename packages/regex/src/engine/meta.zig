//! The meta engine: picks the fastest correct strategy for each search.
//!
//! 1. A pattern that is one literal (no assertions, no classes) is a
//!    `memmem` search.
//! 2. Otherwise the forward lazy DFA finds the leftmost-first match end. If
//!    every match starts with one of a small set of prefix literals, the DFA
//!    jumps to the next prefilter candidate whenever it is in an unanchored
//!    start state (no match in progress).
//! 3. The reverse lazy DFA, anchored at that end and limited to the search
//!    start, finds the match start.
//! 4. Captures run the PikeVM anchored on the match span.
//! 5. When a DFA quits (non-ASCII byte with Unicode `\b`) or gives up (cache
//!    thrash, or out of memory), the PikeVM handles the search.

const std = @import("std");
const prog = @import("../nfa/program.zig");
const input_mod = @import("../input.zig");
const pikevm = @import("pikevm.zig");
const lazy_dfa = @import("lazy_dfa.zig");
const prefilter_mod = @import("../prefilter.zig");

const Allocator = std.mem.Allocator;
const Input = input_mod.Input;
const Program = prog.Program;

/// A match span `[start, end)`.
pub const Match = struct {
    start: u64,
    end: u64,

    /// Length in bytes.
    pub fn len(m: Match) u64 {
        return m.end - m.start;
    }
};

/// The compiled engines of one regex.
pub const Engines = struct {
    fwd: Program,
    rev: Program,
    prefilter: ?prefilter_mod.Prefilter,
    /// Set when the whole pattern is this literal.
    literal: ?prefilter_mod.memmem.Finder,
    literal_bytes: []const u8,
    dfa_cache_bytes: usize,

    /// Frees everything.
    pub fn deinit(e: *Engines, gpa: Allocator) void {
        e.fwd.deinit();
        e.rev.deinit();
        if (e.prefilter) |*p| p.deinit(gpa);
        gpa.free(e.literal_bytes);
    }
};

/// Per-thread scratch; sub-caches are created on first use.
pub const Cache = struct {
    gpa: Allocator,
    pike: ?pikevm.Cache = null,
    fwd: ?lazy_dfa.Cache = null,
    rev: ?lazy_dfa.Cache = null,
    /// Set after an allocation failure: use the PikeVM only.
    dfa_disabled: bool = false,

    /// Frees the scratch.
    pub fn deinit(c: *Cache) void {
        if (c.pike) |*p| p.deinit(c.gpa);
        if (c.fwd) |*f| f.deinit();
        if (c.rev) |*r| r.deinit();
    }

    /// The PikeVM cache, or null when it cannot be allocated.
    fn pikeCache(c: *Cache, e: *const Engines) ?*pikevm.Cache {
        if (c.pike == null) c.pike = pikevm.Cache.init(c.gpa, &e.fwd) catch return null;
        return &c.pike.?;
    }

    fn fwdCache(c: *Cache, e: *const Engines) ?*lazy_dfa.Cache {
        if (c.dfa_disabled) return null;
        if (c.fwd == null) c.fwd = lazy_dfa.Cache.init(c.gpa, &e.fwd, e.dfa_cache_bytes) catch {
            c.dfa_disabled = true;
            return null;
        };
        return &c.fwd.?;
    }

    fn revCache(c: *Cache, e: *const Engines) ?*lazy_dfa.Cache {
        if (c.dfa_disabled) return null;
        if (c.rev == null) c.rev = lazy_dfa.Cache.init(c.gpa, &e.rev, e.dfa_cache_bytes) catch {
            c.dfa_disabled = true;
            return null;
        };
        return &c.rev.?;
    }
};

/// Leftmost-first search for the match span.
pub fn find(e: *const Engines, c: *Cache, in: *const Input) ?Match {
    if (in.span.start > in.span.end) return null;
    if (e.literal) |*lit| return findLiteral(e, lit, in);
    if (findDfa(e, c, in)) |r| return r else |_| {}
    return findPike(e, c, in);
}

/// Whether there is any match in the span.
pub fn isMatch(e: *const Engines, c: *Cache, in: *const Input) bool {
    var ein = in.*;
    ein.earliest = true;
    if (e.literal) |*lit| return findLiteral(e, lit, &ein) != null;
    if (c.fwdCache(e)) |fc| {
        const dfa = lazy_dfa.Dfa.init(&e.fwd, .leftmost_first);
        if (dfa.findFwd(fc, &ein)) |end| return end != null else |_| {}
    }
    const pc = c.pikeCache(e) orelse return false;
    var slots: [2]u64 = undefined;
    return pikevm.search(&e.fwd, pc, &ein, &slots) != null;
}

/// Leftmost-first search with captures. `slots` must have room for the
/// program's slot count (2 per group); returns whether a match was found.
pub fn captures(e: *const Engines, c: *Cache, in: *const Input, slots: []u64) bool {
    const m = find(e, c, in) orelse {
        @memset(slots, pikevm.none);
        return false;
    };
    const pc = c.pikeCache(e) orelse return false;
    var sub = in.withSpan(.{ .start = m.start, .end = m.end });
    sub.anchored = true;
    sub.earliest = false;
    const hm = pikevm.search(&e.fwd, pc, &sub, slots);
    std.debug.assert(hm != null and hm.?.end == m.end);
    return true;
}

fn findLiteral(e: *const Engines, lit: *const prefilter_mod.memmem.Finder, in: *const Input) ?Match {
    const n = e.literal_bytes.len;
    if (in.asSlice()) |s| {
        const hay = s[0..@intCast(in.span.end)];
        if (in.anchored) {
            if (std.mem.startsWith(u8, hay[@intCast(in.span.start)..], e.literal_bytes)) return .{ .start = in.span.start, .end = in.span.start + n };
            return null;
        }
        const i = lit.find(hay, @intCast(in.span.start)) orelse return null;
        return .{ .start = i, .end = i + n };
    }
    // Chunked: the prefilter (when available) handles boundaries; verify.
    if (e.prefilter) |*pf| {
        var at = in.span.start;
        while (pf.find(in, at)) |cand| {
            if (in.anchored and cand != in.span.start) return null;
            if (cand + n <= in.span.end and matchesAt(in, cand, e.literal_bytes)) return .{ .start = cand, .end = cand + n };
            if (in.anchored) return null;
            at = cand + 1;
        }
        return null;
    }
    var at = in.span.start;
    while (at + n <= in.span.end) : (at += 1) {
        if (matchesAt(in, at, e.literal_bytes)) return .{ .start = at, .end = at + n };
        if (in.anchored) break;
    }
    return null;
}

fn matchesAt(in: *const Input, at: u64, bytes: []const u8) bool {
    for (bytes, 0..) |b, i| if (in.byteAt(at + i) != b) return false;
    return true;
}

const DfaError = error{Fallback};

fn findDfa(e: *const Engines, c: *Cache, in: *const Input) DfaError!?Match {
    const fc = c.fwdCache(e) orelse return error.Fallback;
    const fwd = lazy_dfa.Dfa.init(&e.fwd, .leftmost_first);
    var start_at = in.span.start;
    const pf: ?*const prefilter_mod.Prefilter = if (in.anchored or e.prefilter == null) null else &e.prefilter.?;
    // Skip to the first prefilter candidate (no match can start earlier).
    if (pf) |p| start_at = p.find(in, start_at) orelse return null;
    const sub = in.withSpan(.{ .start = start_at, .end = in.span.end });
    const end = (fwd.findFwdPrefilter(fc, &sub, pf) catch return error.Fallback) orelse return null;
    if (in.anchored) return .{ .start = in.span.start, .end = end };
    const rc = c.revCache(e) orelse return error.Fallback;
    const rev = lazy_dfa.Dfa.init(&e.rev, .all);
    const rin = in.withSpan(.{ .start = start_at, .end = end });
    const start = (rev.findRev(rc, &rin) catch return error.Fallback) orelse unreachable;
    return .{ .start = start, .end = end };
}

fn findPike(e: *const Engines, c: *Cache, in: *const Input) ?Match {
    const pc = c.pikeCache(e) orelse return null;
    var slots: [2]u64 = undefined;
    const hm = pikevm.search(&e.fwd, pc, in, &slots) orelse return null;
    return .{ .start = slots[0], .end = hm.end };
}
