//! The PikeVM: a breadth-first NFA simulation with capture slots. It runs in
//! O(m·n) time for any pattern and is the universal fallback and the capture
//! engine (the meta engine runs it anchored on the span the DFAs found).
//!
//! Threads live in two sparse sets (current and next position) whose
//! insertion order is the priority order; reaching a match state drops every
//! lower-priority thread, which yields leftmost-first semantics. Epsilon
//! closures use an explicit stack with slot-restore frames, as in
//! `regex-automata`.

const std = @import("std");
const prog = @import("../nfa/program.zig");
const input_mod = @import("../input.zig");
const look = @import("look.zig");

const Allocator = std.mem.Allocator;
const Program = prog.Program;
const StateId = prog.StateId;
const Input = input_mod.Input;

/// An unset slot.
pub const none: u64 = std.math.maxInt(u64);

/// A match end and the pattern that matched.
pub const HalfMatch = struct { pattern: prog.PatternId, end: u64 };

const SparseSet = struct {
    dense: []StateId,
    sparse: []u32,
    len: u32 = 0,

    fn init(gpa: Allocator, n: usize) Allocator.Error!SparseSet {
        const s: SparseSet = .{ .dense = try gpa.alloc(StateId, n), .sparse = try gpa.alloc(u32, n) };
        return s;
    }

    fn deinit(s: *SparseSet, gpa: Allocator) void {
        gpa.free(s.dense);
        gpa.free(s.sparse);
    }

    inline fn contains(s: *const SparseSet, id: StateId) bool {
        const i = s.sparse[id];
        return i < s.len and s.dense[i] == id;
    }

    /// Inserts `id`; returns false when already present.
    inline fn insert(s: *SparseSet, id: StateId) bool {
        if (s.contains(id)) return false;
        s.dense[s.len] = id;
        s.sparse[id] = s.len;
        s.len += 1;
        return true;
    }

    inline fn clear(s: *SparseSet) void {
        s.len = 0;
    }
};

const Threads = struct {
    set: SparseSet,
    /// `slot_count` slots per state.
    slots: []u64,

    fn init(gpa: Allocator, n: usize, slot_count: usize) Allocator.Error!Threads {
        var set = try SparseSet.init(gpa, n);
        errdefer set.deinit(gpa);
        return .{ .set = set, .slots = try gpa.alloc(u64, n * slot_count) };
    }

    fn deinit(t: *Threads, gpa: Allocator) void {
        t.set.deinit(gpa);
        gpa.free(t.slots);
    }
};

const Frame = union(enum) {
    explore: StateId,
    restore: struct { slot: u32, value: u64 },
};

/// Mutable scratch for one thread of execution over one program.
pub const Cache = struct {
    curr: Threads,
    next: Threads,
    stack: std.ArrayList(Frame) = .empty,
    scratch: []u64,
    slot_count: usize,

    /// Allocates scratch sized for `p`.
    pub fn init(gpa: Allocator, p: *const Program) Allocator.Error!Cache {
        // Even without capture groups, slots 0/1 track the match bounds.
        const sc: usize = @max(p.slot_count, 2);
        var curr = try Threads.init(gpa, p.states.len, sc);
        errdefer curr.deinit(gpa);
        var next = try Threads.init(gpa, p.states.len, sc);
        errdefer next.deinit(gpa);
        // The closure stack never holds more than one frame per epsilon edge
        // plus one restore frame per capture state, so reserve that once and
        // searches never allocate.
        var frames: usize = 1;
        for (p.states) |s| frames += switch (s) {
            .union_ => |alts| alts.len,
            .binary_union => 2,
            .capture => 2,
            else => 1,
        };
        var stack: std.ArrayList(Frame) = .empty;
        try stack.ensureTotalCapacity(gpa, frames);
        errdefer stack.deinit(gpa);
        return .{ .curr = curr, .next = next, .stack = stack, .scratch = try gpa.alloc(u64, sc), .slot_count = sc };
    }

    /// Frees the scratch.
    pub fn deinit(c: *Cache, gpa: Allocator) void {
        c.curr.deinit(gpa);
        c.next.deinit(gpa);
        c.stack.deinit(gpa);
        gpa.free(c.scratch);
    }
};

/// Leftmost-first search. On a match, `slots` (length `>= 2`, up to the
/// program's slot count) holds the capture positions and the match end is
/// returned. Without capture states (multi-pattern or capture-free
/// programs) only the end is reported and slot 0 is left unset.
pub fn search(p: *const Program, cache: *Cache, in: *const Input, slots: []u64) ?HalfMatch {
    @memset(slots, none);
    const sc = cache.slot_count;
    var curr = &cache.curr;
    var next = &cache.next;
    curr.set.clear();
    next.set.clear();
    const start_state = p.start_anchored;
    var hm: ?HalfMatch = null;
    var cursor = input_mod.Cursor.init(in);
    var at = in.span.start;
    const end = in.span.end;
    while (true) {
        if (curr.set.len == 0) {
            if (hm != null) break;
            if (in.anchored and at > in.span.start) break;
        }
        if (hm == null and (!in.anchored or at == in.span.start)) {
            @memset(cache.scratch, none);
            closure(p, cache, curr, start_state, at, in);
        }
        // Step every thread over the byte at `at` (or handle matches).
        const have_byte = at < end;
        const byte: u8 = if (have_byte) cursor.get(at) else 0;
        var i: u32 = 0;
        while (i < curr.set.len) : (i += 1) {
            const sid = curr.set.dense[i];
            const tslots = curr.slots[sid * sc ..][0..sc];
            switch (p.states[sid]) {
                .byte_range => |t| if (have_byte and t.contains(byte)) {
                    @memcpy(cache.scratch, tslots);
                    closure(p, cache, next, t.next, at + 1, in);
                },
                .sparse => |ts| if (have_byte) {
                    for (ts) |t| {
                        if (byte < t.lo) break;
                        if (byte <= t.hi) {
                            @memcpy(cache.scratch, tslots);
                            closure(p, cache, next, t.next, at + 1, in);
                            break;
                        }
                    }
                },
                .match => |pid| {
                    hm = .{ .pattern = pid, .end = at };
                    const n = @min(slots.len, sc);
                    @memcpy(slots[0..n], tslots[0..n]);
                    if (in.earliest) return hm;
                    // Lower-priority threads can only produce later-starting
                    // or lower-priority matches.
                    break;
                },
                else => {},
            }
        }
        if (at >= end) break;
        std.mem.swap(*Threads, &curr, &next);
        next.set.clear();
        at += 1;
    }
    return hm;
}

/// Adds the epsilon closure of `sid` at position `at` to `set`, carrying
/// `cache.scratch` as the thread's slots.
fn closure(p: *const Program, cache: *Cache, threads: *Threads, sid0: StateId, at: u64, in: *const Input) void {
    const sc = cache.slot_count;
    const stack = &cache.stack;
    stack.appendAssumeCapacity(.{ .explore = sid0 });
    while (stack.pop()) |frame| {
        var sid = switch (frame) {
            .restore => |r| {
                cache.scratch[r.slot] = r.value;
                continue;
            },
            .explore => |s| s,
        };
        // Follow a chain of single epsilons without pushing.
        while (true) {
            if (!threads.set.insert(sid)) break;
            switch (p.states[sid]) {
                .byte_range, .sparse, .match => {
                    @memcpy(threads.slots[sid * sc ..][0..sc], cache.scratch);
                    break;
                },
                .fail => break,
                .empty => |n| sid = n,
                .look => |l| {
                    if (!look.matches(l.look, in, at)) break;
                    sid = l.next;
                },
                .binary_union => |u| {
                    stack.appendAssumeCapacity(.{ .explore = u.alt2 });
                    sid = u.alt1;
                },
                .union_ => |alts| {
                    var k = alts.len;
                    while (k > 1) {
                        k -= 1;
                        stack.appendAssumeCapacity(.{ .explore = alts[k] });
                    }
                    sid = alts[0];
                },
                .capture => |cp| {
                    if (cp.slot < sc) {
                        stack.appendAssumeCapacity(.{ .restore = .{ .slot = cp.slot, .value = cache.scratch[cp.slot] } });
                        cache.scratch[cp.slot] = at;
                    }
                    sid = cp.next;
                },
            }
        }
    }
}

/// Overlapping multi-pattern search: sets `out[pid]` for every pattern with
/// a match anywhere in the span. Stops early once every pattern matched.
pub fn searchSet(p: *const Program, cache: *Cache, in: *const Input, out: *std.DynamicBitSetUnmanaged) void {
    var curr = &cache.curr;
    var next = &cache.next;
    curr.set.clear();
    next.set.clear();
    var cursor = input_mod.Cursor.init(in);
    var at = in.span.start;
    const end = in.span.end;
    var found: usize = 0;
    const total = p.patternCount();
    while (true) {
        if (!in.anchored or at == in.span.start) {
            @memset(cache.scratch, none);
            closure(p, cache, curr, p.start_anchored, at, in);
        } else if (curr.set.len == 0) break;
        const have_byte = at < end;
        const byte: u8 = if (have_byte) cursor.get(at) else 0;
        var i: u32 = 0;
        while (i < curr.set.len) : (i += 1) {
            const sid = curr.set.dense[i];
            switch (p.states[sid]) {
                .byte_range => |t| if (have_byte and t.contains(byte)) closure(p, cache, next, t.next, at + 1, in),
                .sparse => |ts| if (have_byte) {
                    for (ts) |t| if (t.contains(byte)) {
                        closure(p, cache, next, t.next, at + 1, in);
                        break;
                    };
                },
                .match => |pid| if (!out.isSet(pid)) {
                    out.set(pid);
                    found += 1;
                    if (found == total) return;
                },
                else => {},
            }
        }
        if (at >= end) break;
        std.mem.swap(*Threads, &curr, &next);
        next.set.clear();
        at += 1;
    }
}
