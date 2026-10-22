//! Shared diff plumbing: run-length edit scripts, the per-element change
//! marks every algorithm fills in, and deadlines.
//!
//! Algorithms mark which elements of `a` are deleted and which of `b` are
//! inserted (as git's xdiff does); unmarked elements pair up in order and
//! are equal. `toScript` turns the marks into a run-length `Edit` list.
//! Marks make post-processing (sliding hunk boundaries) a matter of moving
//! flags.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// One run of an edit script. `equal` runs advance both sides, `delete`
/// only `a`, `insert` only `b`. Runs cover both sequences in order.
pub const Edit = struct {
    kind: Kind,
    a_start: u32,
    b_start: u32,
    len: u32,

    pub const Kind = enum { equal, insert, delete };
};

/// A wall-clock limit for a diff. When it passes, regions still to be
/// searched are reported as delete plus insert (a valid, coarse script).
pub const Deadline = struct {
    io: std.Io,
    at: std.Io.Timestamp,

    /// `ns` nanoseconds from now on the awake clock.
    pub fn after(io: std.Io, ns: u64) Deadline {
        const now = std.Io.Timestamp.now(io, .awake);
        return .{ .io = io, .at = now.addDuration(.fromNanoseconds(@intCast(ns))) };
    }

    /// Whether the limit has passed.
    pub fn expired(d: Deadline) bool {
        return std.Io.Timestamp.now(d.io, .awake).nanoseconds >= d.at.nanoseconds;
    }
};

/// Change marks over two id sequences, shared by the algorithms.
pub const Marks = struct {
    a: []const u32,
    b: []const u32,
    /// `ca[i]`: a[i] is deleted.
    ca: []bool,
    /// `cb[j]`: b[j] is inserted.
    cb: []bool,
    deadline: ?Deadline = null,
    /// Set once the deadline passed; later regions are marked wholesale.
    timed_out: bool = false,
    polls: u32 = 0,

    /// Marks with every element unchanged.
    pub fn init(gpa: Allocator, a: []const u32, b: []const u32, deadline: ?Deadline) Allocator.Error!Marks {
        const ca = try gpa.alloc(bool, a.len);
        errdefer gpa.free(ca);
        const cb = try gpa.alloc(bool, b.len);
        @memset(ca, false);
        @memset(cb, false);
        return .{ .a = a, .b = b, .ca = ca, .cb = cb, .deadline = deadline };
    }

    /// Frees the mark arrays.
    pub fn deinit(m: *Marks, gpa: Allocator) void {
        gpa.free(m.ca);
        gpa.free(m.cb);
    }

    /// Marks `a[alo..ahi]` deleted and `b[blo..bhi]` inserted.
    pub fn markAll(m: *Marks, alo: usize, ahi: usize, blo: usize, bhi: usize) void {
        @memset(m.ca[alo..ahi], true);
        @memset(m.cb[blo..bhi], true);
    }

    /// Polls the deadline (cheaply: one clock read per 16 calls).
    pub fn checkTime(m: *Marks) bool {
        if (m.timed_out) return true;
        const d = m.deadline orelse return false;
        m.polls +%= 1;
        if (m.polls % 16 != 0) return false;
        if (d.expired()) m.timed_out = true;
        return m.timed_out;
    }

    /// Shrinks a region by its common prefix and suffix.
    pub fn trim(m: *const Marks, alo: *usize, ahi: *usize, blo: *usize, bhi: *usize) void {
        while (alo.* < ahi.* and blo.* < bhi.* and m.a[alo.*] == m.b[blo.*]) {
            alo.* += 1;
            blo.* += 1;
        }
        while (alo.* < ahi.* and blo.* < bhi.* and m.a[ahi.* - 1] == m.b[bhi.* - 1]) {
            ahi.* -= 1;
            bhi.* -= 1;
        }
    }

    /// The run-length script for the marks.
    pub fn toScript(m: *const Marks, gpa: Allocator) Allocator.Error![]Edit {
        var out: std.ArrayList(Edit) = .empty;
        errdefer out.deinit(gpa);
        var i: usize = 0;
        var j: usize = 0;
        while (i < m.a.len or j < m.b.len) {
            if (i < m.a.len and m.ca[i]) {
                const s = i;
                while (i < m.a.len and m.ca[i]) i += 1;
                try push(&out, gpa, .delete, s, j, i - s);
            } else if (j < m.b.len and m.cb[j]) {
                const s = j;
                while (j < m.b.len and m.cb[j]) j += 1;
                try push(&out, gpa, .insert, i, s, j - s);
            } else {
                std.debug.assert(i < m.a.len and j < m.b.len and m.a[i] == m.b[j]);
                const si = i;
                const sj = j;
                while (i < m.a.len and j < m.b.len and !m.ca[i] and !m.cb[j]) {
                    i += 1;
                    j += 1;
                }
                try push(&out, gpa, .equal, si, sj, i - si);
            }
        }
        return out.toOwnedSlice(gpa);
    }
};

fn push(out: *std.ArrayList(Edit), gpa: Allocator, kind: Edit.Kind, a: usize, b: usize, len: usize) Allocator.Error!void {
    if (len == 0) return;
    if (out.items.len > 0) {
        const last = &out.items[out.items.len - 1];
        if (last.kind == kind) {
            last.len += @intCast(len);
            return;
        }
    }
    try out.append(gpa, .{ .kind = kind, .a_start = @intCast(a), .b_start = @intCast(b), .len = @intCast(len) });
}

/// Checks that `edits` turns `a` into `b` (tests and fuzzing).
pub fn validate(edits: []const Edit, a: []const u32, b: []const u32) bool {
    var i: usize = 0;
    var j: usize = 0;
    for (edits) |e| {
        if (e.a_start != i or e.b_start != j or e.len == 0) return false;
        switch (e.kind) {
            .equal => {
                if (i + e.len > a.len or j + e.len > b.len) return false;
                if (!std.mem.eql(u32, a[i..][0..e.len], b[j..][0..e.len])) return false;
                i += e.len;
                j += e.len;
            },
            .delete => i += e.len,
            .insert => j += e.len,
        }
    }
    return i == a.len and j == b.len;
}

/// Number of equal elements in a script.
pub fn equalCount(edits: []const Edit) usize {
    var n: usize = 0;
    for (edits) |e| if (e.kind == .equal) {
        n += e.len;
    };
    return n;
}
